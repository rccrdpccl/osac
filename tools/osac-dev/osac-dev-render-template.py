#!/usr/bin/env python3
"""Render a file with explicit KEY=VALUE substitutions, never shell evaluation."""

import argparse
import re
import sys
from pathlib import Path
from string import Template


def render(path: Path, assignments: list[str]) -> str:
    values: dict[str, str] = {}
    for assignment in assignments:
        key, separator, value = assignment.partition("=")
        if not separator or not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", key):
            raise ValueError(f"expected KEY=VALUE, got {assignment!r}")
        if key in values:
            raise ValueError(f"duplicate template value: {key}")
        values[key] = value
    # substitute(), not safe_substitute(): missing values and malformed
    # placeholders must fail before any partial manifest reaches oc apply.
    return Template(path.read_text()).substitute(values)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    parser.add_argument("values", metavar="KEY=VALUE", nargs="*")
    options = parser.parse_args()
    try:
        rendered = render(options.template, options.values)
    except (OSError, ValueError, KeyError) as error:
        print(f"ERROR: could not render {options.template}: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
