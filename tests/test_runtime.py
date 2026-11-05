import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeIdentityTests(unittest.TestCase):
    def test_bundled_launcher_selects_installation_runtime_without_touching_legacy(self):
        for identity in [None, 'nomad-1234567890abcdef']:
            with self.subTest(identity=identity), tempfile.TemporaryDirectory(prefix='nomad-runtime-test-') as folder:
                workspace = Path(folder)
                binary = workspace / 'bin/darwin-arm64/nomad'
                binary.parent.mkdir(parents=True)
                shutil.copy2(ROOT / 'bin/darwin-arm64/nomad', binary)
                (workspace / 'bootstrap-ubuntu.sh').touch()
                (workspace / 'storage.json').write_text(json.dumps({'version': 1, 'format': 'raw', 'dockerGiB': 64}))
                if identity:
                    (workspace / 'runtime-id').write_text(identity + '\n')
                commands = workspace / 'commands'
                commands.mkdir()
                trace = workspace / 'calls.json'
                mock = commands / 'msb'
                mock.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["RUNTIME_TEST_TRACE"]).write_text(json.dumps(sys.argv[1:]))\n')
                mock.chmod(0o755)
                environment = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
                                   MSB_HOME=str(workspace / 'context'), RUNTIME_TEST_TRACE=str(trace))
                result = subprocess.run([str(binary), 'status'], env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(trace.read_text()), ['inspect', identity or 'nomad-x5'])


if __name__ == '__main__':
    unittest.main()
