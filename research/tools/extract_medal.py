#!/usr/bin/env python3
"""Read-only, version-pinned extraction for the inspected Medal installer.
Does not run Windows binaries, install anything, download dependencies or launch Medal.
"""
from __future__ import annotations
import argparse, hashlib, json, os, shutil, stat, struct, sys, tempfile, unicodedata, zipfile
from pathlib import Path, PurePosixPath

KNOWN_INSTALLER = 'e6477e89f968593fe4b8335f09fc25f81889dd412c28ff85522a0a37415decdb'
MAX_TOTAL = 2 * 1024**3
MAX_MEMBER = 512 * 1024**2
MAX_COMPRESSION_RATIO = 200

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def safe_relative(name: str) -> Path:
    # Treat both slash styles as separators, including on POSIX hosts.
    s = name.replace('\\', '/')
    p = PurePosixPath(s)
    if not s or p.is_absolute() or any(x in ('..', '.') or ':' in x or '\x00' in x for x in p.parts):
        raise ValueError(f'Unsafe archive path: {name!r}')
    return Path(*p.parts)

def collision_key(path: Path) -> str:
    return unicodedata.normalize('NFC', path.as_posix()).casefold()

def validate_zip_infos(infos: list[zipfile.ZipInfo]) -> None:
    if sum(i.file_size for i in infos) > MAX_TOTAL: raise ValueError('Archive size limit exceeded')
    names = set()
    for i in infos:
        relative = safe_relative(i.filename)
        normalized = collision_key(relative)
        if normalized in names: raise ValueError('Duplicate archive entry')
        names.add(normalized)
        if stat.S_ISLNK(i.external_attr >> 16): raise ValueError('Symlink entry is not supported')
        if i.file_size > MAX_MEMBER: raise ValueError('Archive member size limit exceeded')
        if i.file_size > 1024**2 and i.file_size / max(1, i.compress_size) > MAX_COMPRESSION_RATIO:
            raise ValueError('Suspicious archive compression ratio')

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('installer', type=Path)
    ap.add_argument('--out', type=Path, required=True, help='New, nonexistent output directory')
    ap.add_argument('--allow-unknown', action='store_true', help='Inspection only; tests remain pinned to the inspected client')
    args = ap.parse_args()
    installer = args.installer.resolve(strict=True)
    if args.out.exists(): raise ValueError('Output must not exist; original input and existing profiles are never overwritten')
    digest = sha256(installer)
    if digest != KNOWN_INSTALLER and not args.allow_unknown:
        raise ValueError('Unknown installer SHA-256. Use --allow-unknown only to inspect a different build; do not apply known-build patches.')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix='.medal-extract-', dir=args.out.parent))
    report = {'installer_sha256': digest, 'known_build': digest == KNOWN_INSTALLER,
              'packed_integrity_verified': 0, 'unpacked_integrity_mismatches': [], 'files': 0}
    try:
        with zipfile.ZipFile(installer) as z:
            infos = z.infolist()
            validate_zip_infos(infos)
            report['archive_entries'] = len(infos)
            report['electron_version'] = z.read('lib/app/version').decode().strip()
            prefix = 'lib/app/resources/'
            for i in infos:
                if i.is_dir() or not i.filename.startswith(prefix): continue
                dest = tmp / safe_relative(i.filename[len(prefix):])
                dest.parent.mkdir(parents=True, exist_ok=True)
                with z.open(i) as src, dest.open('xb') as dst: shutil.copyfileobj(src, dst)
        asar = (tmp/'app.asar').read_bytes()
        if len(asar) < 16: raise ValueError('Truncated ASAR')
        size, header_size, pickle_size, json_size = struct.unpack_from('<IIII', asar)
        base = 8 + header_size
        if size != 4 or not 16 <= 16+json_size <= base <= len(asar): raise ValueError('Invalid ASAR header bounds')
        header = json.loads(asar[16:16+json_size])
        seen = set()
        def walk(files: dict, parent: Path = Path()) -> None:
            for name, info in files.items():
                part = safe_relative(name)
                if len(part.parts) != 1: raise ValueError('Invalid nested ASAR member name')
                rel = parent / part
                if 'files' in info:
                    walk(info['files'], rel); continue
                if 'link' in info: raise ValueError(f'ASAR link not supported: {rel}')
                # Case-insensitive targets need this guard, even on Linux extraction hosts.
                target_key = collision_key(rel)
                if target_key in seen: raise ValueError(f'Case/Unicode collision: {rel}')
                seen.add(target_key)
                n = int(info['size'])
                if n < 0 or n > MAX_MEMBER: raise ValueError('Invalid ASAR member size')
                if info.get('unpacked'):
                    data = (tmp/'app.asar.unpacked'/rel).read_bytes()
                else:
                    off = base + int(info['offset'])
                    if off < base or off+n > len(asar): raise ValueError('Invalid ASAR data bounds')
                    data = asar[off:off+n]
                integ = info.get('integrity', {})
                good_size = len(data) == n
                good_hash = integ.get('algorithm') != 'SHA256' or hashlib.sha256(data).hexdigest() == integ['hash']
                if info.get('unpacked'):
                    if not good_size or not good_hash:
                        report['unpacked_integrity_mismatches'].append(str(rel))
                elif not good_size or not good_hash: raise ValueError(f'ASAR integrity failed: {rel}')
                elif integ.get('algorithm') == 'SHA256': report['packed_integrity_verified'] += 1
                dest = tmp/'app'/rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
                if info.get('executable'): dest.chmod(0o755)
                report['files'] += 1
        walk(header['files'])
        report['main_sha256'] = sha256(tmp/'app/main.min.js')
        (tmp/'extraction-report.json').write_text(json.dumps(report, indent=2)+'\n')
        os.rename(tmp, args.out)
        print(json.dumps(report, indent=2))
        print(f'Extracted app: {args.out / "app"}')
        print('This is NOT a runnable native port. See PATCH_PLAN.json and README.md.')
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
        print(f'Extraction failed: {e}', file=sys.stderr); sys.exit(1)
