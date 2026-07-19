---
description: Integrate the SageAttention3 Blackwell source build.
---

# SageAttention3 Integration Contract

## Context

- Current worktree: `/home/build/torch` on `main`; the pre-existing uninitialized `triton` submodule is outside this scope.
- Relevant paths: `build.sh`, `update.sh`, `.gitmodules`, `.env.example`, and the new `sageattention` submodule.
- Relevant archived scope references: none.

## Findings

- SageAttention3 is implemented under `sageattention/sageattention3_blackwell`, not the upstream repository root.
- The upstream SageAttention3 setup clones CUTLASS into its build tree when missing and packages the distribution as `sageattn3`.
- Evidence: upstream README and `sageattention/sageattention3_blackwell/setup.py` at pinned commit `d1a57a546c3d395b1ffcbeecc66d81db76f3b4b5`.

## Outcome

- Done when: SageAttention is a pinned root submodule; `build.sh` builds SageAttention3 after local Torch and FA4; `update.sh` discovers the new checkout.
- Runtime state: the SageAttention3 wheel is retained in `dist/`, installed in `.venv`, and verified by importing `sageattn3.sageattn3_blackwell`.
- Durable knowledge: upstream's nested CUTLASS download must occur only in a `.build/` staging copy. Every stage records a chained key containing its source state, relevant configuration, toolchain identity, and preceding stage key.

## Goals / Non-goals

Goals:

- Add `https://github.com/thu-ml/SageAttention.git` as `sageattention`.
- Build the current `sageattention3_blackwell` source through the existing wheel lifecycle.
- Keep SageAttention3 downloads, staging source, and rebuild state inside `.build/`.
- Skip any unchanged stage only when its chained cache key and installed import remain valid; rebuild all following stages after an upstream stage changes.

Non-goals:

- Do not build or install the upstream root `sageattention` 2.2 package.
- Do not alter existing components' build behavior, update upstream sources, or run a full CUDA build.

## Target Files / Modules

- `.gitmodules`, `sageattention` gitlink, `build.sh`, `update.sh`, and `.env.example`.
- `.codex/wiki/how-to/build-and-validation.md` and `.codex/wiki/how-to/upstream-update.md` for durable workflow alignment.

## Constraints

- `.env` remains the sole mutable configuration source and is not read or modified for this task.
- Generated SageAttention3 content stays in `.build/`; retained wheels remain in `dist/` under existing repository policy.
- Preserve unrelated working-tree state, including `triton`.

## Boundaries

Allowed changes:

- Root orchestration, submodule declaration/pointer, local configuration template, scope record, and wiki notes.

Forbidden changes:

- Modifying upstream SageAttention source, installing dependencies globally, committing, pushing, or performing a full build.

## Decision Summary

| Decision | Evidence Source | Evidence Strength | Conflict | Result | Confidence Reason |
| --- | --- | --- | --- | --- | --- |
| Build the nested SageAttention3 directory rather than the repository root | upstream README and `setup.py` | high | resolved | Build `sageattention/sageattention3_blackwell` as `sageattn3` | The upstream root packages SageAttention 2.2 while its README identifies the nested directory as SageAttention3. |
| Stage source under `.build` | upstream `setup.py` CUTLASS clone behavior and user boundary | high | resolved | Export a git archive into `.build/sources/sageattention3` before wheel build | Prevents generated CUTLASS content from entering the submodule. |
| Skip unchanged rebuilds | user request and extension ABI/runtime requirements | high | resolved | Cache every stage's source, recursive submodules, relevant configuration, toolchain, upstream stage key, and import health | Avoids redundant extensions while guaranteeing a rebuilt PyTorch invalidates all later stages. |

## Verification Surface

- `bash -n build.sh update.sh`.
- Shell-function harnesses exercising chained cache keys, staging, and skip/rebuild behavior without CUDA compilation.
- `git diff --check`, `git submodule status`, and targeted metadata inspection.
- Repo-scope and wiki structural checks.

## Escalation Triggers

- Escalate if the upstream package layout or distribution name changes, or SageAttention3 requires a dependency absent from the pinned local build environment.

## Rollback

- Remove the `sageattention` gitlink and `.gitmodules` entry, then revert the root orchestration changes. Delete only SageAttention3-generated `.build/` paths if needed.

## Open Questions

- None.

## Execution Log / Evidence Updates

- 2026-07-19: created single-contract scope, pinned upstream `main` at `d1a57a546c3d395b1ffcbeecc66d81db76f3b4b5`, integrated the Blackwell-only build, and added chained incremental rebuild keys for all seven stages.
