import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
CLI = ROOT / 'tools/osac-dev/osac-dev'


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.log = self.directory / 'calls'
        self.config = self.directory / 'hub with spaces.yaml'
        self.config.touch()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('OSAC_DEV_', 'AAP_', 'PULL_SECRET', 'SNO_', 'HUB', 'BM_CNV', 'REMOTE_HOST'))}
        self.env.update(PATH=f'{self.directory}:{os.environ["PATH"]}', CALL_LOG=str(self.log))
        for executable in ('cluster-tool', 'ssh', 'helm', 'skaffold', 'kind'):
            path = self.directory / executable
            path.write_text('#!/bin/sh\nprintf sentinel >> "$CALL_LOG"\nexit 99\n')
            path.chmod(0o755)
        path = self.directory / 'oc'
        path.write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["CALL_LOG"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nprint(json.dumps({"metadata":{"uid":"observed-uid"}} if "get" in sys.argv else {"current-context":"selected","contexts":[{"name":"selected","context":{"cluster":"hub"}}],"clusters":[{"name":"hub","cluster":{"server":"https://api.example:6443"}}]}))\n')
        path.chmod(0o755)

    def run_command(self, args, make=False, **env):
        command = ['make', '--no-print-directory', 'osac-dev', *args] if make else [str(CLI), *args]
        return subprocess.run(command, cwd=ROOT, env={**self.env, **env}, text=True, capture_output=True)

    def test_kind_gate_direct_environment_and_make(self):
        cases = [(['up', '--hub', 'name:hub', '--platform', 'kind', '--pull-secret-file', '/missing', '--aap-license-file', '/missing'], False, {}),
                 (['plan', '--hub', 'name:hub'], False, {'OSAC_DEV_PLATFORM': 'kind'}),
                 (['HUB=name:hub', 'OSAC_DEV_PLATFORM=kind', 'REMOTE_HOST=root@host', 'AAP_LICENSE_FILE=/missing'], True, {})]
        for args, make, env in cases:
            with self.subTest(args=args):
                result = self.run_command(args, make, **env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("platform 'kind' is not implemented", result.stderr)
                self.assertFalse(self.log.exists())

    def test_kubeconfig_inspection_and_wrapper_spaces(self):
        for make in (False, True):
            args = [f'HUB=kubeconfig:{self.config}', 'OSAC_DEV_COMMAND=plan'] if make else ['plan', '--hub', f'kubeconfig:{self.config}']
            result = self.run_command(args, make)
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary['hub'], summary['bm_cnv'])
            self.assertEqual(summary['flavor'], 'not applicable')
            self.assertNotIn('sentinel', self.log.read_text())

    def test_make_license_and_host_translation_without_unused_reads(self):
        result = self.run_command([f'HUB=kubeconfig:{self.config}', 'OSAC_DEV_COMMAND=plan', 'REMOTE_HOST=root@hypervisor', 'AAP_LICENSE_FILE=/license with spaces.zip'], True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['inputs']['license_source'], 'remote')
        self.assertNotIn('sentinel', self.log.read_text())

    def test_hub_required_unknown_platform_help_and_unimplemented_stage(self):
        for args in (['plan'], ['plan', '--hub', 'name:hub', '--platform', 'nonsense']):
            self.assertEqual(self.run_command(args).returncode, 2)
        result = self.run_command(['up', '--help'])
        self.assertEqual(result.returncode, 0)
        self.assertIn('kind', result.stdout)
        result = self.run_command(['up', '--hub', 'name:hub'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not implemented', result.stderr)
        self.assertFalse(self.log.exists())
