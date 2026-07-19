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
last_checked: 2026-07-19
updated: 2026-07-19T00:00:00Z
---

# Source Build and Validation

`build.sh` is the canonical entry point for the local CUDA source build. It builds Triton, PyTorch, Flash Attention 4, Torchvision, and Torchaudio in that order. Create the required local `.env` from the credential-free `.env.example`, then review it for the host. `.env` is the sole mutable configuration source and uses commented sections for general lifecycle settings, source paths, CUDA/LLVM tooling, each component's build options, and FA4 verification. The script creates or validates the ignored root `.venv` before it modifies package state; it rejects a non-venv interpreter. Each selected wheel is force-reinstalled into that venv so a same-version prior wheel cannot satisfy validation.

Final wheels are retained in the ignored root `dist/` directory. The script installs a just-built wheel only into `.venv` where a later component needs it; it does not install artifacts into a system or user Python environment. Install selected files from `dist/` explicitly into the consumer environment after a successful build. Manifests capture recursive submodule commits, installed packages, build/tool metadata, CUDA architecture targets, and wheel checksums before runtime validation; the `ERR` trap updates the record if a later step fails.

`requirements/build.in` and its generated hash-locked `requirements/build.lock` pin the PyTorch build-tool closure. The local PyTorch and FA4 runtime closure cannot be resolved correctly from PyPI before the local Torch wheel exists, so the build records its post-build environment and wheel metadata as provenance instead of substituting an incompatible public Torch wheel.

PyTorch builds its own pinned `pytorch/third_party/flash-attention` tree as the in-tree SDPA implementation. The script does not replace that source tree with an installed package or an external checkout.

Flash Attention 4 is built independently from `flash-attention/flash_attn/cute` into root `dist/`. Its dependency installation constrains `torch` to the version installed by the preceding local PyTorch step, and the generated wheel is installed with `--no-deps`; this prevents pip from replacing the local PyTorch package. The FA4 wheel provides direct and Inductor-oriented functionality on SM120, but it is not activated as PyTorch's standard SDPA backend.

Before a full build, run `bash -n build.sh` and confirm `.env` has the intended local values. Final verification proves every module and distribution resolves in the build venv, requires an exact native `sm_<major><minor>` PyTorch architecture match for the active GPU, and checks CUDA NMS. FA4 exercises FP16 and BF16, causal and non-causal forward paths, finite outputs, a small SDPA reference comparison, and backward gradients.
