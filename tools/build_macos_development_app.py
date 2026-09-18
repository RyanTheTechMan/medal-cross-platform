#!/usr/bin/env python3
"""Build an atomically versioned, Apple-Development-signed local Electron app.

This is a development/TCC identity builder, not a release or notarization tool. The user-imported
Medal payload stays in the ignored local artifacts tree and is never emitted by this script as a
redistributable package.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ENTITLEMENTS = ROOT / 'packaging' / 'macos' / 'electron-development.entitlements.plist'
CLIENT_BUNDLE_ID = 'com.squirrel.medal.medal'
RECORDER_BUNDLE_ID = 'com.squirrel.medal.medal.recorder'
ELECTRON_HELPER_IDS = {
    'Electron Helper.app': f'{CLIENT_BUNDLE_ID}.helper',
    'Electron Helper (Renderer).app': f'{CLIENT_BUNDLE_ID}.helper.renderer',
    'Electron Helper (GPU).app': f'{CLIENT_BUNDLE_ID}.helper.gpu',
    'Electron Helper (Plugin).app': f'{CLIENT_BUNDLE_ID}.helper.plugin',
}


class BuildFailure(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, stderr: bool = False) -> str:
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or str(error)).strip()
        raise BuildFailure(f'command failed ({" ".join(command)}): {detail}') from error
    return result.stderr if stderr else result.stdout


def plist(path: Path) -> dict[str, object]:
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise BuildFailure(f'invalid property list {path}: {error}') from error


def write_plist(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_name(f'.{path.name}.{uuid.uuid4().hex}.tmp')
    with temporary.open('wb') as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_XML, sort_keys=True)
    os.replace(temporary, path)


def validate_identity(identity: str) -> str:
    listing = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
    match = re.search(rf'\b{re.escape(identity)}\b\s+"([^"]+)"', listing, re.IGNORECASE)
    if match is None:
        raise BuildFailure(f'codesigning identity {identity} is not currently valid in the keychain')
    common_name = match.group(1)
    if not common_name.startswith('Apple Development:'):
        raise BuildFailure(f'development app must use an Apple Development identity, got {common_name}')
    return common_name


def signature_metadata(bundle: Path, expected_identifier: str) -> dict[str, str]:
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)], stderr=True)
    details = run(['/usr/bin/codesign', '-dvvv', str(bundle)], stderr=True)
    requirement_result = subprocess.run(
        ['/usr/bin/codesign', '-d', '--requirements', '-', str(bundle)],
        check=True,
        capture_output=True,
        text=True,
    )
    requirements = requirement_result.stdout + requirement_result.stderr
    fields: dict[str, str] = {}
    authorities: list[str] = []
    for line in details.splitlines():
        if line.startswith('Authority='):
            authorities.append(line.split('=', 1)[1])
        elif '=' in line:
            key, value = line.split('=', 1)
            fields[key] = value
    if fields.get('Identifier') != expected_identifier:
        raise BuildFailure(f'{bundle} identifier is {fields.get("Identifier")}, expected {expected_identifier}')
    team = fields.get('TeamIdentifier')
    if not team or team == 'not set':
        raise BuildFailure(f'{bundle} does not have a team-backed signing identity')
    designated = next(
        (line.removeprefix('designated => ') for line in requirements.splitlines() if line.startswith('designated => ')),
        '',
    )
    if not designated:
        raise BuildFailure(f'{bundle} has no designated requirement')
    return {
        'identifier': expected_identifier,
        'teamIdentifier': team,
        'authorities': ' | '.join(authorities),
        'designatedRequirement': designated,
    }


def sign(identity: str, target: Path, entitlements: Path | None = None) -> None:
    command = [
        '/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', identity,
    ]
    if entitlements is not None:
        command.extend(['--entitlements', str(entitlements)])
    command.append(str(target))
    run(command, stderr=True)


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        magic = path.open('rb').read(4)
    except OSError:
        return False
    return magic in {
        b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
        b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
    }


def customize_plists(app: Path) -> None:
    main_path = app / 'Contents' / 'Info.plist'
    main = plist(main_path)
    main.update({
        'CFBundleDisplayName': 'Medal',
        'CFBundleIdentifier': CLIENT_BUNDLE_ID,
        'CFBundleIconFile': 'Medal.icns',
        'CFBundleName': 'Medal',
        'LSApplicationCategoryType': 'public.app-category.video',
        'NSAudioCaptureUsageDescription': (
            'Native Medal captures audio only for a recording source you select in the system sharing picker.'
        ),
        'NSCameraUsageDescription': 'Native Medal uses a camera only when you enable a camera overlay.',
        'NSMicrophoneUsageDescription': (
            'Native Medal captures your selected microphone only when microphone recording is enabled.'
        ),
    })
    main.pop('ElectronAsarIntegrity', None)
    write_plist(main_path, main)

    frameworks = app / 'Contents' / 'Frameworks'
    for name, identifier in ELECTRON_HELPER_IDS.items():
        info_path = frameworks / name / 'Contents' / 'Info.plist'
        helper = plist(info_path)
        helper['CFBundleIdentifier'] = identifier
        write_plist(info_path, helper)


def install_imported_medal_icon(app: Path) -> dict[str, str]:
    resources = app / 'Contents' / 'Resources'
    source = resources / 'app' / 'src' / 'assets' / 'icon' / 'MedalApp.png'
    if not source.is_file():
        raise BuildFailure(f'imported Medal icon is missing: {source}')
    destination = resources / 'Medal.icns'
    with tempfile.TemporaryDirectory(prefix='native-medal-icon-') as temporary:
        iconset = Path(temporary) / 'Medal.iconset'
        iconset.mkdir()
        sizes = {
            16: ['icon_16x16.png'],
            32: ['icon_16x16@2x.png', 'icon_32x32.png'],
            64: ['icon_32x32@2x.png'],
            128: ['icon_128x128.png'],
            256: ['icon_128x128@2x.png', 'icon_256x256.png'],
            512: ['icon_256x256@2x.png', 'icon_512x512.png'],
            1024: ['icon_512x512@2x.png'],
        }
        for size, names in sizes.items():
            generated = iconset / names[0]
            run(['/usr/bin/sips', '-z', str(size), str(size), str(source), '--out', str(generated)])
            for name in names[1:]:
                shutil.copyfile(generated, iconset / name)
        run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(destination)])
    return {'sourceSha256': sha256(source), 'installedSha256': sha256(destination)}


def sign_inside_out(app: Path, identity: str) -> None:
    resources = app / 'Contents' / 'Resources'
    for target in sorted(resources.rglob('*')):
        if is_macho(target):
            sign(identity, target)

    frameworks = app / 'Contents' / 'Frameworks'
    # Hardened runtime library validation requires every non-platform Electron framework image,
    # including libffmpeg and the framework executables, to carry the same development team.
    for target in sorted(frameworks.rglob('*')):
        if is_macho(target):
            sign(identity, target)
    nested_frameworks = sorted(frameworks.glob('*.framework'), key=lambda item: len(item.parts), reverse=True)
    for target in nested_frameworks:
        sign(identity, target)
    for name in ELECTRON_HELPER_IDS:
        sign(identity, frameworks / name, ENTITLEMENTS)

    recorder = resources / 'app' / 'native-port' / 'bin' / 'NativeMedalRecorder.app'
    if not recorder.is_dir():
        raise BuildFailure(f'prepared client is missing its recorder bundle: {recorder}')
    sign(identity, recorder)
    sign(identity, app, ENTITLEMENTS)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], stderr=True)


def activate(install_root: Path, version_directory: Path) -> None:
    relative = Path('versions') / version_directory.name / 'Medal.app'
    link = install_root / f'.current.{uuid.uuid4().hex}.tmp'
    link.symlink_to(relative)
    os.replace(link, install_root / 'current')


def build(args: argparse.Namespace) -> dict[str, object]:
    identity_name = validate_identity(args.signing_identity)
    electron = args.electron_app.resolve(strict=True)
    prepared = args.prepared_client.resolve(strict=True)
    install_root = args.install_root.resolve()
    if electron.suffix != '.app' or not (electron / 'Contents' / 'MacOS' / 'Electron').is_file():
        raise BuildFailure(f'not an Electron application bundle: {electron}')
    manifest_path = prepared / 'native-port' / 'patch-manifest.json'
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise BuildFailure(f'prepared client manifest is missing or invalid: {error}') from error
    if manifest.get('portBuild') != 'development-m3.2' or manifest.get('target') != 'darwin-arm64':
        raise BuildFailure('development app requires a development-m3.2 darwin-arm64 prepared client')

    fingerprint = hashlib.sha256()
    for target in (manifest_path, electron / 'Contents' / 'MacOS' / 'Electron', Path(__file__), ENTITLEMENTS):
        fingerprint.update(bytes.fromhex(sha256(target)))
    version_key = f'{manifest["clientVersion"]}-{manifest["portBuild"]}-{fingerprint.hexdigest()[:16]}'
    versions = install_root / 'versions'
    install_root.mkdir(parents=True, exist_ok=True)
    versions.mkdir(exist_ok=True)
    version_directory = versions / version_key
    final_app = version_directory / 'Medal.app'
    idempotent = final_app.is_dir()
    if not idempotent:
        stage = install_root / f'.stage-{uuid.uuid4().hex}'
        try:
            stage.mkdir()
            stage_app = stage / final_app.name
            shutil.copytree(electron, stage_app, symlinks=True)
            resources = stage_app / 'Contents' / 'Resources'
            default_app = resources / 'default_app.asar'
            if default_app.exists():
                default_app.unlink()
            shutil.copytree(prepared, resources / 'app', symlinks=True)
            customize_plists(stage_app)
            install_imported_medal_icon(stage_app)
            sign_inside_out(stage_app, args.signing_identity)
            os.rename(stage, version_directory)
        finally:
            if stage.exists():
                shutil.rmtree(stage)

    client_signature = signature_metadata(final_app, CLIENT_BUNDLE_ID)
    recorder = final_app / 'Contents' / 'Resources' / 'app' / 'native-port' / 'bin' / 'NativeMedalRecorder.app'
    recorder_signature = signature_metadata(recorder, RECORDER_BUNDLE_ID)
    if client_signature['teamIdentifier'] != recorder_signature['teamIdentifier']:
        raise BuildFailure('client and recorder were not signed by the same development team')
    activate(install_root, version_directory)
    result: dict[str, object] = {
        'schemaVersion': 1,
        'status': 'ready_for_manual_tcc_prerequisite',
        'releaseStatus': 'local_development_only_not_notarized',
        'idempotent': idempotent,
        'versionKey': version_key,
        'app': str(final_app),
        'current': str(install_root / 'current'),
        'preparedClientManifestSha256': sha256(manifest_path),
        'signingIdentityFingerprint': args.signing_identity.upper(),
        'signingIdentityCommonName': identity_name,
        'upstreamWindowsAppUserModelId': CLIENT_BUNDLE_ID,
        'icon': {
            'sourceSha256': sha256(final_app / 'Contents' / 'Resources' / 'app' / 'src' / 'assets' / 'icon' / 'MedalApp.png'),
            'installedSha256': sha256(final_app / 'Contents' / 'Resources' / 'Medal.icns'),
        },
        'client': client_signature,
        'recorder': recorder_signature,
        'manualTccPrerequisite': (
            'Launch this exact signed development app as the interactive user and approve only the individual '
            'macOS prompts/settings needed by the test. Do not reset TCC or disable macOS security.'
        ),
    }
    report_path = version_directory / 'development-signing-report.json'
    temporary = report_path.with_name(f'.{report_path.name}.{uuid.uuid4().hex}.tmp')
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, report_path)
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--electron-app', type=Path, required=True)
    result.add_argument('--prepared-client', type=Path, required=True)
    result.add_argument('--install-root', type=Path, required=True)
    result.add_argument('--signing-identity', required=True, help='40-hex Apple Development certificate fingerprint')
    return result


def main() -> int:
    try:
        build(parser().parse_args())
        return 0
    except (BuildFailure, OSError) as error:
        print(f'development app build failed: {error}', file=os.sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
