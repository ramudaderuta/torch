---
title: 2026-07-19 Full CUDA Build Failures and Remedies
type: debugging
status: current
scope: root-orchestration
related_scopes: []
related_files:
  - build.sh
  - patches/pytorch/cuda-13-clang21-compat.patch
  - patches/pytorch/cudss-0.8-api-compat.patch
  - patches/triton/ignore-generated-wheel-metadata.patch
  - patches/xformers/fa4-namespace-compat.patch
  - requirements/build.in
  - .env.example
  - scripts/verify_install.py
source_docs: []
tags:
  - build
  - cuda
  - oom
  - triton
  - xformers
  - flash-attention
  - validation
last_checked: 2026-07-19
updated: 2026-07-19T11:10:00Z
---

# 2026-07-19 Full CUDA Build Failures and Remedies

## Evidence

The canonical `build.sh` completed all five local wheels on 2026-07-19: Triton, PyTorch, standalone Flash Attention 4, Torchvision, and Torchaudio. After the CUDA 13.3.73 migration, the installed project `.venv` passed module provenance, CUDA 13.3, native SM120, CUDA matmul, Torchvision CUDA NMS, and FA4 FP16/BF16 forward and backward validation. PyTorch, Torchvision, and Torchaudio build versions in `.env` match their checked-out source version files; Triton and FA4 derive their versions from upstream metadata and the configured wheel suffix.

## Failures and fixes

- Triton initially failed because its no-build-isolation build imported `nanobind==2.10.2`, which was absent from the root build lock. Add the exact requirement to `requirements/build.in` and regenerate the hash-locked file.
- Clang 21 rejected a TensorPipe CUDA warning as an error because only the base `tensorpipe` target had the upstream suppression. The PyTorch compatibility patch applies the same suppression to `tensorpipe_cuda`.
- cuDSS 0.8 changes the API to `cudssDataType_t` and requires CSR offset, index, and value data types. Keep that source correction in the separate `cudss-0.8-api-compat.patch`, including the CSR `rowEnd` pointer at `rowOffsets + 1`. It applies cleanly, but cuDSS 0.8.0 returns `CUDSS_STATUS_NOT_SUPPORTED` for both 32-bit and 64-bit CSR descriptors on the RTX 5090 (SM120), including through a minimal direct C++ probe. Set `PYTORCH_USE_CUDSS=0` until a newer cuDSS release passes that probe on this GPU; the build then excludes the unsupported backend while retaining CUDA support.
- CUDA 13's cuTENSOR 2.7 and cuSPARSELt 0.9 replace the old generic packages. The latter changes the runtime SONAME from `libcusparseLt.so.0`; wheels built against the removed 0.7 package cannot import and must be rebuilt. Set the CUDA 13-specific cuSPARSELt include and library directories explicitly so CMake selects 0.9.1.
- `TRITON_BUILD_UT=0` was exported by the root script but omitted from Triton setup CMake passthrough, enabling unit-test targets and a CMake 4.4 GoogleTest JSON-discovery failure. Set Triton's supported `TRITON_APPEND_CMAKE_ARGS` entry point to pass `-DTRITON_BUILD_UT=0`.
- A PyTorch rebuild at `MAX_JOBS=24` exhausted host memory while compiling CUDA Flash Attention translation units. The kernel recorded global OOM events and killed multiple CUDA `cicc` processes, each using roughly 1.85-2.39 GiB RSS; Ninja then reported only the secondary `subcommand failed` error. The current local and template setting is `MAX_JOBS=18`. If it fails with `cicc ... Killed` again, rebuild at the previously successful value `MAX_JOBS=16`; do not diagnose this signature as a source or compiler compatibility error.
- The commits after xFormers `v0.0.35` on upstream `main` move the FMHA API to a declared `mslk` dependency. The public index resolves `mslk==0.0.0`, but that distribution has no importable module. Pin the root gitlink to the latest public release tag `v0.0.35` rather than treating the latest main commit as usable.
- xFormers `v0.0.35` treats any `flash_attn` package as FlashAttention 2 and unconditionally imports `flash_attn.flash_attn_interface`. Standalone FA4 owns the same namespace but intentionally does not contain that FA2 module, so xFormers import fails before its own CUDA kernels can run. Apply `patches/xformers/fa4-namespace-compat.patch` only while building: it recognizes the absent optional FA2 module and falls back to PyTorch Flash. The patched wheel imported and completed CUDA memory-efficient attention on SM120.
- FA4 requires `nvidia-cutlass-dsl` dev releases. The FA4 dependency install must explicitly allow prereleases.
- Runtime validation must compare package public versions when a wheel adds PEP 440 local build metadata. FA4 reports a static module version and returns `(out, lse)`, so provenance validation bypasses its module version and validation uses the first tuple element while still checking type, values, and gradients.

## Operational boundary

Run the entry point with `HOME` and `CCACHE_DIR` under root `.build/`. All created wheels, cache state, temporary files, and the venv remain in the project boundary or `/tmp`; do not install build dependencies globally. The script applies the version-controlled compatibility patches after it cleans each source tree, records their SHA-256 values in provenance, and removes only the patches that it applied when the process exits. The Clang patch is always required; the cuDSS patch is applied only when `PYTORCH_USE_CUDSS=1`; the xFormers patch is always applied with the pinned release. A patch mismatch stops the build, which makes an upstream update's compatibility failure explicit. The retained Triton Python egg-info directory is ignored as generated output by its build-time patch.
