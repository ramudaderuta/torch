"""Print a wheel's validated distribution name and version."""

import sys
from email.parser import Parser
from zipfile import ZipFile

from packaging.utils import canonicalize_name
from packaging.version import InvalidVersion, Version


def main() -> int:
    if len(sys.argv) != 3:
        raise RuntimeError("Usage: validate_wheel_metadata.py WHEEL_PATH EXPECTED_DISTRIBUTION")
    wheel_path, expected_name = sys.argv[1:]
    with ZipFile(wheel_path) as wheel:
        metadata_files = [name for name in wheel.namelist() if name.endswith(".dist-info/METADATA")]
        if len(metadata_files) != 1:
            raise RuntimeError(f"Expected one wheel METADATA file, found: {metadata_files}")
        metadata = Parser().parsestr(wheel.read(metadata_files[0]).decode("utf-8"))

    actual_name = metadata.get("Name")
    version = metadata.get("Version")
    if not actual_name or not version:
        raise RuntimeError(f"Wheel metadata missing Name or Version: {wheel_path}")
    if canonicalize_name(actual_name) != canonicalize_name(expected_name):
        raise RuntimeError(f"Wheel distribution mismatch: expected {expected_name}, got {actual_name}")
    try:
        Version(version)
    except InvalidVersion as error:
        raise RuntimeError(f"Wheel metadata has an invalid PEP 440 version: {version}") from error
    print(f"{actual_name}\t{version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
