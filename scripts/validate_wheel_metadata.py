"""Print a wheel's validated distribution name and version."""

import sys
from email.parser import Parser
from pathlib import Path
from zipfile import ZipFile

from packaging.utils import canonicalize_name
from packaging.version import InvalidVersion, Version


def main() -> int:
    if len(sys.argv) != 3:
        raise RuntimeError("Usage: validate_wheel_metadata.py WHEEL_PATH EXPECTED_DISTRIBUTION")
    wheel_path = Path(sys.argv[1]).resolve()
    expected_name = sys.argv[2]
    if not wheel_path.is_file():
        raise RuntimeError(f"Wheel does not exist or is not a file: {wheel_path}")
    if wheel_path.suffix != ".whl":
        raise RuntimeError(f"Not a wheel file: {wheel_path}")
    with ZipFile(wheel_path) as wheel:
        metadata_files = [name for name in wheel.namelist() if name.endswith(".dist-info/METADATA")]
        if len(metadata_files) != 1:
            raise RuntimeError(f"Expected one wheel METADATA file, found: {metadata_files}")
        metadata = Parser().parsestr(wheel.read(metadata_files[0]).decode("utf-8"))

    names = metadata.get_all("Name", [])
    versions = metadata.get_all("Version", [])
    if len(names) != 1 or len(versions) != 1:
        raise RuntimeError(
            f"Wheel metadata must contain exactly one Name and Version: "
            f"names={names}, versions={versions}, wheel={wheel_path}"
        )
    actual_name = names[0]
    version = versions[0]
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
