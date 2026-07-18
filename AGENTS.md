# Project Agent Instructions

## Purpose and source of truth

This repository orchestrates local source builds of PyTorch, Triton, Torchvision, Torchaudio, and Flash Attention for an NVIDIA/CUDA development host. Start durable project research at `.codex/wiki/index.md`. Executable behavior is authoritative in the current source tree and scripts.

## Instruction precedence

These instructions apply at the repository root. Each Git submodule is a separate upstream repository. Before editing a submodule, read its nearest `AGENTS.md`; closer instructions override this file. In particular, `triton/AGENTS.md` governs `triton/`.

## Working boundaries

- Keep root changes focused on `build.sh`, `update.sh`, `.gitmodules`, submodule pointers, root documentation, and `.codex/wiki/`.
- Inspect root and affected submodule status before editing and preserve user changes.
- Do not commit, push, rewrite history, change remotes, update upstream sources, or publish artifacts unless explicitly requested.
- Do not treat caches, wheels, build outputs, dependency trees, or `*_build.log` files as source.
- Keep credentials, secrets, private environment values, and authentication state out of scripts, logs, documentation, and commits.

## Build guidance

`build.sh` is the canonical build entry point. Read it before changing or invoking it. Verify Python, CUDA, compiler versions, submodule commits, storage, GPU architecture settings, and requested scope. Prefer the smallest validation that proves the change; do not launch a costly full build by default.

- `build.sh` requires the root `.env` as its only mutable configuration source. Keep it local, mode `600`, and untracked; never add machine paths, secrets, or generated values to the script as replacement defaults.
- Build PyTorch against its pinned `pytorch/third_party/flash-attention` tree. Do not replace it with an external checkout or installed package. Build standalone FA4 from `flash-attention/flash_attn/cute` after PyTorch; generated wheels belong under ignored `.build/` and install with the local torch version constrained.
- FA4 is a direct/Inductor package on this SM120 host, not PyTorch's standard SDPA backend. Do not co-install standalone FA2 and FA4 because both own the `flash_attn` Python namespace.

## Updating upstream sources

`update.sh` is the canonical update entry point. Run it only when requested. Preserve local modifications, record old and new submodule commits, inspect the resulting diff, and validate compatibility; a successful fetch is not sufficient evidence.

## Validation and completion

- Shell changes: run `bash -n` and inspect the diff.
- Submodule-pointer changes: verify `git submodule status`, commits, and compatibility evidence.
- Build changes: run the narrowest applicable build and inspect status and logs.
- Runtime changes: test imports, versions, CUDA availability, and affected extensions in the intended Python environment.
- Wiki or agent-document changes: rebuild the wiki and run doctor, stale-reference, and surface checks.

At completion, inspect `git status --short --branch` and report changes, validation, skipped checks, and residual risk.

## Wiki maintenance

Use the host `wiki-note` tooling for `.codex/wiki/`; do not manually edit generated auto-index blocks. Durable pages require structured front matter, relevant file anchors, current evidence, and a `last_checked` date. Never store secrets or oversized raw logs in the wiki.
