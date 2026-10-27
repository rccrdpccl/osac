"""CLI and explicit legacy Make translation; application stages land separately."""

import argparse
import json
import os
import sys
from dataclasses import dataclass

from .cluster_tool import ClusterTool
from .host import HostExecutor
from .kubernetes import Kubernetes
from .model import Reference, safe_name
from .platform import select_platform
from .runner import CommandError, Runner
from .targets import Resolver


@dataclass
class Options:
    command: str
    platform: str
    hub: Reference
    bm_cnv: Reference | None
    hub_context: str | None
    bm_cnv_context: str | None
    hub_server: str | None
    bm_cnv_server: str | None
    hub_host: str | None
    bm_cnv_host: str | None
    pull_secret_file: str | None
    license_file: str | None
    license_source: str | None
    flavor: str
    flavor_constraint: str | None


def parse_options(argv, env=None, *, wrapper=False):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description='OSAC development tool (incremental rewrite)')
    subcommands = parser.add_subparsers(dest='command', required=True)
    for command in ('plan', 'doctor', 'up', 'infra', 'lab', 'deploy', 'test', 'clean'):
        sub = subcommands.add_parser(command, description='Read-only target inspection' if command in ('plan', 'doctor') else 'Reserved stage; not wired until its implementation task')
        sub.add_argument('--hub', required=not (wrapper and env.get('HUB')), default=env.get('HUB') if wrapper else None, help='mandatory name:NAME or kubeconfig:PATH')
        sub.add_argument('--bm-cnv', default=env.get('BM_CNV') if wrapper else None, help='typed target; omitted means the resolved hub')
        for role in ('hub', 'bm-cnv'):
            sub.add_argument(f'--{role}-context', help='context in the selected local kubeconfig')
            sub.add_argument(f'--{role}-server', help='explicit existing native server alias for named targets')
            sub.add_argument(f'--{role}-host', help='explicit lab host binding; does not authorize host operations')
        sub.add_argument('--platform', choices=('ocp', 'kind'), default=env.get('OSAC_DEV_PLATFORM') or 'ocp', help='default ocp; kind is not implemented')
        sub.add_argument('--pull-secret-file', default=env.get('PULL_SECRET_FILE'), help='local JSON; required only for creation/consuming CaaS stages')
        licenses = sub.add_mutually_exclusive_group()
        licenses.add_argument('--aap-license-file', help='local subscription-manifest ZIP for licensed deployment')
        licenses.add_argument('--aap-license-remote-file', help='ZIP on explicit hub host; mutually exclusive with local input')
        sub.add_argument('--cluster-tool-flavor', default=env.get('SNO_FLAVOR'), help='creation flavor (SNO_FLAVOR, then sno-4-22); constrains existing clones only when supplied')
    args = parser.parse_args(argv)
    try:
        select_platform(args.platform)  # Before references, host initialization or any file read.
        hub = Reference.parse(args.hub)
        bm = Reference.parse(args.bm_cnv) if args.bm_cnv else None
        if not bm and (args.bm_cnv_context or args.bm_cnv_server or args.bm_cnv_host):
            raise ValueError('BM-CNV options require --bm-cnv; omission reuses the hub')
        host = args.hub_host
        if wrapper and env.get('REMOTE_HOST'):
            legacy = env['REMOTE_HOST']
            if host and host != legacy:
                raise ValueError('REMOTE_HOST conflicts with --hub-host')
            host = legacy
        # Validate syntax only; neither constructs a connection nor executes it.
        HostExecutor(None, host)
        HostExecutor(None, args.bm_cnv_host)
        for server in (args.hub_server, args.bm_cnv_server):
            if server:
                safe_name(server)
        flavor = safe_name(args.cluster_tool_flavor or 'sno-4-22')
        source, license_file = None, None
        if args.aap_license_file is not None:
            source, license_file = 'local', args.aap_license_file
        elif args.aap_license_remote_file is not None:
            source, license_file = 'remote', args.aap_license_remote_file
        elif env.get('AAP_LICENSE_FILE'):
            source = 'remote' if wrapper and host not in (None, 'localhost', 'local') else 'local'
            license_file = env['AAP_LICENSE_FILE']
        return Options(args.command, args.platform, hub, bm, args.hub_context, args.bm_cnv_context,
                       args.hub_server, args.bm_cnv_server, host, args.bm_cnv_host,
                       args.pull_secret_file, license_file, source, flavor, args.cluster_tool_flavor)
    except ValueError as error:
        parser.error(str(error))


def main(argv=None, *, wrapper=False):
    options = parse_options(sys.argv[1:] if argv is None else argv, wrapper=wrapper)
    if options.command not in ('plan', 'doctor'):
        print(f'{options.command}: application stage is not implemented yet; no backend operation performed', file=sys.stderr)
        return 2
    runner = Runner()
    native = ClusterTool(runner)
    try:
        for ref, server, host in ((options.hub, options.hub_server, options.hub_host),
                                  (options.bm_cnv, options.bm_cnv_server, options.bm_cnv_host)):
            if ref and ref.kind == 'name' and host and server:
                native.connection(server, host)
        context = Resolver(Kubernetes(runner), native).resolve(
            options.hub, options.bm_cnv, hub_context=options.hub_context, bm_context=options.bm_cnv_context,
            hub_server=options.hub_server, bm_server=options.bm_cnv_server, flavor_constraint=options.flavor_constraint)
        named = any(t.reference.kind == 'name' for t in (context.hub, context.bm_cnv))
        blockers = []
        if any(t.missing for t in (context.hub, context.bm_cnv)):
            blockers.append('provisional creation; concrete infrastructure diff requires reinspection and review')
            if not options.pull_secret_file:
                blockers.append('creation requires --pull-secret-file')
        print(json.dumps({'scope': 'target inspection only; infrastructure planning/diagnostics not wired yet',
                          'hub': context.hub.summary(), 'bm_cnv': context.bm_cnv.summary(),
                          'flavor': options.flavor if named else 'not applicable', 'blockers': blockers,
                          'inputs': {'license_source': options.license_source, 'pull_secret_source': 'local' if options.pull_secret_file else None}}, indent=2))
        return 1 if options.command == 'doctor' and blockers else 0
    except (ValueError, KeyError, TypeError, CommandError) as error:
        print(f'osac-dev: {error}', file=sys.stderr)
        return 1


def wrapper_main():
    # Make exports values verbatim, never interpolates paths into a shell program.
    import shlex
    return main([os.environ.get('OSAC_DEV_COMMAND') or 'up', *shlex.split(os.environ.get('ARGS', ''))], wrapper=True)
