"""Exercise the dev prerequisite wrapper without cluster or hypervisor writes."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

DEPS = Path(__file__).resolve().with_name('deps.sh')
NODE = 'test-infra-cluster-dev-master-0'
CI_OVERRIDE = 'INFRA_VALUES_EXTRA=--set lvms.deviceSelector.optionalPaths={/dev/sdb}'
FAKE = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

cmd, *args = sys.argv
cmd = Path(cmd).name
with open(os.environ['CALLS'], 'a') as stream:
    print(json.dumps([cmd, *args]), file=stream)
state = os.environ.get('LVMS_STATE', 'fresh')
if cmd == 'getent':
    pass
elif cmd == 'helm':
    if os.environ.get('RELEASES_DEPLOYED') == '1':
        print(json.dumps({'version': '0.0.1', 'status': 'deployed'}))
    else:
        sys.exit(1)
elif cmd == 'ssh' and 'virsh domblklist' in args[-1]:
    print(' file disk sda /data/cluster-tool/overlays/dev-disk-0.qcow2')
    print(f" file disk sdb {os.environ.get('DATA_DISK', '/data/cluster-tool/overlays/dev-disk-1.qcow2')}")
elif cmd == 'kubectl':
    _, namespace, *args = args
    if args[:2] == ['get', 'crd']:
        if state != 'fresh':
            print('customresourcedefinition.apiextensions.k8s.io/lvmclusters.lvm.topolvm.io')
    elif args[:2] == ['get', 'lvmclusters.lvm.topolvm.io']:
        path = '/dev/sdb' if state == 'ready' else '/dev/vdb'
        selector = {'optionalPaths': [path]}
        if state == 'custom':
            selector['forceWipeDevicesAndDestroyAllData'] = True
        print(json.dumps({
            'metadata': {'resourceVersion': '123'},
            'spec': {'storage': {'deviceClasses': [{'name': 'vg1', 'deviceSelector': selector}]}},
            'status': {'state': 'Ready' if state == 'ready' else 'Failed'},
        }))
    elif args[:2] == ['get', 'nodes']:
        print(json.dumps({'items': [{'metadata': {'name': os.environ['NODE']}}]}))
    elif args[:2] == ['get', 'lvmvolumegroupnodestatus.lvm.topolvm.io']:
        reasons = ['/dev/sdb is not part of the device selector or could not be resolved via symlink resolution']
        if state == 'busy':
            reasons.append('/dev/sdb has an invalid filesystem signature (xfs) and cannot be used')
        print(json.dumps({'spec': {'nodeStatus': [
            {'status': 'Failed', 'name': 'vg1', 'excluded': [{'name': '/dev/sdb', 'reasons': reasons}]},
        ]}}))
    elif args[0] == 'patch':
        assert namespace == 'openshift-storage'
    elif args[0] == 'wait':
        sys.exit(int(os.environ.get('WAIT_EXIT', '0')))
    else:
        sys.exit(f'unexpected kubectl args: {args}')
elif cmd != 'make':
    sys.exit(f'unexpected command: {cmd} {args}')
'''


class DevDepsTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        home = Path(tmp.name)
        for name in ('getent', 'helm', 'ssh', 'make', 'kubectl'):
            stub = home / name
            stub.write_text(FAKE)
            stub.chmod(0o755)
        (home / '.kube').mkdir()
        self.kubeconfig = home / '.kube/dev.kubeconfig'
        self.kubeconfig.touch()
        self.calls = home / 'calls'
        self.calls.touch()
        self.env = {
            'HOME': tmp.name,
            'PATH': f'{tmp.name}:{os.environ["PATH"]}',
            'CLUSTER_NAME': 'dev',
            'CLUSTER_DOMAIN': 'hub.example.test',
            'REMOTE_HOST': 'root@lab.example.test',
            'NODE': NODE,
            'CALLS': str(self.calls),
        }

    def run_deps(self, *args: str) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
        self.calls.write_text('')
        result = subprocess.run(
            ['bash', str(DEPS), *args], env=self.env, capture_output=True,
            text=True, timeout=10,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def assert_no_install_or_patch(self, calls: list[list[str]]) -> None:
        self.assertFalse(any(call[0] == 'make' or 'patch' in call for call in calls), calls)

    def test_fresh_clone_uses_the_same_device_override_as_ci(self) -> None:
        result, calls = self.run_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][0], 'make')
        self.assertIn(CI_OVERRIDE, calls[-1])
        self.assertFalse(any('patch' in call for call in calls))

    def test_failed_clone_stops_before_helm_and_explains_recovery(self) -> None:
        self.env['LVMS_STATE'] = 'failed'
        result, calls = self.run_deps()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--repair-lvms', result.stderr)
        self.assert_no_install_or_patch(calls)

    def test_opt_in_checks_then_patches_only_the_old_selector_and_waits(self) -> None:
        self.env['LVMS_STATE'] = 'failed'
        result, calls = self.run_deps('--repair-lvms')
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = [i for i, call in enumerate(calls) if 'virsh domblklist' in call[-1]
                  or 'lvmvolumegroupnodestatus.lvm.topolvm.io' in call]
        self.assertEqual(len(checks), 2)
        patch, wait, install = calls[-3:]
        self.assertLess(max(checks), len(calls) - 3)
        self.assertEqual(patch[1:6], ['-n', 'openshift-storage', 'patch',
                                      'lvmclusters.lvm.topolvm.io', 'lvms-cluster'])
        payload = json.loads(patch[-1])
        self.assertIn({'op': 'test', 'path': '/metadata/resourceVersion', 'value': '123'}, payload)
        self.assertEqual([op for op in payload if op['op'] != 'test'], [{
            'op': 'replace', 'path': '/spec/storage/deviceClasses/0/deviceSelector/optionalPaths',
            'value': ['/dev/sdb'],
        }])
        self.assertIn('--for=condition=VolumeGroupsReady', wait)
        self.assertEqual(install[0], 'make')
        self.assertIn(CI_OVERRIDE, install)

    def test_missing_or_foreign_data_disk_stops_before_install(self) -> None:
        self.env['DATA_DISK'] = '/var/lib/libvirt/images/unrelated.qcow2'
        result, calls = self.run_deps()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected', result.stderr)
        self.assertIn('dev-disk-1.qcow2', result.stderr)
        self.assert_no_install_or_patch(calls)

    def test_opt_in_never_repairs_a_busy_disk_or_nondefault_selector(self) -> None:
        for state in ('busy', 'custom'):
            with self.subTest(state=state):
                self.env['LVMS_STATE'] = state
                result, calls = self.run_deps('--repair-lvms')
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_install_or_patch(calls)

    def test_opt_in_refuses_to_patch_a_different_hub(self) -> None:
        self.env.update(LVMS_STATE='failed', NODE='another-hub')
        result, calls = self.run_deps('--repair-lvms')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected a single hub node', result.stderr)
        self.assert_no_install_or_patch(calls)

    def test_healthy_lvms_is_not_patched_when_helm_needs_a_retry(self) -> None:
        self.env['LVMS_STATE'] = 'ready'
        result, calls = self.run_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(CI_OVERRIDE, calls[-1])
        self.assertFalse(any('patch' in call for call in calls))

    def test_repair_timeout_never_starts_helm_install(self) -> None:
        self.env.update(LVMS_STATE='failed', WAIT_EXIT='1')
        result, calls = self.run_deps('--repair-lvms')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('VolumeGroupsReady', result.stderr)
        self.assertFalse(any(call[0] == 'make' for call in calls))

    def test_adopted_hub_keeps_its_own_lvms_configuration(self) -> None:
        self.env['OSAC_DEV_HUB_KUBECONFIG'] = str(self.kubeconfig)
        result, calls = self.run_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][0], 'make')
        self.assertNotIn(CI_OVERRIDE, calls[-1])
        self.assertFalse(any(call[0] in ('ssh', 'kubectl') for call in calls))
        result, calls = self.run_deps('--repair-lvms')
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_install_or_patch(calls)

    def test_explicit_infra_values_disable_clone_storage_defaults(self) -> None:
        self.env['INFRA_VALUES_EXTRA'] = '-f custom.yaml'
        result, calls = self.run_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(CI_OVERRIDE, calls[-1])
        self.assertFalse(any(call[0] in ('ssh', 'kubectl') for call in calls))

    def test_deployed_releases_keep_existing_fast_path(self) -> None:
        self.env['RELEASES_DEPLOYED'] = '1'
        result, calls = self.run_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(call[0] in ('getent', 'helm') for call in calls), calls)


if __name__ == '__main__':
    unittest.main()
