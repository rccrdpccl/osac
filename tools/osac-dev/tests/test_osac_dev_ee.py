#!/usr/bin/env python3
"""Exercise the configured EE builder with real files and recording tool doubles."""

import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[3]
SKAFFOLD = shutil.which("skaffold")

TOOL = r"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

args = sys.argv[1:]
name = Path(sys.argv[0]).name
with open(os.environ["TEST_COMMANDS"], "a") as stream:
    stream.write(json.dumps({"name": name, "args": args}) + "\n")
if name == "uv":
    if os.environ.get("TEST_CREATE_FAIL") == "1":
        sys.exit(23)
    assert args[:6] == ["tool", "run", "--from", "ansible-builder~=3.0", "ansible-builder", "create"]
    assert args[args.index("-f") + 1] == "osac-aap/execution-environment/execution-environment.yaml"
    context = Path(args[args.index("--context") + 1])
    (context / "Containerfile").write_text("FROM example.test/ee-base\n")
    for source in ("collections", "vendor"):
        shutil.copytree(Path("osac-aap") / source, context / "_build" / source, dirs_exist_ok=True)
elif name == "docker" and args[0] == "build":
    if os.environ.get("TEST_BUILD_FAIL") == "1":
        sys.exit(24)
    context = Path(args[-1])
    capture = {
        "context": str(context),
        "files": {str(path.relative_to(context)): path.read_text() for path in context.rglob("*") if path.is_file()},
    }
    Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps(capture))
elif name == "skaffold":
    config = json.loads(Path(args[args.index("-f") + 1]).read_text())
    artifact = next(item for item in config["build"]["artifacts"] if item["image"] == "osac-aap-ee")
    sys.exit(subprocess.call(artifact["custom"]["buildCommand"], shell=True, cwd=artifact["context"]))
