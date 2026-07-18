---
description: API and schema contracts for isolated-wheel-build.
---

# isolated-wheel-build Contracts

## API Contracts

`build.sh` accepts no new positional API. It reads `.env`, creates the
configured venv, and writes artifacts to the configured root `dist/` path.

## Shared Types / Schemas

`BUILD_CONSTRAINTS_FILE` is a pip/uv constraints file. `BUILD_NUMBER` is a
non-negative integer. Vision and Audio final versions must parse as PEP 440.

## Event and Streaming Contracts

The script emits stage headers to the main log. On failure it emits a compact
error record containing phase, source line, exit code, and stage log path.

## Error Model

Missing/invalid configuration, unavailable venv interpreter, invalid version,
missing constraints, missing artifact, and failed CUDA smoke are fatal. Optional
metadata diagnostics are non-fatal only when explicitly marked as such.

## Validation and Compatibility Rules

Each selected wheel must match exactly one expected package pattern in `dist/`.
FA4's dependencies constrain Torch to the local wheel version. CUDA validation
compares the active device capability with `torch.cuda.get_arch_list()`.

## Requirement Boundary Notes

Exact dependency pins are not invented in this refactor. The constraints-file
interface and manifest establish the reproducibility boundary; generating an
accepted lock requires a successful, reviewed resolution on this host.
