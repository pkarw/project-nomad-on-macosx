import hashlib
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'nomad':
    args.append(sys.argv[0])
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, args, os.environ.get('MSB_HOME')]) + '\\n')
if name == 'df':
    print('Filesystem 1024-blocks Used Available Capacity Mounted on\\nfake 999999999 0 999999999 0% /')
elif name == 'xcrun':
    print('/mock/swiftc')
elif name == 'curl':
    shutil.copyfile(os.environ['TEST_ARCHIVE'], args[args.index('-o') + 1])
elif name == 'msb':
    if args[0] == 'create':
        for volume in ['seed-data', 'seed-docker']:
            target = pathlib.Path(os.environ['MSB_HOME']) / 'volumes' / volume / 'disk.raw'
            target.parent.mkdir(parents=True)
            target.write_bytes(b'clean test seed')
    elif args[0] == 'exec' and os.environ.get('TEST_FAIL_GUEST') == '1':
        sys.exit(42)
    elif args[0] == '--version':
        print('msb 0.7.13')
elif name == 'swiftc':
    pathlib.Path(args[args.index('-o') + 1]).write_text('test executable')
elif name == 'swift':
    desktop = pathlib.Path(args[2])
    desktop.mkdir(exist_ok=True)
    for app in ['NOMAD', 'Stop NOMAD']:
        (desktop / (app + args[3])).write_text(args[1])
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nomad-installer-test-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.commands = self.base / 'commands'
        self.commands.mkdir()
        for name in ['df', 'xcrun', 'curl', 'msb', 'swiftc', 'swift', 'codesign']:
            path = self.commands / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.archive = self.base / 'source.tar.gz'
        tracked = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name in tracked:
                if name in ['bin/darwin-arm64/nomad', 'bin/darwin-arm64/SHA256SUMS']:
                    continue
                if (ROOT / name).is_file():
                    archive.add(ROOT / name, arcname='source/' + name)
            binary = MOCK.encode()
            checksum = (hashlib.sha256(binary).hexdigest() + '  nomad\n').encode()
            for name, data in [('nomad', binary), ('SHA256SUMS', checksum)]:
                entry = tarfile.TarInfo('source/bin/darwin-arm64/' + name)
                entry.size = len(data)
                entry.mode = 0o755
                archive.addfile(entry, io.BytesIO(data))
        self.log = self.base / 'calls.jsonl'
        self.environment = dict(os.environ, HOME=str(self.home),
                                PATH=str(self.commands) + ':' + os.environ['PATH'],
                                TEST_LOG=str(self.log), TEST_ARCHIVE=str(self.archive))
        self.environment.pop('MSB_HOME', None)
        self.environment.pop('NOMAD_INSTALL_DIR', None)

    def tearDown(self):
        if self.log.exists():
            for name, args, context in self.calls():
                if context and context.startswith("/tmp/nm."):
                    shutil.rmtree(context, ignore_errors=True)

    def run_installer(self, *args):
        return subprocess.run(['sh', '-s', '--', *args], input=(ROOT / 'install.sh').read_text(),
                              text=True, capture_output=True, env=self.environment)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_pipe_install_keeps_apps_together_and_does_not_start_with_no_start(self):
        result = self.run_installer('--no-start')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        destination = self.home / 'Project-NOMAD'
        self.assertTrue((destination / 'Launchers/NOMAD.app/Contents/MacOS/NOMAD').is_file())
        self.assertEqual((destination / 'Launchers/Project-NOMAD').resolve(), destination.resolve())
        self.assertTrue((self.home / 'Desktop/NOMAD').exists())
        self.assertFalse(list(self.home.glob('.nomad-install.*')))
        self.assertFalse(list(self.home.glob('*.app')))
        manifest = json.loads((destination / 'release-checksums.json').read_text())
        self.assertIn('disks/docker-empty.img', manifest)
        for name, args, context in self.calls():
            if name == 'msb' and args[0] in ['create', 'exec', 'stop', 'remove', 'volume']:
                self.assertTrue(context.startswith('/tmp/nm.'))

    def test_default_start_uses_the_same_disk_path_as_the_desktop_apps(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        starts = [call for call in self.calls() if call[0] == 'nomad']
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][1][0], 'start')
        self.assertIn('/Launchers/Project-NOMAD/bin/darwin-arm64/nomad', starts[0][1][1])
        self.assertIsNone(starts[0][2])

    def test_custom_directory_coexists_with_existing_workspace_and_shortcuts(self):
        original = self.home / 'Project-NOMAD'
        original.mkdir()
        (original / 'my-data').write_text('keep me')
        desktop = self.home / 'Desktop'
        desktop.mkdir()
        for name in ['NOMAD', 'Stop NOMAD']:
            (desktop / name).write_text('original shortcut')
        self.environment['NOMAD_INSTALL_DIR'] = str(original)
        destination = self.home / 'Project-Nomad-2'
        result = self.run_installer('--no-start', '--dir', str(destination))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((destination / 'disks/nomad-data.img').is_file())
        self.assertEqual((original / 'my-data').read_text(), 'keep me')
        for name in ['NOMAD', 'Stop NOMAD']:
            self.assertEqual((desktop / name).read_text(), 'original shortcut')
            self.assertEqual((desktop / (name + ' (Project-Nomad-2)')).read_text(), str(destination))
        self.assertFalse([call for call in self.calls() if call[0] == 'nomad'])

    def test_directory_equals_syntax_and_paths_with_spaces(self):
        destination = self.home / 'My NOMAD'
        result = self.run_installer('--dir=' + str(destination), '--no-start')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((destination / 'disks/nomad-data.img').is_file())

    def test_invalid_directory_arguments_do_not_change_anything(self):
        for arguments in [('--dir',), ('--dir', '--no-start'), ('--dir=',), ('--dir', 'relative')]:
            with self.subTest(arguments=arguments):
                result = self.run_installer(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())
                self.assertFalse(list(self.home.glob('.nomad-install.*')))

    def test_existing_workspace_is_preserved(self):
        destination = self.home / 'Project-NOMAD'
        destination.mkdir()
        sentinel = destination / 'my-data'
        sentinel.write_text('keep me')
        result = self.run_installer('--no-start')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Destination already exists', result.stderr)
        self.assertEqual(sentinel.read_text(), 'keep me')
        self.assertFalse(self.log.exists())

    def test_guest_failure_stops_only_builder_and_retains_recovery_files(self):
        self.environment['TEST_FAIL_GUEST'] = '1'
        result = self.run_installer('--no-start')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / 'Project-NOMAD').exists())
        self.assertTrue(list(self.home.glob('.nomad-install.*')))
        self.assertIn('Recovery files:', result.stderr)
        stops = [call for call in self.calls() if call[0] == 'msb' and call[1][0] == 'stop']
        self.assertEqual(len(stops), 1)
        self.assertTrue(stops[0][2].startswith('/tmp/nm.'))

    def test_check_is_read_only(self):
        result = self.run_installer('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / 'Project-NOMAD').exists())
        self.assertFalse(list(self.home.glob('.nomad-install.*')))
        self.assertEqual([call[0] for call in self.calls()], ['df', 'xcrun', 'msb'])


if __name__ == '__main__':
    unittest.main()
