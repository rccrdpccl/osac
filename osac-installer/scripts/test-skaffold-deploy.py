#!/usr/bin/env python3
"""Exercise the real installer/Skaffold handoff without a cluster or builds."""

import contextlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

INSTALLER = Path(__file__).resolve().parents[1]
REPO = INSTALLER.parent
ADAPTER = INSTALLER / "scripts/skaffold-deploy.py"

# One recording executable, installed under each tool's name. The real adapter
# runs under the test interpreter; uv never installs anything in these tests.
TOOL = r"""
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_COMMANDS"], "a") as stream:
    stream.write(json.dumps({"command": name, "args": args, "cwd": os.getcwd()}) + "\n")
if name == "uv":
    index = args.index("python")
    os.execv(sys.executable, [sys.executable, *args[index + 1:]])
elif name == "helm" and args[:1] == ["version"]:
    print(os.environ.get("TEST_HELM_VERSION", "v4.3.1"))
elif name == "oc":
    if args[:2] == ["get", "ingresses.config/cluster"]:
        print("apps.example.test")
    elif args[:2] == ["get", "secret"] and os.environ.get("TEST_DB_MISSING") == "1":
        sys.exit(1)
    elif args[:1] == ["create"]:
        print("apiVersion: v1\nkind: Secret\nmetadata:\n  name: fixture")
    elif args[:1] == ["apply"]:
        sys.stdin.read()
elif name == "skaffold":
    config_path = Path(args[args.index("-f") + 1])
    capture = {
        "args": args, "cwd": os.getcwd(), "path": str(config_path),
        "mode": config_path.stat().st_mode & 0o777,
        "config": json.loads(config_path.read_text()),
    }
    if os.environ.get("TEST_SLOW_SHUTDOWN") == "1":
        import signal
        import time

        def shutdown(signum, frame):
            with open(os.environ["TEST_SHUTDOWN"], "a") as stream:
                stream.write(f"signal {signum}\n")
            time.sleep(1)
            # Helm cleanup can still need the temporary config during shutdown.
            json.loads(config_path.read_text())
            with open(os.environ["TEST_SHUTDOWN"], "a") as stream:
                stream.write("cleanup-complete\n")
            sys.exit(int(os.environ.get("TEST_SKAFFOLD_EXIT", "0")))

        signal.signal(signal.SIGINT, shutdown)
        signal.signal(signal.SIGTERM, shutdown)
        capture["pid"] = os.getpid()
        Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps(capture))
        while True:
            time.sleep(60)
    Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps(capture))
    sys.exit(int(os.environ.get("TEST_SKAFFOLD_EXIT", "0")))
"""


class SkaffoldDeployTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="osac-skaffold-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.installer = self.directory / "osac-installer"
        self.installer.mkdir()
        shutil.copy(INSTALLER / "Makefile", self.installer / "Makefile")
        (self.installer / "scripts").symlink_to(INSTALLER / "scripts", target_is_directory=True)
        (self.installer / "values").symlink_to(INSTALLER / "values", target_is_directory=True)
        for chart in ("osac", "osac-infra", "osac-devstack"):
            directory = self.installer / "charts" / chart
            directory.mkdir(parents=True)
            shutil.copy(INSTALLER / "charts" / chart / "Chart.yaml", directory / "Chart.yaml")
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name in ("uv", "helm", "oc", "skaffold", "docker"):
            command = self.bin / name
            command.write_text(f"#!{sys.executable}\n" + TOOL)
            command.chmod(0o755)
        self.commands_file = self.directory / "commands.jsonl"
        self.capture_file = self.directory / "capture.json"
        self.license = self.directory / "license with spaces.zip"
        self.license.write_bytes(b"private-license-fixture")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "TEST_COMMANDS": str(self.commands_file),
            "TEST_CAPTURE": str(self.capture_file),
            "OSAC_DEV_REGISTRY": "quay.io/example/dev",
            "SKAFFOLD_MODE": "run",
            "KUBECONFIG": str(self.directory / "kubeconfig"),
            "DOCKER_HOST": "unix:///example/podman.sock",
        }
        # Do not inherit a caller's Make flags or unrelated installation options.
        for key in (
            "MAKEFLAGS",
            "MFLAGS",
            "DEV_MODE",
            "DRY_RUN",
            "EXTRA_HELM_ARGS",
            "REMOTE_KUBECONFIG",
            "REMOTE_API_ADDRESS",
            "OSAC_CHART_OCI_REF",
            "OSAC_CHART_OCI_VERSION",
        ):
            self.env.pop(key, None)

    def make(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "make",
                "--no-print-directory",
                "install-osac",
                "PLATFORM=openshift",
                "PROFILE=caas-ci",
                "NS=example",
                f"AAP_LICENSE_FILE={self.license}",
                "CONTAINER_TOOL=docker",
                *args,
            ],
            cwd=self.installer,
            env=env or self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def commands(self) -> list[dict[str, Any]]:
        if not self.commands_file.exists():
            return []
        return [json.loads(line) for line in self.commands_file.read_text().splitlines()]

    def capture(self) -> dict[str, Any]:
        self.assertTrue(self.capture_file.is_file(), "Skaffold was not called")
        return json.loads(self.capture_file.read_text())

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_no_mutation(self) -> None:
        for command in self.commands():
            if command["command"] == "oc":
                self.assertNotIn(command["args"][0], ("create", "apply", "label"))
            if command["command"] == "helm":
                self.assertEqual(command["args"][0], "version")
        self.assertFalse(self.capture_file.exists())

    def test_default_installer_keeps_direct_helm_without_dev_tools(self) -> None:
        for name in ("uv", "skaffold", "docker"):
            (self.bin / name).unlink()
        result = self.make()
        self.assert_success(result)
        applies = [
            item
            for item in self.commands()
            if item["command"] == "helm" and item["args"][:2] == ["upgrade", "--install"]
        ]
        self.assertEqual(len(applies), 1)
        self.assertIn("--force-conflicts", applies[0]["args"])
        self.assertFalse(self.capture_file.exists())

    def test_dev_mode_shares_preparation_and_installer_configuration(self) -> None:
        overlay = self.directory / "extra values.yaml"
        overlay.write_text("service: {}\n")
        result = self.make("DEV_MODE=1", f'EXTRA_HELM_ARGS=-f "{overlay}" --set-string service.label=001')
        self.assert_success(result)
        capture = self.capture()
        config = capture["config"]
        release = config["deploy"]["helm"]["releases"][0]
        self.assertEqual(release["name"], "osac")
        self.assertEqual(release["namespace"], "example")
        self.assertEqual(release["chartPath"], str(self.installer / "charts/osac"))
        self.assertEqual(release["valuesFiles"], [str(self.installer / "values/caas-ci/instance.yaml"), str(overlay)])
        # Watch redeploys must refresh local file:// chart dependencies too.
        self.assertFalse(release["skipBuildDependencies"])
        self.assertFalse(config["deploy"]["statusCheck"])
        flags = config["deploy"]["helm"]["flags"]
        self.assertEqual(flags["install"], flags["upgrade"])
        self.assertIn("--force-conflicts", flags["upgrade"])
        for value in (
            "global.osacDeploymentId=example/osac",
            "service.externalHostname=fulfillment-api-example.apps.example.test",
            "service.internalHostname=fulfillment-internal-api-example.apps.example.test",
            "global.clusterDomain=apps.example.test",
            "ui.auth.oidcIssuerURL=https://keycloak-keycloak.apps.example.test/realms/osac",
            "service.label=001",
            "--set-string",
            "--create-namespace",
            "--wait",
            "40m",
        ):
            self.assertIn(value, flags["upgrade"])
        self.assertIn(
            "IMAGE_REPO_fulfillment_service", release["setValueTemplates"]["service.images.service.repository"]
        )
        for artifact in config["build"]["artifacts"]:
            self.assertTrue(Path(artifact["context"]).is_absolute())
        calls = self.commands()
        secret = next(
            i for i, item in enumerate(calls) if item["command"] == "oc" and item["args"][:2] == ["create", "secret"]
        )
        deploy = next(i for i, item in enumerate(calls) if item["command"] == "skaffold")
        self.assertLess(secret, deploy)
        self.assertEqual(sum(item["command"] == "helm" and "dependency" in item["args"] for item in calls), 1)
        self.assertFalse(any(item["command"] == "helm" and "upgrade" in item["args"] for item in calls))
        self.assertIn("bundledPostgres enabled", result.stdout)

    def test_one_shot_and_watch_use_identical_configuration(self) -> None:
        self.assert_success(self.make("DEV_MODE=1"))
        run = self.capture()
        self.assert_success(self.make("DEV_MODE=1", "SKAFFOLD_MODE=dev"))
        dev = self.capture()
        self.assertEqual(run["config"], dev["config"])
        self.assertEqual(run["args"][0], "run")
        self.assertEqual(dev["args"][0], "dev")
        self.assertIn("--default-repo", dev["args"])
        self.assertIn("quay.io/example/dev", dev["args"])
        self.assertEqual(dev["cwd"], str(self.installer))

    def test_helm_three_does_not_receive_force_conflicts(self) -> None:
        env = {**self.env, "TEST_HELM_VERSION": "v3.16.3"}
        self.assert_success(self.make("DEV_MODE=1", env=env))
        flags = self.capture()["config"]["deploy"]["helm"]["flags"]
        self.assertNotIn("--force-conflicts", flags["upgrade"])

    def test_temp_config_is_private_removed_and_does_not_embed_license(self) -> None:
        self.assert_success(self.make("DEV_MODE=1"))
        capture = self.capture()
        self.assertEqual(capture["mode"], 0o600)
        self.assertFalse(Path(capture["path"]).exists())
        self.assertNotIn("private-license-fixture", json.dumps(capture["config"]))

    def test_failure_propagates_and_removes_config(self) -> None:
        result = self.make("DEV_MODE=1", env={**self.env, "TEST_SKAFFOLD_EXIT": "42"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error 42", result.stderr)
        self.assertFalse(Path(self.capture()["path"]).exists())

    def test_shutdown_waits_for_skaffold_cleanup(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            for target in ("adapter", "foreground-group"):
                with self.subTest(signal=signum, target=target):
                    self.capture_file.unlink(missing_ok=True)
                    shutdown = self.directory / "shutdown.log"
                    shutdown.unlink(missing_ok=True)
                    process = subprocess.Popen(
                        [sys.executable, str(ADAPTER), "osac", "charts/osac", "-n", "example"],
                        cwd=self.installer,
                        env={**self.env, "TEST_SLOW_SHUTDOWN": "1", "TEST_SHUTDOWN": str(shutdown)},
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        start_new_session=True,
                    )
                    capture = None
                    try:
                        deadline = time.monotonic() + 10
                        while not self.capture_file.exists() and process.poll() is None:
                            self.assertLess(time.monotonic(), deadline, "Skaffold did not start")
                            time.sleep(0.02)
                        capture = self.capture()
                        if target == "adapter":
                            process.send_signal(signum)
                        else:
                            os.killpg(process.pid, signum)
                        stdout, stderr = process.communicate(timeout=10)
                        self.assertEqual(process.returncode, 0, stdout + stderr)
                        self.assertEqual(shutdown.read_text().splitlines(), [f"signal {signum}", "cleanup-complete"])
                        self.assertFalse(Path(capture["path"]).exists())
                    finally:
                        if process.poll() is None:
                            process.kill()
                        if capture:
                            with contextlib.suppress(ProcessLookupError):
                                os.kill(capture["pid"], signal.SIGKILL)
                        process.communicate(timeout=5)

    def test_preserves_helm_override_semantics_and_relative_file_paths(self) -> None:
        args = [
            sys.executable,
            str(ADAPTER),
            "osac",
            "charts/osac",
            "--namespace",
            "example",
            "-f",
            "values/caas-ci/instance.yaml",
            "--set",
            "feature.enabled=false",
            "--set-string",
            "feature.code=001",
            "--set-file",
            r"feature.license\.zip=relative license.zip",
            "--set",
            "feature.enabled=true",
            "--wait",
            "--timeout",
            "40m",
        ]
        result = subprocess.run(args, cwd=self.installer, env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_success(result)
        capture = self.capture()
        self.assertEqual(capture["config"]["deploy"]["helm"]["flags"]["upgrade"], args[8:])
        self.assertEqual(capture["cwd"], str(self.installer))

    def test_helm_values_url_is_not_reinterpreted_as_a_local_path(self) -> None:
        url = "https://example.test/instance.yaml"
        args = [sys.executable, str(ADAPTER), "osac", "charts/osac", "--namespace", "example", "-f", url]
        result = subprocess.run(args, cwd=self.installer, env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_success(result)
        release = self.capture()["config"]["deploy"]["helm"]["releases"][0]
        self.assertEqual(release["valuesFiles"], [url])

    def test_unsupported_settings_fail_before_mutation(self) -> None:
        cases = [
            (["DEV_MODE=yes"], "DEV_MODE must be 0 or 1"),
            (["DEV_MODE=1", "PLATFORM=kind", "PROFILE=dev"], "DEV_MODE=1 requires PLATFORM=openshift"),
            (["DEV_MODE=1", "SKAFFOLD_MODE=invalid"], "SKAFFOLD_MODE must be run or dev"),
            (["DEV_MODE=1", "DRY_RUN=1"], "DEV_MODE=1 does not support DRY_RUN=1"),
            (
                ["DEV_MODE=1", "OSAC_CHART_OCI_REF=oci://example/chart", "OSAC_CHART_OCI_VERSION=1.0.0"],
                "DEV_MODE=1 requires the local checkout chart",
            ),
            (["DEV_MODE=1", "OSAC_DEV_REGISTRY="], "OSAC_DEV_REGISTRY is required"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                self.commands_file.unlink(missing_ok=True)
                result = self.make(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assert_no_mutation()

    def test_postgres_prerequisite_failure_prevents_build_and_deploy(self) -> None:
        infra = self.directory / "infra.yaml"
        infra.write_text("bundledPostgres:\n  enabled: false\n")
        result = self.make("DEV_MODE=1", f"INFRA_VALUES={infra}", env={**self.env, "TEST_DB_MISSING": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture_file.exists())
        self.assertFalse(any(item["command"] == "skaffold" for item in self.commands()))

    def test_remote_secret_helm_overrides_are_forwarded_without_reinterpretation(self) -> None:
        args = [
            sys.executable,
            str(ADAPTER),
            "osac",
            "charts/osac",
            "--namespace",
            "remote-test",
            "--set-string",
            "operator.remoteClusterKubeconfigSecretKey=config.json",
            "--set-string",
            "aap.configAsCode.remoteClusterKubeconfigSecretName=remote-test",
            "--wait",
            "--timeout",
            "40m",
        ]
        result = subprocess.run(args, cwd=self.installer, env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_success(result)
        self.assertEqual(self.capture()["config"]["deploy"]["helm"]["flags"]["upgrade"], args[6:])

    def test_unreadable_helm_version_fails_before_mutation(self) -> None:
        result = self.make("DEV_MODE=1", env={**self.env, "TEST_HELM_VERSION": "unknown"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not determine the Helm version", result.stderr)
        self.assert_no_mutation()

    def test_missing_skaffold_fails_before_mutation(self) -> None:
        (self.bin / "skaffold").unlink()
        result = self.make("DEV_MODE=1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("skaffold", result.stderr)
        self.assert_no_mutation()


if __name__ == "__main__":
    unittest.main()
