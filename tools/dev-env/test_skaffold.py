"""Render the dev release through Skaffold and the real Helm values schema."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEV_IMAGES = (
    'osac-operator',
    'fulfillment-service',
    'bare-metal-fulfillment-operator',
    'metering-service',
    'metering-echo-adapter',
    'osac-ui',
    'osac-aap',
)


@unittest.skipUnless(shutil.which('skaffold') and shutil.which('helm'), 'requires Skaffold and Helm')
class SkaffoldRenderTest(unittest.TestCase):
    def test_dev_release_accepts_the_actual_skaffold_overrides(self) -> None:
        deps = subprocess.run(
            ['helm', 'dependency', 'list', 'osac-installer/charts/osac'],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        if not all(line.split()[-1] == 'ok' for line in deps.stdout.splitlines()[1:] if line.strip()):
            self.skipTest('run make -C osac-installer helm-deps first')

        env = dict(
            os.environ,
            OSAC_NAMESPACE='osac',
            OSAC_CLUSTER_DOMAIN='apps.example.test',
            OSAC_DEV_AAP_PROJECT_GIT_BRANCH='',
            OSAC_DEV_AAP_PROJECT_ARCHIVE_URI='http://osac-dev-aap-project.osac.svc:8080/osac-aap.tar.gz',
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            artifacts = Path(temp_dir) / 'builds.json'
            artifacts.write_text(json.dumps({'builds': [
                {'imageName': image, 'tag': f'registry.example.test/osac/{image}:smoke'}
                for image in DEV_IMAGES
            ]}))
            result = subprocess.run(
                ['skaffold', 'render', '--offline', '--digest-source=tag',
                 '--build-artifacts', str(artifacts), '--output', os.devnull],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=60,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
