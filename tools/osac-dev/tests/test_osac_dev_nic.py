"""Offline Unit coverage owned by OSAC-6091 [DEV]."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "nic", pathlib.Path(__file__).resolve().parents[1] / "osac-dev-nic.py"
)
nic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nic)


class SelectNic(unittest.TestCase):
    def inventory(self):
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

    def test_selects_secondary_without_name_assumptions(self):
        self.assertEqual(nic.select(self.inventory(), "192.0.2.10"), "ens4")

    def test_selects_secondary_with_higher_metric_default_route(self):
        data = self.inventory()
        data["routes"] = [
            {"dst": "default", "dev": "ens3", "metric": 48},
            {"dst": "default", "dev": "ens4", "metric": 101},
        ]
        self.assertEqual(nic.select(data, "192.0.2.10"), "ens4")

    def test_rejects_primary_override(self):
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(self.inventory(), "192.0.2.10", "ens3")

    def test_rejects_missing_override(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            nic.select(self.inventory(), "192.0.2.10", "wrong0")

    def test_reuses_bridge_port(self):
        data = self.inventory()
        data["links"][1]["master"] = "br-bmh"
        data["addresses"][1]["ifname"] = "br-bmh"
        self.assertEqual(nic.select(data, "192.0.2.10"), "ens4")

    def test_ambiguity_requires_override(self):
        data = self.inventory()
        data["links"].append({"ifname": "ens5", "link_type": "ether", "flags": ["UP", "LOWER_UP"]})
        data["physical"].append("ens5")
        data["addresses"].append({"ifname": "ens5", "addr_info": data["addresses"][1]["addr_info"]})
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            nic.select(data, "192.0.2.10")
        self.assertEqual(nic.select(data, "192.0.2.10", "ens5"), "ens5")

    def test_missing_or_unaddressed_secondary(self):
        data = self.inventory()
        data["addresses"].pop()
        with self.assertRaisesRegex(ValueError, "no safe"):
            nic.select(data, "192.0.2.10")

    def test_protects_node_ip_even_without_default_route(self):
        data = self.inventory()
        data["routes"] = []
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(data, "192.0.2.10", "ens3")

    def test_requires_identifiable_primary_ip(self):
        with self.assertRaisesRegex(ValueError, "InternalIP"):
            nic.select(self.inventory(), "203.0.113.99")

    def test_rejects_down_link(self):
        data = self.inventory()
        data["links"][1]["flags"] = ["UP"]
        with self.assertRaisesRegex(ValueError, "carrier"):
            nic.select(data, "192.0.2.10")

    def test_protects_slave_of_primary_bridge(self):
        data = self.inventory()
        data["links"][1]["master"] = "br-ex"
        data["addresses"][1]["ifname"] = "br-ex"
        with self.assertRaisesRegex(ValueError, "protected"):
            nic.select(data, "198.51.100.10", "ens4")

    def test_rejects_ovs_port_and_virtual_device(self):
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
