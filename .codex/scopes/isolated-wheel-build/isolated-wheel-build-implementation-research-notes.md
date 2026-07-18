---
description: Implementation research notes for isolated-wheel-build.
---

# isolated-wheel-build Implementation Research Notes

## Baseline (Current State)

- `build.sh` calls `"$PYTHON" -m pip uninstall/install` and `pip wheel` for all
  components; it uses `"$PYTHON" -m uv` for PyTorch and Torchaudio
  requirements.
- `.env` selects a missing external `/home/build/.venv/bin/python`, while its
  source directories are rooted at `ROOT_DIR` and resolve when loaded by the
  script.
- Final wheels are emitted into the root `dist/` directory; component-local
  output is staged in the ignored build tree before the selected new wheel is
  copied there.
- Torchaudio's current `audio/src/torchaudio/__init__.py` no longer exports
  `list_audio_backends`, but `build.sh` calls it during verification.

## Gap Analysis

| Gap | Evidence | Consequence |
|---|---|---|
| Host/environment coupling | `build.sh` installs and uninstalls through configurable `$PYTHON` | An accidental system interpreter is mutated and partial failure is hard to recover from. |
| Unstable `uv` invocation | `build.sh` uses `$PYTHON -m uv` but only optionally bootstraps the module | Disabling bootstrap makes dependency installation fail despite a host `uv` CLI. |
| Artifact scattering | Every component uses its own wheel output directory | Consumers cannot use one artifact location and stale wheels are difficult to reason about. |
| Fragile verification | Torchaudio calls removed API; FA4 verification mixes import and CUDA smoke | Successful build failures are not classified cleanly. |
| Missing diagnostics | No `ERR` trap or stage context | Failure output does not immediately identify the phase and log. |

## Candidate Designs and Trade-offs

The selected repository venv retains local Torch only as a build dependency;
the wheel files in `dist/` are the supported handoff. A second venv would make
the producer/consumer contract stricter but adds package transfer logic without
benefit for this single-host source-build workflow.

## Decision Roundtable

| Decision | Requirement Clarity | Evidence Strength | Evidence Source | Conflict | User-Intent Confidence | Implementation Confidence | Risk/Reversibility | Confidence Reason | Outcome |
|---|---:|---:|---|---|---:|---:|---:|---|---|
| Project venv ownership | 5 | 5 | User request; `.env`; `build.sh` | resolved | 5 | 5 | 5 | `.venv` is ignored and can be recreated; it contains all intentional mutations. | Use root `.venv` |
| Root wheel output | 5 | 5 | User request; current per-source `dist` paths | resolved | 5 | 5 | 5 | A root `dist/` is conventional and can retain independently installable artifacts. | Use root `dist/` |
| Resolver interface | 4 | 4 | Current range requirements; audit evidence | resolved | 5 | 4 | 4 | A configured constraints path prevents untracked resolver policy; exact pins require a tested resolution. | Require a constraints file path and record installed packages |
| Verification layering | 5 | 5 | Current Torchaudio/FA4 source | resolved | 5 | 5 | 5 | Import, metadata, ABI checks, and kernel execution have distinct failure meaning. | Separate checks |

## Selected Design

`build.sh` derives its interpreter from configured `VENV_DIR`, creates it with
the host `uv` executable when absent, and refuses a non-venv interpreter. The
PyTorch build-tool closure uses a configured hash lock; local-Torch-dependent
runtime resolution remains dynamically constrained after that wheel exists.
Each component writes a wheel to `dist/`; only its wheel is installed into
`.venv` when required by subsequent builds.

## Validation Plan

- `bash -n build.sh` and `git diff --check`.
- Confirm `.venv` and `dist/` are ignored, create the venv, and verify its
  interpreter is isolated.
- Run shell preflight-only structural probes without a full CUDA build.
- Verify wheel selection, PEP 440 validation, and import-smoke snippets by
  static/source inspection; reserve actual CUDA checks for a requested build.
- Run scope, wiki, and stale-reference checks.

## Risks and Assumptions

- The current Python 3.13 runtime is available to `uv`; venv creation verifies
  this rather than silently using another interpreter.
- Constraints are supplied from `.env`; an absent or empty path is a hard
  failure. Initial exact lock refresh is intentionally not guessed.
- `auditwheel` is advisory for local CUDA wheels and is not a build gate.
