---
description: Task list for isolated-wheel-build phase 2.
---

# Tasks: isolated-wheel-build Phase 2

## Input
- Canonical sources:
  - `README.md`
  - `.codex/scopes/isolated-wheel-build/isolated-wheel-build-scope-milestones.md`
  - `.codex/scopes/isolated-wheel-build/isolated-wheel-build-brainstorming.md`
  - `.codex/scopes/isolated-wheel-build/isolated-wheel-build-implementation-research-notes.md`
  - `.codex/scopes/isolated-wheel-build/isolated-wheel-build-technical-documentation.md`
  - `.codex/scopes/isolated-wheel-build/isolated-wheel-build-contracts.md`

## Canonical architecture / Key constraints
- Keep architecture aligned with isolated-wheel-build scope docs and contracts.
- Preserve the decision chain from research notes, brainstorming decisions, and
  scope milestones.
- Keep provider/runtime/channel boundaries unchanged unless explicitly in scope.
- Keep security and test gates in Definition of Done.

## Format
- [ID] [P?] [Component] Description
- [P] means parallelizable.
- Valid components: Backend, Frontend, Agentic, Docs, Config, QA, Security, Infra.
- Every task must have a clear DoD.

## Phase 2: Build Pipeline Refactor
Goal: Route all resolution, wheel output, local dependency installation, and failure diagnostics through the isolated architecture.

Definition of Done: `build.sh` produces root `dist` wheels, uses host `uv` against `.venv`, validates configuration, and no longer auto-installs final packages outside the project.

Tasks:
- [x] T021 [Infra] Refactor interpreter and artifact lifecycle
  - DoD: `build.sh` creates/uses `.venv`, writes each component wheel to `dist`, and installs only the selected wheel into `.venv` when downstream builds require it.
- [ ] T022 [Config] Apply lock and provenance boundaries
  - Progress: Manifests now record resolved packages, recursive submodule commits, tool/build metadata, and wheel checksums without credentials, including on a post-preflight failure. The remaining resolver-lock requirement is unchanged.
  - DoD: Every resolver install consumes `requirements/build.lock`; manifests record resolved packages and recursive submodule commits without credentials.
- [x] T023 [QA] Layer build verification and error reporting
  - DoD: Torchaudio no longer calls removed backend APIs, FA4 diagnostics are layered, CUDA architecture and Torchvision CUDA NMS checks are explicit, and `ERR` output identifies the failed stage.

Checkpoint: Shell syntax and targeted static checks pass without a CUDA build; runtime validation remains intentionally unexecuted.

## Dependencies & Execution Order
- Phase 1 blocks all others.
- Phase 2 depends on completion of phases 1-1.
- Tasks marked [P] within this phase may run concurrently only when they do not touch the same files.
