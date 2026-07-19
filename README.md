# Local PyTorch CUDA Build

This repository orchestrates local CUDA source builds of PyTorch, Triton,
Flash Attention 4, Torchvision, and Torchaudio. Upstream sources are Git
submodules; root scripts provide the supported local workflow.

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
   ./build.sh
   ```

`build.sh` creates or validates `.venv`, installs build-time dependencies only
there, and writes wheels to `dist/`. It may clean untracked files in source
submodules when `CLEAN_BUILD=1`; review that setting before running it.

The build order is Triton, PyTorch, FA4, Torchvision, then Torchaudio. The
entry point always builds this complete set; it has no component-skip switches.
Local wheels are installed into `.venv` only when a later component needs them
to build. They are not installed into a system or user Python environment.
Shell orchestration lives in `build.sh`; the focused Python validation helpers
it invokes are under `script/` and receive the exported local configuration.

## Install artifacts

After a successful build, choose the target environment deliberately and
install the desired wheel files from `dist/`, for example:

```bash
python -m pip install /path/to/torch/dist/torch-*.whl
```

Install matching Torchvision and Torchaudio wheels after the local Torch wheel.
FA4 and standalone FA2 share the `flash_attn` namespace and must not be
co-installed.

## Validation and maintenance

The build performs import and CUDA smoke checks when `VERIFY_INSTALL=1`.
Generated logs, manifests, wheels, `.venv`, and `.build` are local outputs.
For deeper operational details, see `.codex/wiki/how-to/build-and-validation.md`.

Run `update.sh` only when intentionally updating upstream sources; it refuses
non-fast-forward histories and never resets local commits. Inspect submodule
changes and compatibility before building.
