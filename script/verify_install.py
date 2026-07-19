"""Run final runtime verification for the complete local CUDA build."""

import os
import sys
from importlib import metadata
from pathlib import Path

import flash_attn.cute as flash_attn_cute
import torch
import torchaudio
import torchvision
import triton
from flash_attn.cute import flash_attn_func


def report_package(label: str, module: object, distribution_name: str) -> None:
    distribution = metadata.distribution(distribution_name)
    module_path = Path(module.__file__).resolve()
    environment_root = Path(sys.prefix).resolve()
    distribution_root = Path(distribution.locate_file("")).resolve()
    assert module_path.is_relative_to(environment_root), (
        f"{label} imported outside the configured venv: {module_path} "
        f"(venv: {environment_root})"
    )
    assert distribution_root.is_relative_to(environment_root), (
        f"{label} distribution is outside the configured venv: {distribution_root} "
        f"(venv: {environment_root})"
    )
    module_version = getattr(module, "__version__", None)
    if module_version is not None:
        assert module_version == distribution.version, (
            f"{label} module/distribution version mismatch: "
            f"{module_version} != {distribution.version}"
        )
    print(
        f"{label}: version={distribution.version} distribution="
        f"{distribution.metadata['Name']} module={module_path} "
        f"distribution_root={distribution_root}"
    )


print("Python:", sys.version)
report_package("Triton", triton, "pytorch-triton")
report_package("PyTorch", torch, "torch")
report_package("Torchvision", torchvision, "torchvision")
report_package("Torchaudio", torchaudio, "torchaudio")
report_package("Flash Attention 4", flash_attn_cute, "flash-attn-4")
print("PyTorch CUDA:", torch.version.cuda)
assert torch.cuda.is_available(), "CUDA not enabled"
assert torch.backends.cudnn.is_available(), "cuDNN extension not compiled"
print("Torchvision extension marker:", getattr(torchvision, "_HAS_OPS", "unavailable"))
major, minor = torch.cuda.get_device_capability()
expected_arch = f"sm_{major}{minor}"
compiled_arches = torch.cuda.get_arch_list()
assert expected_arch in compiled_arches, (
    f"Current GPU requires native {expected_arch}, but PyTorch contains: {compiled_arches}"
)
x = torch.randn(10, 10, device="cuda")
matmul = x @ x
assert torch.isfinite(matmul).all(), "CUDA matmul produced non-finite output"
print("CUDA matrix multiplication norm:", matmul.norm().item())
boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11]], device="cuda", dtype=torch.float32)
nms_result = torchvision.ops.nms(boxes, torch.tensor([0.9, 0.8], device="cuda"), 0.5)
assert nms_result.tolist() == [0], f"Unexpected Torchvision CUDA NMS result: {nms_result.tolist()}"
print("Torchvision CUDA NMS:", nms_result.tolist())

dtype_map = {"float16": torch.float16, "bfloat16": torch.bfloat16}
for dtype_name in os.environ["VERIFY_FA4_DTYPES"].split():
    dtype = dtype_map[dtype_name]
    for causal in (False, True):
        q = torch.randn(
            int(os.environ["VERIFY_FA4_BATCH_SIZE"]),
            int(os.environ["VERIFY_FA4_SEQUENCE_LENGTH"]),
            int(os.environ["VERIFY_FA4_HEADS"]),
            int(os.environ["VERIFY_FA4_HEAD_DIM"]),
            device="cuda",
            dtype=dtype,
            requires_grad=True,
        )
        k = torch.randn_like(q, requires_grad=True)
        v = torch.randn_like(q, requires_grad=True)
        output = flash_attn_func(q, k, v, causal=causal)
        assert torch.isfinite(output).all(), f"FA4 produced non-finite {dtype} output"
        reference = torch.nn.functional.scaled_dot_product_attention(
            q.detach().transpose(1, 2),
            k.detach().transpose(1, 2),
            v.detach().transpose(1, 2),
            is_causal=causal,
        ).transpose(1, 2)
        torch.testing.assert_close(
            output.detach(),
            reference,
            rtol=float(os.environ["VERIFY_FA4_RTOL"]),
            atol=float(os.environ["VERIFY_FA4_ATOL"]),
        )
        output.float().sum().backward()
        for tensor_name, tensor in (("q", q), ("k", k), ("v", v)):
            assert tensor.grad is not None, f"FA4 {tensor_name} gradient missing for {dtype}, causal={causal}"
            assert torch.isfinite(tensor.grad).all(), f"FA4 {tensor_name} gradient is non-finite for {dtype}, causal={causal}"
        print("Flash Attention 4:", f"dtype={dtype} causal={causal} shape={tuple(output.shape)} backward=ok")

print("All components verified successfully")
