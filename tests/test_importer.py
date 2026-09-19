#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import shutil
import stat
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


extractor = load('extract_medal', ROOT / 'research' / 'tools' / 'extract_medal.py')
importer = load('native_port_importer', ROOT / 'tools' / 'native_port_importer.py')


class ImporterSecurityTests(unittest.TestCase):
    def test_rejects_traversal_absolute_drive_and_nul_paths(self):
        for hostile in ('../escape', '/absolute', 'C:\\escape', 'ok/../escape', 'nul\0name'):
            with self.subTest(hostile=hostile), self.assertRaises(ValueError):
                extractor.safe_relative(hostile)

    def test_collision_key_covers_case_and_unicode_normalization(self):
        self.assertEqual(
            extractor.collision_key(Path('Assets/CAFÉ.png')),
            extractor.collision_key(Path('assets/CAFE\u0301.png')),
        )

    def test_zip_policy_rejects_symlink_duplicate_and_bomb(self):
        regular = zipfile.ZipInfo('safe/file')
        regular.file_size = 4
        regular.compress_size = 4

        duplicate = zipfile.ZipInfo('SAFE/FILE')
        duplicate.file_size = 4
        duplicate.compress_size = 4
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            extractor.validate_zip_infos([regular, duplicate])

        symlink = zipfile.ZipInfo('link')
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        symlink.file_size = 4
        symlink.compress_size = 4
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            extractor.validate_zip_infos([symlink])

        bomb = zipfile.ZipInfo('bomb')
        bomb.file_size = 8 * 1024**2
        bomb.compress_size = 1
        with self.assertRaisesRegex(ValueError, 'compression ratio'):
            extractor.validate_zip_infos([bomb])

    def test_copy_audit_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'file').write_text('safe')
            (root / 'link').symlink_to(root / 'file')
            with self.assertRaisesRegex(importer.ImportFailure, 'symlinks'):
                importer.audit_copy_source(root)

    def test_patch_predicate_failure_is_non_mutating(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'main.js'
            target.write_text('known anchor once')
            before = importer.sha256(target)
            with self.assertRaisesRegex(importer.ImportFailure, 'expected 2 exact matches'):
                importer.exact_replace(target, 'known anchor', 'replacement', 2, 'test', 'main.js')
            self.assertEqual(importer.sha256(target), before)

    def test_unknown_build_refusal_preserves_active_install(self):
        source = ROOT / 'research' / 'extracted-macos-m0' / 'app'
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            copied = temporary / 'changed-app'
            shutil.copytree(source, copied)
            with (copied / 'index.js').open('a') as stream:
                stream.write('\n// upstream changed')
            managed = temporary / 'managed'
            old_version = managed / 'versions' / 'old'
            old_version.mkdir(parents=True)
            (old_version / 'marker').write_text('preserve me')
            (managed / 'current').symlink_to(Path('versions') / 'old')
            with self.assertRaisesRegex(importer.ImportFailure, 'unsupported patch predicate'):
                importer.verify_supported_build(copied)
            self.assertEqual(os.readlink(managed / 'current'), 'versions/old')
            self.assertEqual((managed / 'current' / 'marker').read_text(), 'preserve me')

    def test_wave_resource_scanner_honors_riff_bounds(self):
        payload = b'WAVEfmt ' + b'\x00' * 16
        valid = b'RIFF' + struct.pack('<I', len(payload)) + payload
        truncated = b'RIFF' + struct.pack('<I', 4096) + b'WAVEshort'
        self.assertEqual(importer.wave_resources(b'prefix' + valid + truncated), [valid])


if __name__ == '__main__':
    unittest.main(verbosity=2)
