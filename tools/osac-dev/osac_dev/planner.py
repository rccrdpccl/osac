"""Dependency order is validated completely before executing any work."""

from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class Step:
    name: str
    requires: tuple[str, ...]
    run: Callable


def ordered(steps):
    steps = list(steps)
    by_name = {step.name: step for step in steps}
    if len(by_name) != len(steps):
        raise ValueError('duplicate plan step')
    if any(dependency not in by_name for step in steps for dependency in step.requires):
        raise ValueError('unknown plan dependency')
    result = []
    visited = set()
    active = set()

    def visit(name):
        if name in active:
            raise ValueError('dependency cycle')
        if name in visited:
            return
        active.add(name)
        for dependency in by_name[name].requires:
            visit(dependency)
        active.remove(name)
        visited.add(name)
        result.append(by_name[name])

    for name in by_name:
        visit(name)
    return result


def execute(steps):
    results = {}
    for step in ordered(steps):
        result = step.run()
        if getattr(result, 'action', None) == 'blocked':
            raise RuntimeError(f'prerequisite blocked: {step.name}')
        results[step.name] = result
    return results
