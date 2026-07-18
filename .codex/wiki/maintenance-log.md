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
