"""Validate build and FA4 verification configuration before compilation starts."""

import math
import os

from packaging.version import InvalidVersion, Version


def positive_integer(name: str) -> int:
    try:
        value = int(os.environ[name])
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def finite_non_negative_float(name: str) -> float:
    try:
        value = float(os.environ[name])
    except ValueError as error:
        raise ValueError(f"{name} must be a number") from error
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{name} must be a finite non-negative number")
    return value


def main() -> int:
    try:
        Version(f"{os.environ['VISION_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
        Version(f"{os.environ['AUDIO_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
    except InvalidVersion as error:
        raise ValueError(f"Invalid PEP 440 build version: {error}") from error

    for name in ("VERIFY_FA4_RTOL", "VERIFY_FA4_ATOL"):
        finite_non_negative_float(name)

    dtype_names = os.environ["VERIFY_FA4_DTYPES"].split()
    allowed_dtypes = {"float16", "bfloat16"}
    if not dtype_names or not set(dtype_names).issubset(allowed_dtypes):
        raise ValueError(f"VERIFY_FA4_DTYPES must contain only {sorted(allowed_dtypes)}")
    if len(dtype_names) != len(set(dtype_names)):
        raise ValueError("VERIFY_FA4_DTYPES must not repeat a dtype")

    dimensions = {
        name: positive_integer(name)
        for name in (
            "VERIFY_FA4_BATCH_SIZE",
            "VERIFY_FA4_SEQUENCE_LENGTH",
            "VERIFY_FA4_HEADS",
            "VERIFY_FA4_HEAD_DIM",
            "VERIFY_FA4_MAX_TENSOR_ELEMENTS",
        )
    }
    try:
        allowed_head_dims = {
            positive_integer_value(value, "VERIFY_FA4_ALLOWED_HEAD_DIMS")
            for value in os.environ["VERIFY_FA4_ALLOWED_HEAD_DIMS"].split()
        }
    except ValueError as error:
        raise ValueError("VERIFY_FA4_ALLOWED_HEAD_DIMS must contain positive integers") from error
    if not allowed_head_dims or dimensions["VERIFY_FA4_HEAD_DIM"] not in allowed_head_dims:
        raise ValueError(
            f"VERIFY_FA4_HEAD_DIM={dimensions['VERIFY_FA4_HEAD_DIM']} is not allowed: "
            f"{sorted(allowed_head_dims)}"
        )

    elements = (
        dimensions["VERIFY_FA4_BATCH_SIZE"]
        * dimensions["VERIFY_FA4_SEQUENCE_LENGTH"]
        * dimensions["VERIFY_FA4_HEADS"]
        * dimensions["VERIFY_FA4_HEAD_DIM"]
    )
    max_elements = dimensions["VERIFY_FA4_MAX_TENSOR_ELEMENTS"]
    if elements > max_elements:
        raise ValueError(
            f"FA4 verification tensor has {elements} elements, exceeding "
            f"VERIFY_FA4_MAX_TENSOR_ELEMENTS={max_elements}"
        )
    return 0


def positive_integer_value(value: str, name: str) -> int:
    try:
        integer = int(value)
    except ValueError as error:
        raise ValueError(f"{name} must contain integers") from error
    if integer <= 0:
        raise ValueError(f"{name} must contain positive integers")
    return integer


if __name__ == "__main__":
    raise SystemExit(main())
