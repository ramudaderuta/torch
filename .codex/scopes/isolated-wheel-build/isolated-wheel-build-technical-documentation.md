---
description: Canonical technical architecture for isolated-wheel-build.
---

# isolated-wheel-build Technical Documentation

## Canonical Architecture

`.env` supplies machine-specific directories, version inputs, `VENV_DIR`, the
constraints-file path, and all component build/verification switches. Its
commented sections are mirrored in the tracked, credential-free `.env.example`
template. `build.sh` owns orchestration: it creates/validates
`.venv`, configures CUDA, builds in dependency order, emits wheels into
`dist/`, and installs selected wheels only into `.venv` for downstream builds.
The ignored build tree holds generated temporary wheel staging and provenance
evidence.

## Key Constraints and Non-Goals

- `dist/` is the artifact handoff; `.venv/` is disposable and ignored.
- `--no-build-isolation` remains intentional because required local Torch and
  CUDA build tools must be visible; constraints and manifests bound its risk.
- FA4's package namespace remains mutually exclusive with standalone FA2.

## Major Decisions and Trade-offs

- The host `uv` CLI targets `.venv`, avoiding the fragile target-module form.
- Wheel installation inside `.venv` is retained only to build dependent
  components; automatic installation into user/system environments is removed.
- A constraints-file contract is preferable to embedding a long mutable list
  of package pins in a shell script.

## Module Boundaries and Data Flow

`uv venv` -> `.venv/bin/python` -> build dependencies -> component wheel in
`.build/wheels/<component>` -> selected new wheel copied to `dist/` and
installed into `.venv` -> next component. The consumer explicitly installs
selected wheels from `dist/` into its chosen environment after the build
completes.

## Interfaces and Contracts

- `.env`: trusted local shell configuration, mode 600, never committed.
- `BUILD_CONSTRAINTS_FILE`: existing non-empty hash lock for the PyTorch build
  tool closure. FA4's local-Torch-dependent runtime closure is constrained
  dynamically after the local wheel exists and captured in provenance.
- `dist/`: root artifact directory containing one wheel for each component
  package name.

## Security and Reliability

The script reports phase, line, exit code, and relevant log path on `ERR`, but
never dumps the environment. It rejects an external/non-venv target interpreter
and records dependency/submodule provenance without index credentials. It writes
provenance before runtime validation and updates it to a failed status through
the `ERR` trap, including source commits, tool versions, configured build
versions, CUDA architecture targets, and wheel checksums.

## Test Strategy

Use shell syntax, venv isolation, configuration, diff, scope, and wiki checks
in this scope. A future full build validates imports and distribution paths,
the exact native CUDA architecture list, Torchvision CUDA NMS, Torchaudio
extension availability, and FA4 FP16/BF16 causal/non-causal forward, reference,
and backward execution separately.
