"""Platform gate must precede every backend and credential reader."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Platform:
    name: str
    installer_profile: str
    required_apis: tuple[str, ...]


def select_platform(name):
    if name == 'kind':
        raise ValueError("platform 'kind' is not implemented; use '--platform ocp'")
    if name != 'ocp':
        raise ValueError('unknown platform')
    return Platform('ocp', 'openshift', ('config.openshift.io', 'route.openshift.io', 'security.openshift.io'))
