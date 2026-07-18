---
description: Contract for fa4-wheel-build.
---

# fa4-wheel-build Contract

## Context

- Current repo/worktree: `/home/build/torch` builds local PyTorch-family sources for CUDA 13.1.
- Relevant source paths: `build.sh`, `pytorch/third_party/flash-attention`, and `flash-attention/flash_attn/cute`.
- Relevant archived scope references: none.

## Findings

- PyTorch compiles its embedded Flash Attention source tree into its CUDA targets; an installed `flash_attn` wheel is not used for this path.
- The host GPU is RTX 5090 (SM120). The checked-out FA4 source contains dedicated SM120 forward and backward paths, while PyTorch's FA4 dispatcher registration currently accepts only capability 9 or 10.
- FA2 and FA4 both own the `flash_attn` Python namespace and must not be installed together in this environment.

## Outcome

- Done when: the root build script builds PyTorch against its embedded Flash Attention and then produces and installs a local FA4 wheel without dependency resolution replacing local PyTorch.
- User-visible/runtime state: `flash-attn-4` is importable and a CUDA SM120 FA4 forward call is included in the final validation path.
- Durable knowledge to preserve: FA4 is an independent wheel for direct or Inductor use, not a replacement for PyTorch's built-in SDPA FA2 backend on SM120.

## Goals / Non-goals

Goals:
- Keep `build.sh` as the sole build entry point.
- Build `flash-attention/flash_attn/cute` as `flash-attn-4` after local PyTorch.
- Store generated wheels under an ignored build-output directory.
- Prevent dependency resolution from replacing locally built `torch`.

Non-goals:
- Do not patch Flash Attention or PyTorch source code.
- Do not activate PyTorch's FA4 SDPA dispatcher on SM120.
- Do not build or install the standalone FA2 wheel.

## Target files / modules

- `build.sh`
- `.gitignore`
- `.codex/scopes/fa4-wheel-build/fa4-wheel-build-contract.md`

## Constraints

- Use the configured local Python interpreter and CUDA 13.1 environment.
- Preserve the current four-component build order around the inserted FA4 step.
- Do not run a full CUDA build as part of this implementation validation.

## Boundaries

Allowed changes:
- Root build orchestration, output ignores, and scope evidence.

Forbidden changes:
- Submodule source, upstream references, remotes, commits, or package publication.

## Decision Summary

| Decision | Evidence Source | Evidence Strength | Conflict | Result | Confidence Reason |
| --- | --- | --- | --- | --- | --- |
| Keep PyTorch embedded FA2 | `pytorch/aten/src/ATen/CMakeLists.txt` globs and compiles `third_party/flash-attention` | High | resolved | Do not replace the source tree | It is PyTorch's compiled-in ABI boundary |
| Build independent FA4 wheel | `flash-attention/flash_attn/cute/pyproject.toml`; SM120 paths in `flash_attn/cute` | High | resolved | Build FA4 from its subproject with CUDA 13 extras | It is the checked-out implementation with explicit SM120 support |
| Install without dependency resolution | Local PyTorch is built earlier; FA4 metadata depends on `torch` | High | resolved | Use `--no-deps` for the generated wheel | Avoids replacing local PyTorch |

## Verification surface

- `bash -n build.sh`
- `git diff --check`
- static checks that no source-link replacement or Triton patch command remains
- a future full build validates the FA4 wheel import and CUDA forward call

## Escalation triggers

- Escalate only when code/runtime evidence, authoritative wiki, and scope docs materially conflict and the conflict cannot be resolved from local evidence.
- Escalate for data deletion, permission semantics, production access model, or public API compatibility decisions outside the stated boundaries.
- Escalate when user-specified boundaries cannot be satisfied together.

## Rollback

- Revert the root-script and ignore-rule diff; generated wheels live under ignored `.build/`.

## Open questions

- None.

## Execution log / evidence updates

- Confirmed hardware: `nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader` returned RTX 5090, 12.0.
- Confirmed FA4 packaging: `flash-attention/flash_attn/cute/pyproject.toml` declares `flash-attn-4` and CUDA 13 extra.
- Implemented: `build.sh` now builds FA4 after PyTorch, writes wheels under `.build/wheels/flash-attn-4`, constrains dependency resolution to the local torch version, and installs the generated wheel with `--no-deps`.
- Implemented: removed the external Flash Attention source-link path from the PyTorch build; PyTorch now uses its pinned `third_party/flash-attention` tree.
- Implemented: moved all mutable build configuration, including source paths, build flags, CUDA/LLVM paths, output paths, and PyTorch/Vision/Audio versions, from `build.sh` to the ignored `.env`. The script rejects a missing or incomplete configuration before build preflight.
- Passed: `bash -n build.sh`, `git diff --check`, `repo-task-driven placeholder-scan`, and `repo-task-driven text-scan`.
- Passed: `wiki-note rebuild`, `wiki-note doctor --stale-refs`, and `wiki-note lint`.
- Skipped: full build, FA4 wheel generation, and CUDA runtime verification because they would clean source outputs, install dependencies, and perform long-running CUDA compilation/JIT work.
