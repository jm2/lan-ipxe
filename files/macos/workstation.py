#!/usr/bin/env python3
"""macOS workstation reconciler; Python stdlib only, bootstrapped by Bash 3.2.

All mutations pass through apply-only methods. Importing this module has no effects.
Preview reads local receipts/plists and never executes package managers or user apps.
"""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

PAYLOAD = Path(__file__).resolve().parent


class Deferred(Exception):
    """A required user action or unsupported state, not an installer failure."""


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def read_plist(path):
    try:
        with Path(path).open('rb') as stream:
            return plistlib.load(stream)
    except FileNotFoundError:
        return {}


def merge_dict(old, desired):
    result = dict(old)
    for key, value in desired.items():
        result[key] = merge_dict(result.get(key, {}), value) if isinstance(value, dict) else value
    return result


def managed_block(text, name, body):
    start, end = '# >>> lan-ipxe ' + name + ' >>>', '# <<< lan-ipxe ' + name + ' <<<'
    replacement = start + '\n' + body.rstrip() + '\n' + end
    if text.count(start) != text.count(end) or text.count(start) > 1:
        raise Deferred('Malformed/duplicate managed block: ' + name)
    if start in text:
        a, b = text.index(start), text.index(end) + len(end)
        if b < a:
            raise Deferred('Reversed managed block: ' + name)
        return text[:a] + replacement + text[b:]
    return text + ('\n' if text and not text.endswith('\n') else '') + replacement + '\n'


# A small JSONC lexer/parser gives value spans without discarding user comments.
TOKEN = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\]:,]')


def jsonc_members(text):
    tokens, pos = [], 0
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match:
            raise Deferred('Invalid JSONC near character ' + str(pos))
        token = match.group()
        if not token.isspace() and not token.startswith(('//', '/*')):
            tokens.append((token, match.start(), match.end()))
        pos = match.end()
    index = 0
    members = {}

    def value(top=False):
        nonlocal index
        if index >= len(tokens):
            raise Deferred('Truncated JSONC')
        token = tokens[index][0]
        index += 1
        if token in ('{', '['):
            mapping = token == '{'
            close = '}' if mapping else ']'
            result = {} if mapping else []
            while index < len(tokens) and tokens[index][0] != close:
                if mapping:
                    key = json.loads(tokens[index][0]); index += 1
                    if not isinstance(key, str) or tokens[index][0] != ':':
                        raise Deferred('Invalid JSONC object key')
                    index += 1
                    if key in result:
                        raise Deferred('Duplicate JSONC key: ' + key)
                begin = tokens[index][1]
                item = value()
                finish = tokens[index - 1][2]
                if mapping:
                    result[key] = item
                    if top:
                        members[key] = (begin, finish, item)
                else:
                    result.append(item)
                if tokens[index][0] == close:
                    break
                if tokens[index][0] != ',':
                    raise Deferred('Expected JSONC comma')
                index += 1
            if index >= len(tokens):
                raise Deferred('Unclosed JSONC object/array')
            index += 1
            return result
        return json.loads(token)

    try:
        result = value(True)
        if not isinstance(result, dict) or index != len(tokens):
            raise Deferred('Settings must contain one JSONC object')
        return members, tokens
    except (IndexError, ValueError) as exc:
        raise Deferred('Cannot safely merge settings JSONC: ' + str(exc)) from exc


def merge_jsonc(text, desired):
    text = text if text.strip() else '{}\n'
    members, tokens = jsonc_members(text)
    replacements = []
    missing = []
    for key, value in desired.items():
        if key in members:
            a, b, old = members[key]
            if old != value:
                replacements.append((a, b, json.dumps(value, ensure_ascii=False)))
        else:
            missing.append(json.dumps(key) + ': ' + json.dumps(value, ensure_ascii=False))
    if missing:
        close = tokens[-1][1]
        comma = ',' if len(tokens) > 2 and tokens[-2][0] != ',' else ''
        # Insert a comma before a final line comment, never after it.
        if comma:
            at = tokens[-2][2]
            replacements.append((at, at, ','))
        replacements.append((close, close, '\n    ' + ',\n    '.join(missing) + '\n'))
    for a, b, value in sorted(replacements, reverse=True):
        text = text[:a] + value + text[b:]
    jsonc_members(text)
    return text


def sdk_versions(listing):
    """Only exact stable numeric paths; exclude previews, extensions, emulators."""
    result = []
    for pattern in (r'platforms;android-([0-9]+)', r'build-tools;([0-9]+\.[0-9]+\.[0-9]+)', r'ndk;([0-9]+\.[0-9]+\.[0-9]+)'):
        matches = re.findall(r'^\s*(' + pattern + r')\s*\|', listing, re.M)
        if not matches:
            raise Deferred('Stable Android package unavailable: ' + pattern)
        result.append(max(matches, key=lambda item: tuple(map(int, item[1].split('.'))))[0])
    return result


def installed_sdk_versions(root):
    result = {}
    for group, pattern in [('platforms', r'android-([0-9]+)'), ('build-tools', r'([0-9]+\.[0-9]+\.[0-9]+)'), ('ndk', r'([0-9]+\.[0-9]+\.[0-9]+)')]:
        candidates = []
        for path in (root / group).glob('*'):
            match = re.fullmatch(pattern, path.name)
            if match and (path / 'source.properties').is_file():
                candidates.append((tuple(map(int, match[1].split('.'))), group + ';' + path.name))
        if candidates:
            result[group] = max(candidates)[1]
    return result


def dock_items(existing, apps):
    """Retain every unrelated tile and existing order; append missing selected apps."""
    result = list(existing)
    ids = {item.get('tile-data', {}).get('bundle-identifier', '').lower() for item in existing}
    paths = {item.get('tile-data', {}).get('file-data', {}).get('_CFURLString') for item in existing}
    for app in apps:
        uri = app['path'].as_uri() + '/'
        if app['id'].lower() in ids or uri in paths:
            continue
        result.append({'tile-type': 'file-tile', 'tile-data': {
            'bundle-identifier': app['id'], 'file-label': app['path'].stem,
            'file-type': 41, 'file-data': {'_CFURLString': uri, '_CFURLStringType': 15}}})
        ids.add(app['id'].lower()); paths.add(uri)
    return result


def yamagi_data_root(home, environment):
    # yquake2 8.70, USE_XDG: existing ~/.yq2 takes precedence over XDG_DATA_HOME.
    legacy = home / '.yq2'
    if legacy.is_dir():
        return legacy
    return Path(environment.get('XDG_DATA_HOME', str(home / '.local/share'))) / 'YamagiQ2'


def power_values(text):
    sections, current = {}, None
    for line in text.splitlines():
        if line.strip() in ('AC Power:', 'Battery Power:'):
            current = line.strip(); sections[current] = {}
        elif current:
            match = re.match(r'\s*(\w+)\s+(\d+)\s*$', line)
            if match:
                sections[current][match[1]] = int(match[2])
    return sections


