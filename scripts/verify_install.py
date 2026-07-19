"""Run final runtime verification for the complete local CUDA build."""

import os
import sys
from importlib import metadata
from pathlib import Path
from types import ModuleType

from packaging.version import Version


def require_within(label: str, path: Path, root: Path) -> None:
    try:
        path.relative_to(root)
    except ValueError as error:
        raise RuntimeError(f"{label} is outside {root}: {path}") from error


def report_package(
    label: str,
    module: ModuleType,
    distribution_name: str,
    source_roots: list[Path],
    *,
    compare_module_version: bool = True,
) -> None:
    distribution = metadata.distribution(distribution_name)
    module_file = getattr(module, "__file__", None)
    if module_file is None:
        raise RuntimeError(f"{label} does not have a module file")
    module_path = Path(module_file).resolve()
    environment_root = Path(sys.prefix).resolve()
    distribution_root = Path(distribution.locate_file("")).resolve()
    require_within(f"{label} module", module_path, environment_root)
    require_within(f"{label} distribution", distribution_root, environment_root)
    for source_root in source_roots:
        try:
            module_path.relative_to(source_root)
        except ValueError:
            continue
        raise RuntimeError(f"{label} imported from source checkout: {module_path}")
    module_version = getattr(module, "__version__", None)
    if compare_module_version and module_version is not None and Version(module_version).public != Version(distribution.version).public:
        raise RuntimeError(
            f"{label} module/distribution version mismatch: "
            f"{module_version} != {distribution.version}"
        )
    print(
        f"{label}: version={distribution.version} distribution="
        f"{distribution.metadata['Name']} module={module_path} "
        f"distribution_root={distribution_root}"
    )

def verify_fa4(torch: ModuleType, flash_attn_func: object) -> None:
    torch.manual_seed(0)
    torch.cuda.manual_seed_all(0)
    dtype_map = {"float16": torch.float16, "bfloat16": torch.bfloat16}
    batch_size = int(os.environ["VERIFY_FA4_BATCH_SIZE"])
    sequence_length = int(os.environ["VERIFY_FA4_SEQUENCE_LENGTH"])
    heads = int(os.environ["VERIFY_FA4_HEADS"])
    head_dim = int(os.environ["VERIFY_FA4_HEAD_DIM"])
    rtol = float(os.environ["VERIFY_FA4_RTOL"])
    atol = float(os.environ["VERIFY_FA4_ATOL"])

    for dtype_name in os.environ["VERIFY_FA4_DTYPES"].split():
        dtype = dtype_map[dtype_name]
        for causal in (False, True):
            q = torch.randn(batch_size, sequence_length, heads, head_dim, device="cuda", dtype=dtype, requires_grad=True)
            k = torch.randn_like(q, requires_grad=True)
            v = torch.randn_like(q, requires_grad=True)
            result = flash_attn_func(q, k, v, causal=causal)
            if not isinstance(result, tuple) or not result or not isinstance(result[0], torch.Tensor):
                raise RuntimeError(f"FA4 returned an unexpected result: {type(result)!r}")
            output = result[0]
            shape = tuple(output.shape)
            if not torch.isfinite(output).all():
                raise RuntimeError(f"FA4 produced non-finite output: dtype={dtype} causal={causal} shape={shape}")
            reference = torch.nn.functional.scaled_dot_product_attention(
                q.detach().transpose(1, 2),
                k.detach().transpose(1, 2),
                v.detach().transpose(1, 2),
                is_causal=causal,
            ).transpose(1, 2)
            difference = (output.detach().float() - reference.float()).abs()
            max_abs_error = difference.max().item()
            max_relative_error = (difference / reference.float().abs().clamp_min(torch.finfo(torch.float32).eps)).max().item()
            try:
                torch.testing.assert_close(output.detach(), reference, rtol=rtol, atol=atol)
            except AssertionError as error:
                raise RuntimeError(
                    "FA4 reference mismatch: "
                    f"dtype={dtype} causal={causal} shape={shape} "
                    f"max_abs_error={max_abs_error} max_relative_error={max_relative_error}"
                ) from error
            output.float().sum().backward()
            for tensor_name, tensor in (("q", q), ("k", k), ("v", v)):
                if tensor.grad is None:
                    raise RuntimeError(f"FA4 {tensor_name} gradient is missing: dtype={dtype} causal={causal}")
                if tensor.grad.shape != tensor.shape:
                    raise RuntimeError(
                        f"FA4 {tensor_name} gradient shape mismatch: "
                        f"expected={tuple(tensor.shape)} actual={tuple(tensor.grad.shape)}"
                    )
                if not torch.isfinite(tensor.grad).all():
                    raise RuntimeError(f"FA4 {tensor_name} gradient is non-finite: dtype={dtype} causal={causal}")
            print(
                "Flash Attention 4:",
                f"dtype={dtype} causal={causal} shape={shape} backward=ok "
                f"max_abs_error={max_abs_error} max_relative_error={max_relative_error}",
            )


def main() -> int:
    import flash_attn.cute as flash_attn_cute
    import torch
    import torchaudio
    import torchvision
    import triton
    from flash_attn.cute import flash_attn_func

    root_dir = Path(__file__).resolve().parent.parent
    source_roots = [root_dir / name for name in ("pytorch", "triton", "vision", "audio", "flash-attention")]
    print("Python:", sys.version)
    report_package("Triton", triton, os.environ["TRITON_DISTRIBUTION_NAME"], source_roots)
    report_package("PyTorch", torch, "torch", source_roots)
    report_package("Torchvision", torchvision, "torchvision", source_roots)
    report_package("Torchaudio", torchaudio, "torchaudio", source_roots)
    report_package(
        "Flash Attention 4",
        flash_attn_cute,
        os.environ["FA4_DISTRIBUTION_NAME"],
        source_roots,
        compare_module_version=False,
    )
    print("PyTorch CUDA:", torch.version.cuda)
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA not enabled")
    if not torch.backends.cudnn.is_available():
        raise RuntimeError("cuDNN extension not compiled")
    print("Torchvision extension marker:", getattr(torchvision, "_HAS_OPS", "unavailable"))
    major, minor = torch.cuda.get_device_capability()
    expected_arch = f"sm_{major}{minor}"
    compiled_arches = torch.cuda.get_arch_list()
    if expected_arch not in compiled_arches:
        raise RuntimeError(f"Current GPU requires native {expected_arch}, but PyTorch contains: {compiled_arches}")
    x = torch.randn(10, 10, device="cuda")
    matmul = x @ x
    if not torch.isfinite(matmul).all():
        raise RuntimeError("CUDA matmul produced non-finite output")
    print("CUDA matrix multiplication norm:", matmul.norm().item())
    boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11]], device="cuda", dtype=torch.float32)
    nms_result = torchvision.ops.nms(boxes, torch.tensor([0.9, 0.8], device="cuda"), 0.5)
    if nms_result.tolist() != [0]:
        raise RuntimeError(f"Unexpected Torchvision CUDA NMS result: {nms_result.tolist()}")
    print("Torchvision CUDA NMS:", nms_result.tolist())
    verify_fa4(torch, flash_attn_func)
    print("All components verified successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
