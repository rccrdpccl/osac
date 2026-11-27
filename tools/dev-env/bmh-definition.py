"""Grow only the persistent definitions of identified dev libvirt workers."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

VIRSH = ('virsh', '-c', 'qemu:///system')


def resize_definition(xml: str, name: str, uuid: str, mac: str, network: str,
                      cpu: int, memory_mib: int) -> str | None:
    domain = ET.fromstring(xml)
    if domain.findtext('name') != name or domain.findtext('uuid') != uuid:
        raise ValueError(f'{name}: libvirt domain identity does not match the inventory')
    for interface in domain.findall('devices/interface'):
        source, address = interface.find('source'), interface.find('mac')
        if (source is not None and source.get('network') == network
                and address is not None and address.get('address', '').lower() == mac.lower()):
            break
    else:
        raise ValueError(f'{name}: libvirt domain network or boot MAC does not match the clone')

    vcpu = domain.find('vcpu')
    memory, current = domain.find('memory'), domain.find('currentMemory')
    if (vcpu is None or memory is None or current is None
            or any(node.get('unit') != 'KiB' for node in (memory, current))):
        raise ValueError(f'{name}: unexpected libvirt CPU or memory definition')
    old_cpu = int(vcpu.get('current') or vcpu.text or '0')
    old_memory = int(current.text or '0')
    target = memory_mib * 1024
    if old_cpu >= cpu and old_memory >= target:
        return None
    if old_cpu < cpu:
        if domain.find('cpu/topology') is not None or domain.find('vcpus') is not None:
            raise ValueError(f'{name}: refusing to resize a custom CPU topology')
        vcpu.text = str(max(cpu, int(vcpu.text or '0')))
        if 'current' in vcpu.attrib:
            vcpu.set('current', str(cpu))
    if old_memory < target:
        if domain.find('maxMemory') is not None or domain.find('cpu/numa') is not None:
            raise ValueError(f'{name}: refusing to resize a custom memory topology')
        memory.text = str(max(target, int(memory.text or '0')))
        current.text = str(target)
    return ET.tostring(domain, encoding='unicode')


def main(argv: list[str]) -> None:
    mode, network, cpu, memory_mib, *workers = argv
    # Validate every worker before updating any definitions. No power or
    # storage commands: a subsequent cold start applies the new definition.
    if mode not in ('preview', 'apply') or not workers or len(workers) % 3:
        raise ValueError('expected a mode and the exact worker name, UUID and MAC for each definition')
    pending = []
    for name, uuid, mac in zip(workers[::3], workers[1::3], workers[2::3]):
        xml = subprocess.check_output([*VIRSH, 'dumpxml', '--inactive', uuid], text=True)
        updated = resize_definition(xml, name, uuid, mac, network, int(cpu), int(memory_mib))
        if updated is None:
            print(f'{name}: persistent definition already meets the requested sizing', flush=True)
        else:
            pending.append((name, updated))
    for name, xml in pending:
        if mode == 'preview':
            print(f'{name}: would grow persistent definition to at least {cpu} vCPUs and {memory_mib} MiB')
            continue
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as definition:
            definition.write(xml)
            definition.flush()
            subprocess.run([*VIRSH, 'define', '--validate', definition.name], check=True)
        print(f'{name}: persistent definition updated; a cold start is required', flush=True)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f'error: {error}')