class Workstation:
    def __init__(self, args, home=None, prefix=None, applications=None):
        self.args = args
        self.preview = args.check or args.dry_run
        self.home = Path(home or Path.home())
        self.prefix = Path(prefix or '/opt/homebrew')
        self.applications = Path(applications or '/Applications')
        self.state = self.home / 'Library/Application Support/lan-ipxe/workstation'
        self.manifest = read_json(PAYLOAD / 'manifest.json')
        self.events = []
        self.restart = set()
        self.brew = self.prefix / 'bin/brew'
        self.env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_INSTALL_CLEANUP='1',
                        HOMEBREW_NO_ANALYTICS='1', PATH=str(self.prefix / 'bin') + ':' + os.environ.get('PATH', ''))
        self.apps = self.scan_apps()
        self.outdated = set()
        self.updated = False
        self.receipts = read_json(self.state / 'receipts.json', {})
        self.original_receipts = json.dumps(self.receipts, sort_keys=True)
        self.run_id = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid())
        self.live_log = None

    def emit(self, kind, label, detail=''):
        event = {'status': kind, 'item': label, 'detail': detail}
        self.events.append(event)
        print(f'{kind:8} {label}' + (': ' + detail if detail else ''), flush=True)
        if self.live_log is not None:
            with self.live_log.open('a') as stream:
                stream.write(json.dumps(event) + '\n')

    def attempt(self, label, function, *args):
        if not self.preview:
            self.emit('START', label)
        try:
            return function(*args)
        except Deferred as exc:
            self.emit('MANUAL', label, str(exc))
        except (OSError, ValueError, RuntimeError, KeyError, StopIteration, subprocess.SubprocessError, plistlib.InvalidFileException) as exc:
            self.emit('FAILED', label, str(exc) or type(exc).__name__)
        return None

    def command(self, argv, *, mutate=False, capture=True, check=True, env=None, timeout=120):
        if mutate and self.preview:
            raise RuntimeError('Preview attempted a mutation: ' + str(argv[0]))
        args = [str(arg) for arg in argv]
        # Captured checks must never wait on hidden input or leave descendants
        # holding their output pipes open. Interactive installers retain the TTY.
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL if capture else None,
                                   stdout=subprocess.PIPE if capture else None,
                                   stderr=subprocess.PIPE if capture else None,
                                   start_new_session=capture, env=env or self.env, text=True)
        started = time.monotonic()
        while True:
            elapsed = time.monotonic() - started
            interval = max(0.01, min(30, timeout - elapsed)) if capture else 30
            try:
                stdout, stderr = process.communicate(timeout=interval)
                break
            except subprocess.TimeoutExpired:
                if capture and time.monotonic() - started >= timeout:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    # A helper that deliberately detached from the process group
                    # must not keep this cleanup waiting on an inherited pipe.
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.stdout.close(); process.stderr.close()
                    raise RuntimeError(f'{Path(args[0]).name} timed out after {timeout:g}s; later steps will continue') from None
                self.emit('WAIT', Path(args[0]).name, f'still running after {int(time.monotonic() - started)}s')
            except KeyboardInterrupt:
                if capture:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                raise
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        if check and result.returncode:
            # Do not echo arbitrary command output (may include private paths/config).
            raise RuntimeError(f'{Path(argv[0]).name} failed with exit {result.returncode}')
        return result

    def fetch(self, url, destination=None):
        if self.preview:
            raise RuntimeError('Preview attempted network access')
        if urllib.parse.urlparse(url).scheme != 'https':
            raise ValueError('Download must use HTTPS')
        request = urllib.request.Request(url, headers={'User-Agent': 'lan-ipxe-macos-workstation'})
        with urllib.request.urlopen(request, timeout=120) as response:
            if urllib.parse.urlparse(response.url).scheme != 'https':
                raise ValueError('Refusing insecure download redirect')
            if destination:
                with Path(destination).open('wb') as stream:
                    shutil.copyfileobj(response, stream)
                return None
            return response.read()

    def file(self, path, content, mode=0o644):
        path = Path(path)
        if isinstance(content, str):
            content = content.encode()
        if path.is_symlink():
            raise Deferred('Managed file is a symlink; preserve and reconcile manually: ' + str(path))
        if path.exists() and path.stat().st_uid != os.getuid():
            raise Deferred('Managed file is owned by another user: ' + str(path))
        old = path.read_bytes() if path.exists() else None
        if old == content and path.stat().st_mode & 0o777 == mode:
            return False
        if self.preview:
            self.emit('DRIFT', str(path), 'merge/update managed content')
            return True
        path.parent.mkdir(parents=True, exist_ok=True)
        if old is not None:
            self.backup(path, old)
        fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), mode)
                stream.write(content)
                stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self.emit('CHANGED', str(path))
        return True

    def backup(self, path, content):
        if self.preview:
            raise RuntimeError('Preview attempted backup')
        folder = self.state / 'backups' / self.run_id
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = folder / (hashlib.sha256(str(path).encode()).hexdigest()[:12] + '-' + Path(path).name)
        if not target.exists():
            with target.open('xb') as stream:
                os.chmod(target, 0o600); stream.write(content)

    def link(self, path, target):
        path, target = Path(path), Path(target)
        if path.is_symlink() and path.resolve() == target.resolve():
            return
        prior = self.receipts.get('links', {}).get(str(path))
        if (path.exists() or path.is_symlink()) and not (path.is_symlink() and os.readlink(path) == prior):
            raise Deferred('Command/path collision: ' + str(path))
        if not target.exists():
            raise Deferred('Link target missing: ' + str(target))
        if self.preview:
            self.emit('DRIFT', str(path), 'link to ' + str(target)); return
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
        try:
            temporary.symlink_to(target); os.replace(temporary, path)
        finally:
            if temporary.is_symlink():
                temporary.unlink()
        self.receipts.setdefault('links', {})[str(path)] = str(target)
        self.emit('CHANGED', str(path), 'public command/link')

    def scan_apps(self):
        result = []
        for root in (self.applications, self.home / 'Applications'):
            if not root.exists():
                continue
            # One nested level includes ETLegacy without traversing bundle contents.
            paths = list(root.glob('*.app')) + list(root.glob('*/*.app'))
            for path in paths:
                try:
                    info = read_plist(path / 'Contents/Info.plist')
                    if info.get('CFBundleIdentifier'):
                        result.append({'path': path, 'id': info['CFBundleIdentifier'],
                                       'version': info.get('CFBundleShortVersionString') or info.get('CFBundleVersion', 'unknown'),
                                       'store': (path / 'Contents/_MASReceipt/receipt').exists(), 'info': info})
                except (OSError, ValueError, plistlib.InvalidFileException):
                    continue
        return result

    def app_for(self, app):
        ids = {value.lower() for value in [app['id']] + app.get('alternatives', [])}
        matches = [a for a in self.apps if a['id'].lower() in ids]
        if len(matches) > 1:
            raise Deferred('Multiple apps share bundle ID ' + app['id'])
        return matches[0] if matches else None

    def formula_installed(self, name):
        canonical = self.manifest['aliases'].get(name, name)
        # opt aliases also accommodate future current Python versions offline.
        roots = [self.prefix / 'Cellar' / canonical, self.prefix / 'opt' / name]
        return any(root.exists() and (list(root.glob('*/INSTALL_RECEIPT.json')) or
                                     (root / 'INSTALL_RECEIPT.json').is_file()) for root in roots)

    def prepare_brew(self):
        if self.preview:
            self.emit('CURRENT' if self.brew.exists() else 'DRIFT', 'Homebrew', 'offline installed-state inspection; upstream versions are not checked')
            return
        if not self.brew.exists():
            raise RuntimeError('Homebrew bootstrap did not produce native brew')
        snapshot = self.command([self.brew, 'info', '--json=v2', '--installed']).stdout
        self.file(self.state / 'snapshots' / (self.run_id + '.json'), snapshot, 0o600)
        if not self.args.no_upgrade:
            self.command([self.brew, 'update'], mutate=True, capture=False)
            data = json.loads(self.command([self.brew, 'outdated', '--json=v2']).stdout)
            self.outdated = {item.get('name', item.get('token')) for group in data.values() for item in group}
        self.updated = True

    def package(self, name, kind='formula'):
        installed = self.formula_installed(name) if kind == 'formula' else (self.prefix / 'Caskroom' / name / '.metadata').is_dir()
        if self.preview:
            self.emit('CURRENT' if installed else 'DRIFT', kind + ' ' + name)
            return
        if not self.updated:
            raise Deferred('Package metadata preparation failed')
        canonical = self.manifest['aliases'].get(name, name)
        if installed and (self.args.no_upgrade or not {name, canonical} & self.outdated):
            self.emit('CURRENT', kind + ' ' + name); return
        data = json.loads(self.command([self.brew, 'info', '--json=v2', '--' + kind, name]).stdout)
        info = data['formulae' if kind == 'formula' else 'casks'][0]
        if info.get('disabled') or info.get('deprecated'):
            raise Deferred('Homebrew has disabled/deprecated ' + name)
        if kind == 'formula':
            bottles = info.get('bottle', {}).get('stable', {}).get('files', {})
            if not any(key == 'all' or key.startswith('arm64_') and key != 'arm64_linux' for key in bottles):
                raise Deferred('No validated Apple Silicon bottle for ' + name)
        if kind == 'cask' and installed and info.get('auto_updates'):
            self.emit('CURRENT', name, 'native app updater retained'); return
        if kind == 'cask' and 'Rosetta' in (info.get('caveats') or ''):
            self.rosetta()
        operation = 'upgrade' if installed else 'install'
        self.command([self.brew, operation, '--no-ask', '--' + kind, name], mutate=True, capture=False)
        okay = self.formula_installed(name) if kind == 'formula' else (self.prefix / 'Caskroom' / name / '.metadata').is_dir()
        if not okay:
            raise RuntimeError('Package postcondition missing: ' + name)
        self.emit('CHANGED', kind + ' ' + name, operation)

    def rosetta(self):
        receipt = self.command(['/usr/sbin/pkgutil', '--pkg-info', 'com.apple.pkg.RosettaUpdateAuto'], check=False)
        if receipt.returncode:
            if not sys.stdin.isatty():
                raise Deferred('Selected Intel app requires Rosetta; rerun in a terminal for Apple license interaction')
            self.command(['/usr/sbin/softwareupdate', '--install-rosetta'], mutate=True, capture=False)

    def validate_app(self, path, app, signed=False, allow_intel=False):
        info = read_plist(path / 'Contents/Info.plist')
        if info.get('CFBundleIdentifier', '').lower() != app['id'].lower():
            raise RuntimeError('Unexpected bundle identity for ' + app['name'])
        executable = path / 'Contents/MacOS' / info.get('CFBundleExecutable', '')
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeError('Missing executable for ' + app['name'])
        architecture = self.command(['/usr/bin/file', '-b', executable]).stdout
        if 'arm64' not in architecture and 'script' not in architecture.lower():
            if allow_intel and 'x86_64' in architecture:
                self.rosetta()
            else:
                raise Deferred('Native ARM64 executable not verified for ' + app['name'])
        if signed:
            self.command(['/usr/bin/codesign', '--verify', '--deep', '--strict', path])
            self.command(['/usr/sbin/spctl', '--assess', '--type', 'execute', path])
            if app.get('team'):
                details = self.command(['/usr/bin/codesign', '-dv', '--verbose=4', path]).stderr
                if 'TeamIdentifier=' + app['team'] not in details:
                    raise RuntimeError('Unexpected signing team for ' + app['name'])
        return info

    @contextlib.contextmanager
    def mounted(self, image):
        result = self.command(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', image], mutate=True)
        mounts = [Path(e['mount-point']) for e in plistlib.loads(result.stdout.encode())['system-entities'] if 'mount-point' in e]
        if len(mounts) != 1:
            for mount in mounts:
                self.command(['/usr/bin/hdiutil', 'detach', mount], mutate=True, check=False)
            raise RuntimeError('Expected one DMG volume')
        try:
            yield mounts[0]
        finally:
            self.command(['/usr/bin/hdiutil', 'detach', mounts[0]], mutate=True)

    def download_verified(self, url, sha256, target):
        self.fetch(url, target)
        digest = hashlib.sha256(Path(target).read_bytes()).hexdigest()
        if sha256 and digest != sha256:
            raise RuntimeError('Artifact SHA-256 mismatch')
        return digest

    def release(self, app):
        # Reviewed pins for games; GUI application releases can resolve newer stable tags.
        if app['profile'] == 'full' or self.args.no_upgrade:
            return app['tag'], app['asset'], app['sha256']
        data = json.loads(self.fetch('https://api.github.com/repos/' + app['repo'] + '/releases/latest'))
        if data.get('prerelease') or data.get('draft'):
            raise Deferred('No stable release for ' + app['repo'])
        assets = [a for a in data['assets'] if a['name'].endswith('.dmg') and ('aarch64' in a['name'] or 'arm64' in a['name'])]
        if len(assets) != 1:
            raise Deferred('Ambiguous native release asset for ' + app['repo'])
        asset = assets[0]
        digest = asset.get('digest', '') or ''
        if not digest.startswith('sha256:'):
            if data['tag_name'] == app['tag'] and asset['name'] == app['asset']:
                return app['tag'], app['asset'], app['sha256']
            raise Deferred('New release has no verifiable digest: ' + app['repo'])
        return data['tag_name'], asset['name'], digest[7:]

    def direct_app(self, app, current):
        receipt = self.receipts.get('apps', {}).get(app['id'], {})
        if current and not app.get('strict_source'):
            self.emit('CURRENT', app['name'], 'existing native app retained'); return
        if current and receipt.get('repo') == app.get('repo') and receipt.get('sha256') == app.get('sha256'):
            executable = current['path'] / 'Contents/MacOS' / current['info']['CFBundleExecutable']
            if hashlib.sha256(executable.read_bytes()).hexdigest() == receipt.get('executable_sha256'):
                self.emit('CURRENT', app['name'], 'verified ' + app['repo']); return
        if self.preview:
            self.emit('DRIFT', app['name'], 'verify/reconcile ' + app.get('repo', app.get('url', 'release'))); return
        with tempfile.TemporaryDirectory(prefix='macos-workstation-') as temporary:
            image = Path(temporary) / 'release.dmg'
            if 'repo' in app:
                tag, asset, checksum = self.release(app)
                url = 'https://github.com/' + app['repo'] + '/releases/download/' + urllib.parse.quote(tag, safe='') + '/' + asset
            else:
                tag, checksum, url = 'vendor-current', None, app['url']
            digest = self.download_verified(url, checksum, image)
            with self.mounted(image) as mount:
                candidates = [p for p in mount.glob('*.app') if read_plist(p / 'Contents/Info.plist').get('CFBundleIdentifier', '').lower() == app['id'].lower()]
                if len(candidates) != 1:
                    raise RuntimeError('Expected one matching app in ' + app['name'] + ' release')
                source = candidates[0]
                info = self.validate_app(source, app, signed=not checksum)
                executable_digest = hashlib.sha256((source / 'Contents/MacOS' / info['CFBundleExecutable']).read_bytes()).hexdigest()
                # Unknown Cro-Mag copy may be adopted only after exact executable comparison.
                if current:
                    existing = current['path'] / 'Contents/MacOS' / current['info']['CFBundleExecutable']
                    if hashlib.sha256(existing.read_bytes()).hexdigest() != executable_digest:
                        raise Deferred('Existing Cro-Mag Rally is not the approved fork executable; move its app aside and rerun (data stays untouched)')
                    destination = current['path']
                else:
                    destination = self.applications / app['app']
                    if destination.exists():
                        raise Deferred('Application destination collision: ' + str(destination))
                    staged = self.applications / ('.lan-ipxe-' + uuid.uuid4().hex + '.app')
                    privileged = not os.access(self.applications, os.W_OK)
                    prefix = ['/usr/bin/sudo'] if privileged else []
                    try:
                        self.command(prefix + ['/usr/bin/ditto', source, staged], mutate=True, capture=not privileged)
                        self.validate_app(staged, app, signed=not checksum)
                        self.command(prefix + ['/bin/mv', '-n', staged, destination], mutate=True, capture=not privileged)
                        if staged.exists():
                            raise RuntimeError('Application destination appeared during install')
                    finally:
                        if staged.exists():
                            self.command(prefix + ['/bin/rm', '-rf', staged], mutate=True, capture=not privileged)
                self.receipts.setdefault('apps', {})[app['id']] = {'repo': app.get('repo'), 'tag': tag, 'sha256': digest,
                    'path': str(destination), 'executable_sha256': executable_digest}
                self.apps = self.scan_apps()
                self.emit('CHANGED', app['name'], 'verified release ' + tag)

    def application(self, app):
        current = self.app_for(app)
        if current and current['store']:
            self.emit('EXCLUDED', app['name'], 'App Store installation ignored'); return
        if app.get('cask'):
            owned = (self.prefix / 'Caskroom' / app['cask'] / '.metadata').is_dir()
            if current and not owned:
                self.emit('CURRENT', app['name'], 'existing direct/native owner'); return
            destination = self.applications / app['app']
            if not current and destination.exists():
                raise Deferred('Conflicting app bundle at ' + str(destination))
            if app['cask'] == 'battle-net' and not current:
                raise Deferred('Run the official Battle.net installer interactively: https://www.blizzard.com/apps/battle.net/desktop')
            self.package(app['cask'], 'cask')
            if not self.preview:
                self.apps = self.scan_apps()
                current = self.app_for(app)
                if not current:
                    raise RuntimeError('Installed cask has unexpected/missing app identity: ' + app['id'])
                self.validate_app(current['path'], app, allow_intel=True)
        elif app.get('archive'):
            self.archive_app(app, current)
        else:
            self.direct_app(app, current)
        if app.get('cli'):
            current = self.app_for(app)
            if not current:
                if self.preview:
                    self.emit('DRIFT', app['name'] + ' CLI', 'link bundled command after app installation'); return
                raise RuntimeError('App missing for bundled CLI: ' + app['name'])
            if not self.preview:
                self.validate_app(current['path'], app, signed=True)
            for name, relative in app['cli'].items():
                target = current['path'] / relative
                if not target.is_file() or not os.access(target, os.X_OK):
                    raise RuntimeError('Bundled command is missing or not executable: ' + name)
                public = shutil.which(name, path=self.env['PATH'])
                if public and Path(public).resolve() != target.resolve():
                    raise Deferred('Existing ' + name + ' command has a different owner: ' + public)
                self.link(self.home / '.local/bin' / name, target)

    def archive_app(self, app, current):
        if current:
            self.emit('CURRENT', app['name'], 'existing native engine retained'); return
        if self.preview:
            self.emit('DRIFT', app['name'], 'engine-only archive ' + app['url']); return
        destination = self.applications / app['folder']
        if destination.exists():
            raise Deferred('Existing engine directory has no matching app; preserve and reconcile manually')
        import tarfile
        with tempfile.TemporaryDirectory(prefix='macos-engine-') as temporary:
            folder = Path(temporary)
            archive = folder / 'engine.tar.gz'
            self.download_verified(app['url'], app['sha256'], archive)
            with tarfile.open(archive) as contents:
                for member in contents.getmembers():
                    if member.name.startswith('/') or '..' in Path(member.name).parts or member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                        raise RuntimeError('Unexpected archive member')
            self.command(['/usr/bin/tar', '-xzf', archive, '-C', folder], mutate=True)
            source = folder / app['archive_root']
            self.validate_app(source / app['app'], app)
            privileged = [] if os.access(self.applications, os.W_OK) else ['/usr/bin/sudo']
            staged = self.applications / ('.lan-ipxe-' + uuid.uuid4().hex)
            try:
                self.command(privileged + ['/usr/bin/ditto', source, staged], mutate=True, capture=not privileged)
                self.command(privileged + ['/bin/mv', '-n', staged, destination], mutate=True, capture=not privileged)
                if staged.exists():
                    raise RuntimeError('Engine destination appeared during install')
            finally:
                if staged.exists():
                    self.command(privileged + ['/bin/rm', '-rf', staged], mutate=True, capture=not privileged)
            self.apps = self.scan_apps()
            self.emit('CHANGED', app['name'], 'engine archive; original game assets omitted')

    def native_cli(self, name):
        path = self.home / '.local/bin' / name
        existing = path if path.exists() else None
        if not existing:
            for folder in (self.prefix / 'bin', Path('/usr/local/bin')):
                if (folder / name).exists():
                    existing = folder / name; break
        if self.preview:
            self.emit('CURRENT' if existing else 'DRIFT', name, 'native CLI; no execution in preview'); return
        if existing:
            if self.args.no_upgrade or name == 'agy':
                self.emit('CURRENT', name, 'existing owner retained'); return
            target = existing.resolve()
            owned = (name == 'codex' and str(target).startswith(str(self.home / '.codex/packages/standalone/releases') + '/')) or (
                name == 'claude' and str(target).startswith(str(self.home / '.local/share/claude/versions') + '/'))
            if not owned:
                self.emit('CURRENT', name, 'other installer owner retained'); return
        if name == 'agy':
            self.package('antigravity-cli', 'cask')
            if not (self.prefix / 'bin/agy').exists():
                raise RuntimeError('Antigravity CLI command missing')
            return
        url = {'codex': 'https://chatgpt.com/codex/install.sh', 'claude': 'https://claude.ai/install.sh'}[name]
        with tempfile.TemporaryDirectory(prefix='macos-cli-') as temporary:
            installer = Path(temporary) / 'install.sh'
            self.fetch(url, installer)
            shell = '/bin/sh' if name == 'codex' else '/bin/bash'
            self.command([shell, '-n', installer])
            env = dict(self.env, PATH=str(self.home / '.local/bin') + ':' + self.env['PATH'])
            if name == 'codex':
                env.update(CODEX_INSTALL_DIR=str(self.home / '.local/bin'), CODEX_NON_INTERACTIVE='true',
                           CODEX_INSTALLER_USE_RELEASES_OPENAI_COM='true')
            self.command([shell, installer], mutate=True, capture=False, env=env)
        if not path.exists() or not os.access(path, os.X_OK):
            raise RuntimeError(name + ' native installation did not produce a command')
        self.emit('CHANGED', name, 'official native installer (upstream verifies release checksums)')

    def powershell(self):
        path = Path('/usr/local/microsoft/powershell/7/pwsh')
        if self.preview:
            self.emit('CURRENT' if path.exists() else 'DRIFT', 'PowerShell', 'official Microsoft package'); return
        if path.exists() and self.args.no_upgrade:
            self.link(self.home / '.local/bin/pwsh', path); return
        data = json.loads(self.fetch('https://api.github.com/repos/PowerShell/PowerShell/releases/latest'))
        version = data['tag_name'].lstrip('v')
        if path.exists():
            installed = self.command([path, '-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']).stdout.strip()
            if tuple(map(int, installed.split('.'))) >= tuple(map(int, version.split('.'))):
                self.emit('CURRENT', 'PowerShell', installed)
                self.link(self.home / '.local/bin/pwsh', path); return
        elif (self.prefix / 'bin/pwsh').exists() or Path('/usr/local/bin/pwsh').exists():
            raise Deferred('Existing PowerShell has a different installer owner')
        asset = next(a for a in data['assets'] if a['name'] == 'powershell-' + version + '-osx-arm64.pkg')
        digest = asset.get('digest') or ''
        if not digest.startswith('sha256:'):
            raise Deferred('PowerShell release lacks SHA-256')
        with tempfile.TemporaryDirectory(prefix='macos-pwsh-') as temporary:
            package = Path(temporary) / 'PowerShell.pkg'
            self.download_verified(asset['browser_download_url'], digest[7:], package)
            self.command(['/usr/sbin/pkgutil', '--check-signature', package])
            self.command(['/usr/sbin/spctl', '--assess', '--type', 'install', package])
            self.command(['/usr/bin/sudo', '/usr/sbin/installer', '-pkg', package, '-target', '/'], mutate=True, capture=False)
        if not path.exists():
            raise RuntimeError('Official PowerShell package postcondition missing')
        self.link(self.home / '.local/bin/pwsh', path)
        self.emit('CHANGED', 'PowerShell', version)

    def speedtest(self):
        path = self.home / '.local/bin/speedtest'
        if path.exists() or (self.prefix / 'bin/speedtest').exists():
            # Official binary includes Ookla in --version; don't accidentally accept Python's namesake.
            if self.preview:
                self.emit('CURRENT', 'Speedtest command', 'identity unverified offline'); return
            executable = path if path.exists() else self.prefix / 'bin/speedtest'
            if 'Ookla' not in self.command([executable, '--version']).stdout:
                raise Deferred('speedtest collision with a non-Ookla command')
            self.emit('CURRENT', 'Ookla Speedtest', 'presence-only update policy'); return
        if self.preview:
            self.emit('DRIFT', 'Ookla Speedtest', 'official universal 1.2.0'); return
        with tempfile.TemporaryDirectory(prefix='macos-speedtest-') as temporary:
            folder = Path(temporary)
            archive = folder / 'speedtest.tgz'
            self.download_verified('https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-macosx-universal.tgz',
                                   'c9f8192149ebc88f8699998cecab1ce144144045907ece6f53cf50877f4de66f', archive)
            self.command(['/usr/bin/tar', '-xzf', archive, '-C', folder, 'speedtest'], mutate=True)
            self.file(path, (folder / 'speedtest').read_bytes(), 0o755)

    def rust(self):
        root = self.home / '.rustup'
        toolchain = root / 'toolchains/stable-aarch64-apple-darwin'
        components = ['rustfmt', 'clippy', 'rust-analyzer']
        installed = (toolchain / 'lib/rustlib/components')
        text = installed.read_text() if installed.exists() else ''
        missing = [name for name in components if not any(line.startswith(name) for line in text.splitlines())]
        if self.preview:
            self.emit('DRIFT' if missing or not toolchain.exists() else 'CURRENT', 'Rust stable native toolchain', ', '.join(missing)); return
        rustup = self.prefix / 'opt/rustup/bin/rustup'
        if not rustup.exists():
            raise Deferred('Homebrew rustup is missing')
        if not toolchain.exists() or not self.args.no_upgrade:
            self.command([rustup, 'toolchain', 'install', 'stable', '--profile', 'minimal', '--no-self-update'], mutate=True, capture=False)
        if missing:
            self.command([rustup, 'component', 'add', '--toolchain', 'stable'] + missing, mutate=True, capture=False)
        settings = root / 'settings.toml'
        if not settings.exists() or not re.search(r'^default_toolchain\s*=', settings.read_text(), re.M):
            self.command([rustup, 'default', 'stable'], mutate=True, capture=False)
        self.emit('CURRENT', 'Rust', 'native stable + rustfmt/clippy/rust-analyzer; project overrides preserved')

    def sdk_root(self):
        left, right = os.environ.get('ANDROID_HOME'), os.environ.get('ANDROID_SDK_ROOT')
        if left and right and Path(left).resolve() != Path(right).resolve():
            raise Deferred('ANDROID_HOME and ANDROID_SDK_ROOT disagree')
        root = Path(left or right or self.home / 'Library/Android/sdk').expanduser()
        if not root.is_absolute():
            raise Deferred('Android SDK root must be an absolute path')
        return root

    def platform_tools(self):
        root = self.sdk_root()
        target = root / 'platform-tools'
        existing = (target / 'adb').is_file() and (target / 'fastboot').is_file()
        candidates = [self.prefix / 'bin/adb', self.home / '.local/bin/adb', Path('/usr/local/bin/adb')]
        public = shutil.which('adb', path=self.env['PATH'])
        if public:
            candidates.append(Path(public))
        if any(path.exists() and path.resolve() != (target / 'adb').resolve() for path in candidates):
            raise Deferred('Existing adb outside selected SDK root; reconcile its owner before Android provisioning')
        if self.preview:
            self.emit('CURRENT' if existing else 'DRIFT', 'Android platform-tools', str(target)); return
        managed = self.receipts.get('platform_tools', {}).get('root') == str(root)
        if existing and (not managed or self.args.no_upgrade or self.args.profile == 'full'):
            self.emit('CURRENT', 'Android platform-tools', 'existing Google SDK owner'); return
        data = json.loads(self.fetch('https://formulae.brew.sh/api/cask/android-platform-tools.json'))
        if data.get('disabled') or data.get('deprecated') or not re.fullmatch('[a-f0-9]{64}', data['sha256']):
            raise Deferred('No supported verifiable Google platform-tools archive')
        if existing and self.receipts['platform_tools'].get('sha256') == data['sha256']:
            self.emit('CURRENT', 'Android platform-tools'); return
        if target.exists() and not managed:
            raise Deferred('Unmanaged/incomplete platform-tools directory')
        if not data['url'].startswith('https://dl.google.com/android/repository/platform-tools_'):
            raise RuntimeError('Unexpected platform-tools source')
        with tempfile.TemporaryDirectory(prefix='macos-android-') as temporary:
            archive = Path(temporary) / 'tools.zip'
            self.download_verified(data['url'], data['sha256'], archive)
            self.command(['/usr/bin/ditto', '-xk', archive, temporary], mutate=True)
            source = Path(temporary) / 'platform-tools'
            for name in ['adb', 'fastboot']:
                if 'arm64' not in self.command(['/usr/bin/file', '-b', source / name]).stdout:
                    raise RuntimeError('Platform tools lack ARM64')
            root.mkdir(parents=True, exist_ok=True)
            stage = root / ('.platform-tools-' + uuid.uuid4().hex)
            self.command(['/usr/bin/ditto', source, stage], mutate=True)
            if target.exists():
                backup = root / ('platform-tools.backup-' + self.run_id)
                target.rename(backup)
            try:
                stage.rename(target)
            except OSError:
                if 'backup' in locals():
                    backup.rename(target)
                raise
        self.receipts['platform_tools'] = {'root': str(root), 'version': data['version'], 'sha256': data['sha256']}
        self.emit('CHANGED', 'Android platform-tools', str(target))

    def android(self):
        root = self.sdk_root()
        self.package('android-commandlinetools', 'cask')
        manager = self.prefix / 'share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager'
        if self.preview:
            required = self.receipts.get('android', {}).get('packages', [])
            present = required and all((root / name.replace(';', '/') / 'source.properties').exists() for name in required)
            self.emit('CURRENT' if present else 'DRIFT', 'Android stable SDK/build-tools/NDK',
                      str(root) + '; upstream stable versions and licenses checked only during apply')
            return
        if not (root / 'platform-tools/adb').exists():
            raise Deferred('Resolve platform-tools before provisioning the full SDK')
        java = self.prefix / 'opt/openjdk/libexec/openjdk.jdk/Contents/Home'
        studio = self.app_for({'id': 'com.google.android.studio'})
        # A freshly downloaded Studio helper can block at macOS first-launch
        # assessment. Full already includes Homebrew's standalone JDK.
        if not (java / 'bin/java').exists() and studio:
            java = studio['path'] / 'Contents/jbr/Contents/Home'
        if not (java / 'bin/java').exists():
            raise Deferred('Android requires the full JDK/Studio runtime')
        env = dict(self.env, JAVA_HOME=str(java), ANDROID_HOME=str(root), ANDROID_SDK_ROOT=str(root))
        args = [manager, '--sdk_root=' + str(root)]
        receipt = self.receipts.get('android', {})
        packages = receipt.get('packages', []) if self.args.no_upgrade and receipt.get('root') == str(root) else []
        if not packages:
            retained = installed_sdk_versions(root) if self.args.no_upgrade else {}
            if len(retained) == 3:
                packages = list(retained.values())
            else:
                listing = self.command(args + ['--list', '--channel=0'], mutate=True, env=env).stdout
                packages = [retained.get(name.split(';')[0], name) for name in sdk_versions(listing)]
        missing = [name for name in packages if not (root / name.replace(';', '/') / 'source.properties').exists()]
        if missing:
            if not sys.stdin.isatty():
                raise Deferred('Rerun full in a terminal to review Android SDK licenses')
            self.command(args + ['--licenses'], mutate=True, capture=False, env=env)
            # The selected SDK is the sole platform-tools owner in both profiles.
            self.command(args + ['--install'] + missing, mutate=True, capture=False, env=env)
        if not self.args.no_upgrade:
            self.command(args + ['--install', 'platform-tools'], mutate=True, capture=False, env=env)
        if not all((root / name.replace(';', '/') / 'source.properties').exists() for name in packages):
            raise Deferred('Android licenses/packages are incomplete')
        self.link(root / 'cmdline-tools/latest', manager.parent.parent)
        ndk = next(name for name in packages if name.startswith('ndk;')).split(';')[1]
        self.link(root / 'ndk/current', root / 'ndk' / ndk)
        self.receipts['android'] = {'root': str(root), 'packages': packages}
        self.receipts['platform_tools'] = {'root': str(root), 'owner': 'Google SDK repository'}
        self.emit('CURRENT', 'Android', ', '.join(packages))

    def shell(self):
        config = self.home / '.config/lan-ipxe'
        for name in ('environment.sh', 'bashrc'):
            self.file(config / name, (PAYLOAD / name).read_bytes())
        fragments = {
            '.bash_profile': ('login', '[ ! -r "$HOME/.config/lan-ipxe/environment.sh" ] || . "$HOME/.config/lan-ipxe/environment.sh"\ncase $- in *i*) [ -n "${_WORKSTATION_BASH_LOADED-}" ] || [ ! -r "$HOME/.bashrc" ] || . "$HOME/.bashrc" ;; esac'),
            '.bashrc': ('interactive', '[ ! -r "$HOME/.config/lan-ipxe/bashrc" ] || . "$HOME/.config/lan-ipxe/bashrc"'),
            '.zprofile': ('environment', '[ ! -r "$HOME/.config/lan-ipxe/environment.sh" ] || . "$HOME/.config/lan-ipxe/environment.sh"'),
            '.vimrc': ('vim', 'source ' + str(config / 'vimrc').replace(' ', '\\ '))}
        self.file(config / 'vimrc', (PAYLOAD.parent / 'vimrc').read_bytes())
        for name, (tag, body) in fragments.items():
            path = self.home / name
            old = path.read_text() if path.exists() else ''
            if name == '.vimrc':
                # Vim uses a double quote for comments, not Bash's hash.
                start, end = '" >>> lan-ipxe vim >>>', '" <<< lan-ipxe vim <<<'
                if old.count(start) != old.count(end) or old.count(start) > 1:
                    raise Deferred('Malformed managed Vim block')
                block = start + '\n' + body + '\n' + end + '\n'
                new = re.sub(re.escape(start) + r'[\s\S]*?' + re.escape(end) + r'\n?', lambda _: block, old) if start in old else old + ('\n' if old and not old.endswith('\n') else '') + block
            else:
                new = managed_block(old, tag, body)
            mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
            self.file(path, new, mode)

    def editor(self):
        desired = read_json(PAYLOAD / 'editor.json')
        settings = self.home / 'Library/Application Support/Code/User/settings.json'
        text = settings.read_text() if settings.exists() else '{}\n'
        self.file(settings, merge_jsonc(text, desired['settings']))
        app = self.app_for({'id': 'com.microsoft.VSCode'})
        installed = read_json(self.home / '.vscode/extensions/extensions.json', [])
        ids = {item.get('identifier', {}).get('id', '').lower() for item in installed}
        missing = [name for name in desired['extensions'] if name.lower() not in ids]
        if self.preview:
            for name in missing:
                self.emit('DRIFT', 'VS Code extension ' + name)
        elif app:
            code = app['path'] / 'Contents/Resources/app/bin/code'
            actual = set(self.command([code, '--list-extensions']).stdout.lower().splitlines())
            for name in desired['extensions']:
                if name.lower() not in actual:
                    self.attempt('VS Code extension ' + name, lambda n=name: self.command(
                        [code, '--install-extension', n], mutate=True, capture=False))
            actual = set(self.command([code, '--list-extensions']).stdout.lower().splitlines())
            if any(name.lower() not in actual for name in desired['extensions']):
                raise RuntimeError('Some required VS Code extensions remain missing')
        else:
            raise Deferred('VS Code is missing; extension installation deferred')
        if app:
            self.link(self.home / '.local/bin/code', app['path'] / 'Contents/Resources/app/bin/code')

    def preferences(self, domain):
        result = self.command(['/usr/bin/defaults', 'export', domain, '-'], check=False)
        if result.returncode:
            # Domain absence is normal; do not confuse malformed existing plists with absence.
            path = self.home / 'Library/Preferences' / (domain + '.plist')
            return read_plist(path)
        return plistlib.loads(result.stdout.encode())

    def preference(self, domain, key, desired, current):
        old = current.get(key)
        value = merge_dict(old or {}, desired) if isinstance(desired, dict) else desired
        if type(old) is type(value) and old == value:
            return False
        if self.preview:
            self.emit('DRIFT', domain + ' ' + key, repr(value) if not isinstance(value, (dict, list)) else 'merge structured preference')
            return True
        self.backup(domain + '.plist', plistlib.dumps(current))
        if isinstance(value, bool):
            tail = ['-bool', 'true' if value else 'false']
        elif isinstance(value, int):
            tail = ['-int', str(value)]
        elif isinstance(value, float):
            tail = ['-float', str(value)]
        elif isinstance(value, str):
            tail = ['-string', value]
        else:
            xml = plistlib.dumps(value).decode()
            tail = [xml[xml.index('<plist version="1.0">') + 21:xml.rindex('</plist>')].strip()]
        self.command(['/usr/bin/defaults', 'write', domain, key] + tail, mutate=True)
        verified = self.preferences(domain).get(key)
        if verified != value or type(verified) is not type(value):
            raise RuntimeError('Preference verification failed: ' + domain + ' ' + key)
        current[key] = value
        if domain in ('com.apple.dock', 'com.apple.finder'):
            self.restart.add('Dock' if domain == 'com.apple.dock' else 'Finder')
        self.emit('CHANGED', domain + ' ' + key)
        return True

    def desktop(self):
        for domain, values in read_json(PAYLOAD / 'preferences.json').items():
            current = self.preferences(domain)
            for key, desired in values.items():
                self.attempt(domain + ' ' + key, self.preference, domain, key, desired, current)
        domain = 'com.apple.Terminal'
        current = self.preferences(domain)
        profile = read_plist(PAYLOAD / 'Clear Dark.terminal')
        self.preference(domain, 'Window Settings', {'Clear Dark': profile}, current)
        for key in ('Default Window Settings', 'Startup Window Settings'):
            self.preference(domain, key, 'Clear Dark', current)
        dock = self.preferences('com.apple.dock')
        managed_ids = [app['id'].lower() for app in self.selected_apps()]
        candidates = [app for app in self.apps if app['id'].lower() in managed_ids and not app['store']]
        candidates.sort(key=lambda a: managed_ids.index(a['id'].lower()))
        self.preference('com.apple.dock', 'persistent-apps', dock_items(dock.get('persistent-apps', []), candidates), dock)
        self.emit('NOTE', 'Desktop preferences', 'Some global changes take effect in new apps or after logout; no logout/reboot is initiated')

    def xcode(self):
        xcode = self.applications / 'Xcode.app'
        desired = xcode / 'Contents/Developer'
        if not desired.is_dir():
            raise Deferred('Supply Xcode.app yourself; App Store automation is excluded')
        current = self.command(['/usr/bin/xcode-select', '-p'], check=False).stdout.strip()
        if current != str(desired):
            if self.preview:
                self.emit('DRIFT', 'Xcode selection', str(desired)); return
            self.command(['/usr/bin/sudo', '/usr/bin/xcode-select', '--switch', desired], mutate=True, capture=False)
        # This status query does not accept licenses or run first-launch installation.
        env = dict(self.env, DEVELOPER_DIR=str(desired))
        result = self.command([desired / 'usr/bin/xcodebuild', '-checkFirstLaunchStatus'], env=env, check=False)
        if result.returncode:
            raise Deferred('Open Xcode and complete its license/first-launch steps, then rerun')
        self.emit('CURRENT', 'Xcode selection')

    def sharing(self):
        user = self.command(['/usr/bin/id', '-un']).stdout.strip()
        disabled = self.command(['/bin/launchctl', 'print-disabled', 'system'], check=False).stdout
        for service, group in [('com.openssh.sshd', 'com.apple.access_ssh'), ('com.apple.screensharing', 'com.apple.access_screensharing')]:
            membership = self.command(['/usr/sbin/dseditgroup', '-o', 'checkmember', '-m', user, group], check=False)
            enabled = re.search('"' + re.escape(service) + r'"\s*=>\s*false', disabled) is not None
            if self.preview:
                self.emit('CURRENT' if enabled and membership.returncode == 0 else 'DRIFT', service, 'restricted access group membership and service enablement'); continue
            if membership.returncode:
                exists = self.command(['/usr/bin/dscl', '.', '-read', '/Groups/' + group], check=False).returncode == 0
                if not exists:
                    self.command(['/usr/bin/sudo', '/usr/sbin/dseditgroup', '-o', 'create', group], mutate=True, capture=False)
                self.command(['/usr/bin/sudo', '/usr/sbin/dseditgroup', '-o', 'edit', '-a', user, '-t', 'user', group], mutate=True, capture=False)
            if not enabled:
                if service == 'com.openssh.sshd':
                    result = self.command(['/usr/bin/sudo', '/usr/sbin/systemsetup', '-setremotelogin', 'on'], mutate=True, capture=False, check=False)
                    if result.returncode:
                        raise Deferred('Enable Remote Login in System Settings; systemsetup may require Full Disk Access')
                else:
                    self.command(['/usr/bin/sudo', '/bin/launchctl', 'enable', 'system/' + service], mutate=True, capture=False)
                    registered = self.command(['/bin/launchctl', 'print', 'system/' + service], check=False).returncode == 0
                    if not registered:
                        self.command(['/usr/bin/sudo', '/bin/launchctl', 'bootstrap', 'system', '/System/Library/LaunchDaemons/com.apple.screensharing.plist'], mutate=True, capture=False)
            verified = self.command(['/bin/launchctl', 'print-disabled', 'system']).stdout
            if not re.search('"' + re.escape(service) + r'"\s*=>\s*false', verified):
                raise Deferred('Confirm Sharing access in System Settings: ' + service)
            self.emit('CURRENT', service, 'enabled; existing access-group members retained')
        self.emit('NOTE', 'SMB', 'No shares or guest access configured; paths/access policy require a separate choice')

    def power(self):
        model = self.command(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.strip()
        if model != 'MacBookPro18,2':
            raise Deferred('Measured power profile is validated only for MacBookPro18,2 (M1 Max)')
        text = self.command(['/usr/bin/pmset', '-g', 'custom']).stdout
        sections = power_values(text)
        for label, flag, desired in [('AC Power:', '-c', {'sleep': 0, 'displaysleep': 10, 'womp': 1, 'powermode': 2}),
                                     ('Battery Power:', '-b', {'sleep': 1, 'displaysleep': 2, 'womp': 0, 'powermode': 0})]:
            values = sections.get(label)
            if values is None:
                self.emit('MANUAL', label, 'Power source settings unavailable; skipped'); continue
            changes = {k: v for k, v in desired.items() if values.get(k) != v}
            if not changes:
                self.emit('CURRENT', label); continue
            if self.preview:
                self.emit('DRIFT', label, str(changes)); continue
            if any(k not in values for k in changes):
                raise Deferred('A selected pmset setting is unsupported')
            self.backup('pmset.txt', text.encode())
            tail = [str(item) for pair in changes.items() for item in pair]
            self.command(['/usr/bin/sudo', '/usr/bin/pmset', flag] + tail, mutate=True, capture=False)
            verified = power_values(self.command(['/usr/bin/pmset', '-g', 'custom']).stdout).get(label, {})
            if any(verified.get(key) != value for key, value in desired.items()):
                raise RuntimeError('Power settings failed verification: ' + label)
            self.emit('CHANGED', label, str(changes))
        if not self.preview:
            self.emit('NOTE', 'Power', self.command(['/usr/bin/pmset', '-g', 'custom']).stdout.strip())

    def selected_apps(self):
        return [app for app in self.manifest['apps'] if app['profile'] == 'core' or self.args.profile == 'full']

    def game_report(self):
        print('\nGame data directories (filename checks only; no data is downloaded or created):')
        for entry in read_json(PAYLOAD / 'game-data.json'):
            paths = [Path(value.replace('~', str(self.home), 1)) for value in entry.get('directories', [])]
            found = next((app for app in self.apps if app['id'] in entry.get('ids', [])), None)
            if found and found['id'] == 'com.etlegacy.etl':
                paths[0] = found['path'].parent / 'etmain'
            if 'com.macsourceports.yquake2' in entry.get('ids', []):
                paths[0] = yamagi_data_root(self.home, os.environ)
            status = 'not required (bundled)' if entry.get('bundled') else 'unverified'
            checks = entry.get('required', [])
            if checks and paths:
                status = 'present' if all((paths[0] / value).exists() for value in checks) else 'missing'
            identity = str(found['path']) + ' ' + found['version'] if found else 'engine not detected'
            print('\n' + entry['name'] + ' | ' + identity + ' | ' + status)
            for path in paths:
                print('  ' + str(path) + (' -> ' + str(path.resolve()) if path.is_symlink() else ''))
            print('  ' + entry['note'])

    def run(self):
        print('macOS workstation: ' + self.args.profile + (' (offline preview)' if self.preview else ' (apply)'))
        selected = self.command(['/usr/bin/xcode-select', '-p'], check=False).stdout.strip()
        if not selected or not (Path(selected) / 'usr/bin/clang').exists():
            if not self.preview:
                raise Deferred('Complete Apple Command Line Tools installation, then rerun')
            self.emit('DRIFT', 'Apple developer tools', 'Complete Command Line Tools installation, then rerun')
        if not self.preview:
            if os.stat('/dev/console').st_uid != os.getuid():
                raise Deferred('Apply requires the active console user')
            free = shutil.disk_usage(self.home).free // (1024 ** 3)
            minimum = 40 if self.args.profile == 'full' else 15
            if free < minimum:
                raise Deferred(f'Need at least {minimum} GiB free for this profile; found {free}')
            self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(self.state, 0o700)
            log_dir = self.state / 'logs'
            log_dir.mkdir(exist_ok=True, mode=0o700)
            self.live_log = log_dir / (self.run_id + '.jsonl')
            self.live_log.touch(mode=0o600, exist_ok=False)
        self.attempt('Homebrew preparation', self.prepare_brew)
        names = self.manifest['formulae']['core'] + (self.manifest['formulae']['full'] if self.args.profile == 'full' else [])
        for name in names:
            self.attempt('formula ' + name, self.package, name)
        self.attempt('Rust', self.rust)
        for app in self.selected_apps():
            self.attempt(app['name'], self.application, app)
        for name in ('codex', 'claude', 'agy'):
            self.attempt(name, self.native_cli, name)
        self.attempt('PowerShell', self.powershell)
        self.attempt('Speedtest', self.speedtest)
        self.attempt('Android platform-tools', self.platform_tools)
        if self.args.profile == 'full':
            self.attempt('Android full', self.android)
            self.attempt('SteamCMD', self.package, 'steamcmd', 'cask')
        self.attempt('Shell configuration', self.shell)
        self.attempt('Editor configuration', self.editor)
        self.attempt('Desktop configuration', self.desktop)
        for selected, label, method in [(self.args.with_xcode, 'Xcode', self.xcode),
                                        (self.args.with_sharing, 'Sharing', self.sharing),
                                        (self.args.with_power_settings, 'Power', self.power)]:
            if selected:
                self.attempt(label, method)
        for exception in self.manifest['exceptions']:
            self.emit('EXCLUDED', exception['name'], exception['reason'])
        if not self.preview:
            if json.dumps(self.receipts, sort_keys=True) != self.original_receipts:
                self.file(self.state / 'receipts.json', json.dumps(self.receipts, indent=2) + '\n', 0o600)
            for process in sorted(self.restart):
                self.command(['/usr/bin/killall', '-u', str(os.getuid()), process], mutate=True, check=False)
            # The log contains action records only, never package-manager/auth output.
            self.file(self.state / 'logs' / (self.run_id + '.json'), json.dumps(self.events, indent=2) + '\n', 0o600)
        if self.args.profile == 'full':
            self.game_report()
        counts = {kind: sum(event['status'] == kind for event in self.events) for kind in ('CURRENT', 'CHANGED', 'DRIFT', 'MANUAL', 'FAILED')}
        print('\nResult: ' + ', '.join(f'{value} {key.lower()}' for key, value in counts.items()))
        if self.args.dry_run:
            return 0
        return 1 if counts['FAILED'] else 2 if counts['DRIFT'] or counts['MANUAL'] else 0


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['core', 'full'], default='core')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--dry-run', action='store_true')
    for flag in ('no-upgrade', 'with-xcode', 'with-sharing', 'with-power-settings'):
        parser.add_argument('--' + flag, action='store_true')
    return parser.parse_args(argv)


def main(argv=None):
    args = arguments(argv)
    if sys.platform != 'darwin' or os.getuid() == 0 or platform.machine() != 'arm64' or platform.mac_ver()[0].split('.')[0] != '26':
        print('Run setup-macos-workstation.sh as a normal user on native macOS.', file=sys.stderr)
        return 1
    if Path('/usr/local/bin/brew').exists():
        print('Resolve the Intel Homebrew prefix before applying this script.', file=sys.stderr)
        return 1
    try:
        return Workstation(args).run()
    except Deferred as exc:
        print('MANUAL: ' + str(exc)); return 2
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print('FAILED: ' + str(exc), file=sys.stderr); return 1


if __name__ == '__main__':
    sys.exit(main())
