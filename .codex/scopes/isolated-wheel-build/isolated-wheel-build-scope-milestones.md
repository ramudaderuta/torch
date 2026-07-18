---
description: Scope boundaries and milestones for isolated-wheel-build.
---

# isolated-wheel-build Scope and Milestones

## In Scope

- `build.sh`, `.gitignore`, and local `.env` configuration.
- A repository `build-constraints.txt` interface and build provenance manifest.
- Static and preflight validation plus active scope/wiki documentation.

## Out of Scope

- CUDA compilation, package publication, upstream updates, and submodule edits.
- Replacing PyTorch's embedded Flash Attention or enabling FA4 as SDPA.
- Selective component builds and cross-platform wheel portability guarantees.

## Decision Log

| Boundary / Decision | Evidence Source | Evidence Strength | Conflict | Confidence | Confidence Reason | Result |
|---|---|---:|---|---:|---|---|
| `.venv` is build-local, not a release payload | User request; project build flow | High | resolved | High | Final wheels remain independently installable from `dist/`. | Retain `.venv` but ignore it |
| Do not auto-install outside the project | User request | High | resolved | High | Avoids host package pollution. | Install only into `.venv` as build dependency |
| Lock policy needs tested resolution | Upstream range dependencies | High | resolved | High | Unverified pins would falsely claim reproducibility. | Add interface and manifest, defer lock refresh evidence |

## Milestones

1. Establish venv/output ownership and make preflight fail safely.
2. Refactor artifact flow, dependency invocation, validation, and diagnostics.
3. Update documentation and run static/scope/wiki validation.

## Dependencies

Milestone 1 blocks the script refactor. Milestone 2 must finish before docs can
describe final behavior. Milestone 3 closes only after static checks pass.

## Exit Criteria

- `.venv/` and `dist/` are ignored and `.venv` exists with the configured
  interpreter.
- The script writes final wheels only under `dist/` and never installs them
  outside `.venv`.
- The audit findings have a concrete implementation or explicitly recorded
  deferred constraint.

## Escalation Triggers

- Escalate only when code/runtime evidence, authoritative wiki, and scope docs materially conflict and the conflict cannot be resolved from local evidence.
- Escalate for data deletion, permission semantics, production access model, or public API compatibility decisions outside the stated boundaries.
- Escalate when user-specified boundaries cannot be satisfied together.
