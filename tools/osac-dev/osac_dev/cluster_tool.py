"""Public CLI adapter for the revision in dependencies.lock.json.

Tables are bounded compatibility parsers, not health signals. No private state
imports, default-server changes, access repair, or destructive retry operations.
"""

import re
from pathlib import Path

from .model import safe_name


class ClusterTool:
    def __init__(self, runner, home=None):
        self.runner = runner
        self.home = Path(home or Path.home())

    def inspect(self, name, server):
        safe_name(name)
        safe_name(server)
        output = self.runner.run(['cluster-tool', 'list', '--server', server])
        if output.strip() == 'No clones running.':
            return None
        lines = output.strip().splitlines()
        if len(lines) < 3 or lines[0].split() != ['NAME', 'FLAVOR', 'SUBNET', 'CREATED'] or set(lines[1]) != {'-'}:
            raise ValueError('unknown cluster-tool list shape; refusing to infer clone absence')
        entries = {}
        for line in lines[2:]:
            columns = line.split()
            if len(columns) != 4 or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d', columns[3]):
                raise ValueError('unknown cluster-tool clone row')
            clone, flavor = columns[:2]
            safe_name(clone)
            safe_name(flavor)
            if clone in entries:
                raise ValueError('duplicate native clone identity')
            entries[clone] = flavor
        return entries.get(name)

    def access_path(self, name):
        path = self.home / '.kube' / f'{safe_name(name)}.kubeconfig'
        if not path.is_file():
            raise ValueError('native access is missing; use the creator workstation with working access or supply a kubeconfig; import/access repair is unsupported')
        return path

    def connection(self, server, host=None):
        safe_name(server)
        output = self.runner.run(['cluster-tool', 'servers'])
        if output.startswith('No servers connected.'):
            raise ValueError('native connection missing; explicitly run cluster-tool connect before apply')
        lines = output.strip().splitlines()
        if len(lines) < 3 or lines[0].split() != ['NAME', 'HOST', 'DEFAULT'] or set(lines[1]) != {'-'}:
            raise ValueError('unknown cluster-tool servers shape')
        entries = {}
        for line in lines[2:]:
            columns = line.split()
            if len(columns) not in (2, 3) or (len(columns) == 3 and columns[2] != '*') or columns[0] in entries:
                raise ValueError('unknown cluster-tool server row')
            entries[columns[0]] = columns[1]
        if server not in entries:
            raise ValueError('native connection missing; explicitly run cluster-tool connect before apply')
        if host and entries[server] != ('local' if host == 'localhost' else host):
            raise ValueError('host binding conflicts with explicit native server endpoint')
        return entries[server]

    def create(self, name, server, flavor, pull_secret):
        for value in (name, server, flavor):
            safe_name(value)
        self.runner.run(['cluster-tool', 'pull', '--server', server,
                         f'quay.io/osac-project/cluster-flavors:{flavor}'], timeout=7200)
        self.runner.run(['cluster-tool', 'boot', '--server', server, '--flavor', flavor,
                         '--name', name, '--pull-secret', str(pull_secret)], timeout=7200)
