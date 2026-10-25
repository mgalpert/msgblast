"""Offline archive/signing fixtures for the embedded CuaDriver build phase."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('bundle_cua_driver', Path(__file__).parents[1] / 'bundle_cua_driver.py')
helper = importlib.util.module_from_spec(SPEC)
if SPEC.loader is not None:
    SPEC.loader.exec_module(helper)

MEMBER = 'cua-driver-rs-0.38.0-darwin-arm64/cua-driver'

def archive(name=MEMBER, kind=tarfile.REGTYPE, duplicate=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as tar:
        entry = tarfile.TarInfo(name)
        entry.type = kind
        entry.size = 6 if kind == tarfile.REGTYPE else 0
        entry.linkname = '/tmp/unsafe'
        tar.addfile(entry, io.BytesIO(b'binary') if entry.size else None)
        if duplicate:
            tar.addfile(entry, io.BytesIO(b'binary'))
    return output.getvalue()

class BundleCuaDriverTests(unittest.TestCase):
    def asset(self, data):
        return {'url': 'https://example.invalid/driver.tgz', 'sha256': hashlib.sha256(data).hexdigest(), 'member': MEMBER}

    def test_checksum_validated_for_download_and_cached_archive(self):
        data = archive()
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            with mock.patch.object(helper.urllib.request, 'urlopen', return_value=io.BytesIO(data)) as download:
                self.assertEqual(helper.fetch_binary(self.asset(data), cache), b'binary')
                self.assertEqual(helper.fetch_binary(self.asset(data), cache), b'binary')
                self.assertEqual(download.call_count, 1)
            next(cache.glob('*.tgz')).write_bytes(b'tampered')
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                helper.fetch_binary(self.asset(data), cache)
            with mock.patch.object(helper.urllib.request, 'urlopen', return_value=io.BytesIO(b'tampered')):
                with self.assertRaisesRegex(RuntimeError, 'checksum'):
                    helper.fetch_binary(self.asset(data), cache / 'new')

    def test_only_exact_regular_executable_is_selected(self):
        for data in [archive('../cua-driver'), archive('other/cua-driver'), archive(kind=tarfile.SYMTYPE), archive(kind=tarfile.LNKTYPE), archive(duplicate=True)]:
            with self.subTest(data=data[:8]), tempfile.TemporaryDirectory() as temporary:
                with mock.patch.object(helper.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                    with self.assertRaisesRegex(RuntimeError, 'archive'):
                        helper.fetch_binary(self.asset(data), Path(temporary))

    def test_bundle_places_only_signed_helper_and_rejects_wrong_architecture(self):
        data = archive()
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            manifest = workspace / 'pin.json'
            manifest.write_text(json.dumps({'version': '0.38.0', 'assets': {'arm64': self.asset(data)}}))
            destination = workspace / 'msgblast.app/Contents/Helpers/cua-driver'
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if '-thin' in command:
                    Path(command[-1]).write_bytes(b'binary')
                return subprocess.CompletedProcess(command, 0)
            with mock.patch.object(helper, 'MANIFEST', manifest), mock.patch.object(helper.urllib.request, 'urlopen', return_value=io.BytesIO(data)), mock.patch.object(helper.subprocess, 'run', side_effect=run), mock.patch.dict(helper.os.environ, {'CODE_SIGNING_ALLOWED': 'NO'}):
                helper.bundle(['arm64'], destination, workspace / 'cache')
                self.assertEqual(destination.read_bytes(), b'binary')
                self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
                self.assertEqual(list(destination.parent.iterdir()), [destination])
                self.assertTrue(any(command[:5] == ['codesign', '--force', '--sign', '-', '--options'] for command in commands))
                destination.unlink()
                with mock.patch.object(helper.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'lipo')):
                    with self.assertRaises(subprocess.CalledProcessError):
                        helper.bundle(['arm64'], destination, workspace / 'cache')
                self.assertFalse(destination.exists())

    def test_universal_bundle_merges_slices_and_uses_build_signing_identity(self):
        data = archive()
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            manifest = workspace / 'pin.json'
            asset = self.asset(data)
            manifest.write_text(json.dumps({'version': '0.38.0', 'assets': {'arm64': asset, 'x86_64': asset}}))
            destination = workspace / 'app/Contents/Helpers/cua-driver'
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if '-output' in command:
                    Path(command[-1]).write_bytes(b'merged' if '-create' in command else b'slice')
                return subprocess.CompletedProcess(command, 0)
            with mock.patch.object(helper, 'MANIFEST', manifest), mock.patch.object(helper.urllib.request, 'urlopen', return_value=io.BytesIO(data)), mock.patch.object(helper.subprocess, 'run', side_effect=run), mock.patch.dict(helper.os.environ, {'CODE_SIGNING_ALLOWED': 'YES', 'EXPANDED_CODE_SIGN_IDENTITY': 'test-build-identity'}):
                helper.bundle(['arm64', 'x86_64'], destination, workspace / 'cache')
            self.assertEqual(destination.read_bytes(), b'merged')
            self.assertEqual([command[command.index('-thin') + 1] for command in commands if '-thin' in command], ['arm64', 'x86_64'])
            sign = next(command for command in commands if command[:2] == ['codesign', '--force'])
            self.assertEqual(sign[sign.index('--sign') + 1], 'test-build-identity')
            self.assertIn('--timestamp', sign)
            self.assertEqual(sum(command[:3] == ['codesign', '--verify', '--strict'] for command in commands), 1)

    def test_architectures_reject_unavailable_platforms(self):
        self.assertEqual(helper.architectures('arm64 x86_64 arm64'), ['arm64', 'x86_64'])
        for value in ['', 'i386', 'arm64 i386']:
            with self.assertRaisesRegex(RuntimeError, 'architecture'):
                helper.architectures(value)
