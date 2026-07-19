"""Print a wheel's validated distribution name and version."""

import sys
from email.parser import Parser
from zipfile import ZipFile

from packaging.utils import canonicalize_name


wheel_path, expected_name = sys.argv[1:]
with ZipFile(wheel_path) as wheel:
    metadata_files = [name for name in wheel.namelist() if name.endswith(".dist-info/METADATA")]
    assert len(metadata_files) == 1, f"Expected one wheel METADATA file, found: {metadata_files}"
    metadata = Parser().parsestr(wheel.read(metadata_files[0]).decode("utf-8"))

actual_name = metadata.get("Name")
version = metadata.get("Version")
assert actual_name and version, f"Wheel metadata missing Name or Version: {wheel_path}"
assert canonicalize_name(actual_name) == canonicalize_name(expected_name), (
    f"Wheel distribution mismatch: expected {expected_name}, got {actual_name}"
)
print(f"{actual_name}\t{version}")
