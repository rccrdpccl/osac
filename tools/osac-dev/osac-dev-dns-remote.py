#!/usr/bin/env python3
"""Provider-owned dev lab DNS, not an OSAC tenant networking backend.

Run on the cluster-tool host. Original libvirt files are read-only inputs.
All state, timers and process selection are scoped to one validated clone ID.
"""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


LIBVIRT = Path('/var/lib/libvirt/dnsmasq')
CONFIG = Path('/etc/osac-dev')
NM = Path('/etc/NetworkManager/dnsmasq.d')
SYSTEMD = Path('/etc/systemd/system')
PROGRAM = '/usr/local/sbin/osac-dev-dns'
LEASE_HELPER = '/usr/libexec/libvirt_leaseshelper'


def run(args, *, env=None):
    # Never propagate resource JSON (ClusterOrder includes pull secrets) into logs.
    result = subprocess.run(args, text=True, capture_output=True, timeout=60, env=env)
    if result.returncode:
        # Daemon/lease-helper stderr is useful for recovery. Never attach oc
        # output, resource JSON or lease-script stdout to diagnostic errors.
        stderr = result.stderr[-2000:] if Path(args[0]).name in ('dnsmasq', 'libvirt_leaseshelper') else None
        raise subprocess.CalledProcessError(result.returncode, args, stderr=stderr)
    return result.stdout


def validate_cluster(cluster):
    if not re.fullmatch(r'[a-z0-9]{1,4}-dev', cluster):
        raise ValueError('cluster must be <1-4 lowercase letters/digits>-dev')


def dns_name(name):
    if len(name) > 253 or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in name.split('.')):
        raise ValueError('invalid DNS name')
    return name


def parse_network(xml, cluster):
    validate_cluster(cluster)
    root = ET.fromstring(xml)
    if root.findtext('name') not in (f'test-infra-net-{cluster}', f'test-infra-secondary-network-{cluster}'):
        raise ValueError('refusing an unrelated libvirt network')
    domain = dns_name(root.find('domain').get('name'))
    if domain != f'test-infra-cluster-{cluster}.redhat.com':
        raise ValueError('unexpected clone domain')
    entries = [x for x in root.findall('ip') if x.get('family', 'ipv4') == 'ipv4']
    if len(entries) != 1:
        raise ValueError('expected exactly one lab IPv4 subnet')
    entry = entries[0]
    gateway = ipaddress.IPv4Address(entry.get('address'))
    network = ipaddress.IPv4Network(f'{gateway}/{entry.get("prefix") or entry.get("netmask")}', strict=False)
    if network.prefixlen != 24:
        raise ValueError('cluster-tool dev lab requires /24 networks')
    hosts = [x.get('ip') for x in entry.findall('dhcp/host') if x.get('name') == f'test-infra-cluster-{cluster}-master-0']
    if len(hosts) != 1 or ipaddress.IPv4Address(hosts[0]) not in network:
        raise ValueError('missing unique SNO DHCP reservation')
    bridge = root.find('bridge').get('name')
    expected_bridge = f'bs-{cluster}' if root.findtext('name').startswith('test-infra-secondary-') else f'br-{cluster}'
    if bridge != expected_bridge:
        raise ValueError('unexpected lab bridge')
    return dict(name=root.findtext('name'), domain=domain, gateway=str(gateway),
                subnet=network, node_ip=hosts[0], bridge=bridge)


