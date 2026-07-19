---
title: 2026-07-19 Full CUDA Build Failures and Remedies
type: debugging
status: current
scope: root-orchestration
related_scopes: []
related_files:
  - build.sh
  - patches/pytorch/cuda-13.1-clang21-compat.patch
  - patches/triton/ignore-generated-wheel-metadata.patch
  - requirements/build.in
  - scripts/verify_install.py
source_docs: []
tags:
  - build
  - cuda
  - triton
  - flash-attention
  - validation
last_checked: 2026-07-19
updated: 2026-07-19T07:42:15Z
---

# 2026-07-19 Full CUDA Build Failures and Remedies

## Evidence

The canonical `build.sh` completed all five local wheels on 2026-07-19: Triton, PyTorch, standalone Flash Attention 4, Torchvision, and Torchaudio. The installed project `.venv` then passed module provenance, CUDA 13.1, native SM120, CUDA matmul, Torchvision CUDA NMS, and FA4 FP16/BF16 forward and backward validation.

## Failures and fixes

- Triton initially failed because its no-build-isolation build imported `nanobind==2.10.2`, which was absent from the root build lock. Add the exact requirement to `requirements/build.in` and regenerate the hash-locked file.
- Clang 21 rejected a TensorPipe CUDA warning as an error because only the base `tensorpipe` target had the upstream suppression. The PyTorch compatibility patch applies the same suppression to `tensorpipe_cuda`.
- CUDA 13.1 cuDSS uses `cudssDataType_t` and requires CSR offset, index, and value data types. The PyTorch compatibility patch changes `SparseCsrTensorMath.cu` to use `CUDSS_R_*` values and supply both `CUDSS_R_32I` arguments.
- `TRITON_BUILD_UT=0` was exported by the root script but omitted from Triton setup CMake passthrough, enabling unit-test targets and a CMake 4.4 GoogleTest JSON-discovery failure. Set Triton's supported `TRITON_APPEND_CMAKE_ARGS` entry point to pass `-DTRITON_BUILD_UT=0`.
- FA4 requires `nvidia-cutlass-dsl` dev releases. The FA4 dependency install must explicitly allow prereleases.
- Runtime validation must compare package public versions when a wheel adds PEP 440 local build metadata. FA4 reports a static module version and returns `(out, lse)`, so provenance validation bypasses its module version and validation uses the first tuple element while still checking type, values, and gradients.

## Operational boundary

Run the entry point with `HOME` and `CCACHE_DIR` under root `.build/`. All created wheels, cache state, temporary files, and the venv remain in the project boundary or `/tmp`; do not install build dependencies globally. The script applies the version-controlled compatibility patches after it cleans each source tree and records their SHA-256 values in provenance. A patch mismatch stops the build, which makes an upstream update's compatibility failure explicit. The retained Triton Python egg-info directory is ignored as generated output by its build-time patch.
