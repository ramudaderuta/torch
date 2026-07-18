---
description: Task list for isolated-wheel-build phase 3.
---

# Tasks: isolated-wheel-build Phase 3

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

## Phase 3: Evidence and Documentation Alignment
Goal: Align the project wiki and scope evidence with the isolated build contract.

Definition of Done: Wiki and scope records describe `.venv`, `dist`, lock refresh, validation limits, and the skipped full build accurately.

Tasks:
- [x] T041 [Docs] Refresh build workflow documentation
  - DoD: `README.md` and `.codex/wiki/how-to/build-and-validation.md` state the new artifact and environment contract without disclosing local values.
- [x] T042 [QA] Run scope and wiki hygiene checks
  - DoD: Scope placeholder/text/roundtable checks and wiki rebuild, lint, and stale-reference doctor pass.
- [x] T043 [Security] Verify tracked surfaces exclude local state
  - DoD: `git check-ignore` confirms `.env`, `.venv`, and `dist` are ignored and no generated manifest or log is tracked.

Checkpoint: The scope documents static evidence and the full CUDA build remains explicitly deferred.

## Dependencies & Execution Order
- Phase 1 blocks all others.
- Phase 3 depends on completion of phases 1-2.
- Tasks marked [P] within this phase may run concurrently only when they do not touch the same files.
