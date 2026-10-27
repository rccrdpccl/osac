"""Deterministic identity of selected public chart inputs, never runtime Secrets.

Callers must supply only non-secret values/dependency identities. Secret inputs
are reconciled separately and are excluded, not replaced with content hashes.
The key guard is defense in depth, not a general secret detector.
"""

import hashlib
import json
import re
from pathlib import Path

SCHEMA_VERSION = 1
SKIP_PARTS = {'.git', '__pycache__', '.cache', '.pytest_cache', 'node_modules', '.env'}
DOCUMENTATION_FILES = {'README.md', 'LICENSE', 'LICENSE.txt'}
SENSITIVE_KEYS = re.compile(r'(^|[_-])(password|token|secret|license|private[_-]?key|auth|credentials)($|[_-])', re.I)


def validate_public(value):
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r'([a-z])([A-Z])', r'\1_\2', str(key))
            if SENSITIVE_KEYS.search(normalized):
                raise ValueError('sensitive values must be separately reconciled, not fingerprinted')
            validate_public(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            validate_public(item)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def fingerprint(chart, *, platform, values, dependencies, capabilities=()):
    chart = Path(chart)
    if not (chart / 'Chart.yaml').is_file():
        raise ValueError('fingerprint requires a chart source with Chart.yaml')
    for value in (values, dependencies, capabilities):
        validate_public(value)
    sources = []
    for path in sorted(chart.rglob('*')):
        relative = path.relative_to(chart)
        if any(part in SKIP_PARTS for part in relative.parts):
            continue
        # Hash all chart payload paths, including arbitrary .Files.Get inputs.
        # Root documentation is not a rendered input in the supported contract.
        if relative.as_posix() in DOCUMENTATION_FILES:
            continue
        if path.is_symlink():
            raise ValueError('chart source symlinks are unsupported; resolve dependencies explicitly')
        if path.is_file():
            sources.append([relative.as_posix(), hashlib.sha256(path.read_bytes()).hexdigest()])
    identity = {'schema': SCHEMA_VERSION, 'platform': platform, 'sources': sources,
                'values': values, 'dependencies': dependencies, 'capabilities': capabilities}
    return hashlib.sha256(canonical(identity)).hexdigest()


def owned_matches(desired, observed):
    """Compare explicit owned projections; callers omit controller-owned fields.

    Lists are atomic and ordered. A caller needing Kubernetes associative-list
    semantics must project/key those lists explicitly before invoking this.
    """
    if isinstance(desired, dict):
        return isinstance(observed, dict) and all(key in observed and owned_matches(value, observed[key]) for key, value in desired.items())
    if isinstance(desired, list):
        return isinstance(observed, list) and len(desired) == len(observed) and all(owned_matches(a, b) for a, b in zip(desired, observed))
    return type(desired) is type(observed) and desired == observed
