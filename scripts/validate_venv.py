"""Fail unless the configured interpreter belongs to an isolated virtual environment."""

import sys


def main() -> int:
    if sys.prefix == sys.base_prefix:
        raise RuntimeError("Configured Python is not an isolated virtual environment")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
