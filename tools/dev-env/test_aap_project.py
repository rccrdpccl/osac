"""Test the archive publisher against a recording kubectl, without a hub."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PUBLISHER = Path(__file__).with_name("aap-project.sh")
KUBECTL = """#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
if args[:1] == ['-n']:
    args = args[2:]
root = Path(os.environ['STUB_ROOT'])
with (root / 'calls').open('a') as stream:
    print(json.dumps(args), file=stream)
if args[0] == 'apply':
    (root / 'manifest').write_text(sys.stdin.read())
elif args[:2] == ['get', 'pod']:
    def pod(name, image, persistent=True):
        return {'metadata': {'name': name, 'creationTimestamp': name},
                'spec': {'containers': [{'name': 'archive', 'image': image}],
                         'volumes': [{'persistentVolumeClaim': {'claimName': 'osac-dev-aap-project'}}]
                                    if persistent else []},
                'status': {'containerStatuses': [{'name': 'archive', 'ready': False,
                                                  'state': {'running': {}}}]}}
    print(json.dumps({'items': [pod('01-correct', 'expected:aap'),
                               pod('02-old-layout', 'expected:aap', False),
                               pod('03-other-image', 'wrong:aap')]}))
elif args[0] == 'get':
    sys.exit(1)
elif args[0] == 'exec':
    command = args[args.index('--') + 1:]
    if command[0] == 'sha256sum':
        target = root / 'storage' / Path(command[1]).name
        if not target.exists():
            sys.exit(1)
        print(hashlib.sha256(target.read_bytes()).hexdigest(), target)
    elif command[0] == 'sh':
        # Run the real upload command using a temporary volume instead of /archive.
        command = [str(root / 'storage') if value == '/archive' else value for value in command]
        if os.environ.get('CORRUPT_UPLOAD'):
            sys.exit(subprocess.run(command, input=b'truncated').returncode)
        sys.exit(subprocess.run(command).returncode)
    elif 'HEAD' not in ' '.join(command):
        sys.exit(1)
    elif not (root / 'storage' / 'osac-aap.tar.gz').is_file():
        sys.exit(1)
"""


class AAPProjectTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        kubectl = self.root / "kubectl"
        kubectl.write_text(KUBECTL)
        kubectl.chmod(0o755)
        self.archive = self.root / "matched-archive.tar.gz"
        self.archive.write_bytes(b"test archive\n")
        (self.root / "storage").mkdir()
        kubeconfig = self.root / "hub.kubeconfig"
        kubeconfig.touch()
        self.env = {
            "PATH": f"{temp.name}:{os.environ['PATH']}",
            "HOME": temp.name,
            "OSAC_DEV_HUB_KUBECONFIG": str(kubeconfig),
            "SKAFFOLD_IMAGE": "expected:aap",
            "STUB_ROOT": temp.name,
        }

    def run_publisher(self, *args):
        result = subprocess.run(
            ["bash", str(PUBLISHER), *args], env=self.env, text=True,
            capture_output=True, timeout=10,
        )
        calls = self.root / "calls"
        return result, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def test_atomic_upload_into_persistent_volume_before_waiting_for_ready(self):
        result, calls = self.run_publisher("--archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "http://osac-dev-aap-project.osac.svc:8080/osac-aap.tar.gz")
        self.assertNotIn("packing", result.stderr)
        manifest = (self.root / "manifest").read_text()
        self.assertIn("kind: PersistentVolumeClaim", manifest)
        self.assertIn("claimName: osac-dev-aap-project", manifest)
        self.assertIn("mountPath: /archive", manifest)
        self.assertIn("type: Recreate", manifest)
        self.assertIn('method="HEAD"', manifest)
        self.assertIn("http://127.0.0.1:8080/osac-aap.tar.gz", manifest)
        self.assertTrue(all("01-correct" in call for call in calls if call[0] == "exec"))
        self.assertEqual(calls[-1][:2], ["rollout", "status"])
        self.assertEqual((self.root / "storage" / "osac-aap.tar.gz").read_bytes(), self.archive.read_bytes())
        self.assertEqual(len(list((self.root / "storage").iterdir())), 1)

    def test_bad_upload_leaves_preceding_archive_unchanged(self):
        target = self.root / "storage" / "osac-aap.tar.gz"
        target.write_bytes(b"previous archive")
        self.env["CORRUPT_UPLOAD"] = "1"
        result, calls = self.run_publisher("--archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"previous archive")
        self.assertEqual(list(target.parent.iterdir()), [target])
        self.assertFalse(any(call[:2] == ["rollout", "status"] for call in calls))

    def test_existing_checksum_skips_upload(self):
        (self.root / "storage" / "osac-aap.tar.gz").write_bytes(self.archive.read_bytes())
        result, calls = self.run_publisher("--archive", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["exec", "-i"] for call in calls))

    def test_missing_prebuilt_archive_does_not_mutate_hub(self):
        self.archive.unlink()
        result, calls = self.run_publisher("--archive", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or empty archive", result.stderr)
        self.assertEqual(calls, [])

    def test_delete_removes_the_archive_claim(self):
        result, calls = self.run_publisher("--delete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("persistentvolumeclaim", " ".join(calls[-1]))


if __name__ == "__main__":
    unittest.main()
