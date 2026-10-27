"""Explicit kubeconfig, selected context and namespace on every API call."""

import json
from urllib.parse import urlsplit


class Kubernetes:
    def __init__(self, runner):
        self.runner = runner

    def binding(self, path, context=None):
        if not path.is_file():
            raise ValueError('kubeconfig must be an existing readable local file')
        data = json.loads(self.runner.run(['oc', '--kubeconfig', path, 'config', 'view', '-o', 'json']))
        context = context or data.get('current-context')
        selected = [c['context'] for c in data.get('contexts', []) if c['name'] == context]
        if len(selected) != 1:
            raise ValueError('selected kubeconfig context does not exist or is ambiguous')
        clusters = [c['cluster'] for c in data.get('clusters', []) if c['name'] == selected[0]['cluster']]
        if len(clusters) != 1:
            raise ValueError('selected context has no unique cluster')
        endpoint = clusters[0]['server']
        url = urlsplit(endpoint)
        if url.scheme != 'https' or not url.hostname or url.username or url.password:
            raise ValueError('selected cluster requires a credential-free HTTPS API endpoint')
        return context, endpoint.rstrip('/')

    def args(self, target):
        if not target.kubeconfig or not target.context:
            raise ValueError('target access is unresolved')
        return ['oc', '--kubeconfig', str(target.kubeconfig), '--context', target.context]

    def get(self, target, resource, *, namespace=None):
        args = self.args(target) + ['get', resource]
        if namespace:
            args += ['--namespace', namespace]
        return json.loads(self.runner.run(args + ['-o', 'json']))

    def identity(self, target):
        namespace = self.get(target, 'namespace/kube-system')
        uid = namespace.get('metadata', {}).get('uid')
        if not isinstance(uid, str) or not uid:
            raise ValueError('API identity inspection returned no kube-system UID')
        return uid

    def verify_platform(self, target, platform):
        groups = json.loads(self.runner.run(self.args(target) + ['get', '--raw', '/apis']))
        present = {g['name'] for g in groups.get('groups', [])}
        missing = set(platform.required_apis) - present
        if missing:
            raise ValueError('target lacks required OCP APIs: ' + ', '.join(sorted(missing)))
