---
title: Maintenance Log
type: maintenance-log
status: current
updated: 2026-07-18T14:06:24Z
---

# Maintenance Log

Append-only history for wiki updates caused by scope work, implementation closeout, or knowledge refresh.

## 2026-07-18T15:07:04Z [fa4-wheel-build]

- Summary: Documented the separate embedded PyTorch FA2 and independent FA4 wheel build paths.
- Pages: how-to/build-and-validation.md
- Verification: bash -n build.sh
- Residual risk: Full CUDA build and FA4 runtime validation were intentionally not run.

## 2026-07-18T15:12:08Z [fa4-wheel-build]

- Summary: Moved mutable build configuration and source-version values into the ignored required .env file.
- Pages: how-to/build-and-validation.md
- Verification: bash -n build.sh && bash -n .env
- Residual risk: Full CUDA build and FA4 runtime validation were intentionally not run.

## 2026-07-18T15:14:01Z [fa4-wheel-build]

- Summary: Aligned build wiki and agent instructions with required .env configuration, embedded PyTorch FA2, and standalone FA4 boundaries.
- Pages: how-to/build-and-validation.md
- Verification: bash -n build.sh
- Residual risk: Full CUDA build and FA4 runtime validation remain unrun.

## 2026-07-19T07:42:44Z [root-orchestration]

- Summary: Recorded the 2026-07-19 full CUDA build failure chain, environment-compatible fixes, and successful final runtime evidence.
- Pages: debugging/full-cuda-build-failures-2026-07-19.md
- Verification: bash -n build.sh && python3 -m py_compile scripts/*.py && complete five-wheel build plus verify_install.py
- Residual risk: Upstream source patches remain local until submitted upstream or replaced by compatible revisions.

## 2026-07-19T07:54:43Z [root-orchestration]

- Summary: Converted local PyTorch and Triton source edits into version-controlled build-time compatibility patches; Triton unit tests now use its supported CMake argument hook.
- Pages: debugging/full-cuda-build-failures-2026-07-19.md
- Verification: bash -n build.sh; python3 -m py_compile scripts/*.py; git apply --check/apply/reverse checks for both patches
- Residual risk: The patches are pinned to the checked-out upstream revisions and must be revalidated when submodules change.

## 2026-07-19T09:04:59Z [root-orchestration]

- Summary: Recorded CUDA 13.3 library migration, cuSPARSELt ABI rebuild requirement, and successful compatibility-patch verification.
- Pages: debugging/full-cuda-build-failures-2026-07-19.md
- Verification: build.sh; verify_install.py; wiki-note rebuild/lint/doctor

## 2026-07-19T10:13:15Z [root-orchestration]

- Summary: Recorded CUDA 13.3 library verification, cuDSS 0.8 SM120 incompatibility, disabled backend, split patches, and build parallelism increase.
- Pages: debugging/full-cuda-build-failures-2026-07-19.md
- Verification: PyTorch rebuild; verify_install.py; cuDSS probe; wiki-note rebuild/lint/doctor
