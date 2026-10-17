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
import sys
import tempfile
import time
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
        self.obj.command_line_tools = self.root / 'CommandLineTools'
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

    def test_captured_command_timeout_kills_descendants_holding_output_open(self):
        marker = self.home / 'orphan finished'
        child = 'import pathlib,time; time.sleep(1); pathlib.Path(' + repr(str(marker)) + ').touch()'
        parent = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c",' + repr(child) + '])'
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            self.obj.command([sys.executable, '-c', parent], timeout=0.2)
        time.sleep(1)
        self.assertFalse(marker.exists())
        result = self.obj.command([sys.executable, '-c', 'import sys; print(repr(sys.stdin.read()))'])
        self.assertEqual(result.stdout.strip(), "''")

    def test_zed_links_bundled_cli_without_running_it_or_homebrew(self):
        app = next(a for a in self.obj.manifest['apps'] if a['name'] == 'Zed')
        path = self.obj.applications / 'Zed.app'
        target = path / 'Contents/MacOS/cli'
        target.parent.mkdir(parents=True)
        target.write_text('#!/bin/sh\nexit 99\n'); target.chmod(0o755)
        self.obj.apps = [{'id': app['id'], 'path': path, 'store': False}]
        self.obj.env['PATH'] = str(self.obj.prefix / 'bin')
        with patch.object(self.obj, 'command', side_effect=AssertionError('app or brew ran')), \
                patch.object(self.obj, 'validate_app'):
            self.obj.application(app)
            self.obj.application(app)
        self.assertEqual((self.home / '.local/bin/zed').resolve(), target.resolve())
        other = self.obj.prefix / 'bin/zed'
        other.parent.mkdir(parents=True); other.write_text('other'); other.chmod(0o755)
        with patch.object(self.obj, 'validate_app'), self.assertRaises(w.Deferred):
            self.obj.application(app)

    def feed_fixture(self, name, version='2.0.20', body=b'binary'):
        cli = next(c for c in self.obj.manifest['feed_clis'] if c['command'] == name)
        archive = self.root / ('artifact-' + name)
        with w.tarfile.open(archive, 'w:gz') as bundle:
            info = w.tarfile.TarInfo(cli['member']); info.size = len(body)
            bundle.addfile(info, io.BytesIO(body))
        url = cli['url_prefix'] + version + '-123' + cli['url_suffix']
        feed = {'version': version, 'url': url, 'sha512': w.hashlib.sha512(archive.read_bytes()).hexdigest()}
        downloads = []
        def fetch(address, destination=None):
            if address == cli['feed']:
                return json.dumps(feed).encode()
            self.assertEqual(address, url)
            downloads.append(address)
            Path(destination).write_bytes(archive.read_bytes())
        return cli, feed, fetch, downloads

    def test_feed_cli_replaces_homebrew_owner_with_verified_vendor_build(self):
        self.obj.args = w.arguments([])
        cli, _, fetch, downloads = self.feed_fixture('agy')
        self.obj.fetch = fetch
        with patch.object(self.obj, 'verify_binary'):
            self.obj.feed_cli(cli)
            self.obj.feed_cli(cli)
        path = self.home / cli['path']
        self.assertEqual(path.read_bytes(), b'binary')
        self.assertEqual(len(downloads), 1, 'a verified current install must not be downloaded again')
        self.assertEqual((self.home / '.local/bin/agy').resolve(), path.resolve())
        self.assertEqual(self.obj.receipts['clis']['agy']['version'], '2.0.20')
        cli, _, fetch, _ = self.feed_fixture('agy', '2.0.21', b'newer')
        self.obj.fetch = fetch
        with patch.object(self.obj, 'verify_binary'):
            self.obj.feed_cli(cli)
        self.assertEqual(path.read_bytes(), b'newer')
        kind, legacy = cli['homebrew']
        (self.obj.prefix / 'Caskroom' / legacy / '.metadata').mkdir(parents=True)
        with patch.object(self.obj, 'verify_binary'), patch.object(self.obj, 'command', side_effect=AssertionError('brew ran')), \
                self.assertRaisesRegex(w.Deferred, 'brew uninstall --cask antigravity-cli'):
            self.obj.feed_cli(cli)

    def test_opencode_is_purged_for_goose_and_crush(self):
        manifest = json.dumps(self.obj.manifest).lower()
        self.assertNotIn('opencode', manifest)
        goose = next(a for a in self.obj.manifest['apps'] if a['name'] == 'Goose')
        self.assertEqual((goose['cask'], goose['id'], goose['profile']), ('block-goose', 'com.electron.goose', 'core'))
        self.assertIn('charmbracelet/tap/crush', self.obj.manifest['formulae']['core'])
        self.assertIn('goose', w.NATIVE_CLIS)
        (self.obj.prefix / 'Caskroom/opencode-desktop/.metadata').mkdir(parents=True)
        (self.obj.prefix / 'Cellar/opencode/1.18.30').mkdir(parents=True)
        (self.obj.prefix / 'Cellar/opencode/1.18.30/INSTALL_RECEIPT.json').write_text('{}')
        binary = self.home / '.opencode/bin/opencode'
        binary.parent.mkdir(parents=True); binary.write_text('opencode')
        self.obj.link(self.home / '.local/bin/opencode', binary)
        self.obj.receipts.setdefault('clis', {})['opencode'] = {'path': str(binary)}
        config = self.home / '.config/opencode/opencode.json'
        config.parent.mkdir(parents=True); config.write_text('{}')
        self.obj.preview = True
        with patch.object(self.obj, 'command', side_effect=AssertionError('preview ran')):
            self.obj.retire_opencode()
        self.assertEqual([e['status'] for e in self.obj.events[-3:]], ['DRIFT'] * 3)
        self.assertTrue(binary.exists())
        self.obj.preview = False
        calls = []
        def command(argv, **kwargs):
            calls.append([str(a) for a in argv[1:]])
            w.shutil.rmtree(self.obj.prefix / ('Caskroom/opencode-desktop' if argv[2] == '--cask' else 'Cellar/opencode'))
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(self.obj, 'command', side_effect=command):
            self.obj.retire_opencode()
            self.obj.retire_opencode()
        self.assertEqual(calls, [['uninstall', '--cask', 'opencode-desktop'], ['uninstall', '--formula', 'opencode']])
        self.assertFalse((self.home / '.local/bin/opencode').is_symlink())
        self.assertFalse((self.home / '.opencode').exists())
        self.assertNotIn('opencode', self.obj.receipts['clis'])
        self.assertNotIn(str(self.home / '.local/bin/opencode'), self.obj.receipts['links'])
        self.assertEqual(config.read_text(), '{}')

    def test_any_native_opencode_cli_is_purged(self):
        # The official installer's copy is removed even without a receipt.
        native = self.home / '.opencode/bin'
        native.mkdir(parents=True)
        for name in ('opencode', 'opencode2', 'opencode2.cmd'):
            (native / name).write_text('mine')
        public = self.home / '.local/bin/opencode'
        public.parent.mkdir(parents=True); public.symlink_to('../../.opencode/bin/opencode')
        self.obj.receipts.setdefault('links', {})[str(public)] = 'unrelated'
        state = self.home / '.local/state/opencode'
        state.mkdir(parents=True)
        other = self.home / '.local/bin/other'
        other.symlink_to(self.home / 'elsewhere')
        self.obj.preview = True
        self.obj.retire_opencode()
        self.assertEqual([(e['status'], e['item']) for e in self.obj.events], [('DRIFT', 'OpenCode CLI')])
        self.assertTrue(public.is_symlink() and (native / 'opencode').exists())
        self.obj.preview = False
        with patch.object(self.obj, 'command', side_effect=AssertionError('brew ran')):
            self.obj.retire_opencode()
            self.obj.retire_opencode()
        self.assertFalse(public.is_symlink() or (self.home / '.opencode').exists())
        self.assertNotIn(str(public), self.obj.receipts['links'])
        self.assertTrue(state.is_dir() and other.is_symlink())
        self.assertEqual([e['status'] for e in self.obj.events].count('CHANGED'), 1)

    def test_dangling_opencode_link_is_removed(self):
        public = self.home / '.local/bin/opencode'
        public.parent.mkdir(parents=True); public.symlink_to(self.home / '.opencode/bin/opencode')
        self.obj.retire_opencode()
        self.assertFalse(public.is_symlink())

    def test_opencode_installer_path_lines_are_stripped(self):
        home = str(self.home)
        bashrc = self.home / '.bashrc'
        original = 'alias ll="ls -l"\nexport PATH=$HOME/bin:$PATH\n'
        bashrc.write_text(original + '\n# opencode\nexport PATH=' + home + '/.opencode/bin:$PATH\n# after\n')
        bashrc.chmod(0o600)
        fish = self.home / '.config/fish/config.fish'
        fish.parent.mkdir(parents=True)
        fish.write_text('set -x EDITOR vim\n\n# opencode\nfish_add_path ' + home + '/.opencode/bin\n')
        # A user's own line naming the directory, without the installer's marker, stays.
        profile = self.home / '.profile'
        profile.write_text('export PATH=' + home + '/.opencode/bin:$PATH\n')
        zdotdir = self.root / 'zdot'
        zdotdir.mkdir()
        zshrc = zdotdir / '.zshrc'
        zshrc.write_text('\n# opencode\nexport PATH=' + home + '/.opencode/bin:$PATH\n')
        (self.home / '.zshrc').symlink_to(zshrc)
        self.obj.env = dict(self.obj.env, ZDOTDIR=str(zdotdir))
        self.obj.preview = True
        self.obj.retire_opencode()
        self.assertEqual(sorted(e['item'] for e in self.obj.events),
                         sorted('OpenCode PATH entry in ' + str(p.resolve()) for p in (bashrc, fish, zshrc)))
        self.assertIn('# opencode', bashrc.read_text())
        self.obj.preview = False
        self.obj.events = []
        self.obj.retire_opencode()
        self.assertEqual(len(self.obj.events), 3)
        self.assertEqual(bashrc.read_text(), original + '# after\n')
        self.assertEqual(bashrc.stat().st_mode & 0o777, 0o600)
        self.assertEqual(fish.read_text(), 'set -x EDITOR vim\n')
        self.assertEqual(zshrc.read_text(), '')
        self.assertTrue((self.home / '.zshrc').is_symlink())
        self.assertEqual(profile.read_text(), 'export PATH=' + home + '/.opencode/bin:$PATH\n')
        self.obj.events = []
        self.obj.retire_opencode()
        self.assertEqual(self.obj.events, [], 'a cleaned workstation must be a no-op')

    def write_app(self, path, bundle_id):
        (path / 'Contents').mkdir(parents=True)
        with (path / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': bundle_id}, stream)

    def test_dmg_installed_opencode_app_is_removed(self):
        system = self.obj.applications / 'OpenCode.app'
        user = self.home / 'Applications/OpenCode.app'
        self.write_app(system, 'AI.OpenCode.Desktop')
        self.write_app(user, 'com.example.opencode')
        self.obj.preview = True
        self.obj.retire_opencode()
        self.assertEqual([e['item'] for e in self.obj.events], ['OpenCode app ' + str(system)])
        self.assertTrue(system.exists())
        self.obj.preview = False
        self.obj.retire_opencode()
        self.assertFalse(system.exists())
        self.assertTrue(user.exists(), 'an unrelated bundle named OpenCode.app must stay')
        self.obj.events = []
        self.obj.retire_opencode()
        self.assertEqual(self.obj.events, [])

    def test_cask_owned_opencode_app_is_left_to_the_cask_uninstall(self):
        app = self.obj.applications / 'OpenCode.app'
        self.write_app(app, 'ai.opencode.desktop')
        (self.obj.prefix / 'Caskroom/opencode-desktop/.metadata').mkdir(parents=True)
        def command(argv, **kwargs):
            w.shutil.rmtree(self.obj.prefix / 'Caskroom/opencode-desktop')
            w.shutil.rmtree(app)
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(self.obj, 'command', side_effect=command) as brew:
            self.obj.retire_opencode()
        self.assertEqual(brew.call_count, 1)
        self.assertEqual([e['item'] for e in self.obj.events], ['cask opencode-desktop'])

    def test_goose_cli_uses_official_installer_and_defers_homebrew_copy(self):
        self.obj.args = w.arguments([])
        runs = []
        def fetch(url, destination):
            self.assertEqual(url, 'https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh')
            Path(destination).write_text('#!/bin/bash\n')
        def command(argv, **kwargs):
            if argv[1] == '-n':
                return subprocess.CompletedProcess(argv, 0, '', '')
            env = kwargs['env']
            runs.append((env['GOOSE_BIN_DIR'], env['CONFIGURE'], env['PATH'].split(':')[0], kwargs['cwd']))
            self.assertEqual(Path(kwargs['cwd']), Path(argv[1]).parent)
            goose = self.home / '.local/bin/goose'
            goose.parent.mkdir(parents=True, exist_ok=True); goose.write_text('goose'); goose.chmod(0o755)
            return subprocess.CompletedProcess(argv, 0, '', '')
        self.obj.fetch = fetch
        with patch.object(self.obj, 'command', side_effect=command):
            self.obj.native_cli('goose')
            self.obj.native_cli('goose')
        bindir = str(self.home / '.local/bin')
        self.assertEqual([run[:3] for run in runs], [(bindir, 'false', bindir)] * 2, 'the owned copy is refreshed by its installer')
        self.assertFalse(Path(runs[0][3]).exists(), 'the download directory is temporary')
        (self.obj.prefix / 'Cellar/block-goose-cli/1.0/INSTALL_RECEIPT.json').parent.mkdir(parents=True)
        (self.obj.prefix / 'Cellar/block-goose-cli/1.0/INSTALL_RECEIPT.json').write_text('{}')
        self.obj.args = w.arguments(['--no-upgrade'])
        with patch.object(self.obj, 'command', side_effect=AssertionError('ran')), \
                self.assertRaisesRegex(w.Deferred, 'brew uninstall --formula block-goose-cli'):
            self.obj.native_cli('goose')

    def test_tapped_formula_is_tapped_and_installed_without_bottle(self):
        self.obj.args = w.arguments([])
        self.obj.updated = True
        calls = []
        def command(argv, **kwargs):
            calls.append([str(a) for a in argv[1:]])
            if argv[1] == 'info':
                return subprocess.CompletedProcess(argv, 0, json.dumps({'formulae': [{'bottle': {}}]}), '')
            if argv[1] == 'install':
                receipt = self.obj.prefix / 'Cellar/crush/0.98.1/INSTALL_RECEIPT.json'
                receipt.parent.mkdir(parents=True); receipt.write_text('{}')
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(self.obj, 'command', side_effect=command):
            self.obj.package('charmbracelet/tap/crush')
            self.obj.package('charmbracelet/tap/crush')
        self.assertEqual(calls, [['tap', 'charmbracelet/tap'],
                                 ['info', '--json=v2', '--formula', 'charmbracelet/tap/crush'],
                                 ['install', '--no-ask', '--formula', 'charmbracelet/tap/crush']])
        self.assertEqual(self.obj.events[-1]['status'], 'CURRENT')

    def test_feed_cli_adopts_identical_copy_and_preserves_foreign_one(self):
        self.obj.args = w.arguments([])
        cli, _, fetch, _ = self.feed_fixture('agy')
        self.obj.fetch = fetch
        path = self.home / cli['path']
        path.parent.mkdir(parents=True); path.write_bytes(b'binary')
        with patch.object(self.obj, 'verify_binary'):
            self.obj.feed_cli(cli)
        self.assertEqual(self.obj.events[-1]['status'], 'CURRENT')
        self.obj.receipts = {}
        path.write_bytes(b'mine')
        with patch.object(self.obj, 'verify_binary'), self.assertRaises(w.Deferred):
            self.obj.feed_cli(cli)
        self.assertEqual(path.read_bytes(), b'mine')

    def test_feed_cli_preserves_its_own_in_place_update(self):
        self.obj.args = w.arguments([])
        cli, _, fetch, downloads = self.feed_fixture('agy')
        self.obj.fetch = fetch
        with patch.object(self.obj, 'verify_binary'):
            self.obj.feed_cli(cli)
        path = self.home / cli['path']
        path.write_bytes(b'self-updated')
        reported = {'version': '2.0.21'}
        def command(argv, **kwargs):
            self.assertEqual([str(a) for a in argv], [str(path), '--version'])
            return subprocess.CompletedProcess(argv, 0, 'agy ' + reported['version'] + '\n', '')
        with patch.object(self.obj, 'verify_binary'), patch.object(self.obj, 'command', side_effect=command):
            self.obj.feed_cli(cli)
        self.assertEqual(path.read_bytes(), b'self-updated')
        self.assertEqual(len(downloads), 1, 'a self-updated CLI must not be replaced by the feed build')
        self.assertIn('updated in place', self.obj.events[-1]['detail'])
        reported['version'] = '2.0.19'
        with patch.object(self.obj, 'verify_binary'), patch.object(self.obj, 'command', side_effect=command):
            self.obj.feed_cli(cli)
        self.assertEqual(path.read_bytes(), b'binary', 'an older modified copy must be replaced')

    def test_feed_release_rejects_off_origin_prefix_confusion_and_missing_digest(self):
        cli, feed, fetch, _ = self.feed_fixture('agy', '1.2.14')
        self.obj.fetch = fetch
        self.assertEqual(self.obj.feed_release(cli)[0], '1.2.14')
        def check(change, error):
            broken = dict(feed)
            change(broken)
            self.obj.fetch = lambda *a: json.dumps(broken).encode()
            with self.assertRaises(error):
                self.obj.feed_release(cli)
        check(lambda top: top.update(url='https://downloads.example.invalid/1.2.14' + cli['url_suffix']), RuntimeError)
        check(lambda top: top.update(version='1.2.1'), RuntimeError)
        check(lambda top: top.update(sha512=''), w.Deferred)
        self.obj.fetch = lambda *a: json.dumps([]).encode()
        with self.assertRaisesRegex(RuntimeError, 'Malformed release feed'):
            self.obj.feed_release(cli)

    def test_no_upgrade_feed_cli_does_not_query_or_run(self):
        cli = next(c for c in self.obj.manifest['feed_clis'] if c['command'] == 'agy')
        path = self.home / cli['path']; path.parent.mkdir(parents=True); path.write_text('agy')
        self.obj.fetch = lambda *a: self.fail('network')
        with patch.object(self.obj, 'command', side_effect=AssertionError('ran')):
            self.obj.feed_cli(cli)

    def test_live_log_retains_started_and_failed_actions(self):
        self.obj.live_log = self.home / 'actions.jsonl'
        self.obj.attempt('broken', lambda: (_ for _ in ()).throw(RuntimeError('broken installer')))
        events = [json.loads(line) for line in self.obj.live_log.read_text().splitlines()]
        self.assertEqual([event['status'] for event in events], ['START', 'FAILED'])

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

    def make_clang(self, root, relative):
        clang = root / relative
        clang.parent.mkdir(parents=True, exist_ok=True)
        clang.write_text('do not execute'); clang.chmod(0o755)
        return clang

    def test_developer_tools_accept_clt_and_xcode_layouts(self):
        clt = self.root / 'CommandLineTools'
        xcode = self.root / 'Applications/Xcode.app/Contents/Developer'
        self.assertIsNone(w.developer_clang(''))
        self.assertIsNone(w.developer_clang(xcode))
        self.assertEqual(w.developer_clang(clt), None)
        self.assertEqual(w.developer_tools_problem('', clt), 'Complete Apple Command Line Tools installation, then rerun')
        # Xcode.app has no usr/bin/clang; only its default toolchain counts.
        (xcode / 'usr/bin').mkdir(parents=True)
        xcode_clang = self.make_clang(xcode, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang')
        self.assertEqual(w.developer_clang(xcode), xcode_clang)
        self.assertIsNone(w.developer_tools_problem(str(xcode) + '\n', clt))
        clt_clang = self.make_clang(clt, 'usr/bin/clang')
        self.assertEqual(w.developer_clang(clt), clt_clang)
        self.assertIsNone(w.developer_tools_problem(str(clt), clt))
        # Non-executable or directory "clang" entries are not usable compilers.
        xcode_clang.chmod(0o644)
        self.assertIsNone(w.developer_clang(xcode))
        xcode_clang.unlink(); xcode_clang.mkdir()
        self.assertIsNone(w.developer_clang(xcode))

    def test_developer_tools_diagnose_stale_or_missing_selection(self):
        clt = self.root / 'CommandLineTools'
        self.make_clang(clt, 'usr/bin/clang')
        broken = self.root / 'Applications/Xcode.app/Contents/Developer'
        broken.mkdir(parents=True)
        fix = 'run: sudo xcode-select --switch ' + str(clt)
        for selected, reason in (('', 'is not set'), (str(broken), str(broken) + ' has no clang'),
                                 (str(self.root / 'gone'), str(self.root / 'gone') + ' no longer exists')):
            problem = w.developer_tools_problem(selected, clt)
            self.assertIn(reason, problem)
            self.assertIn(fix, problem)

    def test_run_uses_selected_xcode_and_ignores_failed_xcode_select(self):
        xcode = self.root / 'Applications/Xcode.app/Contents/Developer'
        self.make_clang(xcode, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang')
        self.obj.args = w.arguments(['--check'])
        self.obj.preview = True
        outputs = {'returncode': 0, 'stdout': str(xcode) + '\n'}
        def command(argv, **kwargs):
            if Path(argv[0]).name == 'xcode-select':
                return subprocess.CompletedProcess(argv, outputs['returncode'], outputs['stdout'], '')
            return subprocess.CompletedProcess(argv, 1, '', '')
        self.obj.command = command
        self.obj.fetch = lambda *a: self.fail('preview network')
        self.obj.run()
        self.assertFalse([e for e in self.obj.events if 'Apple developer tools' in str(e)])
        # Error text from a failing xcode-select must never be treated as a path.
        self.obj.events = []
        outputs.update(returncode=2, stdout=str(xcode))
        self.obj.run()
        self.assertTrue([e for e in self.obj.events if 'Apple developer tools' in str(e)])
        self.obj.preview = False
        self.obj.args = w.arguments([])
        with self.assertRaises(w.Deferred):
            self.obj.run()

    def test_distro_rust_formula_is_purged_and_cache_pruned(self):
        calls = []
        def command(argv, **kwargs):
            calls.append([str(a) for a in argv])
            if argv[1:3] == ['uninstall', '--formula']:
                self.obj.formula_installed = lambda name: False
            return subprocess.CompletedProcess(argv, 0, '', '')
        self.obj.command = command
        self.obj.formula_installed = lambda name: name == 'rust'
        self.obj.preview = True
        self.obj.purge_distro_rust()
        self.obj.brew_cleanup()
        self.assertEqual(calls, [])
        self.assertEqual(self.obj.events[-1]['status'], 'DRIFT')
        self.obj.preview = False
        self.obj.updated = True
        self.obj.purge_distro_rust()
        self.obj.brew_cleanup()
        self.assertEqual([c[1:] for c in calls], [['uninstall', '--formula', 'rust'], ['cleanup', '--prune=all']])
        self.assertEqual(self.obj.events[-1]['status'], 'CHANGED')

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

    def test_android_uses_standalone_jdk_before_unlaunched_studio_runtime(self):
        root = self.home / 'sdk'
        packages = ['platforms;android-36', 'build-tools;36.0.0', 'ndk;29.0.1']
        for relative in ['platform-tools/adb'] + [name.replace(';', '/') + '/source.properties' for name in packages]:
            path = root / relative; path.parent.mkdir(parents=True, exist_ok=True); path.touch()
        jdk = self.obj.prefix / 'opt/openjdk/libexec/openjdk.jdk/Contents/Home'
        studio = self.obj.applications / 'Android Studio.app'
        for path in [jdk / 'bin/java', studio / 'Contents/jbr/Contents/Home/bin/java']:
            path.parent.mkdir(parents=True); path.touch()
        self.obj.apps = [{'id': 'com.google.android.studio', 'path': studio}]
        self.obj.args.no_upgrade = False
        calls = []
        def command(argv, **kwargs):
            calls.append((argv, kwargs['env']['JAVA_HOME']))
            return subprocess.CompletedProcess(argv, 0, '\n'.join(name + ' | 1 | stable' for name in packages), '')
        with patch.object(self.obj, 'sdk_root', return_value=root), \
                patch.object(self.obj, 'package'), patch.object(self.obj, 'link'), \
                patch.object(self.obj, 'command', side_effect=command):
            self.obj.android()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(java == str(jdk) for _, java in calls))
        self.assertTrue(all('--sdk_root=' + str(root) in argv for argv, _ in calls))

    def test_sharing_service_detection_formats(self):
        formats = {
            'macos_26': '"com.openssh.sshd" => false\n"com.apple.screensharing" => false',
            'macos_27': '"com.openssh.sshd" => enabled\n"com.apple.screensharing" => enabled',
        }
        for name, disabled_output in formats.items():
            # Preview mode recognizes service as enabled without DRIFT
            self.obj.preview = True
            self.obj.events = []
            def command_preview(argv, **kwargs):
                cmd = ' '.join(str(a) for a in argv)
                if 'id -un' in cmd:
                    return subprocess.CompletedProcess(argv, 0, 'tester\n', '')
                if 'launchctl print-disabled system' in cmd:
                    return subprocess.CompletedProcess(argv, 0, disabled_output, '')
                if 'dseditgroup -o checkmember' in cmd:
                    return subprocess.CompletedProcess(argv, 0, 'yes\n', '')
                raise AssertionError(f'Unexpected command in preview ({name}): {cmd}')
            self.obj.command = command_preview
            self.obj.sharing()
            preview_statuses = {e['item']: e['status'] for e in self.obj.events}
            self.assertEqual(preview_statuses.get('com.openssh.sshd'), 'CURRENT')
            self.assertEqual(preview_statuses.get('com.apple.screensharing'), 'CURRENT')
            self.assertFalse(any(e['status'] == 'DRIFT' for e in self.obj.events), f'False DRIFT emitted in {name}')

            # Apply mode recognizes service as enabled without mutating or raising Deferred
            self.obj.preview = False
            self.obj.events = []
            def command_apply(argv, **kwargs):
                self.assertFalse(kwargs.get('mutate', False), f'Mutating command called when service already enabled ({name}): {argv}')
                cmd = ' '.join(str(a) for a in argv)
                if 'id -un' in cmd:
                    return subprocess.CompletedProcess(argv, 0, 'tester\n', '')
                if 'launchctl print-disabled system' in cmd:
                    return subprocess.CompletedProcess(argv, 0, disabled_output, '')
                if 'dseditgroup -o checkmember' in cmd:
                    return subprocess.CompletedProcess(argv, 0, 'yes\n', '')
                raise AssertionError(f'Unexpected command in apply ({name}): {cmd}')
            self.obj.command = command_apply
            self.obj.sharing()
            apply_statuses = {e['item']: e['status'] for e in self.obj.events}
            self.assertEqual(apply_statuses.get('com.openssh.sshd'), 'CURRENT')
            self.assertEqual(apply_statuses.get('com.apple.screensharing'), 'CURRENT')
            self.assertFalse(any(e['status'] == 'DRIFT' for e in self.obj.events), f'False DRIFT emitted in {name}')

        # Disabled service format emits DRIFT in preview
        self.obj.preview = True
        self.obj.events = []
        def command_disabled(argv, **kwargs):
            cmd = ' '.join(str(a) for a in argv)
            if 'id -un' in cmd:
                return subprocess.CompletedProcess(argv, 0, 'tester\n', '')
            if 'launchctl print-disabled system' in cmd:
                return subprocess.CompletedProcess(argv, 0, '"com.openssh.sshd" => true\n"com.apple.screensharing" => true', '')
            if 'dseditgroup -o checkmember' in cmd:
                return subprocess.CompletedProcess(argv, 0, 'yes\n', '')
            raise AssertionError(f'Unexpected command in preview: {cmd}')
        self.obj.command = command_disabled
        self.obj.sharing()
        disabled_statuses = {e['item']: e['status'] for e in self.obj.events}
        self.assertEqual(disabled_statuses.get('com.openssh.sshd'), 'DRIFT')
        self.assertEqual(disabled_statuses.get('com.apple.screensharing'), 'DRIFT')


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
            # A stale/empty xcode-select result falls through to the CLT directory.
            script = 'source "$1"; find_python "$2" "" "$3/stale" "$3/Developer"'
            result = subprocess.run(['/bin/bash', '-c', script, 'test', str(ROOT / 'setup-macos-workstation.sh'), str(missing), temporary], capture_output=True, text=True)
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

    def test_setup_script_macos_version_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake_python = Path(temporary) / 'fake-python'
            fake_python.write_text('#!/bin/sh\necho "python-ran: $@"\n')
            fake_python.chmod(0o755)

            script = (
                'source "$1"; '
                'target_ver="$2"; target_python="$3"; '
                'uname() { case "$1" in -s) echo Darwin;; -m) echo arm64;; esac; }; '
                'sw_vers() { echo "$target_ver"; }; '
                'find_python() { printf "%s\\n" "$target_python"; }; '
                'main --dry-run'
            )

            for version in ('26', '27', '26.0', '27.1.0'):
                result = subprocess.run(
                    ['/bin/bash', '-c', script, 'test', str(ROOT / 'setup-macos-workstation.sh'), version, str(fake_python)],
                    capture_output=True, text=True
                )
                self.assertEqual(result.returncode, 0)
                self.assertIn('python-ran:', result.stdout)
                self.assertNotIn('Supported targets are macOS 26 and 27; other releases are unvalidated.', result.stderr)

            for version in ('25', '28', '25.0', '28.1.0'):
                result = subprocess.run(
                    ['/bin/bash', '-c', script, 'test', str(ROOT / 'setup-macos-workstation.sh'), version, str(fake_python)],
                    capture_output=True, text=True
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn('Supported targets are macOS 26 and 27; other releases are unvalidated.', result.stderr)
                self.assertNotIn('python-ran:', result.stdout)

            bin_dir = Path(temporary) / 'bin'
            bin_dir.mkdir()
            # Fake Apple Silicon too, so Linux CI reaches the version gate.
            uname = bin_dir / 'uname'
            uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) exec /usr/bin/uname "$@";; esac\n')
            uname.chmod(0o755)
            sw_vers = bin_dir / 'sw_vers'
            for unsupported in ('25', '28'):
                sw_vers.write_text(f'#!/bin/sh\necho {unsupported}.0\n')
                sw_vers.chmod(0o755)
                env = os.environ.copy()
                env['PATH'] = f'{bin_dir}:{env["PATH"]}'
                result = subprocess.run(['/bin/bash', str(ROOT / 'setup-macos-workstation.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Supported targets are macOS 26 and 27; other releases are unvalidated.', result.stderr)

    def test_main_platform_version_check(self):
        with patch.object(sys, 'platform', 'darwin'), \
                patch('os.getuid', return_value=501), \
                patch('platform.machine', return_value='arm64'), \
                patch.object(w, 'Workstation') as mock_ws:
            mock_ws.return_value.run.return_value = 0

            for version in ('26', '27', '26.0', '27.1.0'):
                mock_ws.reset_mock()
                with patch('platform.mac_ver', return_value=(version, ('', '', ''), 'arm64')):
                    result = w.main([])
                    self.assertEqual(result, 0)
                    mock_ws.assert_called_once()

            for version in ('25', '28', '25.0', '28.1.0'):
                mock_ws.reset_mock()
                stderr = io.StringIO()
                with patch('platform.mac_ver', return_value=(version, ('', '', ''), 'arm64')), \
                        contextlib.redirect_stderr(stderr):
                    result = w.main([])
                    self.assertEqual(result, 1)
                    mock_ws.assert_not_called()
                    self.assertIn('Run setup-macos-workstation.sh as a normal user on native macOS.', stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
