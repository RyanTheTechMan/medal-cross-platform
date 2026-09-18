#!/usr/bin/env python3
"""Prepare and atomically activate a supported user-owned Medal client for the native port.

This tool never runs the imported installer or its lifecycle scripts. It validates the pinned
build, copies into a same-filesystem staging directory, applies exact-count patches, records
pre/post hashes, and only then changes the `current` symlink atomically. Source inputs are read
only and previous prepared versions remain available for rollback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUPPORTED_PATH = ROOT / 'client_patch' / 'supported-builds.json'
EXTRACTOR_PATH = ROOT / 'research' / 'tools' / 'extract_medal.py'
BOOTSTRAP_PATH = ROOT / 'client_patch' / 'native-port-bootstrap.cjs'
DB_SELFTEST_PATH = ROOT / 'client_patch' / 'db-selftest-preload.cjs'
PROTOCOL_SELFTEST_PATH = ROOT / 'client_patch' / 'protocol-selftest-preload.cjs'
CAPTURE_SELFTEST_PATH = ROOT / 'client_patch' / 'capture-selftest-preload.cjs'
UPDATE_ADAPTER_PATH = ROOT / 'client_patch' / 'velopack-manual-adapter.js'
MAX_COPY_BYTES = 2 * 1024**3
NATIVE_HELPER_BUNDLE_ID = 'com.squirrel.medal.medal.recorder'


class ImportFailure(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f'.{path.name}.{uuid.uuid4().hex}.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def relative_collision_key(path: Path) -> str:
    return unicodedata.normalize('NFC', path.as_posix()).casefold()


def audit_copy_source(source: Path) -> dict[str, object]:
    if not source.is_dir():
        raise ImportFailure(f'extracted app directory is missing: {source}')
    collisions: dict[str, Path] = {}
    total = 0
    files = 0
    for root, directories, names in os.walk(source, followlinks=False):
        base = Path(root)
        for name in [*directories, *names]:
            target = base / name
            relative = target.relative_to(source)
            key = relative_collision_key(relative)
            if key in collisions:
                raise ImportFailure(f'case/Unicode target collision: {collisions[key]} and {relative}')
            collisions[key] = relative
            mode = target.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ImportFailure(f'symlinks are not accepted from imported content: {relative}')
            if not stat.S_ISDIR(mode) and not stat.S_ISREG(mode):
                raise ImportFailure(f'unsupported imported file type: {relative}')
            if stat.S_ISREG(mode):
                total += target.stat().st_size
                files += 1
                if total > MAX_COPY_BYTES:
                    raise ImportFailure('extracted client exceeds the copy size limit')
    return {'files': files, 'bytes': total}


def verify_supported_build(app: Path) -> tuple[str, dict[str, str]]:
    supported = json.loads(SUPPORTED_PATH.read_text())['builds']
    package_path = app / 'package.json'
    try:
        version = json.loads(package_path.read_text())['version']
        expected = supported[version]['files']
    except (OSError, KeyError, json.JSONDecodeError) as error:
        raise ImportFailure(f'unsupported or malformed client build: {error}') from error
    actual: dict[str, str] = {}
    for relative, expected_hash in expected.items():
        target = app / relative
        if not target.is_file():
            raise ImportFailure(f'required client file is missing: {relative}')
        actual_hash = sha256(target)
        actual[relative] = actual_hash
        if actual_hash != expected_hash:
            raise ImportFailure(
                f'unsupported patch predicate for {relative}: expected {expected_hash}, got {actual_hash}'
            )
    return version, actual


def exact_replace(path: Path, before: str, after: str, expected_count: int, patch_id: str,
                  logical_path: str) -> dict[str, object]:
    raw = path.read_text()
    count = raw.count(before)
    if count != expected_count:
        raise ImportFailure(f'{patch_id}: expected {expected_count} exact matches in {path.name}, found {count}')
    pre_hash = sha256(path)
    replaced = raw.replace(before, after)
    path.write_text(replaced)
    return {
        'id': patch_id,
        'file': logical_path,
        'matchCount': count,
        'preSha256': pre_hash,
        'postSha256': sha256(path),
    }


def copy_executable(source: Path, destination: Path) -> dict[str, object]:
    source = source.resolve(strict=True)
    if not source.is_file() or not os.access(source, os.X_OK):
        raise ImportFailure(f'native tool is not executable: {source}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # copy2 would copy macOS restricted system-file flags from /usr/bin tools, making the
    # staged copy immutable. The prepared artifact owns a fresh regular file and explicit mode.
    shutil.copyfile(source, destination)
    destination.chmod(0o755)
    return {
        'source': str(source),
        'sourceSha256': sha256(source),
        'destination': destination.relative_to(destination.parents[2]).as_posix(),
        'installedSha256': sha256(destination),
    }


def bundle_tree_sha256(bundle: Path) -> str:
    digest = hashlib.sha256()
    for target in sorted(bundle.rglob('*'), key=lambda item: item.relative_to(bundle).as_posix()):
        relative = target.relative_to(bundle).as_posix().encode()
        digest.update(len(relative).to_bytes(8, 'big'))
        digest.update(relative)
        mode = target.lstat().st_mode
        if stat.S_ISLNK(mode):
            link = os.readlink(target).encode()
            digest.update(b'L')
            digest.update(len(link).to_bytes(8, 'big'))
            digest.update(link)
        elif stat.S_ISDIR(mode):
            digest.update(b'D')
        elif stat.S_ISREG(mode):
            digest.update(b'F')
            digest.update(bytes.fromhex(sha256(target)))
        else:
            raise ImportFailure(f'unsupported native helper bundle entry: {relative.decode()}')
    return digest.hexdigest()


def code_signature_metadata(bundle: Path, expected_identifier: str) -> dict[str, str]:
    try:
        subprocess.run(
            ['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)],
            check=True,
            capture_output=True,
            text=True,
        )
        details = subprocess.run(
            ['/usr/bin/codesign', '-dvvv', str(bundle)],
            check=True,
            capture_output=True,
            text=True,
        ).stderr
        requirement_result = subprocess.run(
            ['/usr/bin/codesign', '-d', '--requirements', '-', str(bundle)],
            check=True,
            capture_output=True,
            text=True,
        )
        requirements = requirement_result.stdout + requirement_result.stderr
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or str(error)).strip()
        raise ImportFailure(f'native helper bundle signature is invalid: {detail}') from error
    fields: dict[str, str] = {}
    for line in details.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            fields[key] = value
    if fields.get('Identifier') != expected_identifier:
        raise ImportFailure(
            f'native helper bundle identifier must be {expected_identifier}, got {fields.get("Identifier")}'
        )
    if not fields.get('TeamIdentifier') or fields['TeamIdentifier'] == 'not set':
        raise ImportFailure('native helper must use a team-backed Apple Development signature before TCC testing')
    designated = next(
        (line.removeprefix('designated => ') for line in requirements.splitlines() if line.startswith('designated => ')),
        '',
    )
    if not designated:
        raise ImportFailure('native helper signature has no designated requirement')
    return {
        'identifier': fields['Identifier'],
        'teamIdentifier': fields['TeamIdentifier'],
        'authority': fields.get('Authority', ''),
        'designatedRequirement': designated,
    }


def copy_signed_helper_bundle(source: Path, destination: Path) -> dict[str, object]:
    source = source.resolve(strict=True)
    if not source.is_dir() or source.suffix != '.app':
        raise ImportFailure(f'native helper must be a signed .app bundle: {source}')
    info_path = source / 'Contents' / 'Info.plist'
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ImportFailure(f'native helper has an invalid Info.plist: {error}') from error
    if info.get('CFBundleIdentifier') != NATIVE_HELPER_BUNDLE_ID:
        raise ImportFailure(f'native helper Info.plist identifier must be {NATIVE_HELPER_BUNDLE_ID}')
    executable_name = info.get('CFBundleExecutable')
    executable = source / 'Contents' / 'MacOS' / str(executable_name)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ImportFailure(f'native helper bundle executable is missing: {executable}')
    signature = code_signature_metadata(source, NATIVE_HELPER_BUNDLE_ID)
    source_hash = bundle_tree_sha256(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    installed_signature = code_signature_metadata(destination, NATIVE_HELPER_BUNDLE_ID)
    if installed_signature != signature:
        raise ImportFailure('native helper signature metadata changed while copying into the prepared client')
    installed_hash = bundle_tree_sha256(destination)
    if installed_hash != source_hash:
        raise ImportFailure('native helper bundle changed while copying into the prepared client')
    return {
        'source': str(source),
        'sourceTreeSha256': source_hash,
        'destination': destination.relative_to(destination.parents[2]).as_posix(),
        'installedTreeSha256': installed_hash,
        'signature': signature,
    }


def apply_client_patch(stage_app: Path, addon: Path, native_helper: Path, sqlite3: Path, ffmpeg: Path, ffprobe: Path,
                       source_hashes: dict[str, str], version: str, source_audit: dict[str, object]) -> dict[str, object]:
    operations: list[dict[str, object]] = []
    index_path = stage_app / 'index.js'
    operations.append(exact_replace(
        index_path,
        "const { app, crashReporter } = require('electron')",
        "const { app, crashReporter } = require('electron')\nrequire('./native-port/bootstrap.cjs')",
        1,
        'bootstrap-before-client-main',
        'index.js',
    ))

    main_path = stage_app / 'main.min.js'
    operations.append(exact_replace(
        main_path,
        '"sqlite3.exe"',
        '"sqlite3"',
        3,
        'native-sqlite-cli-name',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'if (!refs_default.appPath) {\n    throw new Error(\\`failed to find sqlite3 native module! binding: \\${bindingDir}\\`);\n  }\n  const bindingRoot =',
        'if (!refs_default.appPath || process.platform !== "win32") {\n    throw new Error("native port sqlite binding missing; downloads are disabled for " + process.platform + "-" + process.arch + ": " + bindingDir);\n  }\n  const bindingRoot =',
        1,
        'disable-cross-platform-sqlite-asset-download',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'if(process.platform!=="win32")return bw.set(n,t),t;',
        'if(process.platform!=="win32"){const i=process.env.NATIVE_PORT_TOOLS_DIR;if(!i||!At.default.isAbsolute(i))throw new Error("NATIVE_PORT_TOOLS_DIR must be absolute");const s=At.default.join(i,t);if(!await Ht.default.pathExists(s))throw new Error(`missing packaged native tool: ${s}`);return bw.set(n,s),s}',
        1,
        'absolute-native-media-tools',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'process.platform==="darwin"&&!Ce.app.isInApplicationsFolder()&&Ce.app.moveToApplicationsFolder()',
        'process.platform==="darwin"&&!global.nativePort&&!Ce.app.isInApplicationsFolder()&&Ce.app.moveToApplicationsFolder()',
        1,
        'prevent-imported-client-self-install',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'verifyClient:({origin:t})=>!t',
        'verifyClient:({origin:t,req:n})=>!t&&n.headers["x-native-port-secret"]===process.env.NATIVE_PORT_SESSION_SECRET',
        1,
        'authenticated-loopback-recorder-websocket',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'r$.includes(t.method)||oe.logger.info(Gt.default.grey(`WebSocket message received: ${e}`))',
        'r$.includes(t.method)||oe.logger.info(Gt.default.grey(`WebSocket message received: ${t.method?"request "+t.method:"response"} id=${String(t.id??"none")}${t.error?" error="+String(t.error.code):""} payload=redacted`))',
        1,
        'redact-recorder-values-from-inbound-transport-log',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'n.method&&!r$.includes(n.method)&&oe.logger.info(Gt.default.grey(`WebSocket request sent: ${r}`))',
        'n.method&&!r$.includes(n.method)&&oe.logger.info(Gt.default.grey(`WebSocket request sent: method=${n.method} id=${String(n.id??"notification")} payload=redacted`))',
        1,
        'redact-recorder-values-from-outbound-transport-log',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'oe.logger.info(`setting ${t} to ${JSON.stringify(n)}`)',
        'oe.logger.info(`setting ${t} (${Array.isArray(n)?n.length+" items":"value present"})`)',
        1,
        'redact-recorder-device-values-from-state-log',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'S=function(F){return"Opening stream connection to "+F}',
        'S=function(F){return"Opening stream connection (URL redacted)"}',
        1,
        'redact-feature-stream-context-from-log',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'yt.info("Creating LaunchDarkly Client with key: "+e.key)',
        'yt.info("Creating LaunchDarkly Client (context redacted)")',
        1,
        'redact-feature-client-context-from-log',
        'main.min.js',
    ))
    operations.append(exact_replace(
        main_path,
        'async run(){if(process.platform!=="win32")return;try{',
        'async run(){if(process.platform!=="win32"){if(process.platform!=="darwin")return;await this.getRecorderPort();const t=["--electronPort",this.#i,"--environment",dn.getGenericReleaseChannel(),"--wsComms","--parentPid",process.pid];this.spawn({executablePath:process.env.NATIVE_PORT_RECORDER_EXE,executableArgs:t,reset:n=>(this.logger[n?"error":"info"](`native recorder exited with code: ${n}`),this.stateMachine.meta={...this.stateMachine.meta,didReset:!0},!1)}),un("lowDiskSpace",void 0);return}try{',
        1,
        'launch-native-recorder-with-selected-port',
        'main.min.js',
    ))

    bootstrap_destination = stage_app / 'native-port' / 'bootstrap.cjs'
    bootstrap_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(BOOTSTRAP_PATH, bootstrap_destination)
    shutil.copy2(DB_SELFTEST_PATH, stage_app / 'native-port' / 'db-selftest-preload.cjs')
    shutil.copy2(PROTOCOL_SELFTEST_PATH, stage_app / 'native-port' / 'protocol-selftest-preload.cjs')
    shutil.copy2(CAPTURE_SELFTEST_PATH, stage_app / 'native-port' / 'capture-selftest-preload.cjs')
    adapter_destination = stage_app / 'node_modules' / 'velopack' / 'lib' / 'index.js'
    adapter_pre = sha256(adapter_destination)
    shutil.copy2(UPDATE_ADAPTER_PATH, adapter_destination)
    operations.append({
        'id': 'manual-update-adapter-for-both-entry-points',
        'file': 'node_modules/velopack/lib/index.js',
        'matchCount': 1,
        'preSha256': adapter_pre,
        'postSha256': sha256(adapter_destination),
    })

    addon = addon.resolve(strict=True)
    addon_destination = stage_app / 'lib' / 'binding' / 'node-v148-darwin-arm64' / 'better_sqlite3.node'
    addon_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(addon, addon_destination)
    helper = copy_signed_helper_bundle(
        native_helper,
        stage_app / 'native-port' / 'bin' / 'NativeMedalRecorder.app',
    )
    tools_destination = stage_app / 'native-port' / 'tools'
    tools = [
        copy_executable(sqlite3, tools_destination / 'sqlite3'),
        copy_executable(ffmpeg, tools_destination / 'ffmpeg'),
        copy_executable(ffprobe, tools_destination / 'ffprobe'),
    ]

    manifest = {
        'schemaVersion': 1,
        'clientVersion': version,
        'portBuild': 'development-m3.2',
        'target': 'darwin-arm64',
        'electron': {'version': '43.2.0', 'modulesAbi': '148'},
        'sourceAudit': source_audit,
        'sourceHashes': source_hashes,
        'patches': operations,
        'nativeAddon': {
            'sourceSha256': sha256(addon),
            'installedSha256': sha256(addon_destination),
            'destination': 'lib/binding/node-v148-darwin-arm64/better_sqlite3.node',
        },
        'nativeHelper': helper,
        'clientPatchFiles': {
            'native-port/bootstrap.cjs': sha256(bootstrap_destination),
            'native-port/db-selftest-preload.cjs': sha256(stage_app / 'native-port' / 'db-selftest-preload.cjs'),
            'native-port/protocol-selftest-preload.cjs': sha256(
                stage_app / 'native-port' / 'protocol-selftest-preload.cjs'
            ),
            'native-port/capture-selftest-preload.cjs': sha256(
                stage_app / 'native-port' / 'capture-selftest-preload.cjs'
            ),
        },
        'tools': tools,
        'updatePolicy': 'manual_verified_import_only',
        'recorderPolicy': 'native_helper_only_no_download',
    }
    atomic_json(stage_app / 'native-port' / 'patch-manifest.json', manifest)
    return manifest


def activate(install_root: Path, version_directory: Path) -> dict[str, object]:
    versions = (install_root / 'versions').resolve()
    resolved_version = version_directory.resolve(strict=True)
    if resolved_version.parent != versions:
        raise ImportFailure('activation target must be an immediate child of the versions directory')
    relative_target = Path('versions') / resolved_version.name
    current = install_root / 'current'
    previous = install_root / 'previous'
    old_target: str | None = None
    if current.is_symlink():
        old_target = os.readlink(current)
        old_resolved = (install_root / old_target).resolve(strict=True)
        if old_resolved.parent != versions:
            raise ImportFailure('existing current link escapes the managed versions directory')
    elif current.exists():
        raise ImportFailure('current activation path is not a managed symlink')

    if old_target and old_target != relative_target.as_posix():
        next_previous = install_root / f'.previous.{uuid.uuid4().hex}.tmp'
        next_previous.symlink_to(old_target)
        os.replace(next_previous, previous)
    next_current = install_root / f'.current.{uuid.uuid4().hex}.tmp'
    next_current.symlink_to(relative_target)
    os.replace(next_current, current)
    state = {
        'current': relative_target.as_posix(),
        'previous': old_target if old_target != relative_target.as_posix() else None,
    }
    atomic_json(install_root / 'activation.json', state)
    return state


def prepare(args: argparse.Namespace) -> dict[str, object]:
    install_root = args.install_root.resolve()
    install_root.mkdir(parents=True, exist_ok=True)
    versions = install_root / 'versions'
    versions.mkdir(exist_ok=True)

    extracted_temp: Path | None = None
    extraction_report: dict[str, object] | None = None
    if args.installer:
        installer = args.installer.resolve(strict=True)
        extracted_temp = Path(tempfile.mkdtemp(prefix='.native-port-extracted-', dir=install_root))
        extracted_output = extracted_temp / 'payload'
        subprocess.run(
            [sys.executable, str(EXTRACTOR_PATH), str(installer), '--out', str(extracted_output)],
            check=True,
            capture_output=True,
            text=True,
        )
        extraction_report = json.loads((extracted_output / 'extraction-report.json').read_text())
        source_app = extracted_output / 'app'
    else:
        source_app = args.extracted_app.resolve(strict=True)

    stage = install_root / f'.stage-{uuid.uuid4().hex}'
    try:
        source_audit = audit_copy_source(source_app)
        version, source_hashes = verify_supported_build(source_app)
        version_name = f'{version}-native-port-m3.2'
        final_version = versions / version_name
        shutil.copytree(source_app, stage, symlinks=False)
        manifest = apply_client_patch(
            stage,
            args.native_addon,
            args.native_helper,
            args.sqlite3,
            args.ffmpeg,
            args.ffprobe,
            source_hashes,
            version,
            source_audit,
        )
        if final_version.exists():
            existing_manifest_path = final_version / 'native-port' / 'patch-manifest.json'
            if not existing_manifest_path.is_file() or json.loads(existing_manifest_path.read_text()) != manifest:
                raise ImportFailure(f'prepared version already exists with different contents: {final_version}')
            shutil.rmtree(stage)
            idempotent = True
        else:
            os.rename(stage, final_version)
            idempotent = False
        activation = activate(install_root, final_version) if args.activate else None
        result = {
            'status': 'prepared',
            'idempotent': idempotent,
            'sourceExtraction': extraction_report,
            'versionDirectory': str(final_version),
            'manifest': str(final_version / 'native-port' / 'patch-manifest.json'),
            'activation': activation,
        }
        print(json.dumps(result, indent=2))
        return result
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        if extracted_temp and extracted_temp.exists():
            shutil.rmtree(extracted_temp)


def rollback(args: argparse.Namespace) -> dict[str, object]:
    install_root = args.install_root.resolve(strict=True)
    previous = install_root / 'previous'
    if not previous.is_symlink():
        raise ImportFailure('no previous prepared version is available')
    target = (install_root / os.readlink(previous)).resolve(strict=True)
    state = activate(install_root, target)
    result = {'status': 'rolled_back', 'activation': state}
    print(json.dumps(result, indent=2))
    return result


def inspect(args: argparse.Namespace) -> dict[str, object]:
    app = args.extracted_app.resolve(strict=True)
    source_audit = audit_copy_source(app)
    version, hashes = verify_supported_build(app)
    result = {'status': 'supported', 'version': version, 'sourceAudit': source_audit, 'hashes': hashes}
    print(json.dumps(result, indent=2))
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest='command', required=True)
    inspect_parser = commands.add_parser('inspect')
    inspect_parser.add_argument('--extracted-app', type=Path, required=True)
    inspect_parser.set_defaults(function=inspect)

    prepare_parser = commands.add_parser('prepare')
    source = prepare_parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--installer', type=Path)
    source.add_argument('--extracted-app', type=Path)
    prepare_parser.add_argument('--install-root', type=Path, required=True)
    prepare_parser.add_argument('--native-addon', type=Path, required=True)
    prepare_parser.add_argument('--native-helper', type=Path, required=True)
    prepare_parser.add_argument('--sqlite3', type=Path, required=True)
    prepare_parser.add_argument('--ffmpeg', type=Path, required=True)
    prepare_parser.add_argument('--ffprobe', type=Path, required=True)
    prepare_parser.add_argument('--activate', action='store_true')
    prepare_parser.set_defaults(function=prepare)

    rollback_parser = commands.add_parser('rollback')
    rollback_parser.add_argument('--install-root', type=Path, required=True)
    rollback_parser.set_defaults(function=rollback)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.function(args)
        return 0
    except (ImportFailure, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f'native port import failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
