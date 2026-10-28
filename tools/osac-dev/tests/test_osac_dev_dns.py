#!/usr/bin/env python3
"""Unit tests: real DNS parsing/rendering and temporary files; no live services."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import mock_open, patch

MODULE = Path(__file__).resolve().parents[1] / "osac-dev-dns-remote.py"


def load():
    spec = importlib.util.spec_from_file_location("dev_dns", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DNSCase(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), "persistent DNS helper has not been implemented")
        self.dns = load()

    def network(self, secondary=True, octet=180):
        name = "test-infra-secondary-network-osac-dev" if secondary else "test-infra-net-osac-dev"
        return self.dns.parse_network(f'''<network><name>{name}</name>
<bridge name="{'bs' if secondary else 'br'}-osac-dev"/>
<domain name="test-infra-cluster-osac-dev.redhat.com"/>
<ip address="192.168.{octet}.1" prefix="24"><dhcp>
<range start="192.168.{octet}.128" end="192.168.{octet}.254"/>
<host name="test-infra-cluster-osac-dev-master-0" ip="192.168.{octet}.10"/>
</dhcp></ip></network>''', "osac-dev")

    def resources(self):
        return {"items": [
            {"kind": "ClusterOrder", "metadata": {"namespace": "osac", "name": "order-a"},
             "status": {"clusterReference": {"namespace": "osac-order-a", "hostedClusterName": "order-a"},
                        "workers": [{"bareMetalInstance": {"id": "uuid-1"}}]}},
            {"kind": "BareMetalInstance", "metadata": {"namespace": "osac", "name": "bmi-uuid-1",
             "labels": {"osac.openshift.io/baremetalinstance-uuid": "uuid-1"}},
             "spec": {"externalHostID": "host-inventory/virtual-bmh-2"}},
            {"kind": "BareMetalHost", "metadata": {"namespace": "host-inventory", "name": "virtual-bmh-2"},
             "status": {"hardware": {"nics": [{"ip": "fe80::1"}, {"ip": "192.168.180.211"}]}}},
            {"kind": "Service", "metadata": {"namespace": "osac-order-a-order-a", "name": "kube-apiserver"},
             "status": {"loadBalancer": {"ingress": [{"ip": "192.168.162.241"}]}}},
        ]}

    def test_current_network_not_yesterdays_subnet(self):
        net = self.network()
        base = "interface=bs-osac-dev\ndhcp-range=192.168.180.128,192.168.180.254,255.255.255.0\ndhcp-authoritative\naddress=/.apps.test-infra-cluster-osac-dev.redhat.com/192.168.162.10\n"
        conf = self.dns.render(base, net, {}, "10.11.160.238", primary=False)
        self.assertIn("dhcp-range=192.168.180.128,192.168.180.254", conf)
        self.assertIn("dhcp-authoritative", conf)
        self.assertIn("address=/apps.test-infra-cluster-osac-dev.redhat.com/192.168.180.10", conf)
        self.assertIn("address=/rhel.pool.ntp.org/10.11.160.238", conf)
        self.assertNotIn("192.168.179", conf)
        self.assertNotIn("192.168.161", conf)

    def test_primary_dhcp_excludes_lab_vip_pool(self):
        net = self.network(False, 162)
        conf = self.dns.render("dhcp-range=192.168.162.128,192.168.162.254,255.255.255.0\n", net, {}, "10.11.160.238", primary=True)
        self.assertIn("dhcp-range=192.168.162.128,192.168.162.239,255.255.255.0", conf)

    def test_record_discovery_without_cluster_order_bmi_label(self):
        records = self.dns.records(self.resources(), self.network())
        self.assertEqual(records, {
            "api.order-a.hosted.test-infra-cluster-osac-dev.redhat.com": "192.168.162.241",
            "api-int.order-a.hosted.test-infra-cluster-osac-dev.redhat.com": "192.168.162.241",
            "apps.order-a.hosted.test-infra-cluster-osac-dev.redhat.com": "192.168.180.211",
        })

    def test_no_fabricated_api_vip_or_stale_order(self):
        data = self.resources()
        data["items"][-1]["status"]["loadBalancer"] = {}
        self.assertFalse(any(k.startswith("api.") for k in self.dns.records(data, self.network())))
        data["items"] = data["items"][1:]
        self.assertEqual(self.dns.records(data, self.network()), {})

    def test_uuid_lookup_is_namespaced(self):
        data = self.resources()
        data["items"][1]["metadata"]["namespace"] = "another-tenant"
        self.assertFalse(any(k.startswith("apps.") for k in self.dns.records(data, self.network())))

    def test_invalid_network_stops_before_changes(self):
        with self.assertRaises(ValueError):
            self.dns.parse_network('<network><name>unrelated</name></network>', "osac-dev")
        with self.assertRaises(ValueError):
            self.dns.validate_cluster("../another-network")

    def test_reject_dns_configuration_injection(self):
        with self.assertRaises(ValueError):
            self.dns.render("", self.network(), {"bad\nserver=evil": "192.0.2.1"}, "10.11.160.238", primary=False)

    def test_network_and_bridge_must_belong_to_same_clone_role(self):
        network = self.network(False, 162)
        with patch.object(self.dns, 'run', side_effect=[network['name'] + '\n', '[{"flags": []}]']):
            with self.assertRaisesRegex(ValueError, 'bridge.*not active'):
                self.dns.assert_network_active(network)
        with patch.object(self.dns, 'run', return_value='') as run:
            with self.assertRaisesRegex(ValueError, 'not active'):
                self.dns.assert_network_active(network)
            self.assertEqual(run.call_count, 1)
        with self.assertRaises(ValueError):
            self.dns.listener_unit('../other-dev', 'primary')

    def test_startup_errors_keep_daemon_stderr_but_never_resource_output(self):
        for binary in ('dnsmasq', 'oc'):
            result = subprocess.CompletedProcess([binary], 11, 'PRIVATE_STDOUT', 'lease-script init failed')
            with patch.object(subprocess, 'run', return_value=result):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    self.dns.run([binary])
                self.assertNotIn('PRIVATE_STDOUT', self.dns.error_detail(caught.exception))
                self.assertEqual(caught.exception.stderr, 'lease-script init failed' if binary == 'dnsmasq' else None)

    def test_preflight_propagates_bridge_to_real_lease_helper_child(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            helper = root / 'libvirt_leaseshelper'
            helper.write_text('#!/usr/bin/env python3\nimport os, sys\n'
                              'assert sys.argv[1:] == ["init"]\n'
                              'assert os.environ["VIR_BRIDGE_NAME"] == "bs-osac-dev"\n')
            helper.chmod(0o755)
            with patch.object(self.dns, 'LEASE_HELPER', str(helper)), \
                 patch.object(self.dns, 'assert_network_active'), \
                 patch.object(self.dns, 'validate_config'):
                self.dns.preflight('osac-dev', self.network(), 'interface=bs-osac-dev\n')

    def test_readiness_is_bounded_and_requires_dhcp_and_dns(self):
        with patch.object(self.dns, 'service_pid', return_value=42), \
             patch.object(self.dns, 'listener_ready', return_value=False), \
             patch.object(self.dns.time, 'monotonic', side_effect=[0, 0, 11]), \
             patch.object(self.dns.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'readiness timed out'):
                self.dns.wait_ready('osac-dev', self.network())

class LifecycleCase(unittest.TestCase):
    """Real config files with recording service/libvirt/API boundaries."""

    network = DNSCase.network
    resources = DNSCase.resources

    def setUp(self):
        self.dns = load()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('LIBVIRT', 'CONFIG', 'SYSTEMD', 'NM'):
            value = self.root / name.lower()
            value.mkdir()
            replacement = patch.object(self.dns, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        self.networks = [self.network(False, 162), self.network()]
        self.calls = []
        self.pids = {}
        self.fail_start = []
        self.next_pid = 100
        self.legacy = {}
        for network in self.networks:
            self.dns.source_config(network).write_text('interface=' + network['bridge'] + '\n')
        self.mock('load_networks', return_value=self.networks)
        self.mock('assert_network_active')
        self.mock('processes', side_effect=self.processes)
        self.mock('listener_ready', side_effect=lambda network, pid: bool(pid))
        self.mock('run', side_effect=self.execute)
        self.mock('stop_processes', side_effect=lambda pids: [self.legacy.pop(pid, None) for pid in pids])

    def mock(self, name, **kwargs):
        replacement = patch.object(self.dns, name, **kwargs)
        result = replacement.start()
        self.addCleanup(replacement.stop)
        return result

    def processes(self, paths):
        result = {pid: argv for pid, argv in self.legacy.items()
                  if any(f'--conf-file={path}' in argv for path in paths)}
        for role, pid in self.pids.items():
            path = self.dns.managed_config('osac-dev', role)
            if path in paths:
                result[pid] = ['dnsmasq', '--keep-in-foreground', f'--conf-file={path}']
        return result

    def execute(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if args[0] != 'systemctl':
            return ''
        if args[1] == 'show':
            role = args[-1].removesuffix('.service').rsplit('-', 1)[-1]
            return str(self.pids.get(role, 0))
        if args[1] in ('start', 'stop'):
            role = args[-1].removesuffix('.service').rsplit('-', 1)[-1]
            self.pids.pop(role, None)
            if args[1] == 'start':
                if self.fail_start:
                    failure = self.fail_start.pop(0)
                    if failure:
                        raise RuntimeError(failure)
                self.next_pid += 1
                self.pids[role] = self.next_pid
        return ''

    def content(self, network, marker):
        return f'interface={network["bridge"]}\n# {marker.strip()}\n'

    def prepare(self, index=0, content='old\n'):
        network = self.networks[index]
        role = self.dns.network_role(network)
        path = self.dns.managed_config('osac-dev', role)
        self.dns.atomic_write(path, self.content(network, content))
        self.dns.install_listener_units('osac-dev', self.networks)
        self.pids[role] = index + 10
        self.calls.clear()
        return network, path

    def mutations(self):
        return [args for args, _ in self.calls
                if args[0] == 'systemctl' and args[1] in ('start', 'stop')]

    def test_services_own_foreground_listeners_and_environment(self):
        self.dns.install_listener_units('osac-dev', self.networks)
        for role, bridge in (('primary', 'br-osac-dev'), ('secondary', 'bs-osac-dev')):
            unit = self.dns.SYSTEMD / self.dns.listener_unit('osac-dev', role)
            content = unit.read_text()
            for expected in ('Type=exec', '--keep-in-foreground', 'Restart=on-failure',
                             'StartLimitBurst=3', 'KillMode=control-group',
                             f'Environment=VIR_BRIDGE_NAME={bridge}',
                             'ExecStartPre=', ' preflight ', 'ExecStartPost=', ' ready '):
                self.assertIn(expected, content)
            for forbidden in ('PartOf=', 'BindsTo=', 'RemainAfterExit', 'KillMode=process',
                              'KillMode=none', '--no-daemon'):
                self.assertNotIn(forbidden, content)
        self.assertFalse(self.mutations(), 'unit installation must preserve legacy listeners')

    def test_unchanged_managed_listeners_keep_pid(self):
        for index in (0, 1):
            network, _ = self.prepare(index, 'same\n')
            before = dict(self.pids)
            self.dns.activate('osac-dev', network, self.content(network, 'same'))
            self.assertEqual(self.pids, before)
            self.assertEqual(self.mutations(), [])

    def test_changed_configuration_restarts_only_affected_network(self):
        self.prepare(0)
        network, path = self.prepare(1)
        self.dns.activate('osac-dev', network, self.content(network, 'new'))
        self.assertEqual(self.pids['primary'], 10)
        self.assertNotEqual(self.pids['secondary'], 11)
        self.assertEqual(path.read_text(), self.content(network, 'new'))
        self.assertTrue(all('secondary.service' in args[-1] for args in self.mutations()))

    def test_lease_failure_does_not_stop_listener(self):
        network, path = self.prepare()
        original = self.execute
        def execute(args, **kwargs):
            if args[0] == self.dns.LEASE_HELPER:
                self.assertEqual(kwargs['env']['VIR_BRIDGE_NAME'], network['bridge'])
                raise RuntimeError('lease init failed')
            return original(args, **kwargs)
        self.dns.run.side_effect = execute
        with self.assertRaisesRegex(RuntimeError, 'lease init failed'):
            self.dns.activate('osac-dev', network, self.content(network, 'new'))
        self.assertEqual(path.read_text(), self.content(network, 'old'))
        self.assertEqual(self.mutations(), [])

    def test_activation_failure_restores_config_and_supervised_listener(self):
        for index in (0, 1):
            with self.subTest(index=index):
                network, path = self.prepare(index)
                self.fail_start = ['activation failed', None]
                with self.assertRaisesRegex(RuntimeError, 'activation failed.*previous configuration restored'):
                    self.dns.activate('osac-dev', network, self.content(network, 'new'))
                self.assertEqual(path.read_text(), self.content(network, 'old'))
                self.assertIn(self.dns.network_role(network), self.pids)
                self.assertFalse(any(args[0] == 'dnsmasq' and '--test' not in args
                                     for args, _ in self.calls))

    def test_failed_rollback_reports_both_failures(self):
        network, path = self.prepare()
        self.fail_start = ['activation failed', 'rollback failed']
        with self.assertRaisesRegex(RuntimeError, 'activation failed.*rollback also failed.*rollback failed'):
            self.dns.activate('osac-dev', network, self.content(network, 'new'))
        self.assertEqual(path.read_text(), self.content(network, 'old'))

    def test_readiness_failure_rolls_back_even_after_start_succeeds(self):
        network, path = self.prepare()
        self.dns.listener_ready.side_effect = [False, True]
        with self.assertRaisesRegex(RuntimeError, 'previous configuration restored'):
            self.dns.activate('osac-dev', network, self.content(network, 'new'))
        self.assertEqual(path.read_text(), self.content(network, 'old'))

    def test_legacy_migration_uses_services_and_preserves_original_files(self):
        self.dns.install_listener_units('osac-dev', self.networks)
        for index, legacy_path in ((0, None), (1, None), (1, 'secondary-dnsmasq.conf')):
            with self.subTest(index=index, legacy_path=legacy_path):
                self.pids.clear()
                network = self.networks[index]
                source = self.dns.source_config(network)
                original = source.read_text()
                live = self.dns.CONFIG / legacy_path if legacy_path else source
                live.write_text(original)
                self.legacy = {42: ['dnsmasq', f'--conf-file={live}']}
                path = self.dns.managed_config('osac-dev', self.dns.network_role(network))
                path.unlink(missing_ok=True)
                self.dns.activate('osac-dev', network, self.content(network, 'new'))
                self.assertEqual(source.read_text(), original)
                self.assertFalse(self.legacy)
                self.assertIn(self.dns.network_role(network), self.pids)

    def test_first_migration_failure_restores_live_legacy_config_under_supervision(self):
        self.dns.install_listener_units('osac-dev', self.networks)
        network = self.networks[1]
        legacy = self.dns.CONFIG / 'secondary-dnsmasq.conf'
        legacy.write_text(self.content(network, 'legacy working'))
        self.legacy = {42: ['dnsmasq', f'--conf-file={legacy}']}
        self.fail_start = ['activation failed', None]
        with self.assertRaisesRegex(RuntimeError, 'previous configuration restored'):
            self.dns.activate('osac-dev', network, self.content(network, 'new'))
        self.assertEqual(self.dns.managed_config('osac-dev', 'secondary').read_text(), self.content(network, 'legacy working'))
        self.assertIn('secondary', self.pids)

    def test_unmanaged_clone_config_is_deliberately_adopted_during_configure(self):
        for index in (0, 1):
            network, path = self.prepare(index)
            role = self.dns.network_role(network)
            self.pids.pop(role)
            self.legacy = {42: ['dnsmasq', f'--conf-file={path}']}
            self.dns.activate('osac-dev', network, path.read_text())
            self.assertIn(role, self.pids)
            self.assertFalse(self.legacy)

    def test_recovery_keeps_healthy_legacy_and_managed_listeners(self):
        self.prepare(0)
        source = self.dns.source_config(self.networks[1])
        self.legacy = {42: ['dnsmasq', f'--conf-file={source}']}
        oc = self.mock('oc')
        self.assertEqual(self.dns.recover('osac-dev'), 0)
        self.assertFalse(self.mutations())
        oc.assert_not_called()

    def test_recovery_starts_absent_listener_with_last_working_config_without_api(self):
        self.prepare(0, 'working hosted records\n')
        self.prepare(1)
        self.pids.pop('primary')
        oc = self.mock('oc')
        self.assertEqual(self.dns.recover('osac-dev'), 1)
        self.assertEqual(self.dns.managed_config('osac-dev', 'primary').read_text(), self.content(self.networks[0], 'working hosted records'))
        self.assertEqual(self.pids['secondary'], 11)
        oc.assert_not_called()

    def test_recovery_refuses_inactive_network_before_any_start(self):
        self.dns.assert_network_active.side_effect = ValueError('not active')
        with self.assertRaisesRegex(ValueError, 'not active'):
            self.dns.recover('osac-dev')
        self.assertEqual(self.mutations(), [])

    def test_sync_preflights_both_before_replacement(self):
        self.mock('oc', side_effect=[json.dumps(self.resources()), json.dumps({'spec': {}})])
        activation = self.mock('activate')
        self.mock('preflight', side_effect=[None, ValueError('secondary invalid')])
        with self.assertRaisesRegex(ValueError, 'secondary invalid'):
            self.dns.sync('osac-dev', '192.0.2.123')
        activation.assert_not_called()

    def test_api_failure_retains_working_configuration(self):
        network, path = self.prepare()
        activation = self.mock('activate')
        self.mock('oc', side_effect=RuntimeError('API unavailable'))
        with self.assertRaisesRegex(RuntimeError, 'API unavailable'):
            self.dns.sync('osac-dev', '192.0.2.123')
        activation.assert_not_called()
        self.assertEqual(path.read_text(), self.content(network, 'old'))
        self.assertFalse(self.mutations())

    def test_repeated_remove_restores_baseline_and_keeps_units(self):
        self.prepare(0)
        self.prepare(1)
        quiesce = self.mock('stop_refresh')
        for _ in range(2):
            self.dns.remove('osac-dev')
        for network in self.networks:
            role = self.dns.network_role(network)
            self.assertEqual(self.dns.managed_config('osac-dev', role).read_text(),
                             self.dns.source_config(network).read_text())
            self.assertTrue((self.dns.SYSTEMD / self.dns.listener_unit('osac-dev', role)).exists())
            self.assertIn(role, self.pids)
        self.assertEqual(quiesce.call_count, 2)

    def test_cleanup_refuses_networks_still_defined(self):
        self.dns.run.side_effect = lambda args, **kwargs: self.networks[0]['name']
        with self.assertRaisesRegex(ValueError, 'still exist'):
            self.dns.cleanup('osac-dev')

    def test_repeated_cleanup_after_absent_networks_preserves_other_clone(self):
        self.prepare(0)
        self.prepare(1)
        unrelated = self.dns.SYSTEMD / self.dns.listener_unit('lab-dev', 'primary')
        unrelated.write_text('unrelated service\n')
        for _ in range(2):
            self.dns.cleanup('osac-dev')
        self.assertEqual(unrelated.read_text(), 'unrelated service\n')
        for role in ('primary', 'secondary'):
            self.assertFalse((self.dns.SYSTEMD / self.dns.listener_unit('osac-dev', role)).exists())
            self.assertFalse(self.dns.managed_config('osac-dev', role).exists())

    def test_remove_handles_partial_installation_and_absent_networks(self):
        self.dns.load_networks.return_value = []
        self.dns.remove('osac-dev')
        self.dns.remove('osac-dev')
        self.assertFalse(self.mutations())

    def test_missing_original_config_does_not_stop_managed_listener(self):
        network, path = self.prepare()
        self.prepare(1)
        self.dns.source_config(network).unlink()
        with self.assertRaises(FileNotFoundError):
            self.dns.remove('osac-dev')
        self.assertEqual(self.pids, {'primary': 10, 'secondary': 11})
        self.assertEqual(path.read_text(), self.content(network, 'old'))
        self.assertFalse(self.mutations())

    def test_failed_destruction_retains_baseline_services(self):
        self.prepare(0)
        self.prepare(1)
        self.mock('stop_refresh')
        with patch.object(self.dns.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['cluster-tool'])):
            with self.assertRaisesRegex(RuntimeError, 'destruction failed'):
                self.dns.destroy('osac-dev', 'cluster-tool')
        self.assertEqual(set(self.pids), {'primary', 'secondary'})
        self.assertTrue((self.dns.SYSTEMD / self.dns.listener_unit('osac-dev', 'primary')).exists())

    def test_successful_destruction_cleans_units_after_network_removal(self):
        self.prepare(0)
        self.prepare(1)
        with patch.object(self.dns.subprocess, 'run') as destroy:
            self.dns.destroy('osac-dev', '/example/cluster-tool')
        destroy.assert_called_once_with(['/example/cluster-tool', 'destroy', 'osac-dev', '--server', 'local'], check=True)
        for role in ('primary', 'secondary'):
            self.assertFalse((self.dns.SYSTEMD / self.dns.listener_unit('osac-dev', role)).exists())

    def test_refresh_unit_is_oneshot_without_listener_stop_dependencies(self):
        self.dns.install_timer('lab-dev', '192.0.2.123')
        service = (self.dns.SYSTEMD / 'osac-dev-dns-lab-dev.service').read_text()
        self.assertIn('Type=oneshot', service)
        self.assertIn('sync lab-dev --ntp 192.0.2.123', service)
        self.assertNotIn('RemainAfterExit', service)
        self.assertNotIn('KillMode=', service)

    def test_configuration_quiesces_before_lock_and_stops_refresh_after_lock(self):
        events = []
        self.mock('quiesce_timer', side_effect=lambda cluster: events.append('timer'))
        self.mock('stop_refresh', side_effect=lambda cluster: events.append('stop'))
        self.mock('recover', side_effect=lambda cluster: events.append('recover'))
        self.mock('sync')
        self.mock('install_timer')
        with patch.object(self.dns.sys, 'argv', ['helper', 'configure', 'osac-dev', '--ntp', '192.0.2.123']), \
             patch.object(self.dns.os, 'geteuid', return_value=0), \
             patch('builtins.open', mock_open()), \
             patch.object(self.dns.fcntl, 'flock', side_effect=lambda *args: events.append('lock')):
            self.dns.main()
        self.assertEqual(events, ['timer', 'lock', 'stop', 'recover'])

    def test_main_recovery_precedes_ntp_and_api(self):
        events = []
        self.mock('recover', side_effect=lambda cluster: events.append('recover'))
        self.mock('selected_ntp', side_effect=lambda: events.append('ntp') or '192.0.2.123')
        self.mock('sync', side_effect=lambda *args: events.append('sync'))
        self.mock('quiesce_timer')
        self.mock('stop_refresh')
        self.mock('install_timer')
        for action in ('configure', 'sync'):
            events.clear()
            with patch.object(self.dns.sys, 'argv', ['helper', action, 'osac-dev']), \
                 patch.object(self.dns.os, 'geteuid', return_value=0), \
                 patch('builtins.open', mock_open()), patch.object(self.dns.fcntl, 'flock'):
                self.dns.main()
            self.assertEqual(events, ['recover', 'ntp', 'sync'])

    def test_ntp_failure_does_not_change_healthy_listeners(self):
        network, path = self.prepare()
        self.prepare(1)
        self.mock('selected_ntp', side_effect=ValueError('no NTP source'))
        self.mock('quiesce_timer')
        self.mock('stop_refresh')
        with patch.object(self.dns.sys, 'argv', ['helper', 'configure', 'osac-dev']), \
             patch.object(self.dns.os, 'geteuid', return_value=0), \
             patch('builtins.open', mock_open()), patch.object(self.dns.fcntl, 'flock'):
            with self.assertRaisesRegex(ValueError, 'no NTP source'):
                self.dns.main()
        self.assertEqual(path.read_text(), self.content(network, 'old'))
        self.assertFalse(self.mutations())


if __name__ == '__main__':
    unittest.main()
