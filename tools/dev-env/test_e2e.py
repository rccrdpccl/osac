"""Exercise the dev E2E launcher without a cluster or a real CLI build."""

import json
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

    def test_remote_caas_dry_run_does_not_require_local_uv_or_cli(self):
        self.env['REMOTE_HOST'] = 'root@dev-hypervisor'
        self.stub('ssh', 'exit 99')
        result = self.run_launcher('--suite', 'caas/sanity', '--dry-run', '--', '-n', '0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('remote Podman on root@dev-hypervisor', result.stdout)
        self.assertIn('pytest tests/e2e/caas/sanity -n 0', result.stdout)

    def test_remote_runner_isolates_inputs_and_copies_results_on_test_failure(self):
        infra = self.home / 'test-infra'
        infra.mkdir()
        for name in ['Containerfile', 'pyproject.toml', 'uv.lock']:
            (infra / name).touch()
        subprocess.run(['git', 'init', '-q', str(infra)], check=True)
        subprocess.run(['git', '-C', str(infra), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(infra), '-c', 'user.email=test@example.test',
                        '-c', 'user.name=Test', 'commit', '-qm', 'CI recipe'], check=True)
        self.env.update(REMOTE_HOST='root@dev-hypervisor', TEST_INFRA_DIR=str(infra), E2E_RUNNER='remote-container')
        self.stub('ssh', '''
command=${!#}
if [[ $command == 'tar '* && $command == *' -xf -'* ]]; then
  [[ $command == *'--no-same-owner'* ]] || exit 23
fi
exec /bin/bash -c "$command"
''')
        self.stub('kubectl', 'case "$*" in *"exec deploy/"*) echo mock-cli;; *"config view"*) echo mock-config;; esac')
        self.stub('podman', '''
case "$1" in
  build)
    [[ $* == *'--format docker'* ]] || exit 24
    context=${!#}
    test -f "$context/tests/e2e/caas/sanity/test_cluster_create.py"
    test -x "$context/osac-cli-bin"
    test ! -e "$context/inputs"
    ;;
  run)
    [[ $* == *'--network=host'* && $* == *'--dns=none'* ]]
    [[ $* == *'/inputs:ro,Z'* && $* == *'KUBECONFIG=/inputs/kubeconfig'* ]]
    if [[ $* == *' pytest '* ]]; then
      printf 'fake junit\n' >output/junit.xml
      exit 17
    fi
    ;;
  stop|rmi) : ;;
  *) exit 1 ;;
esac
''')
        result = self.run_launcher('--suite', 'vmaas/sanity', '--', '-n', '0')
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        [junit] = self.home.glob('e2e.*/junit.xml')
        self.assertEqual(junit.read_text(), 'fake junit\n')
        self.assertNotIn('mock-config', result.stdout + result.stderr)

    def test_guest_vip_bootstrap_only_patches_missing_caas_settings(self):
        cm = {'metadata': {'resourceVersion': '42'}, 'data': {
            'DNS_CLASS': 'dns.noop.dns',
            'HOSTED_CLUSTER_BASE_DOMAIN': 'hosted.dev.test',
            'EXTERNAL_ACCESS_BASE_DOMAIN': 'hosted.dev.test',
        }}
        patch = self.home / 'patch.json'
        self.env.update(CM=json.dumps(cm), PATCH=str(patch), REMOTE_HOST='root@dev-hypervisor')
        self.stub('kubectl', '''
case "$*" in
  *'get configmap cluster-fulfillment-ig'*) printf '%s' "$CM" ;;
  *'get ingress.config.openshift.io'*) echo apps.dev.test ;;
  *'get clusterorders'*) echo '{"items":[]}' ;;
  *'patch configmap cluster-fulfillment-ig'*) printf '%s' "${!#}" >"$PATCH" ;;
  *) exit 1 ;;
esac
''')
        self.stub('ssh', '''
case "$*" in
  *'show HEAD:.github/scripts/guest_ingress_vip_range.py'*) echo fake-picker ;;
  *'python3 - --explain'*) read -r picker; test "$picker" = fake-picker; echo 192.0.2.124-192.0.2.127 ;;
  *) exit 1 ;;
esac
''')
        result = subprocess.run(
            ['bash', '-c', 'source "$1/common.sh"; source "$1/e2e-remote.sh"; '
             'remote_e2e_stage=$2; remote_e2e_infra=/path/to/infra; configure_dev_caas kubectl',
             'test', str(HERE), str(self.home)],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(patch.read_text()), {
            'metadata': {'resourceVersion': '42'},
            'data': {'EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS': 'hosted.dev.test',
                     'CI_GUEST_INGRESS_IP_RANGE': '192.0.2.124-192.0.2.127'},
        })

    def test_fresh_cli_build_exports_only_the_binary_path(self):
        self.stub("go", 'test "$1:$2" = build:-o; install -m 755 /dev/null "$3"')
        self.stub("uv", 'test -x "$OSAC_CLI_PATH" || exit 19; printf "CLI=[%s]\\n" "$OSAC_CLI_PATH"')
        result = self.run_launcher("--suite", "vmaas/sanity", "--rebuild")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"CLI=[{self.cli_path}]", result.stdout)
        self.assertIn("building the osac CLI", result.stderr)


if __name__ == "__main__":
    unittest.main()
