"""Role bindings are independent of platform and host execution."""

import re
from dataclasses import dataclass
from pathlib import Path


def safe_name(value):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}', value):
        raise ValueError('invalid name; use letters, numbers, dot, underscore or hyphen')
    return value


@dataclass(frozen=True)
class Reference:
    kind: str
    value: str

    @classmethod
    def parse(cls, text):
        kind, separator, value = text.partition(':')
        if not separator or not value or kind not in ('name', 'kubeconfig'):
            raise ValueError('target must be name:NAME or kubeconfig:PATH')
        if kind == 'name':
            safe_name(value)
        else:
            value = str(Path(value).expanduser().resolve())
        return cls(kind, value)


@dataclass
class Target:
    reference: Reference
    kubeconfig: Path | None
    context: str | None
    endpoint: str | None
    server: str | None = None
    cluster_uid: str | None = None
    missing: bool = False

    @property
    def binding(self):
        if self.reference.kind == 'name':
            return ('name', self.server, self.reference.value)
        return ('kubeconfig', str(self.kubeconfig), self.context)

    def summary(self):
        return {'reference': f'{self.reference.kind}:{self.reference.value}',
                'context': self.context, 'server': self.server, 'missing': self.missing}


@dataclass
class Context:
    hub: Target
    bm_cnv: Target
