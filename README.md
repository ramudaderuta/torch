# Local PyTorch CUDA Build

This repository orchestrates local CUDA source builds of PyTorch, Triton, MSLK,
xFormers, Flash Attention 4, Torchvision, and Torchaudio. Upstream sources are
Git submodules; root scripts provide the supported local workflow.

## Layout

- `build.sh` — canonical build entry point.
- `update.sh` — canonical upstream-submodule update entry point.
- `.env` — required local configuration; untracked and mode `600`.
- `.venv/` — project-owned build environment; untracked and disposable.
- `dist/` — retained wheel artifacts; untracked. Install these explicitly into
  the environment that will consume them.
- `requirements/build.in` and `requirements/build.lock` — reviewed, hash-locked
  PyTorch build-tool dependencies.

PyTorch builds its own pinned `pytorch/third_party/flash-attention` source for
its in-tree attention implementation. The standalone FA4 wheel is built from
`flash-attention/flash_attn/cute`; it is not a replacement for PyTorch SDPA.

## Build

1. Initialize all submodules after cloning:

   ```bash
   git submodule update --init --recursive
   ```

2. Create the local `.env` from `.env.example`, then review every value for the
   host. Its commented sections group general lifecycle settings, source and
   toolchain paths, component build switches, dependencies, and verification
   parameters. Do not commit `.env`.

3. Check shell syntax, then run the build:

   ```bash
   bash -n build.sh
   HOME="$PWD/.build/home" \
   CCACHE_DIR="$PWD/.build/ccache" \
   ./build.sh
   ```

`build.sh` creates or validates `.venv`, installs build-time dependencies only
there, and writes wheels to `dist/`. It may clean untracked files in source
submodules when `CLEAN_BUILD=1`; review that setting before running it.

After a successful build, `dist/requirements-runtime.txt` records the direct
runtime requirements declared by the locally built wheels, including the CUDA
13 Cutlass runtime libraries required by FA4. It keeps upstream version ranges
instead of freezing the build virtual environment and excludes local wheels,
test, lint, and build tools. To install into another compatible environment,
first install the matching local Torch, Triton, xFormers, and FA4 wheels from
`dist/`, then resolve this runtime manifest:

```bash
python -m pip install /path/to/torch/dist/torch-*.whl \
  /path/to/torch/dist/pytorch_triton-*.whl \
  /path/to/torch/dist/mslk-*.whl \
  /path/to/torch/dist/xformers-*.whl \
  /path/to/torch/dist/flash_attn_4-*.whl
python -m pip install \
  -r /path/to/torch/dist/requirements-runtime.txt
```

The target must still use a compatible Python, CUDA driver, and local PyTorch
ABI; this is particularly important for the MSLK native kernels and the xFormers
CUDA extension. xFormers' FMHA implementation is provided by MSLK and its
public `mslk` dependency is satisfied by the locally built MSLK wheel, never by
a public index build.

The build order is Triton, PyTorch, MSLK, xFormers, FA4, Torchvision, then
Torchaudio. The
entry point always builds this complete set; it has no component-skip switches.
Local wheels are installed into `.venv` only when a later component needs them
to build. They are not installed into a system or user Python environment.
Shell orchestration lives in `build.sh`; the focused Python validation helpers
it invokes are under `scripts/` and receive the exported local configuration.
The preflight rejects Python/pip prefix overrides and confines the configured
Triton, pip, uv, XDG, temporary, and Python bytecode caches to `.build/`.
Triton downloads its pinned LLVM there; this project rejects `LLVM_SYSPATH` to
prevent an accidental host LLVM override. xFormers builds against the locally
built Torch and Triton wheel with dependency resolution disabled, and its
PyTorch extension cache is confined to `.build/torch-extensions`.

