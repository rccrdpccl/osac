"""Resolve both roles before allowing creation. Missing access is not absence."""

from pathlib import Path

from .inputs import require_creation_input
from .model import Context, Target


def group_targets(targets):
    groups = []
    for target in targets:
        for existing in groups:
            if existing.binding == target.binding:
                break
            if existing.endpoint and existing.endpoint == target.endpoint:
                # Different native clone identities can expose copied identifiers.
                if (existing.reference.kind == 'name' or target.reference.kind == 'name'
                        or not existing.cluster_uid or existing.cluster_uid != target.cluster_uid):
                    raise ValueError('unresolved target identity collision; refusing to merge')
                break
        else:
            groups.append(target)
    return groups


class Resolver:
    def __init__(self, kubernetes, cluster_tool):
        self.kubernetes = kubernetes
        self.cluster_tool = cluster_tool

    def resolve(self, hub, bm_cnv=None, *, hub_context=None, bm_context=None,
                hub_server=None, bm_server=None, flavor_constraint=None):
        roles = [(hub, hub_context, hub_server)]
        if bm_cnv:
            roles.append((bm_cnv, bm_context, bm_server))
        if (bm_cnv and hub.kind == bm_cnv.kind == 'name' and hub.value == bm_cnv.value
                and hub_server != bm_server):
            raise ValueError('same clone name on two servers has ambiguous workstation kubeconfig access; use distinct names or explicit kubeconfigs')
        # Prevalidate all local paths before discovering any named clone.
        for ref, context, server in roles:
            if ref.kind == 'kubeconfig' and not Path(ref.value).is_file():
                raise ValueError('kubeconfig must be an existing readable local file')
            if ref.kind == 'name' and not server:
                raise ValueError('named target requires an explicit --hub-server or --bm-cnv-server; no ambient default')
        cache = {}
        resolved = []
        for ref, context, server in roles:
            key = (ref, context, server if ref.kind == 'name' else None)
            if key not in cache:
                path = Path(ref.value) if ref.kind == 'kubeconfig' else None
                if ref.kind == 'name':
                    observed_flavor = self.cluster_tool.inspect(ref.value, server)
                    if observed_flavor is None:
                        cache[key] = Target(ref, None, context, None, server, missing=True)
                        resolved.append(cache[key])
                        continue
                    if flavor_constraint and flavor_constraint != observed_flavor:
                        raise ValueError('existing clone flavor conflicts with requested flavor; no replacement allowed')
                    path = self.cluster_tool.access_path(ref.value)
                selected, endpoint = self.kubernetes.binding(path, context)
                cache[key] = Target(ref, path, selected, endpoint, server if ref.kind == 'name' else None)
                cache[key].cluster_uid = self.kubernetes.identity(cache[key])
            resolved.append(cache[key])
        group_targets(resolved)
        return Context(resolved[0], resolved[-1])

    def create_missing(self, context, *, command, flavor, pull_secret, platform):
        targets = group_targets([context.hub, context.bm_cnv])
        missing = [t for t in targets if t.missing]
        if missing and command not in ('up', 'infra'):
            raise ValueError('this stage requires existing targets; creation is permitted only for up/infra')
        if missing:
            require_creation_input(pull_secret)
        # Verify all supplied targets before expensive creation, never resize them.
        for target in targets:
            if not target.missing:
                self.kubernetes.verify_platform(target, platform)
        for target in missing:
            self.cluster_tool.connection(target.server)
            self.cluster_tool.create(target.reference.value, target.server, flavor, Path(pull_secret).expanduser().resolve())
            target.kubeconfig = self.cluster_tool.access_path(target.reference.value)
            target.context, target.endpoint = self.kubernetes.binding(target.kubeconfig, target.context)
            target.cluster_uid = self.kubernetes.identity(target)
            self.kubernetes.verify_platform(target, platform)
            target.missing = False
        group_targets(targets)
        return context
