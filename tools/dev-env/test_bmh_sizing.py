"""Check dev worker sizing without modifying a real VM or BareMetalHost."""

import os
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
LIB = HERE.parent / 'shared' / 'virtual-bmh.sh'
FIXTURE = """<domain type='kvm'>
<name>virtual-bmh-dev-b1</name><uuid>12345678-1234-1234-1234-123456789abc</uuid>
<memory unit='KiB'>8388608</memory><currentMemory unit='KiB'>8388608</currentMemory>
<vcpu placement='static'>4</vcpu>
<devices><disk><source file='/tmp/virtual-bmh-dev-b1.qcow2'/></disk>
<interface type='network'><mac address='52:54:00:bb:cc:b1'/><source network='test-infra-net-dev'/></interface>
</devices></domain>"""


class BmhSizingTest(unittest.TestCase):
    def test_create_passes_ci_sizing_to_the_infra_tool(self):
        result = subprocess.run(
            ['bash', '-c', 'source <(head -n -1 "$1"); GW_IP=192.0.2.1; python3() { printf "ARG %s\\n" "$@"; }; grow_vms 0',
             'test', str(LIB)],
            env={**os.environ, 'CLONE_NAME': 'dev', 'BMH_COUNT': '1', 'BMH_CPU': '8', 'BMH_MEMORY_MIB': '12288'},
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ARG --cpu\nARG 8\n', result.stdout)
        self.assertIn('ARG --memory-mib\nARG 12288\n', result.stdout)

    def test_definition_change_preserves_vm_identity_and_disk(self):
        resize = runpy.run_path(str(HERE / 'bmh-definition.py'))['resize_definition']
        changed = resize(FIXTURE, 'virtual-bmh-dev-b1', '12345678-1234-1234-1234-123456789abc',
                         '52:54:00:bb:cc:b1', 'test-infra-net-dev', 8, 12288)
        domain = ET.fromstring(changed)
        self.assertEqual(domain.findtext('vcpu'), '8')
        self.assertEqual(domain.findtext('memory'), '12582912')
        self.assertEqual(domain.findtext('currentMemory'), '12582912')
        self.assertEqual(domain.findtext('uuid'), '12345678-1234-1234-1234-123456789abc')
        self.assertEqual(domain.find('devices/disk/source').get('file'), '/tmp/virtual-bmh-dev-b1.qcow2')
        self.assertIsNone(resize(changed, 'virtual-bmh-dev-b1', '12345678-1234-1234-1234-123456789abc',
                                 '52:54:00:bb:cc:b1', 'test-infra-net-dev', 4, 8192))

    def test_preview_never_defines_or_restarts_a_domain(self):
        main = runpy.run_path(str(HERE / 'bmh-definition.py'))['main']
        argv = ['preview', 'test-infra-net-dev', '8', '12288', 'virtual-bmh-dev-b1',
                '12345678-1234-1234-1234-123456789abc', '52:54:00:bb:cc:b1']
        with mock.patch.object(subprocess, 'check_output', return_value=FIXTURE) as inspection:
            with mock.patch.object(subprocess, 'run') as execution:
                main(argv)
        inspection.assert_called_once_with(
            ['virsh', '-c', 'qemu:///system', 'dumpxml', '--inactive', argv[-2]], text=True,
        )
        execution.assert_not_called()

    def test_definition_rejects_different_clone_network(self):
        resize = runpy.run_path(str(HERE / 'bmh-definition.py'))['resize_definition']
        with self.assertRaisesRegex(ValueError, 'network or boot MAC'):
            resize(FIXTURE, 'virtual-bmh-dev-b1', '12345678-1234-1234-1234-123456789abc',
                   '52:54:00:bb:cc:b1', 'test-infra-net-other', 8, 12288)


if __name__ == '__main__':
    unittest.main()
