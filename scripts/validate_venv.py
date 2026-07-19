"""Fail unless the configured interpreter belongs to an isolated virtual environment."""

import os
import sys
from pathlib import Path


BLOCKED_ENVIRONMENT_VARIABLES = (
    "PYTHONHOME",
    "PYTHONPATH",
    "PIP_PREFIX",
    "PIP_TARGET",
    "PIP_USER",
    "PIP_CONFIG_FILE",
    "UV_SYSTEM_PYTHON",
)


def main() -> int:
    if sys.prefix == sys.base_prefix:
        raise RuntimeError("Configured Python is not an isolated virtual environment")
    expected_prefix = Path(os.environ["VENV_DIR"]).resolve()
    actual_prefix = Path(sys.prefix).resolve()
    if actual_prefix != expected_prefix:
        raise RuntimeError(f"Configured Python venv mismatch: expected {expected_prefix}, got {actual_prefix}")
    configured_overrides = [name for name in BLOCKED_ENVIRONMENT_VARIABLES if os.environ.get(name)]
    if configured_overrides:
        raise RuntimeError(
            "Python environment overrides are not allowed for an isolated build: "
            + ", ".join(configured_overrides)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
