#!/usr/bin/env python3
"""Apply install-osac's resolved Helm configuration with branch-built images.

Run from the installer directory with the same release, chart and arguments
as `helm upgrade --install`. Only the values-file and namespace options are
lifted into Skaffold fields; all other Helm arguments remain opaque and ordered.
"""

import argparse
import contextlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from types import FrameType
from typing import Any

import yaml

REPO = Path(__file__).resolve().parents[2]
CONFIG = REPO / "skaffold.yaml"


def check_environment() -> tuple[str, str]:
    mode = os.environ.get("SKAFFOLD_MODE", "run")
    if mode not in ("run", "dev"):
        raise ValueError("SKAFFOLD_MODE must be run or dev")
    registry = os.environ.get("OSAC_DEV_REGISTRY", "").strip()
    if not registry:
        raise ValueError("OSAC_DEV_REGISTRY is required for DEV_MODE=1")
    for command in ("skaffold", "docker"):
        if not shutil.which(command):
            raise ValueError(f"required command '{command}' not found; run 'make osac-dev-setup'")
    if not CONFIG.is_file():
        raise ValueError(f"missing Skaffold build configuration: {CONFIG}")
    return mode, registry


def deployment_config(arguments: list[str]) -> dict[str, Any]:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("release")
    parser.add_argument("chart")
    parser.add_argument("--namespace", "-n", required=True)
    parser.add_argument("--values", "-f", action="append", default=[])
    options, helm_args = parser.parse_known_args(arguments)
    config = yaml.safe_load(CONFIG.read_text())
    for artifact in config["build"]["artifacts"]:
        # The generated config lives in a private temporary directory, not at
        # the repository root like the checked-in build/image mapping.
        artifact["context"] = str((REPO / artifact.get("context", ".")).absolute())
    helm = config["deploy"]["helm"]
    image_values = helm["releases"][0]["setValueTemplates"]
    helm["releases"] = [
        {
            "name": options.release,
            "chartPath": str(Path(options.chart).absolute()),
            "namespace": options.namespace,
            "valuesFiles": [
                value if "://" in value else str(Path(value).expanduser().absolute()) for value in options.values
            ],
            # Refresh local file:// dependencies on watch redeploys, not just
            # during the installer's initial dependency preparation.
            "skipBuildDependencies": False,
            "setValueTemplates": image_values,
        }
    ]
    helm["flags"] = {"install": helm_args, "upgrade": helm_args}
    return config


def run_skaffold(arguments: list[str]) -> int:
    child: subprocess.Popen | None = None
    pending: list[int] = []

    def forward(signum: int, _frame: FrameType | None) -> None:
        if child is None:
            pending.append(signum)
            return
        # The child may finish just before the signal arrives.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signum)

    previous = {signum: signal.signal(signum, forward) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        # Isolate the child from terminal signals so a foreground-group Ctrl-C
        # is forwarded exactly once. Handle signals before spawning as well.
        child = subprocess.Popen(arguments, start_new_session=True)
        for signum in pending:
            forward(signum, None)
        # subprocess.call (and Popen's context manager) kills the child when
        # KeyboardInterrupt unwinds it. Keep waiting instead: Skaffold/Helm
        # must finish cleanup while the temporary config still exists.
        status = child.wait()
        return status if status >= 0 else 128 - status
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main() -> int:
    try:
        mode, registry = check_environment()
        if sys.argv[1:] == ["--check"]:
            return 0
        config = deployment_config(sys.argv[1:])
        # Keep the caller's working directory: opaque Helm options such as
        # --set-file retain their original relative-path semantics. JSON is
        # accepted by Skaffold, so generated values need no YAML interpolation.
        with tempfile.TemporaryDirectory(prefix="osac-skaffold-") as directory:
            path = Path(directory) / "skaffold.json"
            path.touch(mode=0o600, exist_ok=False)
            path.write_text(json.dumps(config))
            return run_skaffold(["skaffold", mode, "-f", str(path), "--default-repo", registry])
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
