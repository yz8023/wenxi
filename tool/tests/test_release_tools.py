import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tool' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


public = load('public_files', 'check_public_files.py')
release = load('release_assets', 'package-release.py')
settings = load('release_settings', 'prepare-ci-release.py')


class PublicFilesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'source'
        self.root.mkdir()
        (self.root / '.gitignore').write_text('/logs/\n/.local/\n', encoding='utf-8')
        (self.root / 'main.dart').write_text('void main() {}\n', encoding='utf-8')

    def test_private_backups_are_excluded_from_export(self):
        (self.root / 'logs').mkdir()
        (self.root / 'logs/account-backup-1.json').write_text('{}', encoding='utf-8')
        target = self.root.parent / 'public'
        report = public.check(self.root, export=target)
        self.assertTrue(report['passed'])
        self.assertTrue((target / 'main.dart').is_file())
        self.assertFalse((target / 'logs').exists())
        self.assertFalse((self.root / '.git').exists())

    def test_misplaced_backup_is_rejected_without_exporting(self):
        (self.root / 'app-backup-42.json').write_text('{}', encoding='utf-8')
        report = public.check(self.root)
        self.assertFalse(report['passed'])
        target = self.root.parent / 'public'
        with self.assertRaises(ValueError):
            public.check(self.root, export=target)
        self.assertFalse(target.exists())

    def test_renamed_encrypted_account_backup_is_rejected(self):
        (self.root / 'sample.json').write_text(json.dumps({
            'format': 'asterlink-backup-v1', 'ciphertext': 'synthetic-data',
        }), encoding='utf-8')
        report = public.check(self.root)
        self.assertFalse(report['passed'])
        self.assertIn('account-backup-content', [item['rule'] for item in report['findings']])

    def test_staged_blob_is_checked_even_when_working_copy_is_clean(self):
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        secret = 'gh' + 'p_' + 'A1b2' * 10
        (self.root / 'config.txt').write_text(secret, encoding='utf-8')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        (self.root / 'config.txt').write_text('clean working copy', encoding='utf-8')
        report = public.check(self.root, staged=True)
        self.assertFalse(report['passed'])
        self.assertIn('github-token', [item['rule'] for item in report['findings']])
        self.assertNotIn(secret, json.dumps(report))

    def test_reviewed_backup_vector_requires_explicit_rule_and_exact_hash(self):
        path = 'test/fixtures/compatibility.json'
        fixture = self.root / path
        fixture.parent.mkdir(parents=True)
        data = b'{"format":"wenxi-backup-v1","data":"synthetic"}\n'
        fixture.write_bytes(data)
        (self.root / 'tool').mkdir()
        allowlist = self.root / 'tool/public-fixtures.json'
        review = {'sha256': hashlib.sha256(data).hexdigest(), 'reason': 'synthetic vector'}
        allowlist.write_text(json.dumps({path: review}), encoding='utf-8')
        self.assertFalse(public.check(self.root)['passed'])
        review['rules'] = ['account-backup-content']
        allowlist.write_text(json.dumps({path: review}), encoding='utf-8')
        self.assertTrue(public.check(self.root)['passed'])
        fixture.write_bytes(data.replace(b'synthetic', b'changed'))
        self.assertFalse(public.check(self.root)['passed'])
        fixture.write_bytes(data)
        (self.root / 'renamed.json').write_bytes(data)
        self.assertFalse(public.check(self.root)['passed'])

    def test_ignored_but_already_tracked_backup_is_rejected(self):
        subprocess.run(['git', 'init', '--quiet', str(self.root)], check=True)
        (self.root / 'logs').mkdir()
        (self.root / 'logs/accounts.json').write_text('{}', encoding='utf-8')
        subprocess.run(['git', '-C', str(self.root), 'add', '-f', 'logs/accounts.json'], check=True)
        self.assertFalse(public.check(self.root, staged=True)['passed'])

    def test_reviewed_fixture_is_bound_to_its_hash(self):
        (self.root / 'tool').mkdir()
        data = b'-----BEGIN ' + b'PRIVATE KEY-----\nsynthetic\n'
        fixture = self.root / 'fixture.txt'
        fixture.write_bytes(data)
        (self.root / 'tool/public-fixtures.json').write_text(json.dumps({
            'fixture.txt': {'sha256': hashlib.sha256(data).hexdigest(), 'reason': 'synthetic test'},
        }), encoding='utf-8')
        self.assertTrue(public.check(self.root)['passed'])
        fixture.write_bytes(data.replace(b'\n', b'\r\n'))
        self.assertTrue(public.check(self.root)['passed'])
        fixture.write_bytes(data + b'changed')
        self.assertFalse(public.check(self.root)['passed'])

    def test_existing_export_directory_is_never_overwritten(self):
        target = self.root.parent / 'public'
        target.mkdir()
        (target / 'keep.txt').write_text('keep', encoding='utf-8')
        with self.assertRaises(ValueError):
            public.check(self.root, export=target)
        self.assertEqual((target / 'keep.txt').read_text(encoding='utf-8'), 'keep')


class ReleaseFilesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'pubspec.yaml').write_text('version: 1.2.3+4\n', encoding='utf-8')

    def test_apk_name_and_checksum_include_the_build_number(self):
        apk = self.root / 'build/app/outputs/flutter-apk/app-release.apk'
        apk.parent.mkdir(parents=True)
        apk.write_bytes(b'synthetic-apk')
        output = release.stage(self.root, 'android')
        self.assertEqual(release.checksums(output), 1)
        expected = hashlib.sha256(b'synthetic-apk').hexdigest()
        self.assertEqual((output / 'SHA256SUMS.txt').read_text(encoding='utf-8'),
                         expected + '  asterlink-1.2.3+4-android-arm64.apk\n')
        with self.assertRaises(ValueError):
            release.stage(self.root, 'android')

    def test_portable_archive_preserves_the_complete_runtime_layout(self):
        runtime = self.root / 'build/windows/x64/runner/Release'
        for name in ('asterlink.exe', 'asterlink_gopeed.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so'):
            file = runtime / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'fixture')
        output = release.stage(self.root, 'windows')
        with zipfile.ZipFile(output / 'asterlink-1.2.3+4-windows-x64.zip') as archive:
            self.assertIn('data/app.so', archive.namelist())
            self.assertIn('asterlink_gopeed.exe', archive.namelist())
            self.assertFalse(any(name.startswith('Release/') for name in archive.namelist()))

    def test_runtime_with_private_key_is_rejected(self):
        runtime = self.root / 'build/windows/x64/runner/Release'
        for name in ('asterlink.exe', 'asterlink_gopeed.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'data/app.so', 'private.jks'):
            file = runtime / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'fixture')
        with self.assertRaises(ValueError):
            release.stage(self.root, 'windows')


class SigningSettingsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'config').mkdir()
        shutil.copy2(ROOT / 'config/build.community.json', self.root / 'config/build.community.json')

    def test_missing_secrets_do_not_write_partial_signing_files(self):
        with self.assertRaises(ValueError):
            settings.prepare(self.root, True, {})
        self.assertFalse((self.root / '.local').exists())

    def test_existing_local_settings_are_not_replaced(self):
        (self.root / '.local').mkdir()
        config = self.root / '.local/build-config.json'
        config.write_text('{"local":true}', encoding='utf-8')
        with self.assertRaises(ValueError):
            settings.prepare(self.root, environment={})
        self.assertEqual(config.read_text(encoding='utf-8'), '{"local":true}')

    def test_properties_escape_metacharacters_and_keep_secrets_out_of_config(self):
        env = {
            'ANDROID_KEYSTORE_BASE64': base64.b64encode(b'synthetic-keystore').decode(),
            'ANDROID_KEYSTORE_PASSWORD': 'space and=colon:\\line\nnext',
            'ANDROID_KEY_ALIAS': 'test-key',
            'ANDROID_KEY_PASSWORD': 'test-password',
            'GITHUB_REPOSITORY': 'example/project',
        }
        settings.prepare(self.root, True, env)
        config = (self.root / '.local/build-config.json').read_text(encoding='utf-8')
        properties = (self.root / '.local/keystore.properties').read_text(encoding='ascii')
        self.assertEqual(len(properties.splitlines()), 4)
        self.assertIn('\\nnext', properties)
        self.assertIn('\\=', properties)
        self.assertNotIn(env['ANDROID_KEY_PASSWORD'], config)
        self.assertEqual((self.root / '.local/ci-release.jks').read_bytes(), b'synthetic-keystore')
        self.assertEqual(json.loads(config)['githubRepository'], 'example/project')


@unittest.skipUnless(shutil.which('dart'), 'Dart SDK is required for version generation checks')
class VersionTest(unittest.TestCase):
    def test_generation_drift_and_release_tag_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'tool').mkdir()
            shutil.copy2(ROOT / 'tool/sync_version.dart', root / 'tool/sync_version.dart')
            pubspec = root / 'pubspec.yaml'
            pubspec.write_text('version: 1.2.3+4\n', encoding='utf-8')

            def run(*args):
                return subprocess.run([shutil.which('dart'), str(root / 'tool/sync_version.dart'), *args],
                                      cwd=root, capture_output=True, text=True)

            self.assertNotEqual(run('--check').returncode, 0)
            self.assertEqual(run('--write').returncode, 0)
            self.assertEqual(run('--check', '--tag', 'v1.2.3+4').returncode, 0)
            self.assertNotEqual(run('--check', '--tag', 'v1.2.3+3').returncode, 0)
            pubspec.write_text('version: 1.2.3+5\n', encoding='utf-8')
            self.assertNotEqual(run('--check').returncode, 0)


if __name__ == '__main__':
    unittest.main()
