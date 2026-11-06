"""The one switch that tells a suite to leave what it created for inspection.

A suite deletes what it creates, because a run that leaves resources behind
breaks the next one on the same environment. When a person is debugging a live
environment, that cleanup destroys the evidence, so every suite that offers the
escape hatch reads it from here instead of spelling the variable out again.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

# Local debugging only: no CI job sets it. A run that sets it deletes nothing and
# names what stays, so the next run on the same environment starts dirty.
KEEP_RESOURCES_ENV = "OSAC_E2E_KEEP_RESOURCES"


def keep_resources() -> bool:
    """True when a person debugging a live environment wants the resources kept."""
    return os.environ.get(KEEP_RESOURCES_ENV, "").strip().lower() == "true"


def note_kept_resources(what: str, *, remove_with: str) -> None:
    """Name what stays and how to remove it: a kept run must not look like a clean one."""
    logger.warning("%s is true: %s stays. Remove it with: %s", KEEP_RESOURCES_ENV, what, remove_with)