def records(data, secondary):
    items = data['items']
    hosts = {(x['metadata']['namespace'], x['metadata']['name']): x for x in items if x['kind'] == 'BareMetalHost'}
    services = {(x['metadata']['namespace'], x['metadata']['name']): x for x in items if x['kind'] == 'Service'}
    bmis = {(x['metadata']['namespace'], x['metadata'].get('labels', {}).get('osac.openshift.io/baremetalinstance-uuid')): x
            for x in items if x['kind'] == 'BareMetalInstance'}
    desired = {}
    for order in (x for x in items if x['kind'] == 'ClusterOrder' and not x['metadata'].get('deletionTimestamp')):
        meta, status = order['metadata'], order.get('status', {})
        suffix = dns_name(f'{meta["name"]}.hosted.{secondary["domain"]}')
        ref = status.get('clusterReference', {})
        namespace = ref.get('namespace', '') + '-' + ref.get('hostedClusterName', '')
        service = services.get((namespace, 'kube-apiserver'), {})
        for address in service.get('status', {}).get('loadBalancer', {}).get('ingress', []):
            try:
                vip = str(ipaddress.IPv4Address(address['ip']))
            except (KeyError, ValueError):
                continue
            desired[f'api.{suffix}'] = vip
            desired[f'api-int.{suffix}'] = vip
            break
        # Do not depend on a BMI cluster-order label: API-projected BMIs lack it.
        for worker in status.get('workers', []):
            bmi = bmis.get((meta['namespace'], worker.get('bareMetalInstance', {}).get('id')), {})
            host_ref = bmi.get('spec', {}).get('externalHostID', '').split('/')
            if len(host_ref) != 2:
                continue
            host = hosts.get(tuple(host_ref), {})
            for nic in host.get('status', {}).get('hardware', {}).get('nics', []):
                try:
                    address = ipaddress.IPv4Address(nic.get('ip', ''))
                except ValueError:
                    continue
                if address in secondary['subnet']:
                    desired.setdefault(f'apps.{suffix}', str(address))
    return desired


def render(base, network, desired, ntp, primary):
    ntp = str(ipaddress.IPv4Address(ntp))
    apps = f'apps.{network["domain"]}'
    hosted = f'hosted.{network["domain"]}'
    lines = []
    for line in base.splitlines():
        if line.startswith('address=/') and line.split('/')[1].lstrip('.') in (apps, hosted, 'rhel.pool.ntp.org'):
            continue
        if primary and line.startswith('dhcp-range='):
            fields = line.split('=', 1)[1].split(',')
            # Reserve .240-.250 for the dev MetalLB pool, never DHCP them out.
            if len(fields) >= 2 and ipaddress.IPv4Address(fields[1]) >= network['subnet'][240]:
                fields[1] = str(network['subnet'][239])
                if ipaddress.IPv4Address(fields[0]) > network['subnet'][239]:
                    raise ValueError('DHCP range conflicts with dev VIP reservation')
                line = 'dhcp-range=' + ','.join(fields)
        lines.append(line)
    lines += [f'address=/{apps}/{network["node_ip"]}', f'address=/rhel.pool.ntp.org/{ntp}', f'local=/{hosted}/']
    for suffix, address in sorted(desired.items()):
        dns_name(suffix)
        if not suffix.endswith('.' + hosted):
            raise ValueError('record outside the hosted domain')
        lines.append(f'address=/{suffix}/{ipaddress.IPv4Address(address)}')
    return '\n'.join(lines) + '\n'


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as temp:
        temp.write(text)
        pending = Path(temp.name)
    pending.chmod(0o644)
    pending.replace(path)


def processes(configs):
    """Match full config paths, never broad pgrep patterns or other clones."""
    matches = {}
    expected = {f'--conf-file={path}' for path in configs}
    for cmdline in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            argv = cmdline.read_bytes().decode().strip('\0').split('\0')
            if Path(argv[0]).name == 'dnsmasq' and expected.intersection(argv):
                matches[int(cmdline.parent.name)] = argv
        except (OSError, UnicodeError):
            continue
    return matches


