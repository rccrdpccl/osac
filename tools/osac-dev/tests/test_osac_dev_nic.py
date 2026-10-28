"""Offline Unit coverage owned by OSAC-6091 [DEV]."""

import base64
import importlib.util
import io
import json
import pathlib
import re
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nic", pathlib.Path(__file__).resolve().parents[1] / "osac-dev-nic.py")
nic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nic)


class SelectNic(unittest.TestCase):
    def inventory(self) -> dict:
        return {
            "links": [
                {"ifname": "ens3", "link_type": "ether", "flags": ["UP", "LOWER_UP"]},
                {"ifname": "ens4", "link_type": "ether", "flags": ["UP", "LOWER_UP"]},
            ],
            "addresses": [
                {"ifname": "ens3", "addr_info": [{"family": "inet", "scope": "global", "local": "192.0.2.10"}]},
                {"ifname": "ens4", "addr_info": [{"family": "inet", "scope": "global", "local": "198.51.100.10"}]},
            ],
            "routes": [{"dst": "default", "dev": "ens3"}],
            "physical": ["ens3", "ens4"],
        }

    def test_inventory_transport_encodes_the_readable_script(self) -> None:
        script = pathlib.Path(__file__).resolve().parents[1] / "node-scripts/inspect-nics.sh"
        self.assertTrue(script.is_file(), "NIC inventory must be an ordinary shell source file")
        nodes = {
            "items": [
                {
                    "metadata": {"name": "sno"},
                    "status": {"addresses": [{"type": "InternalIP", "address": "192.0.2.10"}]},
                }
            ]
        }
        inventory = "\n".join(f"OSAC_NIC_{key}={json.dumps(value)}" for key, value in self.inventory().items())
        with (
            patch.object(nic.subprocess, "check_output", side_effect=[json.dumps(nodes), inventory]) as command,
            patch.object(nic.sys, "argv", ["osac-dev-nic.py"]),
            patch("sys.stdout", new_callable=io.StringIO) as output,
        ):
            nic.main()
        self.assertEqual(output.getvalue(), "ens4\n")
        encoded = re.search(r"printf %s '([^']+)'", command.call_args.args[0][-1]).group(1)
        self.assertEqual(base64.b64decode(encoded), script.read_bytes())

    def test_selects_secondary_without_name_assumptions(self) -> None:
        self.assertEqual(nic.select(self.inventory(), "192.0.2.10"), "ens4")

    def test_selects_secondary_with_higher_metric_default_route(self) -> None:
        data = self.inventory()
        data["routes"] = [
            {"dst": "default", "dev": "ens3", "metric": 48},
            {"dst": "default", "dev": "ens4", "metric": 101},
        ]
        self.assertEqual(nic.select(data, "192.0.2.10"), "ens4")

    def test_rejects_primary_override(self) -> None:
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(self.inventory(), "192.0.2.10", "ens3")

    def test_rejects_missing_override(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing"):
            nic.select(self.inventory(), "192.0.2.10", "wrong0")

    def test_reuses_bridge_port(self) -> None:
        data = self.inventory()
        data["links"][1]["master"] = "br-bmh"
        data["addresses"][1]["ifname"] = "br-bmh"
        self.assertEqual(nic.select(data, "192.0.2.10"), "ens4")

    def test_ambiguity_requires_override(self) -> None:
        data = self.inventory()
        data["links"].append({"ifname": "ens5", "link_type": "ether", "flags": ["UP", "LOWER_UP"]})
        data["physical"].append("ens5")
        data["addresses"].append({"ifname": "ens5", "addr_info": data["addresses"][1]["addr_info"]})
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            nic.select(data, "192.0.2.10")
        self.assertEqual(nic.select(data, "192.0.2.10", "ens5"), "ens5")

    def test_missing_or_unaddressed_secondary(self) -> None:
        data = self.inventory()
        data["addresses"].pop()
        with self.assertRaisesRegex(ValueError, "no safe"):
            nic.select(data, "192.0.2.10")

    def test_protects_node_ip_even_without_default_route(self) -> None:
        data = self.inventory()
        data["routes"] = []
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(data, "192.0.2.10", "ens3")

    def test_requires_identifiable_primary_ip(self) -> None:
        with self.assertRaisesRegex(ValueError, "InternalIP"):
            nic.select(self.inventory(), "203.0.113.99")

    def test_rejects_down_link(self) -> None:
        data = self.inventory()
        data["links"][1]["flags"] = ["UP"]
        with self.assertRaisesRegex(ValueError, "carrier"):
            nic.select(data, "192.0.2.10")

    def test_protects_slave_of_primary_bridge(self) -> None:
        data = self.inventory()
        data["links"][1]["master"] = "br-ex"
        data["addresses"][1]["ifname"] = "br-ex"
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(data, "198.51.100.10", "ens4")

    def test_rejects_ovs_port_and_virtual_device(self) -> None:
        data = self.inventory()
        data["links"][1]["master"] = "ovs-system"
        with self.assertRaises(ValueError):
            nic.select(data, "192.0.2.10")
        data["links"][1].pop("master")
        data["physical"].remove("ens4")
        with self.assertRaises(ValueError):
            nic.select(data, "192.0.2.10")


if __name__ == "__main__":
    unittest.main()