"""


class ExecutionEnvironmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="osac-ee-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for name in ("skaffold.yaml", ".dockerignore", ".gitignore"):
            shutil.copy(REPO / name, self.repo / name)
        adapter = Path("osac-installer/scripts/skaffold-deploy.py")
        (self.repo / adapter).parent.mkdir(parents=True)
        shutil.copy(REPO / adapter, self.repo / adapter)
        config = yaml.safe_load((REPO / "skaffold.yaml").read_text())
        self.artifact = next(item for item in config["build"]["artifacts"] if item["image"] == "osac-aap-ee")
        self.assertIn("custom", self.artifact, "EE builds must regenerate from watched source inputs")
        helper = Path("tools/osac-dev/osac-dev-build-ee.sh")
        (self.repo / helper).parent.mkdir(parents=True)
        shutil.copy(REPO / helper, self.repo / helper)
        self.collection = (
            self.repo / "osac-aap/collections/ansible_collections/osac/service/roles/example/tasks/main.yml"
        )
        self.collection.parent.mkdir(parents=True)
        self.collection.write_text("first collection revision\n")
        self.vendor = self.repo / "osac-aap/vendor/ansible_collections/example/module.py"
        self.vendor.parent.mkdir(parents=True)
        self.vendor.write_text("first vendor revision\n")
        definition = self.repo / "osac-aap/execution-environment"
        definition.mkdir()
        for name in ("execution-environment.yaml", "requirements.txt"):
            shutil.copy(REPO / "osac-aap/execution-environment" / name, definition / name)
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        for name in ("uv", "docker", "skaffold"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + TOOL)
            path.chmod(0o755)
        self.commands = self.repo / "commands.jsonl"
        self.capture = self.repo / "capture.json"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "TEST_COMMANDS": str(self.commands),
            "TEST_CAPTURE": str(self.capture),
            "TMPDIR": str(self.repo),
            "IMAGE": "quay.io/example/osac-aap-ee:branch",
            "PUSH_IMAGE": "true",
            "PLATFORMS": "linux/amd64",
            "OSAC_DEV_REGISTRY": "quay.io/example",
        }

    def build(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.artifact["custom"]["buildCommand"],
            shell=True,
            cwd=self.repo / self.artifact["context"],
            env={**self.env, **env},
            text=True,
            capture_output=True,
            timeout=15,
        )

    def test_deployments_refresh_collection_and_vendor_sources(self) -> None:
        for revision, mode in (("first", "run"), ("second", "dev")):
            self.collection.write_text(f"{revision} collection revision\n")
            self.vendor.write_text(f"{revision} vendor revision\n")
            result = subprocess.run(
                [sys.executable, "scripts/skaffold-deploy.py", "osac", "charts/osac", "-n", "example"],
                cwd=self.repo / "osac-installer",
                env={**self.env, "SKAFFOLD_MODE": mode},
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            capture = json.loads(self.capture.read_text())
            self.assertEqual(
                capture["files"]["_build/" + str(self.collection.relative_to(self.repo / "osac-aap"))],
                self.collection.read_text(),
            )
            self.assertEqual(
                capture["files"]["_build/" + str(self.vendor.relative_to(self.repo / "osac-aap"))],
                self.vendor.read_text(),
            )
            self.assertFalse(Path(capture["context"]).exists(), "temporary build context was not cleaned up")
        calls = [json.loads(line) for line in self.commands.read_text().splitlines()]
        self.assertEqual([call["name"] for call in calls], ["skaffold", "uv", "docker", "docker"] * 2)
        self.assertEqual(calls[2]["args"][:-1], ["build", "--tag", self.env["IMAGE"], "--platform", "linux/amd64"])
        self.assertEqual(calls[3]["args"], ["push", self.env["IMAGE"]])

    def test_rebuild_does_not_retain_deleted_source(self) -> None:
        self.assertEqual(self.build(PUSH_IMAGE="false").returncode, 0)
        self.vendor.unlink()
        self.assertEqual(self.build(PUSH_IMAGE="false").returncode, 0)
        self.assertFalse(
            any(path.startswith("_build/vendor/") for path in json.loads(self.capture.read_text())["files"])
        )
        self.assertNotIn('"push"', self.commands.read_text())

    def test_source_dependencies_exclude_generated_context(self) -> None:
        custom = self.artifact["custom"]
        self.assertNotIn("docker", self.artifact)
        paths = custom["dependencies"]["paths"]
        dependencies = {
            path.relative_to(self.repo).as_posix()
            for path in self.repo.rglob("*")
            if any(fnmatch.fnmatchcase(path.relative_to(self.repo).as_posix(), pattern) for pattern in paths)
        }
        for path in (
            self.collection,
            self.vendor,
            self.repo / "osac-aap/execution-environment/execution-environment.yaml",
            self.repo / "osac-aap/execution-environment/requirements.txt",
            self.repo / "tools/osac-dev/osac-dev-build-ee.sh",
        ):
            self.assertIn(path.relative_to(self.repo).as_posix(), dependencies)
        self.assertFalse(any("/context" in path for path in dependencies))

    @unittest.skipUnless(SKAFFOLD, "Skaffold is not installed; dependency hashing probe unavailable")
    def test_skaffold_hashes_original_inputs_not_generated_files(self) -> None:
        # Use the real dependency resolver in dry-run mode: no image build,
        # daemon, registry or cluster. These are also the watch dependencies.
        config = {
            "apiVersion": "skaffold/v3",
            "kind": "Config",
            "build": {
                "local": {"push": False, "useDockerCLI": True},
                "tagPolicy": {"inputDigest": {}},
                "artifacts": [self.artifact],
            },
        }
        path = self.repo / "dependency-probe.json"
        path.write_text(json.dumps(config))

        def tag() -> str:
            result = subprocess.run(
                [
                    SKAFFOLD,
                    "build",
                    "-f",
                    str(path),
                    "--dry-run",
                    "--quiet",
                    "--push=false",
                    "--detect-minikube=false",
                    "--kube-context=osac-offline",
                    "--platform=linux/amd64",
                ],
                cwd=self.repo,
                env={**self.env, "KUBECONFIG": str(self.repo / "absent-kubeconfig")},
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)["builds"][0]["tag"]

        previous = tag()
        for source in (
            self.collection,
            self.vendor,
            self.repo / "osac-aap/execution-environment/execution-environment.yaml",
            self.repo / "osac-aap/execution-environment/requirements.txt",
            self.repo / "tools/osac-dev/osac-dev-build-ee.sh",
        ):
            with self.subTest(source=source):
                source.write_text(source.read_text() + "\n# source changed\n")
                current = tag()
                self.assertNotEqual(previous, current)
                previous = current
        generated = self.repo / "osac-aap/execution-environment/context/Containerfile"
        generated.parent.mkdir()
        generated.write_text("ignored generated file\n")
        self.assertEqual(previous, tag(), "generated files must not cause rebuild loops")

    def test_failures_stop_before_push_and_remove_context(self) -> None:
        for variable, status in (("TEST_CREATE_FAIL", 23), ("TEST_BUILD_FAIL", 24)):
            with self.subTest(variable=variable):
                self.commands.unlink(missing_ok=True)
                result = self.build(**{variable: "1"})
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertNotIn('"push"', self.commands.read_text())
                self.assertEqual(list(self.repo.glob("osac-aap-ee.*")), [])


if __name__ == "__main__":
    unittest.main()
