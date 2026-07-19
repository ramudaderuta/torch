"""Validate build and FA4 verification configuration before compilation starts."""

import math
import os

from packaging.version import Version


def positive_float(name: str) -> None:
    value = float(os.environ[name])
    assert math.isfinite(value) and value >= 0, f"{name} must be a finite non-negative number"


Version(f"{os.environ['VISION_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
Version(f"{os.environ['AUDIO_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
for name in ("VERIFY_FA4_RTOL", "VERIFY_FA4_ATOL"):
    positive_float(name)

dtype_names = os.environ["VERIFY_FA4_DTYPES"].split()
allowed_dtypes = {"float16", "bfloat16"}
assert dtype_names and set(dtype_names).issubset(allowed_dtypes), (
    f"VERIFY_FA4_DTYPES must contain only {sorted(allowed_dtypes)}"
)
assert len(dtype_names) == len(set(dtype_names)), "VERIFY_FA4_DTYPES must not repeat a dtype"

head_dim = int(os.environ["VERIFY_FA4_HEAD_DIM"])
allowed_head_dims = {int(value) for value in os.environ["VERIFY_FA4_ALLOWED_HEAD_DIMS"].split()}
assert allowed_head_dims and head_dim in allowed_head_dims, (
    f"VERIFY_FA4_HEAD_DIM={head_dim} is not allowed: {sorted(allowed_head_dims)}"
)
elements = (
    int(os.environ["VERIFY_FA4_BATCH_SIZE"])
    * int(os.environ["VERIFY_FA4_SEQUENCE_LENGTH"])
    * int(os.environ["VERIFY_FA4_HEADS"])
    * head_dim
)
assert elements <= int(os.environ["VERIFY_FA4_MAX_TENSOR_ELEMENTS"]), (
    f"FA4 verification tensor has {elements} elements, exceeding "
    f"VERIFY_FA4_MAX_TENSOR_ELEMENTS={os.environ['VERIFY_FA4_MAX_TENSOR_ELEMENTS']}"
)