def stop_processes(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(50):
        alive = False
        for pid in pids:
            try:
                alive |= bool(Path(f'/proc/{pid}/cmdline').read_bytes())
            except FileNotFoundError:
                pass
        if not alive:
            return
        time.sleep(0.1)
    raise RuntimeError('old dnsmasq did not stop; refusing another listener')


def validate_config(path, content):
    # A service restart can preflight concurrently with a refresh. Each check
    # owns its candidate so one validator cannot replace/delete another's input.
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', prefix=path.name + '.pending.',
                                     dir=path.parent, delete=False) as temp:
        temp.write(content)
        candidate = Path(temp.name)
    try:
        run(['dnsmasq', '--test', f'--conf-file={candidate}'])
    finally:
        candidate.unlink(missing_ok=True)


def lease_environment(bridge):
    if not re.fullmatch(r'(?:br|bs)-[a-z0-9]{1,4}-dev', bridge):
        raise ValueError('unexpected lease-helper bridge')
    return {**os.environ, 'VIR_BRIDGE_NAME': bridge}


def error_detail(error):
    detail = str(error)
    if isinstance(error, subprocess.CalledProcessError) and error.stderr:
        detail += ': ' + error.stderr.strip()
    return detail


def network_role(network):
    return 'secondary' if network['name'].startswith('test-infra-secondary-network-') else 'primary'


def listener_unit(cluster, role):
    validate_cluster(cluster)
    if role not in ('primary', 'secondary'):
        raise ValueError('unknown listener')
    return f'osac-dev-dns-{cluster}-{role}.service'


def managed_config(cluster, role):
    listener_unit(cluster, role)
    return CONFIG / cluster / (role + '.conf')


def source_config(network):
    return LIBVIRT / (network['name'] + '.conf')


def legacy_configs(cluster, network):
    paths = [source_config(network)]
    if cluster == 'osac-dev' and network_role(network) == 'secondary':
        paths.append(CONFIG / 'secondary-dnsmasq.conf')
    return paths


def load_networks(cluster, *, existing_only=False):
    validate_cluster(cluster)
    names = [f'{prefix}-{cluster}' for prefix in ('test-infra-net', 'test-infra-secondary-network')]
    if existing_only:
        active = set(run(['virsh', 'net-list', '--name']).splitlines())
        names = [name for name in names if name in active]
    return [parse_network(run(['virsh', 'net-dumpxml', name]), cluster) for name in names]


def assert_network_active(network):
    active = set(run(['virsh', 'net-list', '--name']).splitlines())
    if network['name'] not in active:
        raise ValueError(f'lab network {network["name"]} is not active; refusing to start a listener')
    links = json.loads(run(['ip', '-j', 'link', 'show', 'dev', network['bridge']]))
    if len(links) != 1 or 'UP' not in links[0].get('flags', []):
        raise ValueError(f'lab bridge {network["bridge"]} is not active')


def preflight(cluster, network, content):
    assert_network_active(network)
    interfaces = [line.split('=', 1)[1] for line in content.splitlines() if line.startswith('interface=')]
    if interfaces != [network['bridge']]:
        raise ValueError('configuration interface does not match the active clone bridge')
    validate_config(managed_config(cluster, network_role(network)), content)
    run([LEASE_HELPER, 'init'], env=lease_environment(network['bridge']))


def install_listener_units(cluster, networks):
    """Install ownership before any recovery; never start or stop a listener here."""
    changed = False
    for network in networks:
        role = network_role(network)
        unit = listener_unit(cluster, role)
        path = managed_config(cluster, role)
        dnsmasq = shutil.which('dnsmasq') or '/usr/sbin/dnsmasq'
        content = f'''[Unit]
Description=Persistent {cluster} {role} lab DNS and DHCP
After=network-online.target libvirtd.service virtqemud.service virtnetworkd.service
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
Type=exec
Environment=PATH=/usr/local/bin:/root/.local/bin:/usr/bin:/usr/sbin:/bin
Environment=VIR_BRIDGE_NAME={network['bridge']}
ExecStartPre=/usr/bin/python3 {PROGRAM} preflight {cluster} --listener {role}
ExecStart={dnsmasq} --keep-in-foreground --conf-file={path} --leasefile-ro --dhcp-script={LEASE_HELPER}
ExecStartPost=/usr/bin/python3 {PROGRAM} ready {cluster} --listener {role}
Restart=on-failure
RestartSec=2s
TimeoutStartSec=45s
TimeoutStopSec=10s
KillMode=control-group
[Install]
WantedBy=multi-user.target
'''
        target = SYSTEMD / unit
        if not target.exists() or target.read_text() != content:
            atomic_write(target, content)
            changed = True
    if changed:
        run(['systemctl', 'daemon-reload'])
    for network in networks:
        run(['systemctl', 'enable', listener_unit(cluster, network_role(network))])


