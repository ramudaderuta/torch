---
title: Source Build and Validation
type: how-to
status: current
scope: root-orchestration
related_scopes: []
related_files:
  - build.sh
  - .gitignore
  - flash-attention/flash_attn/cute/pyproject.toml
source_docs: []
tags:
  - build
  - validation
  - cuda
  - flash-attention
last_checked: 2026-07-18
updated: 2026-07-18T15:14:01Z
---

# Source Build and Validation

`build.sh` is the canonical entry point for the local CUDA source build. It builds Triton, PyTorch, Flash Attention 4, Torchvision, and Torchaudio in that order. `.env` is required and is the sole source for mutable configuration: source paths, versions, compiler and cleanup switches, CUDA/LLVM paths, and wheel-output locations. The script validates every required setting before it performs preflight checks or modifies build outputs.

PyTorch builds its own pinned `pytorch/third_party/flash-attention` tree as the in-tree SDPA implementation. The script does not replace that source tree with an installed package or an external checkout.

Flash Attention 4 is built independently from `flash-attention/flash_attn/cute` into an ignored `.build/wheels/flash-attn-4` directory. Its dependency installation constrains `torch` to the version installed by the preceding local PyTorch step, and the generated wheel is installed with `--no-deps`; this prevents pip from replacing the local PyTorch package. The FA4 wheel provides direct and Inductor-oriented functionality on SM120, but it is not activated as PyTorch's standard SDPA backend.

Before a full build, run `bash -n build.sh` and confirm `.env` has the intended local values. A full build validates imports and runs a CUDA FA4 forward call during final verification.