The entry point detects the installed GPU architecture and builds all seven
components in this order: Triton, PyTorch, MSLK, xFormers, FA4, Torchvision, and
Torchaudio. MSLK and xFormers are one coupled compatibility unit: MSLK builds
first against the locally installed Torch (whose ABI the MSLK native kernels
link), and xFormers then re-exports the MSLK FMHA API; the MSLK commit is part
of the xFormers build cache fingerprint, so an MSLK update invalidates and
revalidates the pair.
It validates wheel metadata, records provenance, and, when `VERIFY_INSTALL=1`,
checks CUDA matmul, xFormers CUDA memory-efficient attention (exercising the
MSLK backend), Torchvision CUDA NMS, and FA4 forward/backward execution.
The current host configuration uses CUDA 13.4 (via the `/usr/local/cuda`
alternatives symlink, so minor upgrades need no `.env` edit) and Clang 21.
`MAX_JOBS` controls the Triton, PyTorch, and xFormers build parallelism, while
`MSLK_MAX_JOBS` controls MSLK's CMake build; use the reviewed `.env` values
rather than setting them in a shell ad hoc.

Root-managed compatibility patches are applied only for the duration of a
build and are removed on exit, including failure. The Clang 21 TensorPipe patch
is no longer applied because upstream merged the fix (PyTorch commit
`297314309d`). The separate cuDSS API patch is applied only when
`PYTORCH_USE_CUDSS=1`; cuDSS is currently disabled because cuDSS 0.8 does not
support the SM120 CSR path on this host. The former xFormers FA4-namespace
patch was removed when xFormers moved its FMHA implementation to MSLK; an
equivalent temporary MSLK patch keeps its optional FA2 probe from mistaking
standalone FA4's top-level `flash_attn` namespace for FA2. The standalone FA4
`flash_attn.cute` package, MSLK, and PyTorch SDPA keep distinct namespaces
after that probe is skipped.

## Updating sources

Run `./update.sh` only when intentionally advancing upstream source trees. It
first reconciles clean nested submodules to their parent repository's locked
commits, which prevents a prior parent update from appearing as a false dirty
state. Git-ignored build outputs and generated `*.egg-info/` metadata do not
block an update, while tracked or other non-ignored untracked source changes
still do. If an upstream branch has intentionally
rewritten history, review it first and then run `./update.sh --reset-on-divergence`;
the script saves the prior local HEAD in an `update-backup/<timestamp>-<branch>`
branch before resetting.
Inspect the resulting root `git status` and submodule commits, then commit any
intended gitlink changes before treating the revision as reproducible. Always
rebuild after an update. Before compiling, `build.sh` verifies that each managed
patch applies to the updated source; an incompatible patch stops the build
instead of being silently skipped.

Public build versions in `.env` must match the corresponding source version
files for PyTorch, Torchvision, and Torchaudio. A submodule commit advance does
not require a version change when its source version is unchanged. Triton,
xFormers, MSLK, and FA4 derive their wheel versions from their upstream build
metadata. xFormers tracks upstream `main`; its FMHA implementation is provided
by MSLK, which is built from source against the same locally built PyTorch
before xFormers. MSLK and xFormers are therefore treated as one coupled
compatibility unit; the public PyPI placeholder for `mslk` is never used.

## Local outputs and cleanup

All normal build writes remain in the repository or `/tmp` when started with
the command above: `.build/` contains pip, uv, Triton, ccache, and temporary
state; `.venv/` is the project-only Python environment; `dist/` retains wheels;
and `*_build.log` files are component logs. Build dependencies are installed
only into `.venv`, not a system or user Python environment.

`CLEAN_BUILD=1` removes untracked generated outputs from each source tree
before building. Set `CLEAR_PIP_CACHE=1` to purge the project pip cache. To
discard all project-local build state and artifacts, run:

```bash
rm -rf .build .venv dist
rm -f *_build.log
```

This does not change source commits, but it removes locally built wheels and
requires the next build to recreate its environment and caches.

## Install artifacts

After a successful build, choose the target environment deliberately and
install the desired wheel files from `dist/`, for example:

```bash
python -m pip install /path/to/torch/dist/torch-*.whl
```

Install matching xFormers, Torchvision, and Torchaudio wheels after the local Torch wheel.
FA4 and standalone FA2 share the `flash_attn` namespace and must not be
co-installed.

## Validation and maintenance

The build performs import and CUDA smoke checks when `VERIFY_INSTALL=1`.
Generated logs, manifests, wheels, `.venv`, and `.build` are local outputs.
For deeper operational details, see `.codex/wiki/how-to/build-and-validation.md`.

For deeper operational details and current compatibility evidence, see
`.codex/wiki/how-to/build-and-validation.md` and
`.codex/wiki/debugging/full-cuda-build-failures-2026-07-19.md`.
