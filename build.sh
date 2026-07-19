#!/usr/bin/env bash
# Build local PyTorch, Triton, Flash Attention 4, Torchvision, and Torchaudio sources for CUDA.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Optional local configuration. Keep this trusted shell-compatible KEY=VALUE file local.
: "${ENV_FILE:=${ROOT_DIR}/.env}"
[[ -f "${ENV_FILE}" ]] || {
  printf 'ERROR: local build configuration is unavailable: %s\n' "${ENV_FILE}" >&2
  exit 1
}
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

MAIN_LOG="${ROOT_DIR}/alltorch_build.log"
TRITON_BUILD_LOG="${ROOT_DIR}/triton_build.log"
PYTORCH_BUILD_LOG="${ROOT_DIR}/pytorch_build.log"
FLASH_ATTENTION_BUILD_LOG="${ROOT_DIR}/flash_attention_build.log"
VISION_BUILD_LOG="${ROOT_DIR}/vision_build.log"
AUDIO_BUILD_LOG="${ROOT_DIR}/audio_build.log"

for log_file in "$MAIN_LOG" "$TRITON_BUILD_LOG" "$PYTORCH_BUILD_LOG" "$FLASH_ATTENTION_BUILD_LOG" "$VISION_BUILD_LOG" "$AUDIO_BUILD_LOG"; do
  : >"$log_file"
done

CURRENT_STAGE="initialization"