def service_pid(cluster, role):
    unit = listener_unit(cluster, role)
    if not (SYSTEMD / unit).exists():
        return 0
    return int(run(['systemctl', 'show', '--property=MainPID', '--value', unit]).strip() or '0')


def dns_probe(network, *, tcp=False):
    """Ask for the local domain SOA: NXDOMAIN is also a valid local response."""
    ident = os.urandom(2)
    name = b''.join(bytes([len(label)]) + label.encode('ascii') for label in network['domain'].split('.')) + b'\0'
    query = ident + struct.pack('!HHHHH', 0, 1, 0, 0, 0) + name + struct.pack('!HH', 6, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as client:
        client.settimeout(0.5)
        client.connect((network['gateway'], 53))
        if tcp:
            client.sendall(struct.pack('!H', len(query)) + query)
            def receive(length):
                data = b''
                while len(data) < length:
                    chunk = client.recv(length - len(data))
                    if not chunk:
                        raise OSError('short DNS response')
                    data += chunk
                return data
            response = receive(struct.unpack('!H', receive(2))[0])
        else:
            client.send(query)
            response = client.recv(4096)
    return (len(response) >= 12 and response[:2] == ident and
            bool(response[2] & 0x80) and (response[3] & 0x0f) in (0, 3))


def listener_ready(network, pid):
    if not pid:
        return False
    try:
        # DNS probes alone cannot prove that this listener also owns DHCP.
        sockets = set()
        for fd in Path(f'/proc/{pid}/fd').iterdir():
            try:
                sockets.add(fd.readlink().name)
            except FileNotFoundError:
                pass
        udp = Path(f'/proc/{pid}/net/udp').read_text().splitlines()[1:]
        dhcp = any(line.split()[1].endswith(':0043') and
                   f'socket:[{line.split()[9]}]' in sockets for line in udp)
        return dhcp and dns_probe(network) and dns_probe(network, tcp=True)
    except (OSError, ValueError):
        return False


def wait_ready(cluster, network):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if listener_ready(network, service_pid(cluster, network_role(network))):
            return
        time.sleep(0.2)
    raise RuntimeError(f'{listener_unit(cluster, network_role(network))}: DNS/DHCP readiness timed out; inspect journalctl -u for diagnostics')


def start_listener(cluster, network):
    unit = listener_unit(cluster, network_role(network))
    run(['systemctl', 'reset-failed', unit])
    run(['systemctl', 'start', unit])
    # ExecStartPost checks readiness on automatic restarts as well. Check here
    # too so a premature service exit cannot be accepted as successful handoff.
    if not listener_ready(network, service_pid(cluster, network_role(network))):
        raise RuntimeError(f'{unit}: started but DNS/DHCP is not ready; inspect journalctl -u {unit}')


def activate(cluster, network, content, *, checked=False):
    role = network_role(network)
    path = managed_config(cluster, role)
    sources = legacy_configs(cluster, network)
    old = processes(sources + [path])
    pid = service_pid(cluster, role)
    previous = path.read_text() if path.exists() else None
    if previous == content and pid in old and listener_ready(network, pid):
        return
    if not checked:
        preflight(cluster, network, content)
    # A first migration must roll back the *live* legacy config, not a stale
    # managed file left behind by an earlier failed configure.
    rollback = previous
    for source in sources:
        if any(f'--conf-file={source}' in argv for argv in old.values()):
            rollback = source.read_text()
            break
    if rollback is None:
        rollback = source_config(network).read_text()
    try:
        preflight(cluster, network, rollback)
    except (ValueError, subprocess.SubprocessError):
        if old:
            raise
        rollback = source_config(network).read_text()
        preflight(cluster, network, rollback)
    unit = listener_unit(cluster, role)
    try:
        run(['systemctl', 'stop', unit])
        stop_processes(processes(sources + [path]))
        atomic_write(path, content)
        start_listener(cluster, network)
    except (subprocess.SubprocessError, OSError, RuntimeError) as activation_error:
        try:
            run(['systemctl', 'stop', unit])
            # A legacy process may still be exiting after a failed stop.
            stop_processes(processes(sources + [path]))
            atomic_write(path, rollback)
            start_listener(cluster, network)
        except (subprocess.SubprocessError, OSError, RuntimeError) as rollback_error:
            raise RuntimeError(
                f'DNS activation failed: {error_detail(activation_error)}; '
                f'rollback also failed: {error_detail(rollback_error)}; '
                f'inspect journalctl -u {unit}; rerun --recover for offline recovery'
            ) from None
        raise RuntimeError(f'DNS activation failed: {error_detail(activation_error)}; previous configuration restored through {unit}') from None


def recover(cluster):
    """Restore absent listeners without API/NTP reads or legacy PID churn."""
    networks = load_networks(cluster)
    for network in networks:
        assert_network_active(network)
    install_listener_units(cluster, networks)
    pending = []
    for network in networks:
        role = network_role(network)
        path = managed_config(cluster, role)
        old = processes(legacy_configs(cluster, network) + [path])
        if any(listener_ready(network, pid) for pid in old):
            continue
        # Retain validated last-working hosted records when available. If a
        # partial installation left invalid managed state, recover baseline.
        content = path.read_text() if path.exists() else source_config(network).read_text()
        try:
            preflight(cluster, network, content)
        except (ValueError, subprocess.SubprocessError):
            content = source_config(network).read_text()
            preflight(cluster, network, content)
        pending.append((network, content))
    for network, content in pending:
        activate(cluster, network, content, checked=True)
        print(f'{cluster}: restored missing DNS/DHCP listener for {network["name"]}')
    return len(pending)


def oc(cluster, *args):
    return run(['oc', '--kubeconfig', f'/root/.kube/{cluster}.kubeconfig',
                '--context', 'system:admin', '--request-timeout=20s', *args])


def sync(cluster, ntp):
    validate_cluster(cluster)
    networks = load_networks(cluster)
    primary, secondary = networks
    # Finish all reads and rendering before stopping either network's DNS.
    data = json.loads(oc(cluster, 'get', 'clusterorders,baremetalinstances,baremetalhosts,services', '-A', '-o', 'json'))
    desired = records(data, secondary)
    pool = json.loads(oc(cluster, 'get', 'ipaddresspool', 'caas-address-pool', '-n', 'metallb-system', '-o', 'json'))
    vip_range = f'{primary["subnet"][240]}-{primary["subnet"][250]}'
    for service in data['items']:
        if service['kind'] != 'Service' or service['metadata'].get('annotations', {}).get('metallb.io/ip-allocated-from-pool') != 'caas-address-pool':
            continue
        for entry in service.get('status', {}).get('loadBalancer', {}).get('ingress', []):
            if 'ip' in entry and not primary['subnet'][240] <= ipaddress.IPv4Address(entry['ip']) <= primary['subnet'][250]:
                raise ValueError('existing API VIP outside current lab pool; refusing reassignment')
    configs = [(network, render(source_config(network).read_text(), network, desired, ntp,
                                primary=index == 0)) for index, network in enumerate(networks)]
    for network, content in configs:
        preflight(cluster, network, content)
    for network, content in configs:
        activate(cluster, network, content, checked=True)
    spec = dict(addresses=[vip_range], autoAssign=True)
    if any(pool['spec'].get(key) != value for key, value in spec.items()):
        oc(cluster, 'patch', 'ipaddresspool', 'caas-address-pool', '-n', 'metallb-system', '--type=merge', '-p', json.dumps({'spec': spec}))
    nm_conf = NM / (cluster + '-cluster.conf')
    forwarding = f'server=/hosted.{primary["domain"]}/{secondary["gateway"]}\n'
    if not nm_conf.exists() or nm_conf.read_text() != forwarding:
        atomic_write(nm_conf, forwarding)
        run(['nmcli', 'general', 'reload', 'dns-full'])
    # Libvirt isolates bridges by default; this lab requires API VIP reachability.
    chain = run(['nft', 'list', 'chain', 'ip', 'libvirt_network', 'forward'])
    for source, target in ((primary, secondary), (secondary, primary)):
        rule = ['iifname', source['bridge'], 'oifname', target['bridge']]
        if f'iifname "{source["bridge"]}" oifname "{target["bridge"]}"' not in chain:
            run(['nft', 'insert', 'rule', 'ip', 'libvirt_network', 'forward', *rule, 'counter', 'accept'])
    print(f'{cluster}: DNS ready; {len(desired)} hosted records refreshed')


def selected_ntp():
    for line in run(['chronyc', '-n', 'sources']).splitlines():
        fields = line.split()
        if fields and fields[0] == '^*':
            return str(ipaddress.IPv4Address(fields[1]))
    raise ValueError('no selected IPv4 chrony source; set OSAC_DEV_NTP_SERVER to a reachable IPv4 NTP server')


def install_timer(cluster, ntp):
    unit = f'osac-dev-dns-{cluster}'
    atomic_write(SYSTEMD / (unit + '.service'), f'''[Unit]
Description=Refresh {cluster} lab DNS from actual provisioning resources
After=network-online.target libvirtd.service
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/root/.local/bin:/usr/bin:/usr/sbin:/bin
ExecStart=/usr/bin/python3 {PROGRAM} sync {cluster} --ntp {ntp}
''')
    atomic_write(SYSTEMD / (unit + '.timer'), '''[Unit]
Description=Keep dev lab DNS current across provisioning and test exits
[Timer]
OnBootSec=30s
OnUnitInactiveSec=10s
[Install]
WantedBy=timers.target
''')
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', unit + '.timer'])


def unit_installed(unit):
    return (SYSTEMD / unit).exists()


def quiesce_timer(cluster):
    unit = f'osac-dev-dns-{cluster}.timer'
    if unit_installed(unit):
        run(['systemctl', 'disable', '--now', unit])


def stop_refresh(cluster):
    # Called only with the clone lock held: an executing refresh has finished,
    # and a queued refresh can be stopped without killing a handoff mid-flight.
    # A configure that held the lock before us may have installed a new timer
    # after the caller's initial quiesce. Disable that timer under the lock too.
    quiesce_timer(cluster)
    unit = f'osac-dev-dns-{cluster}.service'
    if unit_installed(unit):
        run(['systemctl', 'stop', unit])
    for kind in ('service', 'timer'):
        (SYSTEMD / f'osac-dev-dns-{cluster}.{kind}').unlink(missing_ok=True)
    run(['systemctl', 'daemon-reload'])


def remove(cluster):
    stop_refresh(cluster)
    networks = load_networks(cluster, existing_only=True)
    install_listener_units(cluster, networks)
    baseline = [(network, source_config(network).read_text()) for network in networks]
    for network, content in baseline:
        preflight(cluster, network, content)
    for network, content in baseline:
        activate(cluster, network, content, checked=True)
    forwarding = NM / (cluster + '-cluster.conf')
    if forwarding.exists():
        forwarding.unlink()
        run(['nmcli', 'general', 'reload', 'dns-full'])
    # Baseline configs and their persistent services intentionally remain while
    # the networks exist. Original configs, reservations and lease files stay put.


def cleanup(cluster):
    names = {f'{prefix}-{cluster}' for prefix in ('test-infra-net', 'test-infra-secondary-network')}
    present = names.intersection(run(['virsh', 'net-list', '--all', '--name']).splitlines())
    if present:
        raise ValueError('selected clone networks still exist; retaining baseline listener units: ' + ', '.join(sorted(present)))
    for role in ('primary', 'secondary'):
        unit = listener_unit(cluster, role)
        if unit_installed(unit):
            run(['systemctl', 'disable', '--now', unit])
            (SYSTEMD / unit).unlink()
        managed_config(cluster, role).unlink(missing_ok=True)
    stop_refresh(cluster)
    forwarding = NM / (cluster + '-cluster.conf')
    if forwarding.exists():
        forwarding.unlink()
        run(['nmcli', 'general', 'reload', 'dns-full'])
    run(['systemctl', 'daemon-reload'])


def destroy(cluster, cluster_tool):
    remove(cluster)
    try:
        # Destruction can take minutes; stream its output and impose no helper
        # command timeout. The clone lock spans baseline restoration and cleanup.
        subprocess.run([cluster_tool, 'destroy', cluster, '--server', 'local'], check=True)
    except (subprocess.SubprocessError, OSError) as error:
        try:
            remove(cluster)  # Partial destruction: restore each surviving active network.
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as recovery_error:
            raise RuntimeError(f'cluster destruction failed: {error_detail(error)}; baseline recovery also failed: {error_detail(recovery_error)}') from None
        raise RuntimeError(f'cluster destruction failed: {error_detail(error)}; surviving baseline listener services retained') from None
    cleanup(cluster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('configure', 'sync', 'remove', 'recover', 'preflight', 'ready', 'destroy', 'cleanup'))
    parser.add_argument('cluster')
    parser.add_argument('--ntp', default='')
    parser.add_argument('--listener', choices=('primary', 'secondary'))
    parser.add_argument('--cluster-tool', default='cluster-tool')
    args = parser.parse_args()
    validate_cluster(args.cluster)
    if os.geteuid() != 0:
        raise ValueError('host DNS management requires root')
    # systemd start hooks run while the caller owns the lock. They perform only
    # reads and validation; taking the lock here would deadlock systemctl start.
    if args.action in ('preflight', 'ready'):
        if not args.listener:
            raise ValueError('--listener is required')
        prefix = 'test-infra-net' if args.listener == 'primary' else 'test-infra-secondary-network'
        network = parse_network(run(['virsh', 'net-dumpxml', f'{prefix}-{args.cluster}']), args.cluster)
        if args.action == 'preflight':
            preflight(args.cluster, network, managed_config(args.cluster, args.listener).read_text())
        else:
            wait_ready(args.cluster, network)
        return
    if args.action in ('configure', 'remove', 'destroy', 'cleanup'):
        quiesce_timer(args.cluster)
    with open(f'/run/lock/osac-dev-dns-{args.cluster}.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'remove':
            remove(args.cluster)
            return
        if args.action == 'cleanup':
            cleanup(args.cluster)
            return
        if args.action == 'destroy':
            destroy(args.cluster, args.cluster_tool)
            return
        if args.action == 'configure':
            stop_refresh(args.cluster)
        if args.action == 'recover':
            print(f'RECOVERED_LISTENERS={recover(args.cluster)}')
            return
        recover(args.cluster)
        ntp = str(ipaddress.IPv4Address(args.ntp or selected_ntp()))
        sync(args.cluster, ntp)
        if args.action == 'configure':
            install_timer(args.cluster, ntp)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError, ET.ParseError, KeyError, AttributeError) as error:
        print(f'osac-dev-dns: {error_detail(error)}', file=sys.stderr)
        sys.exit(1)
