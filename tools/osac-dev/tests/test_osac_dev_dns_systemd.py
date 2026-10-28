#!/usr/bin/env python3
"""Opt-in, root-only lifecycle acceptance on a disposable systemd/libvirt host.

OSAC_DEV_DNS_SYSTEMD_TEST=1 sudo -E python3 tools/osac-dev/tests/test_osac_dev_dns_systemd.py
Only Kubernetes resource/NTP inputs are simulated. No SNO or existing clone is used.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

MODULE = Path(__file__).resolve().parents[1] / 'osac-dev-dns-remote.py'


def command(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=90).stdout


def dhcp_client(interface, gateway, state, renew):
    """A real DHCP client in the fixture namespace, including unicast renewal."""
    mac = bytes.fromhex(Path(f'/sys/class/net/{interface}/address').read_text().strip().replace(':', ''))
    xid = secrets.randbits(32)
    previous = json.loads(Path(state).read_text()) if renew else {}
    address = previous.get('address', '0.0.0.0')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b'\0')
        client.bind(('', 68))
        client.settimeout(3)

        def packet(kind, requested=None, server=None):
            header = struct.pack('!BBBBIHH4s4s4s4s16s64s128s', 1, 1, 6, 0, xid, 0,
                                 0 if renew else 0x8000, socket.inet_aton(address),
                                 b'\0' * 4, b'\0' * 4, b'\0' * 4, mac.ljust(16, b'\0'), b'', b'')
            options = b'\x63\x82\x53\x63' + bytes([53, 1, kind])
            options += bytes([61, 7, 1]) + mac + bytes([55, 4, 1, 3, 6, 51])
            hostname = b'fixture-guest'
            options += bytes([12, len(hostname)]) + hostname
            if requested:
                options += bytes([50, 4]) + socket.inet_aton(requested)
            if server:
                options += bytes([54, 4]) + socket.inet_aton(server)
            return (header + options + b'\xff').ljust(300, b'\0')

        def exchange(payload, kind):
            for _ in range(5):
                client.sendto(payload, (gateway if renew else '255.255.255.255', 67))
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        reply = client.recv(4096)
                    except socket.timeout:
                        break
                    if len(reply) < 240 or struct.unpack('!I', reply[4:8])[0] != xid:
                        continue
                    options, offset = {}, 240
                    while offset < len(reply) and reply[offset] != 255:
                        key = reply[offset]
                        offset += 1
                        if key == 0:
                            continue
                        length = reply[offset]
                        offset += 1
                        options[key] = reply[offset:offset + length]
                        offset += length
                    if options.get(53) == bytes([kind]):
                        return socket.inet_ntoa(reply[16:20]), options
            raise RuntimeError('fixture DHCP exchange timed out')

        if renew:
            leased, options = exchange(packet(3), 5)
        else:
            offered, offer = exchange(packet(1), 2)
            leased, options = exchange(packet(3, offered, socket.inet_ntoa(offer[54])), 5)
        if leased == '0.0.0.0':
            leased = address
        if socket.inet_ntoa(options[3][:4]) != gateway or socket.inet_ntoa(options[6][:4]) != gateway:
            raise RuntimeError('DHCP did not supply the fixture gateway and DNS')
        command('ip', 'address', 'replace', leased + '/24', 'dev', interface)
        command('ip', 'route', 'replace', 'default', 'via', gateway)
        Path(state).write_text(json.dumps({'address': leased, 'renewed': renew}))


@unittest.skipUnless(os.environ.get('OSAC_DEV_DNS_SYSTEMD_TEST') == '1',
                     'set OSAC_DEV_DNS_SYSTEMD_TEST=1 explicitly on a disposable host')
class SystemdLifecycle(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0 or not Path('/run/systemd/system').is_dir():
            self.fail('requires root and a running systemd system manager')
        for name in ('systemctl', 'systemd-analyze', 'virsh', 'dnsmasq', 'ip', 'nft', 'nmcli', 'dig'):
            if not shutil.which(name):
                self.fail(f'missing required integration tool: {name}')
        if not Path('/usr/libexec/libvirt_leaseshelper').is_file():
            self.fail('requires the libvirt lease helper')
        self.cluster = 'z' + secrets.token_hex(2)[:3] + '-dev'
        self.domain = f'test-infra-cluster-{self.cluster}.redhat.com'
        self.names = [f'test-infra-net-{self.cluster}', f'test-infra-secondary-network-{self.cluster}']
        self.bridges = [f'br-{self.cluster}', f'bs-{self.cluster}']
        self.units = [f'osac-dev-dns-{self.cluster}-{role}.service' for role in ('primary', 'secondary')]
        self.refresh = f'osac-dev-dns-{self.cluster}.service'
        self.timer = f'osac-dev-dns-{self.cluster}.timer'
        self.setup_unit = f'osac-dev-dns-fixture-{self.cluster}.service'
        self.networks_created = []
        self.namespaces = []
        self.resolvers = []
        self.links = []
        self.owned_units = []
        self.unit_dir = Path('/etc/systemd/system')
        # Refuse every collision before acquiring fixture ownership.
        existing = set(command('virsh', 'net-list', '--all', '--name').splitlines())
        for name in self.names:
            self.assertNotIn(name, existing)
            for suffix in ('.conf', '.hostsfile', '.addnhosts', '.status'):
                self.assertFalse((Path('/var/lib/libvirt/dnsmasq') / (name + suffix)).exists())
        for bridge in self.bridges:
            self.assertFalse(subprocess.run(['ip', 'link', 'show', bridge], capture_output=True).returncode == 0)
            self.assertFalse((Path('/var/lib/libvirt/dnsmasq') / (bridge + '.status')).exists())
        ruleset = command('nft', 'list', 'ruleset')
        for bridge in self.bridges:
            self.assertNotIn('"' + bridge + '"', ruleset, 'fixture bridge referenced by an existing firewall rule')
        for unit in self.units + [self.refresh, self.timer, self.setup_unit]:
            self.assertFalse((self.unit_dir / unit).exists(), unit)
            self.assertEqual(command('systemctl', 'show', '-p', 'LoadState', '--value', unit, check=False).strip(), 'not-found')
        self.config_dir = Path('/etc/osac-dev') / self.cluster
        self.nm_file = Path('/etc/NetworkManager/dnsmasq.d') / (self.cluster + '-cluster.conf')
        self.assertFalse(self.config_dir.exists())
        self.assertFalse(self.nm_file.exists())
        occupied = []
        for route in json.loads(command('ip', '-j', '-4', 'route', 'show', 'table', 'all')):
            if route.get('dst', 'default') != 'default':
                occupied.append(ipaddress.ip_network(route['dst'], strict=False))
        for name in existing:
            root = ET.fromstring(command('virsh', 'net-dumpxml', name))
            bridge = root.find('bridge')
            if bridge is not None:
                self.assertNotIn(bridge.get('name'), self.bridges)
            for entry in root.findall('ip'):
                if entry.get('family', 'ipv4') == 'ipv4':
                    occupied.append(ipaddress.ip_network(f'{entry.get("address")}/{entry.get("prefix") or entry.get("netmask")}', strict=False))
        available = [ipaddress.ip_network(f'198.18.{n}.0/24') for n in range(16, 240)
                     if not any(ipaddress.ip_network(f'198.18.{n}.0/24').overlaps(net) for net in occupied)]
        self.assertGreaterEqual(len(available), 2, 'no unused fixture /24 pair')
        self.subnets = available[:2]
        self.gateways = [str(net[1]) for net in self.subnets]
        self.temp = tempfile.TemporaryDirectory(prefix='osac-dns-fixture-', dir='/run')
        self.root = Path(self.temp.name)
        self.addCleanup(self.cleanup_fixture)
        self.addCleanup(self.capture_failure_logs)
        self.runner = self.root / 'helper.py'
        shutil.copyfile(MODULE, self.root / 'implementation.py')
        self.write_runner()
        self.resources = self.root / 'resources.json'
        self.resources.write_text('{"items": []}')
        (self.root / 'pool.json').write_text('{"spec": {}}')
        for index, name in enumerate(self.names):
            network = self.subnets[index]
            xml = self.root / f'network-{index}.xml'
            xml.write_text(f'''<network><name>{name}</name><forward mode="nat"/>
<bridge name="{self.bridges[index]}" stp="off" delay="0"/>
<domain name="{self.domain}" localOnly="yes"/>
<ip address="{network[1]}" prefix="24"><dhcp>
<range start="{network[128]}" end="{network[254]}"/>
<host mac="52:54:00:ee:00:{index + 1:02x}" name="test-infra-cluster-{self.cluster}-master-0" ip="{network[10]}"/>
</dhcp></ip></network>''')
            command('virsh', 'net-define', str(xml))
            self.networks_created.append(name)
            command('virsh', 'net-start', name)
        self.originals = {name: (Path('/var/lib/libvirt/dnsmasq') / (name + '.conf')).read_text()
                          for name in self.names}
        # This is the same backend used by the production refresh helper.
        command('nft', 'list', 'chain', 'ip', 'libvirt_network', 'forward')
        self.owned_units = self.units + [self.refresh, self.timer, self.setup_unit]

    def write_runner(self):
        # Only resource/NTP discovery is replaced; service management, libvirt,
        # lease helper, sockets, DNS, NM and forwarding use the real helper.
        self.runner.write_text('''import fcntl, importlib.util, json, sys
from pathlib import Path
root = Path(__file__).parent
spec = importlib.util.spec_from_file_location('dns', root / 'implementation.py')
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)
dns.PROGRAM = str(Path(__file__))
def oc(cluster, *args):
    if (root / 'api-fail').exists():
        raise RuntimeError('fixture API unavailable')
    path = root / ('pool.json' if 'ipaddresspool' in args else 'resources.json')
    if args[0] == 'patch':
        path.write_text(args[-1])
    return path.read_text()
dns.oc = oc
dns.selected_ntp = lambda: '192.0.2.123'
if sys.argv[1] == 'fixture-fail':
    cluster = sys.argv[2]
    with open(f'/run/lock/osac-dev-dns-{cluster}.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        net = dns.load_networks(cluster)[0]
        path = dns.managed_config(cluster, 'primary')
        dns.activate(cluster, net, path.read_text() + f'log-facility={root}/absent/log\\n')
else:
    dns.main()
''')

    def helper(self, action, check=True):
        return command(sys.executable, str(self.runner), action, self.cluster, check=check)

    def pids(self):
        return [int(command('systemctl', 'show', '-p', 'MainPID', '--value', unit).strip()) for unit in self.units]

    def query(self, gateway, name, expected=None, namespace=None):
        prefix = ['ip', 'netns', 'exec', namespace] if namespace else []
        for transport in ([], ['+tcp']):
            answer = command(*prefix, 'dig', '+time=1', '+tries=1', '+short', *transport, '@' + gateway, name, 'A').strip()
            if expected is not None:
                self.assertEqual(answer, expected)

    def stable_for_30_seconds(self, expected_pids):
        for _ in range(30):
            started = time.monotonic()
            self.assertEqual(self.pids(), expected_pids)
            for index, gateway in enumerate(self.gateways):
                self.query(gateway, 'apps.' + self.domain, str(self.subnets[index][10]))
                cgroup = Path(f'/proc/{expected_pids[index]}/cgroup').read_text()
                self.assertIn(self.units[index], cgroup)
                self.assertNotIn('/' + self.refresh, cgroup)
            time.sleep(max(0, 1 - (time.monotonic() - started)))

    def make_guest(self, index):
        namespace = f'odns-{self.cluster}-{index}'
        host_link = f'v{index}-{self.cluster}'
        self.assertFalse(Path('/run/netns', namespace).exists())
        self.assertFalse(Path('/etc/netns', namespace).exists())
        self.assertNotIn(host_link, [item['ifname'] for item in json.loads(command('ip', '-j', 'link'))])
        command('ip', 'netns', 'add', namespace)
        self.namespaces.append(namespace)
        command('ip', 'link', 'add', host_link, 'type', 'veth', 'peer', 'name', 'guest0', 'netns', namespace)
        self.links.append(host_link)
        command('ip', 'link', 'set', host_link, 'master', self.bridges[index])
        command('ip', 'link', 'set', host_link, 'up')
        command('ip', '-n', namespace, 'link', 'set', 'lo', 'up')
        command('ip', '-n', namespace, 'link', 'set', 'guest0', 'up')
        resolver = Path('/etc/netns') / namespace
        resolver.mkdir(parents=True)
        self.resolvers.append(resolver)
        (resolver / 'resolv.conf').write_text(f'nameserver {self.gateways[index]}\n')
        state = self.root / f'lease-{index}.json'
        base = ['ip', 'netns', 'exec', namespace, sys.executable, str(Path(__file__).resolve()),
                '--dhcp-client', 'guest0', self.gateways[index], str(state)]
        command(*base)
        acquired = json.loads(state.read_text())['address']
        command(*base, '--renew')
        self.assertEqual(json.loads(state.read_text()), {'address': acquired, 'renewed': True})
        self.query(self.gateways[index], 'apps.' + self.domain, str(self.subnets[index][10]), namespace)
        answer = command('ip', 'netns', 'exec', namespace, 'dig', '+short', '+time=1', '+tries=1', 'apps.' + self.domain)
        self.assertEqual(answer.strip(), str(self.subnets[index][10]))
        return namespace

    def test_refresh_survival_migration_dhcp_replacement_rollback_and_cleanup(self):
        # configure from a real oneshot: any daemon children owned by it die at
        # completion. This is the regression the offline doubles cannot prove.
        (self.unit_dir / self.setup_unit).write_text(f'''[Service]
Type=oneshot
ExecStart={sys.executable} {self.runner} configure {self.cluster}
''')
        command('systemctl', 'daemon-reload')
        command('systemctl', 'start', self.setup_unit)
        command('systemctl', 'disable', '--now', self.timer)
        command('systemctl', 'stop', self.refresh)
        command('systemd-analyze', 'verify', *[str(self.unit_dir / unit) for unit in self.units + [self.refresh, self.timer]])
        pids = self.pids()
        self.assertTrue(all(pids))
        for _ in range(2):
            command('systemctl', 'start', self.refresh)
            self.stable_for_30_seconds(pids)
        (self.root / 'api-fail').touch()
        failed = subprocess.run(['systemctl', 'start', self.refresh], capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.stable_for_30_seconds(pids)
        (self.root / 'api-fail').unlink()
        command('systemctl', 'stop', self.refresh)
        self.stable_for_30_seconds(pids)
        for index in (0, 1):
            self.make_guest(index)
        suffix = f'api.order-a.hosted.{self.domain}'
        for last_octet in (241, 242):
            vip = str(self.subnets[0][last_octet])
            self.resources.write_text(json.dumps({'items': [
                {'kind': 'ClusterOrder', 'metadata': {'namespace': 'fixture', 'name': 'order-a'},
                 'status': {'clusterReference': {'namespace': 'fixture', 'hostedClusterName': 'a'}}},
                {'kind': 'Service', 'metadata': {'namespace': 'fixture-a', 'name': 'kube-apiserver'},
                 'status': {'loadBalancer': {'ingress': [{'ip': vip}]}}}]}))
            command('systemctl', 'start', self.refresh)
            for gateway in self.gateways:
                self.query(gateway, suffix, vip)
        baseline = [(self.config_dir / (role + '.conf')).read_text() for role in ('primary', 'secondary')]
        old_secondary = self.pids()[1]
        rollback = subprocess.run([sys.executable, str(self.runner), 'fixture-fail', self.cluster],
                                  text=True, capture_output=True, timeout=90)
        self.assertNotEqual(rollback.returncode, 0)
        self.assertIn('previous configuration restored', rollback.stderr)
        self.assertEqual(self.pids()[1], old_secondary)
        self.assertEqual([(self.config_dir / (role + '.conf')).read_text() for role in ('primary', 'secondary')], baseline)
        for gateway in self.gateways:
            self.query(gateway, suffix, str(self.subnets[0][242]))
        for _ in range(2):
            self.helper('remove')
        self.assertFalse((self.unit_dir / self.timer).exists())
        self.assertFalse((self.unit_dir / self.refresh).exists())
        for unit in self.units:
            self.assertTrue((self.unit_dir / unit).exists())
        # Baseline no longer has hosted overrides, but still serves DNS and DHCP.
        for index in (0, 1):
            state = self.root / f'lease-{index}.json'
            previous = state.read_text()
            command('ip', 'netns', 'exec', self.namespaces[index], sys.executable,
                    str(Path(__file__).resolve()), '--dhcp-client', 'guest0',
                    self.gateways[index], str(state), '--renew')
            self.assertEqual(state.read_text(), previous)
            self.query(self.gateways[index], 'fixture-guest.' + self.domain,
                       json.loads(state.read_text())['address'], self.namespaces[index])
        for name, original in self.originals.items():
            self.assertEqual((Path('/var/lib/libvirt/dnsmasq') / (name + '.conf')).read_text(), original)
        for name in list(self.networks_created):
            command('virsh', 'net-destroy', name)
            command('virsh', 'net-undefine', name)
            self.networks_created.remove(name)
        self.helper('cleanup')
        self.helper('cleanup')
        self.assertFalse(any((self.unit_dir / unit).exists() for unit in self.units))

    def capture_failure_logs(self):
        # Keep bounded diagnostics visible if a prerequisite/acceptance case fails.
        if hasattr(self, 'owned_units'):
            for unit in self.owned_units:
                print(command('journalctl', '--no-pager', '-n', '20', '-u', unit, check=False), file=sys.stderr)

    def cleanup_fixture(self):
        for unit in reversed(self.owned_units):
            command('systemctl', 'disable', '--now', unit, check=False)
            (self.unit_dir / unit).unlink(missing_ok=True)
        for namespace in self.namespaces:
            command('ip', 'netns', 'delete', namespace, check=False)
        for resolver in self.resolvers:
            shutil.rmtree(resolver)
        for link in self.links:
            command('ip', 'link', 'delete', link, check=False)
        for name in self.networks_created:
            command('virsh', 'net-destroy', name, check=False)
            command('virsh', 'net-undefine', name, check=False)
        # The real sync inserted these exact fixture bridge-pair accept rules.
        # No such rule existed at preflight; unrelated firewall rules stay put.
        chain = command('nft', '-a', 'list', 'chain', 'ip', 'libvirt_network', 'forward', check=False)
        pairs = [(self.bridges[0], self.bridges[1]), (self.bridges[1], self.bridges[0])]
        for line in chain.splitlines():
            handle = re.search(r'accept\s+# handle (\d+)\s*$', line)
            if handle and any(f'iifname "{source}" oifname "{target}"' in line for source, target in pairs):
                command('nft', 'delete', 'rule', 'ip', 'libvirt_network', 'forward', 'handle', handle.group(1))
        if self.nm_file.exists():
            self.nm_file.unlink()
            command('nmcli', 'general', 'reload', 'dns-full', check=False)
        if self.config_dir.exists():
            shutil.rmtree(self.config_dir)
        command('systemctl', 'daemon-reload')
        self.temp.cleanup()


if __name__ == '__main__':
    if '--dhcp-client' in sys.argv:
        parser = argparse.ArgumentParser()
        parser.add_argument('--dhcp-client', nargs=3, metavar=('INTERFACE', 'GATEWAY', 'STATE'))
        parser.add_argument('--renew', action='store_true')
        args = parser.parse_args()
        dhcp_client(*args.dhcp_client, args.renew)
    else:
        unittest.main()