on_error() {
  local exit_code="$1"
  local line_number="$2"
  local command="$3"
  trap - ERR
  write_provenance "failed"
  printf 'ERROR: stage=%s line=%s exit=%s command=%q\n' "$CURRENT_STAGE" "$line_number" "$exit_code" "$command" | tee -a "$MAIN_LOG" >&2
  printf 'Logs: main=%s triton=%s pytorch=%s flash-attention=%s vision=%s audio=%s\n' \
    "$MAIN_LOG" "$TRITON_BUILD_LOG" "$PYTORCH_BUILD_LOG" "$FLASH_ATTENTION_BUILD_LOG" "$VISION_BUILD_LOG" "$AUDIO_BUILD_LOG" | tee -a "$MAIN_LOG" >&2
  exit "$exit_code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

die() {
  printf 'ERROR: %s\n' "$*" | tee -a "$MAIN_LOG" >&2
  exit 1
}

require_configuration() {
  local variable
  local -a required_variables=(
    BUILD_NUMBER VENV_DIR PYTHON PYTHON_VERSION BUILD_CONSTRAINTS_FILE DIST_DIR MAX_JOBS USE_CLANG CLEAR_PIP_CACHE CLEAN_BUILD VERIFY_INSTALL
    INSTALL_BUILD_PYTHON_DEPS PYTORCH_SOURCE_DIR VISION_SOURCE_DIR AUDIO_SOURCE_DIR
    TRITON_SOURCE_DIR FLASH_ATTENTION_SOURCE_DIR FLASH_ATTENTION_CUTE_SOURCE_DIR
    CUDA_HOME MAGMA_ROOT OPENMPI_ROOT NVCODEC_HOME
    LLVM_CONFIG_PATH LLVM_SYSPATH PYTORCH_BUILD_VERSION VISION_BUILD_VERSION
    AUDIO_BUILD_VERSION
  )

  for variable in "${required_variables[@]}"; do
    [[ -n "${!variable:-}" ]] || die "Missing required configuration in $ENV_FILE: $variable"
  done
}

log() {
  printf '%s\n' "$*" | tee -a "$MAIN_LOG"
}

section() {
  CURRENT_STAGE="$*"
  log ""
  log "=== $* ==="
}

run_with_log() {
  local log_file="$1"
  shift
  "$@" 2>&1 | tee -a "$log_file"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_source() {
  local name="$1"
  local source_dir="$2"
  [[ -d "$source_dir" && -f "$source_dir/setup.py" ]] || die "$name source is unavailable: $source_dir"
}

require_directory() {
  local name="$1"
  local source_dir="$2"
  [[ -d "$source_dir" ]] || die "$name source is unavailable: $source_dir"
}

clean_source() {
  local name="$1"
  local source_dir="$2"

  if [[ "$CLEAN_BUILD" != "1" ]]; then
    log "[$name] keeping existing build outputs (CLEAN_BUILD=0)"
    return
  fi

  log "[$name] removing untracked build outputs"
  if [[ -d "$source_dir/.git" ]]; then
    git -C "$source_dir" clean -ffdx
  else
    rm -rf "$source_dir/build" "$source_dir/dist" "$source_dir"/*.egg-info "$source_dir/.eggs"
  fi
}

prepare_wheel_dir() {
  local component="$1"
  local wheel_dir="${ROOT_DIR}/.build/wheels/${component}"

  rm -rf -- "$wheel_dir"
  mkdir -p "$wheel_dir"
  printf '%s\n' "$wheel_dir"
}

stage_and_install_wheel() {
  local package_name="$1"
  local wheel_dir="$2"
  local wheel_pattern="$3"
  local -a wheels=("$wheel_dir"/$wheel_pattern)

  compgen -G "$wheel_dir/$wheel_pattern" >/dev/null || die "[$package_name] no wheel produced in $wheel_dir"
  ((${#wheels[@]} == 1)) || die "[$package_name] ambiguous wheel selection in $wheel_dir: $wheel_pattern"
  cp -f -- "${wheels[0]}" "$DIST_DIR/"
  # Reinstall even at an unchanged version so validation cannot reuse an older wheel.
  run_with_log "$MAIN_LOG" "$PYTHON" -m pip install --force-reinstall --no-deps "${wheels[0]}"
}

ensure_project_venv() {
  if [[ ! -x "$PYTHON" ]]; then
    [[ ! -e "$VENV_DIR" ]] || die "Project venv is incomplete: $VENV_DIR"
    require_cmd uv
    uv venv --python "$PYTHON_VERSION" "$VENV_DIR" | tee -a "$MAIN_LOG"
  fi

  "$PYTHON" - <<'PY' || die "Configured Python is not an isolated virtual environment: $PYTHON"
import sys
raise SystemExit(sys.prefix == sys.base_prefix)
PY
}

validate_versions() {
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be a non-negative integer"
  "$PYTHON" - <<'PY' || die "Configured wheel version is not PEP 440 compatible"
import os
from packaging.version import Version
Version(f"{os.environ['VISION_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
Version(f"{os.environ['AUDIO_BUILD_VERSION']}.post{os.environ['BUILD_NUMBER']}")
PY
}

write_provenance() {
  local status="${1:-built}"
  local manifest_dir="${ROOT_DIR}/.build/manifests"

  mkdir -p "$manifest_dir" || return 0
  if [[ -n "${PYTHON:-}" && -x "$PYTHON" ]]; then
    "$PYTHON" -m pip freeze >"${manifest_dir}/pip-freeze.txt" || true
  else
    printf 'Python unavailable while recording provenance\n' >"${manifest_dir}/pip-freeze.txt"
  fi
  git -C "$ROOT_DIR" submodule status --recursive >"${manifest_dir}/submodules.txt" 2>/dev/null || true

  {
    printf 'status=%s\n' "$status"
    printf 'stage=%s\n' "$CURRENT_STAGE"
    printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'build_number=%s\n' "${BUILD_NUMBER:-unavailable}"
    printf 'pytorch_build_version=%s\n' "${PYTORCH_BUILD_VERSION:-unavailable}"
    printf 'vision_build_version=%s\n' "${VISION_BUILD_VERSION:-unavailable}"
    printf 'audio_build_version=%s\n' "${AUDIO_BUILD_VERSION:-unavailable}"
    git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null | sed 's/^/root_commit=/' || true
    if [[ -n "${PYTHON:-}" && -x "$PYTHON" ]]; then
      "$PYTHON" --version 2>&1 | sed 's/^/python=/' || true
      "$PYTHON" -m pip --version 2>&1 | sed 's/^/pip=/' || true
    fi
    nvcc --version 2>/dev/null | grep 'release' | sed 's/^/nvcc=/' || true
    printf 'cc=%s\n' "${CC:-unavailable}"
    printf 'cxx=%s\n' "${CXX:-unavailable}"
    printf 'torch_cuda_arch_list=%s\n' "${TORCH_CUDA_ARCH_LIST:-unavailable}"
    if [[ -d "$DIST_DIR" ]]; then
      find "$DIST_DIR" -maxdepth 1 -type f -name '*.whl' -print0 | sort -z | xargs -0r sha256sum
    fi
  } >"${manifest_dir}/build-provenance.txt"
}

configure_paths() {
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export PATH="${CUDA_HOME}/bin:${OPENMPI_ROOT}/bin:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${MAGMA_ROOT}/lib:${OPENMPI_ROOT}/lib:${NVCODEC_HOME}/lib:${LD_LIBRARY_PATH:-}"
}

configure_compiler() {
  if [[ "$USE_CLANG" == "1" ]]; then
    require_cmd clang-21
    require_cmd clang++-21
    export CC=clang-21 CXX=clang++-21
    log "Using clang-21"
  else
    export CC=gcc CXX=g++
    log "Using GCC"
  fi
}

configure_ccache() {
  if ! command -v ccache >/dev/null 2>&1; then
    log "ccache not found; continuing without compiler cache"
    return
  fi

  export CMAKE_C_COMPILER_LAUNCHER=ccache
  export CMAKE_CXX_COMPILER_LAUNCHER=ccache
  export CMAKE_CUDA_COMPILER_LAUNCHER=ccache
  ccache -z
  log "Enabled ccache"
}

configure_cuda_architectures() {
  local -a compute_caps=()
  mapfile -t compute_caps < <(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | sort -u)
  ((${#compute_caps[@]} > 0)) || die "No CUDA GPU compute capability detected"

  export TORCH_CUDA_ARCH_LIST
  TORCH_CUDA_ARCH_LIST="$(IFS=';'; printf '%s' "${compute_caps[*]}")"

  local capability
  NVCC_FLAGS=""
  for capability in "${compute_caps[@]}"; do
    NVCC_FLAGS+=" -gencode arch=compute_${capability//./},code=sm_${capability//./}"
  done
  export NVCC_FLAGS
  log "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"
}

check_system_dependencies() {
  local -a packages=(
    build-essential ninja-build gcc clang-21 ccache cmake git pkg-config
    cudnn9-cuda-13 cudss nvshmem libnccl-dev libcutensor-dev libcusparselt-dev
    libopenblas-dev liblapack-dev libomp-21-dev intel-mkl-full
    libprotobuf-dev protobuf-compiler zlib1g-dev libssl-dev
    ffmpeg libjpeg-dev libpng-dev libwebp-dev libavcodec-dev libavformat-dev
    libavutil-dev libswresample-dev libswscale-dev
    libsndfile1-dev libsox-dev libsamplerate0-dev
  )
  local -a missing=()
  local package

  for package in "${packages[@]}"; do
    dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
  done
  if ((${#missing[@]})); then
    log "Missing system packages: ${missing[*]}"
  else
    log "All configured system packages are installed"
  fi
}

print_environment() {
  section "Build environment"
  "$PYTHON" --version | tee -a "$MAIN_LOG"
  gcc -dumpfullversion -dumpversion | sed 's/^/GCC: /' | tee -a "$MAIN_LOG"
  clang-21 --version | head -n1 | sed 's/^/Clang: /' | tee -a "$MAIN_LOG"
  cmake --version | head -n1 | sed 's/^/CMake: /' | tee -a "$MAIN_LOG"
  ninja --version | sed 's/^/Ninja: /' | tee -a "$MAIN_LOG"
  nvcc --version | grep 'release' | sed 's/^/nvcc: /' | tee -a "$MAIN_LOG"
  nvidia-smi --query-gpu=driver_version,name --format=csv,noheader | sed 's/^/GPU: /' | tee -a "$MAIN_LOG"
  git --version | tee -a "$MAIN_LOG"
}

preflight() {
  require_cmd uv
  ensure_project_venv
  [[ -f "$BUILD_CONSTRAINTS_FILE" ]] || die "Build constraints are unavailable: $BUILD_CONSTRAINTS_FILE"
  mkdir -p "$DIST_DIR" "${ROOT_DIR}/.build/manifests"
  require_cmd git
  require_cmd cmake
  require_cmd ninja
  require_cmd gcc
  require_cmd nvcc
  require_cmd nvidia-smi
  [[ -x "$LLVM_CONFIG_PATH" ]] || die "llvm-config is unavailable: $LLVM_CONFIG_PATH"
  [[ -f /usr/include/cudnn_version.h || -f /usr/include/x86_64-linux-gnu/cudnn_version.h ]] || die "cuDNN headers are unavailable"

  configure_paths
  print_environment
  configure_compiler
  configure_ccache
  configure_cuda_architectures
  check_system_dependencies

  if [[ "$CLEAR_PIP_CACHE" == "1" ]]; then
    run_with_log "$MAIN_LOG" "$PYTHON" -m pip cache purge || true
  fi
  if [[ "$INSTALL_BUILD_PYTHON_DEPS" == "1" ]]; then
    run_with_log "$MAIN_LOG" uv pip install --python "$PYTHON" --require-hashes -r "$BUILD_CONSTRAINTS_FILE"
  fi
  "$PYTHON" -m pip --version >/dev/null || die "pip is unavailable in project venv: $PYTHON"
  validate_versions
}

build_triton() {
  section "[1/5] Triton"
  require_source Triton "$TRITON_SOURCE_DIR"
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir triton)"
  run_with_log "$TRITON_BUILD_LOG" "$PYTHON" -m pip uninstall -y triton pytorch-triton || true
  clean_source Triton "$TRITON_SOURCE_DIR"

  (
    cd "$TRITON_SOURCE_DIR"
    export TRITON_HOME="$HOME"
    export TRITON_CACHE_DIR="$TRITON_HOME/.triton/cache"
    export TRITON_CUPTI_INCLUDE_PATH="$CUDA_HOME/include"
    export TRITON_CUPTI_LIB_PATH="$CUDA_HOME/lib64"
    export TRITON_LIBDEVICE_PATH="$CUDA_HOME/nvvm/libdevice"
    export TRITON_LIBCUDA_PATH="$CUDA_HOME/lib64"
    export TRITON_PTXAS_PATH="$CUDA_HOME/bin/ptxas"
    export TRITON_CUOBJDUMP_PATH="$CUDA_HOME/bin/cuobjdump"
    export TRITON_NVDISASM_PATH="$CUDA_HOME/bin/nvdisasm"
    export TRITON_WHEEL_NAME=pytorch-triton
    export TRITON_WHEEL_VERSION_SUFFIX=".post${BUILD_NUMBER}"
    export TRITON_BUILD_WITH_CCACHE=1 TRITON_PARALLEL_LINK_JOBS="$MAX_JOBS"
    export TRITON_OFFLINE_BUILD=1 TRITON_BUILD_PROTON=0 TRITON_BUILD_UT=0
    run_with_log "$TRITON_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir
  )
  stage_and_install_wheel Triton "$wheel_dir" 'pytorch_triton*.whl'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import triton; print('Triton:', triton.__version__)" | tee -a "$MAIN_LOG"
}

build_pytorch() {
  section "[2/5] PyTorch"
  require_source PyTorch "$PYTORCH_SOURCE_DIR"
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir pytorch)"
  run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip uninstall -y torch || true
  clean_source PyTorch "$PYTORCH_SOURCE_DIR"

  (
    cd "$PYTORCH_SOURCE_DIR"
    [[ -f requirements-build.txt ]] && run_with_log "$PYTORCH_BUILD_LOG" uv pip install --python "$PYTHON" --require-hashes -r "$BUILD_CONSTRAINTS_FILE"
    export PYTORCH_BUILD_VERSION PYTORCH_BUILD_NUMBER="$BUILD_NUMBER"
    export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_NCCL=1 USE_CUSPARSELT=1 USE_CUDSS=1
    export USE_CUFILE=1 USE_MKLDNN=1 USE_OPENMP=1 USE_FLASH_ATTENTION=1 USE_MEM_EFF_ATTENTION=1
    export USE_DISTRIBUTED=1 USE_XPU=0 USE_ROCM=0 FORCE_CUDA=1 BUILD_TEST=0
    export CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5
    run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir
  )
  stage_and_install_wheel PyTorch "$wheel_dir" 'torch-*.whl'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torch; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda); assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))" | tee -a "$MAIN_LOG"
}

build_flash_attention() {
  section "[3/5] Flash Attention 4"
  require_directory "Flash Attention 4" "$FLASH_ATTENTION_CUTE_SOURCE_DIR"
  local wheel_dir
  local constraints_dir="${ROOT_DIR}/.build/constraints"
  local constraints_file="${constraints_dir}/local-torch.txt"
  local torch_version

  torch_version="$("$PYTHON" -c 'import torch; print(torch.__version__)')"
  wheel_dir="$(prepare_wheel_dir flash-attention-4)"
  mkdir -p "$constraints_dir"
  printf 'torch==%s\n' "$torch_version" >"$constraints_file"

  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip uninstall -y flash-attn flash-attn-4 || true
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" uv pip install --python "$PYTHON" \
    --constraint "$constraints_file" \
    'nvidia-cutlass-dsl[cu13]==4.6.0.dev0' einops typing_extensions \
    'apache-tvm-ffi>=0.1.12,<0.2' torch-c-dlpack-ext 'quack-kernels>=0.5.3'
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip wheel \
    "$FLASH_ATTENTION_CUTE_SOURCE_DIR" --wheel-dir "$wheel_dir" \
    --no-build-isolation --no-deps

  stage_and_install_wheel "Flash Attention 4" "$wheel_dir" 'flash_attn_4*.whl'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "from flash_attn.cute import flash_attn_func; print('Flash Attention 4 import verified:', flash_attn_func)" | tee -a "$MAIN_LOG"
}

build_vision() {
  section "[4/5] Torchvision"
  require_source Torchvision "$VISION_SOURCE_DIR"
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir vision)"
  run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip uninstall -y torchvision || true
  clean_source Torchvision "$VISION_SOURCE_DIR"

  (
    cd "$VISION_SOURCE_DIR"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip install 'pillow>=10.3.0' 'gdown>=4.7.3' scipy
    [[ -f requirements.txt ]] && run_with_log "$VISION_BUILD_LOG" uv pip install --python "$PYTHON" -r requirements.txt
    export BUILD_VERSION="${VISION_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_XPU=0 USE_ROCM=0
    export USE_GPU_VIDEO_DECODER=1 USE_CPU_VIDEO_DECODER=1
    export TORCHVISION_USE_PNG=1 TORCHVISION_USE_JPEG=1 TORCHVISION_USE_WEBP=1 TORCHVISION_USE_NVJPEG=1
    export FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5
    export TORCHVISION_INCLUDE="${TORCHVISION_INCLUDE:-${NVCODEC_HOME}/include}"
    export TORCHVISION_LIBRARY="${TORCHVISION_LIBRARY:-${NVCODEC_HOME}/lib}"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel Torchvision "$wheel_dir" 'torchvision-*.whl'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchvision; print('Torchvision:', torchvision.__version__); from torchvision.ops import nms" | tee -a "$MAIN_LOG"
}

build_audio() {
  section "[5/5] Torchaudio"
  require_source Torchaudio "$AUDIO_SOURCE_DIR"
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir audio)"
  run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip uninstall -y torchaudio || true
  clean_source Torchaudio "$AUDIO_SOURCE_DIR"

  (
    cd "$AUDIO_SOURCE_DIR"
    [[ -f requirements.txt ]] && run_with_log "$AUDIO_BUILD_LOG" uv pip install --python "$PYTHON" -r requirements.txt
    export BUILD_VERSION="${AUDIO_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_CUDA=1 FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release
    run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel Torchaudio "$wheel_dir" 'torchaudio-*.whl'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchaudio; from torchaudio import _extension; print('Torchaudio:', torchaudio.__version__, 'extension:', _extension._IS_TORCHAUDIO_EXT_AVAILABLE)" | tee -a "$MAIN_LOG"
}

verify_all() {
  [[ "$VERIFY_INSTALL" == "1" ]] || return
  section "Final verification"
  "$PYTHON" - <<'PY'
import sys
from importlib import metadata
from pathlib import Path
import torch
import torchaudio
import torchvision
import triton
import flash_attn.cute as flash_attn_cute
from flash_attn.cute import flash_attn_func


def report_package(label, module, distribution_name):
    distribution = metadata.distribution(distribution_name)
    module_path = Path(module.__file__).resolve()
    environment_root = Path(sys.prefix).resolve()
    assert module_path.is_relative_to(environment_root), (
        f"{label} imported outside the configured venv: {module_path} "
        f"(venv: {environment_root})"
    )
    module_version = getattr(module, "__version__", None)
    if module_version is not None:
        assert module_version == distribution.version, (
            f"{label} module/distribution version mismatch: "
            f"{module_version} != {distribution.version}"
        )
    print(
        f"{label}: version={distribution.version} distribution="
        f"{distribution.metadata['Name']} module={module_path} "
        f"distribution_root={distribution.locate_file('')}"
    )

print("Python:", sys.version)
report_package("Triton", triton, "pytorch-triton")
report_package("PyTorch", torch, "torch")
report_package("Torchvision", torchvision, "torchvision")
report_package("Torchaudio", torchaudio, "torchaudio")
report_package("Flash Attention 4", flash_attn_cute, "flash-attn-4")
print("PyTorch CUDA:", torch.version.cuda)
assert torch.cuda.is_available(), "CUDA not enabled"
assert torch.backends.cudnn.is_available(), "cuDNN extension not compiled"
assert torchvision._HAS_OPS, "Torchvision extension not compiled"
major, minor = torch.cuda.get_device_capability()
expected_arch = f"sm_{major}{minor}"
compiled_arches = torch.cuda.get_arch_list()
assert expected_arch in compiled_arches, (
    f"Current GPU requires native {expected_arch}, but PyTorch contains: "
    f"{compiled_arches}"
)
x = torch.randn(10, 10, device="cuda")
print("CUDA matrix multiplication norm:", (x @ x).norm().item())
boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11]], device="cuda", dtype=torch.float32)
print("Torchvision CUDA NMS:", torchvision.ops.nms(boxes, torch.tensor([0.9, 0.8], device="cuda"), 0.5).tolist())
for dtype in (torch.float16, torch.bfloat16):
    for causal in (False, True):
        q = torch.randn(1, 32, 8, 64, device="cuda", dtype=dtype, requires_grad=True)
        k = torch.randn_like(q, requires_grad=True)
        v = torch.randn_like(q, requires_grad=True)
        output = flash_attn_func(q, k, v, causal=causal)
        assert torch.isfinite(output).all(), f"FA4 produced non-finite {dtype} output"
        reference = torch.nn.functional.scaled_dot_product_attention(
            q.detach().transpose(1, 2),
            k.detach().transpose(1, 2),
            v.detach().transpose(1, 2),
            is_causal=causal,
        ).transpose(1, 2)
        torch.testing.assert_close(output.detach(), reference, rtol=2e-2, atol=2e-2)
        output.square().mean().backward()
        assert all(
            gradient is not None and torch.isfinite(gradient).all()
            for gradient in (q.grad, k.grad, v.grad)
        ), f"FA4 backward failed for {dtype}, causal={causal}"
        print(
            "Flash Attention 4:",
            f"dtype={dtype} causal={causal} shape={tuple(output.shape)} backward=ok",
        )
print("All components verified successfully")
PY
}

main() {
  require_configuration
  preflight
  build_triton
  build_pytorch
  build_flash_attention
  build_vision
  build_audio
  write_provenance "built"
  verify_all
  write_provenance "verified"
  section "Build complete"
  log "Main log: $MAIN_LOG"
  log "Triton log: $TRITON_BUILD_LOG"
  log "PyTorch log: $PYTORCH_BUILD_LOG"
  log "Flash Attention log: $FLASH_ATTENTION_BUILD_LOG"
  log "Torchvision log: $VISION_BUILD_LOG"
  log "Torchaudio log: $AUDIO_BUILD_LOG"
}

main "$@"
