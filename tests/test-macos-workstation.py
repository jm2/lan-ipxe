#!/usr/bin/env python3
"""Behavior checks use temporary homes and fake commands; no workstation installs."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('workstation', ROOT / 'files/macos/workstation.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='macos-test-')
        self.root = Path(self.temp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        self.obj = w.Workstation(w.arguments(['--no-upgrade']), home=self.home,
                                 prefix=self.root / 'brew', applications=self.root / 'Applications')
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()

    def tearDown(self):
        self.output.__exit__(None, None, None)
        self.temp.cleanup()

    def test_atomic_idempotence_backups_and_symlink_conflict(self):
        path = self.home / 'settings'
        path.write_text('mine')
        self.assertTrue(self.obj.file(path, 'ours', 0o600))
        before = path.stat().st_mtime_ns
        self.assertFalse(self.obj.file(path, 'ours', 0o600))
        self.assertEqual(path.stat().st_mtime_ns, before)
        backups = list((self.obj.state / 'backups').glob('*/*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'mine')
        link = self.home / 'symlink'; link.symlink_to(path)
        with self.assertRaises(w.Deferred):
            self.obj.file(link, 'replace')
        self.assertEqual(path.read_text(), 'ours')

    def test_managed_blocks_preserve_user_content_and_modes(self):
        profile = self.home / '.bash_profile'
        profile.write_text('export USER_CHOICE=yes\n')
        profile.chmod(0o600)
        self.obj.shell()
        before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in self.home.rglob('*') if p.is_file()}
        self.obj.shell()
        self.assertIn('export USER_CHOICE=yes', profile.read_text())
        self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
        for path, (data, mtime) in before.items():
            self.assertEqual(Path(path).read_bytes(), data)
            self.assertEqual(Path(path).stat().st_mtime_ns, mtime)
        with self.assertRaises(w.Deferred):
            w.managed_block('# >>> lan-ipxe x >>>\n', 'x', 'body')

    def test_jsonc_preserves_comments_unrelated_keys_and_trailing_commas(self):
        text = '{\n // my comment\n "custom": {"a": [1,2,],},\n "workbench.colorTheme": "old" // keep explanation\n}\n'
        desired = {'workbench.colorTheme': 'Dark Modern', 'workbench.startupEditor': 'none'}
        merged = w.merge_jsonc(text, desired)
        self.assertIn('// my comment', merged)
        self.assertIn('"custom": {"a": [1,2,],}', merged)
        self.assertIn('// keep explanation', merged)
        self.assertEqual(w.merge_jsonc(merged, desired), merged)
        self.assertEqual(w.jsonc_members(merged)[0]['workbench.colorTheme'][2], 'Dark Modern')
        for invalid in ('{"a":1,"a":2}', '{"a":}', '[1]', '{bad}'):
            with self.assertRaises(w.Deferred):
                w.merge_jsonc(invalid, desired)

    def test_dock_preserves_unmanaged_tiles_and_deduplicates(self):
        old = [{'GUID': 42, 'tile-data': {'bundle-identifier': 'store.app', 'bookmark': b'original'}}]
        apps = [{'id': 'new.app', 'path': self.home / 'My App.app'}]
        merged = w.dock_items(old, apps)
        self.assertEqual(merged[0], old[0])
        self.assertEqual(w.dock_items(merged, apps), merged)
        self.assertIn('My%20App.app', merged[1]['tile-data']['file-data']['_CFURLString'])
        self.assertNotIn('bookmark', merged[1]['tile-data'])

    def test_store_native_collision_and_optional_failure_continuation(self):
        app = {'id': 'expected', 'name': 'Example', 'app': 'Example.app', 'cask': 'example'}
        self.obj.apps = [{'id': 'expected', 'path': self.root / 'Example.app', 'store': True}]
        with patch.object(self.obj, 'package', side_effect=AssertionError('installer called')):
            self.obj.application(app)
            self.obj.apps[0]['store'] = False
            self.obj.application(app)
        self.obj.apps = []
        self.obj.applications.mkdir()
        (self.obj.applications / 'Example.app').mkdir()
        with self.assertRaises(w.Deferred):
            self.obj.application(app)
        self.obj.attempt('broken', lambda: (_ for _ in ()).throw(RuntimeError('broken installer')))
        self.obj.attempt('independent', self.obj.file, self.home / 'independent', 'okay')
        self.assertEqual((self.home / 'independent').read_text(), 'okay')
        self.assertTrue(any(e['status'] == 'FAILED' for e in self.obj.events))

    def test_command_collisions_and_owned_link_retargeting(self):
        target = self.home / 'tool'; target.write_text('tool')
        link = self.home / 'bin/tool'
        self.obj.link(link, target)
        self.obj.link(link, target)
        target2 = self.home / 'tool2'; target2.write_text('tool2')
        self.obj.link(link, target2)
        self.assertEqual(link.resolve(), target2.resolve())
        conflict = self.home / 'bin/mine'; conflict.write_text('mine')
        with self.assertRaises(w.Deferred):
            self.obj.link(conflict, target)
        self.assertEqual(conflict.read_text(), 'mine')

    def test_no_upgrade_does_not_query_or_run_installed_package(self):
        receipt = self.obj.prefix / 'Cellar/wget/1.0/INSTALL_RECEIPT.json'
        receipt.parent.mkdir(parents=True); receipt.write_text('{}')
        self.obj.updated = True
        with patch.object(self.obj, 'command', side_effect=AssertionError('brew ran')):
            self.obj.package('wget')

    def test_typed_preferences_merge_and_only_write_on_change(self):
        domains = {'test': {'nested': {'user': 1}, 'enabled': False}}
        calls = []
        def command(argv, **kwargs):
            calls.append(argv)
            if argv[1] == 'write':
                domain, key = argv[2:4]
                if argv[4] == '-bool':
                    domains[domain][key] = argv[5] == 'true'
                else:
                    xml = '<?xml version="1.0"?><plist version="1.0">' + argv[4] + '</plist>'
                    domains[domain][key] = plistlib.loads(xml.encode())
            return subprocess.CompletedProcess(argv, 0, '', '')
        self.obj.command = command
        self.obj.preferences = lambda domain: domains[domain].copy()
        current = self.obj.preferences('test')
        self.obj.preference('test', 'nested', {'managed': 2}, current)
        self.obj.preference('test', 'enabled', True, current)
        self.obj.preference('test', 'enabled', True, current)
        self.assertEqual(len(calls), 2)
        self.assertEqual(domains['test']['nested'], {'user': 1, 'managed': 2})

    def test_full_preview_never_writes_executes_package_tools_or_network(self):
        self.obj.args = w.arguments(['--profile', 'full', '--check'])
        self.obj.preview = True
        allowed = {'defaults', 'file', 'xcode-select'}
        def command(argv, **kwargs):
            self.assertFalse(kwargs.get('mutate', False))
            self.assertIn(Path(argv[0]).name, allowed)
            return subprocess.CompletedProcess(argv, 1, '', '')
        self.obj.command = command
        self.obj.fetch = lambda *a: self.fail('preview network')
        before = set(self.home.rglob('*'))
        status = self.obj.run()
        self.assertEqual(status, 2)
        self.assertEqual(set(self.home.rglob('*')), before)
        self.assertFalse(self.obj.state.exists())

    def test_data_report_is_informational_and_uses_no_writes(self):
        before = set(self.home.rglob('*'))
        self.obj.game_report()
        self.assertEqual(set(self.home.rglob('*')), before)
        self.assertEqual(self.obj.events, [])

    def test_yamagi_data_root_respects_legacy_and_xdg(self):
        self.assertEqual(w.yamagi_data_root(self.home, {}), self.home / '.local/share/YamagiQ2')
        custom = self.home / 'custom data'
        self.assertEqual(w.yamagi_data_root(self.home, {'XDG_DATA_HOME': str(custom)}), custom / 'YamagiQ2')
        legacy = self.home / '.yq2'; legacy.mkdir()
        self.assertEqual(w.yamagi_data_root(self.home, {'XDG_DATA_HOME': str(custom)}), legacy)

    def test_profiles_and_fork_source(self):
        self.assertIn('go', self.obj.manifest['formulae']['core'])
        self.assertIn('wget', self.obj.manifest['formulae']['core'])
        self.assertNotIn('openjdk', self.obj.manifest['formulae']['core'])
        core = self.obj.selected_apps()
        self.assertFalse(any(a.get('repo', '').startswith('jorio') for a in core))
        self.obj.args.profile = 'full'
        fork = next(a for a in self.obj.selected_apps() if a.get('strict_source'))
        self.assertEqual(fork['repo'], 'jm2/CroMagRally')
        self.assertEqual(len(fork['sha256']), 64)
        self.assertFalse(any('mas' == n for values in self.obj.manifest['formulae'].values() for n in values))

    def test_checksum_failure_precedes_install_and_mount_always_detaches(self):
        artifact = self.home / 'artifact'
        self.obj.fetch = lambda url, destination: Path(destination).write_bytes(b'wrong')
        with self.assertRaises(RuntimeError):
            self.obj.download_verified('https://example.invalid/release', '0' * 64, artifact)
        calls = []
        def command(argv, **kwargs):
            calls.append(argv)
            data = {'system-entities': [{'mount-point': str(self.root / 'mount')}]}
            return subprocess.CompletedProcess(argv, 0, plistlib.dumps(data).decode(), '')
        self.obj.command = command
        with self.assertRaises(RuntimeError):
            with self.obj.mounted(artifact):
                raise RuntimeError('validation failed')
        self.assertEqual([args[1] for args in calls], ['attach', 'detach'])

    def test_unverified_cromag_is_never_adopted_by_bundle_id_alone(self):
        app = next(a for a in self.obj.manifest['apps'] if a.get('strict_source'))
        self.obj.preview = True
        self.obj.direct_app(app, {'path': self.home / 'Cro-Mag Rally.app'})
        self.assertEqual(self.obj.events[-1]['status'], 'DRIFT')
        self.assertIn('jm2/CroMagRally', self.obj.events[-1]['detail'])
        self.assertNotIn('apps', self.obj.receipts)

    def test_android_stable_selection_and_one_root(self):
        listing = '''\n platforms;android-35 | 1 | stable\n platforms;android-36 | 1 | stable\n platforms;android-37-ext1 | 1 | extension\n platforms;android-Z | 1 | preview\n build-tools;36.0.0 | 1 | stable\n build-tools;36.1.0 | 1 | stable\n build-tools;37.0.0-rc1 | 1 | preview\n ndk;29.0.1 | 1 | stable\n ndk;30.0.2 | 1 | stable\n system-images;android-99;google_apis;arm64-v8a | 1 | ignored\n'''
        self.assertEqual(w.sdk_versions(listing), ['platforms;android-36', 'build-tools;36.1.0', 'ndk;30.0.2'])
        with self.assertRaises(w.Deferred):
            w.sdk_versions('platforms;android-35 | 1 | stable')
        with patch.dict(os.environ, {'ANDROID_HOME': str(self.home / 'sdk'), 'ANDROID_SDK_ROOT': str(self.home / 'different')}):
            with self.assertRaises(w.Deferred):
                self.obj.sdk_root()
        root = self.home / 'sdk'
        for name in ['platforms/android-33', 'platforms/android-35', 'build-tools/35.0.0', 'build-tools/36.0.0-rc1', 'ndk/27.0.1']:
            path = root / name / 'source.properties'
            path.parent.mkdir(parents=True); path.write_text('Pkg.Revision=1')
        self.assertEqual(w.installed_sdk_versions(root), {'platforms': 'platforms;android-35', 'build-tools': 'build-tools;35.0.0', 'ndk': 'ndk;27.0.1'})


class BootstrapTests(unittest.TestCase):
    def test_missing_brew_clt_preview_and_python_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / 'missing'
            script = 'source "$1"; if find_python "$2" ""; then exit 10; fi; preview_without_python "$3" full dry-run'
            result = subprocess.run(['/bin/bash', '-c', script, 'test', str(ROOT / 'setup-macos-workstation.sh'), str(missing), str(ROOT)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn('MANUAL: finish Command Line Tools', result.stdout)
            self.assertIn('jm2/CroMagRally', result.stdout)
            self.assertEqual(list(Path(temporary).iterdir()), [])
            candidate = Path(temporary) / 'Developer/usr/bin/python3'
            candidate.parent.mkdir(parents=True); candidate.write_text('do not execute'); candidate.chmod(0o755)
            script = 'source "$1"; find_python "$2" "$3"'
            result = subprocess.run(['/bin/bash', '-c', script, 'test', str(ROOT / 'setup-macos-workstation.sh'), str(missing), str(candidate.parents[2])], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), str(candidate))

    def test_help_and_invalid_arguments_before_platform_or_side_effects(self):
        command = ['/bin/bash', str(ROOT / 'setup-macos-workstation.sh')]
        result = subprocess.run(command + ['--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        for args in (['--profile'], ['--profile', 'other'], ['--dry-run', '--check'], ['--unknown']):
            self.assertNotEqual(subprocess.run(command + args, capture_output=True).returncode, 0)

    def test_source_is_inert(self):
        result = subprocess.run(['/bin/bash', '-c', '. "$1"', 'test', str(ROOT / 'setup-macos-workstation.sh')], capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')


if __name__ == '__main__':
    unittest.main()
