"""Exercise the dev E2E launcher without a cluster or a real CLI build."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


class E2ERunnerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.kubeconfig = self.home / "hub.kubeconfig"
        self.kubeconfig.touch()
        self.pull_secret = self.home / "pull-secret.json"
        self.pull_secret.write_text("{}")
        self.ssh_key = self.home / "id.pub"
        self.ssh_key.touch()
        self.artifacts_file = self.home / "builds.json"
        self.cli_path = self.home / "osac"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "ARTIFACTS_FILE": str(self.artifacts_file),
            "OSAC_DEV_HUB_KUBECONFIG": str(self.kubeconfig),
            "OSAC_PULL_SECRET_PATH": str(self.pull_secret),
            "OSAC_SSH_PUBLIC_KEY_PATH": str(self.ssh_key),
        }
        self.stub("kubectl", "exit 0")
        self.stub("grpcurl", "exit 0")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/bash\nset -euo pipefail\n{body}\n")
        path.chmod(0o755)

    def run_launcher(self, *args):
        return subprocess.run(
            ["bash", str(HERE / "e2e.sh"), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_fresh_cli_build_exports_only_the_binary_path(self):
        self.stub("go", 'test "$1:$2" = build:-o; install -m 755 /dev/null "$3"')
        self.stub("uv", 'test -x "$OSAC_CLI_PATH" || exit 19; printf "CLI=[%s]\\n" "$OSAC_CLI_PATH"')
        result = self.run_launcher("--suite", "vmaas/sanity", "--rebuild")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"CLI=[{self.cli_path}]", result.stdout)
        self.assertIn("building the osac CLI", result.stderr)


if __name__ == "__main__":
    unittest.main()
