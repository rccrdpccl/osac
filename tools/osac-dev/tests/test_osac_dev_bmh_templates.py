#!/usr/bin/env python3
"""Offline contracts for readable BMH manifests and strict file substitution."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

TOOLS = Path(__file__).resolve().parents[1]
RENDERER = TOOLS / "osac-dev-render-template.py"
TEMPLATES = TOOLS / "templates/bmh"
DEFAULTS = {
    "namespace": "host-inventory",
    "bridge": "br-bmh",
    "name": "virtual-bmh-1",
    "mac": "52:54:00:bb:cc:01",
    "cpu": "4",
    "memory": "8Gi",
    "disk": "150Gi",
    "storage_class": "lvms-vg1",
}


class BmhTemplateTests(unittest.TestCase):
    def render(self, template: Path, *values: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RENDERER), str(template), *values], text=True, capture_output=True, timeout=10
        )

    def resource(self, template: str, **overrides: str) -> list[dict]:
        values = {**DEFAULTS, **overrides}
        result = self.render(TEMPLATES / f"{template}.yaml.tmpl", *(f"{key}={value}" for key, value in values.items()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("${", result.stdout)
        return list(yaml.safe_load_all(result.stdout))

    def test_default_resources_preserve_host_wiring(self) -> None:
        (namespace,) = self.resource("namespace")
        self.assertEqual(namespace, {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "host-inventory"}})
        (nad,) = self.resource("network-attachment")
        self.assertEqual(
            json.loads(nad["spec"]["config"]),
            {"name": "br-bmh-nad", "type": "cnv-bridge", "cniVersion": "1.1.0", "bridge": "br-bmh"},
        )
        pvc, secret, vm, bmc = self.resource("virtual-host")
        self.assertEqual(
            [item["kind"] for item in (pvc, secret, vm, bmc)],
            ["PersistentVolumeClaim", "Secret", "VirtualMachine", "VirtualMachineBMC"],
        )
        for item in (pvc, secret, vm, bmc):
            self.assertEqual(item["metadata"]["namespace"], "host-inventory")
        self.assertEqual(pvc["metadata"]["name"], "virtual-bmh-1-root")
        self.assertEqual(pvc["spec"]["volumeMode"], "Block")
        self.assertEqual(secret, self.resource("bmc-secret")[0])
        self.assertEqual(vm["spec"]["runStrategy"], "Halted")
        guest = vm["spec"]["template"]["spec"]
        self.assertEqual(guest["domain"]["cpu"]["cores"], 4)
        self.assertEqual(guest["domain"]["devices"]["interfaces"][0]["macAddress"], DEFAULTS["mac"])
        self.assertEqual(guest["networks"][0]["multus"]["networkName"], "br-bmh-nad")
        self.assertEqual(
            guest["volumes"], [{"name": "rootdisk", "persistentVolumeClaim": {"claimName": "virtual-bmh-1-root"}}]
        )
        self.assertEqual(bmc["spec"]["authSecretRef"]["name"], secret["metadata"]["name"])
        self.assertEqual(bmc["metadata"]["annotations"]["bmc.kubevirt.io/datavolume-size-margin"], "30")
        (bmh,) = self.resource("baremetalhost")
        self.assertEqual(
            json.loads(bmh["metadata"]["annotations"]["osac.openshift.io/interface-macs"]), {"data-0": DEFAULTS["mac"]}
        )
        self.assertEqual(bmh["spec"]["bootMACAddress"], DEFAULTS["mac"])
        self.assertEqual(bmh["spec"]["bmc"]["credentialsName"], secret["metadata"]["name"])

    def test_resource_overrides_are_consistent(self) -> None:
        values = {
            "namespace": "other-inventory",
            "name": "vb-1",
            "cpu": "2",
            "memory": "4Gi",
            "disk": "100Gi",
            "storage_class": "custom-sc",
        }
        pvc, _, vm, bmc = self.resource("virtual-host", **values)
        self.assertEqual(pvc["spec"]["resources"]["requests"]["storage"], "100Gi")
        self.assertEqual(pvc["spec"]["storageClassName"], "custom-sc")
        self.assertEqual(vm["spec"]["template"]["spec"]["domain"]["cpu"]["cores"], 2)
        self.assertEqual(vm["spec"]["template"]["spec"]["domain"]["memory"]["guest"], "4Gi")
        self.assertEqual(bmc["spec"]["redfish"]["virtualMedia"]["storage"]["storageClassName"], "custom-sc")
        (bmh,) = self.resource("baremetalhost", **values)
        self.assertEqual(
            bmh["spec"]["bmc"]["address"],
            "redfish-virtualmedia+http://vb-1-virtbmc.other-inventory.svc.cluster.local:80/redfish/v1/Systems/1",
        )

    def test_substitution_is_literal_not_shell_evaluation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "literal.tmpl"
            marker = root / "must-not-exist"
            template.write_text("${value}\n")
            value = f"$(touch {marker}) $HOME `uname` = preserved"
            result = self.render(template, f"value={value}")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, value + "\n")
            self.assertFalse(marker.exists())

    def test_missing_and_invalid_values_fail_without_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "missing.tmpl"
            template.write_text("before\n${value}\n${missing}\n")
            cases = (
                (("value=present",), "'missing'"),
                (("value=first", "value=second", "missing=present"), "duplicate template value: value"),
                (("not-an-assignment",), "expected KEY=VALUE"),
                (("invalid-key=value",), "expected KEY=VALUE"),
            )
            for values, diagnostic in cases:
                with self.subTest(values=values):
                    result = self.render(template, *values)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertIn(diagnostic, result.stderr)
                    self.assertNotIn("Traceback", result.stderr)

    def test_malformed_placeholder_fails_without_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "invalid.tmpl"
            template.write_text("before\n${unfinished\n")
            result = self.render(template)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("Traceback", result.stderr)

    def test_renderer_does_not_import_implicit_environment_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory) / "environment.tmpl"
            template.write_text("${PATH}\n")
            self.assertIn("PATH", os.environ)
            result = self.render(template)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PATH", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_missing_template_fails_with_a_clear_diagnostic(self) -> None:
        result = self.render(TEMPLATES / "does-not-exist.yaml.tmpl")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does-not-exist.yaml.tmpl", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
