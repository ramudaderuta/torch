---
description: API and schema contracts for isolated-wheel-build.
---

# isolated-wheel-build Contracts

## API Contracts

`build.sh` accepts no new positional API. It reads `.env`, creates the
configured venv, and writes artifacts to the configured root `dist/` path.
`.env.example` is the tracked, credential-free template; `.env` remains the
only mutable runtime configuration source.
`script/` contains the Python venv, configuration, wheel-metadata, and final
runtime validation helpers invoked by the shell orchestrator.

## Shared Types / Schemas

`BUILD_CONSTRAINTS_FILE` is a pip/uv constraints file. `BUILD_NUMBER` is a
non-negative integer. Vision and Audio final versions must parse as PEP 440.
The local configuration groups general settings, source paths, toolchain,
Triton, PyTorch, FA4, Torchvision, Torchaudio, and FA4 verification settings.
The entry point is intentionally fixed to all five components; it does not
define component-skip settings.

## Event and Streaming Contracts

The script emits stage headers to the main log. On failure it emits a compact
error record containing phase, source line, exit code, and stage log path.

## Error Model

Missing/invalid configuration, unavailable venv interpreter, invalid version,
missing constraints, missing artifact, and failed CUDA smoke are fatal. Optional
metadata diagnostics are non-fatal only when explicitly marked as such.

## Validation and Compatibility Rules

Each selected wheel must match exactly one expected package pattern in `dist/`.
It is force-reinstalled into the project venv so same-version wheels cannot be
silently reused. Final validation confirms the module and distribution versions
and paths resolve within that venv. FA4's dependencies constrain Torch to the
local wheel version. CUDA validation requires an exact native
`sm_<major><minor>` entry for the active device in `torch.cuda.get_arch_list()`.
Before installation, the wheel's own `METADATA` must name the expected
distribution, and its name/version are recorded in the provenance manifest.
FA4 verification inputs are validated before component builds, including the
allowed dtype/head-dimension sets and a tensor-element limit.

## Requirement Boundary Notes

Exact dependency pins are not invented in this refactor. The constraints-file
interface and manifest establish the reproducibility boundary; generating an
accepted lock requires a successful, reviewed resolution on this host.
