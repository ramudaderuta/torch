---
description: Brainstorming and decision framing for isolated-wheel-build.
---

# isolated-wheel-build Brainstorming

## Problem

`build.sh` installs and uninstalls packages in the configured Python interpreter
and writes wheels to each upstream submodule's `dist/` directory. The configured
interpreter no longer exists. The user wants a project-owned environment and
one retained artifact directory, while the audit also identified resolver,
validation, and failure-reporting gaps.

## Scope

Create and use `<repo>/.venv`, retain final wheels under `<repo>/dist`, and
make the script's intermediate installations occur only in that project venv.
Strengthen preflight, dependency provenance, version validation, verification,
and failure reporting without running an expensive CUDA build in this scope.

## Constraints

- Keep `build.sh` as the single executable entry point and `.env` as local
  mutable configuration.
- Do not install final wheels into a non-project Python environment.
- Keep PyTorch's embedded Flash Attention unchanged and preserve standalone
  FA4 as a separate artifact.
- Do not update submodule commits, patch upstream source, or publish wheels.

## Options

| Option | Benefits | Costs | Result |
|---|---|---|---|
| Build directly in an arbitrary configured interpreter | Minimal script change | Repeats the pollution and recovery problems | Rejected |
| Use a disposable build venv and install artifacts elsewhere | Strong isolation | Adds a second environment and does not support dependent local builds naturally | Rejected |
| Use one repository `.venv` for build-time dependencies and retain wheels in root `dist/` | Isolates the host, lets later components build against local Torch, and leaves portable artifacts | The venv remains a build cache and must not be treated as the distributable output | Selected |

## Decision Summary

| Decision | Options Considered | Rationale | Research Note Link |
|---|---|---|---|
| Environment ownership | Arbitrary interpreter; disposable build venv; repository `.venv` | The selected option exactly matches the user request and keeps inter-component ABI dependencies local. | [research](isolated-wheel-build-implementation-research-notes.md) |
| Artifact layout | Per-submodule `dist`; root `dist` | Root `dist` is one discoverable installation surface; package-specific wheel selection prevents stale artifacts from being installed. | [technical](isolated-wheel-build-technical-documentation.md) |

## Decision

Use `uv` as a host tool to create and target `.venv`; do not invoke it as a
module inside the target interpreter. Build wheels into root `dist/`, install
only the just-built wheel into `.venv` when the next component needs it, and
never install artifacts outside the repository.

## Risks

- A full build still mutates source build outputs when `CLEAN_BUILD=1`; it is
  intentionally not run for this refactor.
- A fully reproducible dependency lock needs resolved, tested package versions
  for the host's Python/CUDA combination; this scope records provenance and
  adds a lock-file interface without guessing unverified pins.

## Open Questions

- None. Package-version refresh remains a deliberate follow-up after a
  successful reference build.
