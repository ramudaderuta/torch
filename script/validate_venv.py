"""Fail unless the configured interpreter belongs to an isolated virtual environment."""

import sys


if sys.prefix == sys.base_prefix:
    raise SystemExit("Configured Python is not an isolated virtual environment")
