#!/usr/bin/env bash
# Build local PyTorch, Triton, Flash Attention 4, Torchvision, and Torchaudio sources for CUDA.
set -euo pipefail

ROOT_DIR="$(pwd)"

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

die() {
  printf 'ERROR: %s\n' "$*" | tee -a "$MAIN_LOG" >&2
  exit 1
}

require_configuration() {
  local variable
  local -a required_variables=(
    BUILD_NUMBER PYTHON MAX_JOBS USE_CLANG CLEAR_PIP_CACHE CLEAN_BUILD VERIFY_INSTALL
    INSTALL_BUILD_PYTHON_DEPS PYTORCH_SOURCE_DIR VISION_SOURCE_DIR AUDIO_SOURCE_DIR
    TRITON_SOURCE_DIR FLASH_ATTENTION_SOURCE_DIR FLASH_ATTENTION_CUTE_SOURCE_DIR
    FLASH_ATTENTION_WHEEL_DIR CUDA_HOME MAGMA_ROOT OPENMPI_ROOT NVCODEC_HOME
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

install_wheels() {
  local source_dir="$1"
  local package_name="$2"
  shift 2
  local -a wheels=("$source_dir"/dist/*.whl)

  compgen -G "$source_dir/dist/*.whl" >/dev/null || die "[$package_name] no wheel produced in $source_dir/dist"
  run_with_log "$MAIN_LOG" "$PYTHON" -m pip install "$@" "${wheels[@]}"
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
  [[ -x "$PYTHON" ]] || command -v "$PYTHON" >/dev/null 2>&1 || die "Python is unavailable: $PYTHON"
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
    run_with_log "$MAIN_LOG" "$PYTHON" -m pip install -U pip 'setuptools>=75' 'setuptools-scm>=8' wheel pybind11 uv
  fi
}

build_triton() {
  section "[1/5] Triton"
  require_source Triton "$TRITON_SOURCE_DIR"
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
    run_with_log "$TRITON_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir
  )
  install_wheels "$TRITON_SOURCE_DIR" Triton
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import triton; print('Triton:', triton.__version__)" | tee -a "$MAIN_LOG"
}

build_pytorch() {
  section "[2/5] PyTorch"
  require_source PyTorch "$PYTORCH_SOURCE_DIR"
  run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip uninstall -y torch || true
  clean_source PyTorch "$PYTORCH_SOURCE_DIR"

  (
    cd "$PYTORCH_SOURCE_DIR"
    [[ -f requirements-build.txt ]] && run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m uv pip install -r requirements-build.txt
    export PYTORCH_BUILD_VERSION PYTORCH_BUILD_NUMBER="$BUILD_NUMBER"
    export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_NCCL=1 USE_CUSPARSELT=1 USE_CUDSS=1
    export USE_CUFILE=1 USE_MKLDNN=1 USE_OPENMP=1 USE_FLASH_ATTENTION=1 USE_MEM_EFF_ATTENTION=1
    export USE_DISTRIBUTED=1 USE_XPU=0 USE_ROCM=0 FORCE_CUDA=1 BUILD_TEST=0
    export CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5
    run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir
  )
  install_wheels "$PYTORCH_SOURCE_DIR" PyTorch
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torch; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda); assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))" | tee -a "$MAIN_LOG"
}

build_flash_attention() {
  section "[3/5] Flash Attention 4"
  require_directory "Flash Attention 4" "$FLASH_ATTENTION_CUTE_SOURCE_DIR"
  local constraints_dir="${ROOT_DIR}/.build/constraints"
  local constraints_file="${constraints_dir}/local-torch.txt"
  local torch_version

  torch_version="$("$PYTHON" -c 'import torch; print(torch.__version__)')"
  mkdir -p "$FLASH_ATTENTION_WHEEL_DIR" "$constraints_dir"
  printf 'torch==%s\n' "$torch_version" >"$constraints_file"

  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip uninstall -y flash-attn flash-attn-4 || true
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip install -U \
    --constraint "$constraints_file" \
    'nvidia-cutlass-dsl[cu13]==4.6.0.dev0' einops typing_extensions \
    'apache-tvm-ffi>=0.1.12,<0.2' torch-c-dlpack-ext 'quack-kernels>=0.5.3'
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip wheel \
    "$FLASH_ATTENTION_CUTE_SOURCE_DIR" --wheel-dir "$FLASH_ATTENTION_WHEEL_DIR" \
    --no-build-isolation --no-deps

  local -a wheels=("$FLASH_ATTENTION_WHEEL_DIR"/*.whl)
  compgen -G "$FLASH_ATTENTION_WHEEL_DIR/*.whl" >/dev/null || die "[Flash Attention 4] no wheel produced in $FLASH_ATTENTION_WHEEL_DIR"
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip install --no-deps "${wheels[@]}"
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "from flash_attn.cute import flash_attn_func; print('Flash Attention 4 import verified:', flash_attn_func)" | tee -a "$MAIN_LOG"
}

build_vision() {
  section "[4/5] Torchvision"
  require_source Torchvision "$VISION_SOURCE_DIR"
  run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip uninstall -y torchvision || true
  clean_source Torchvision "$VISION_SOURCE_DIR"

  (
    cd "$VISION_SOURCE_DIR"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip install 'pillow>=10.3.0' 'gdown>=4.7.3' scipy
    [[ -f requirements.txt ]] && run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m uv pip install -r requirements.txt
    export BUILD_VERSION="${VISION_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_XPU=0 USE_ROCM=0
    export USE_GPU_VIDEO_DECODER=1 USE_CPU_VIDEO_DECODER=1
    export TORCHVISION_USE_PNG=1 TORCHVISION_USE_JPEG=1 TORCHVISION_USE_WEBP=1 TORCHVISION_USE_NVJPEG=1
    export FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5
    export TORCHVISION_INCLUDE="${TORCHVISION_INCLUDE:-${NVCODEC_HOME}/include}"
    export TORCHVISION_LIBRARY="${TORCHVISION_LIBRARY:-${NVCODEC_HOME}/lib}"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir --no-deps
  )
  install_wheels "$VISION_SOURCE_DIR" Torchvision
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchvision; print('Torchvision:', torchvision.__version__); from torchvision.ops import nms" | tee -a "$MAIN_LOG"
}

build_audio() {
  section "[5/5] Torchaudio"
  require_source Torchaudio "$AUDIO_SOURCE_DIR"
  run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip uninstall -y torchaudio || true
  clean_source Torchaudio "$AUDIO_SOURCE_DIR"

  (
    cd "$AUDIO_SOURCE_DIR"
    [[ -f requirements.txt ]] && run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m uv pip install -r requirements.txt
    export BUILD_VERSION="${AUDIO_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_CUDA=1 FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release
    run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir --no-deps
  )
  install_wheels "$AUDIO_SOURCE_DIR" Torchaudio
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchaudio; print('Torchaudio:', torchaudio.__version__); print(torchaudio.list_audio_backends())" | tee -a "$MAIN_LOG"
}

verify_all() {
  [[ "$VERIFY_INSTALL" == "1" ]] || return
  section "Final verification"
  "$PYTHON" - <<'PY'
import sys
import torch
import torchaudio
import torchvision
import triton
from flash_attn.cute import flash_attn_func

print("Python:", sys.version)
print("Triton:", triton.__version__)
print("PyTorch:", torch.__version__, "CUDA:", torch.version.cuda)
print("Torchvision:", torchvision.__version__)
print("Torchaudio:", torchaudio.__version__)
assert torch.cuda.is_available(), "CUDA not enabled"
assert torch._C._has_cudnn, "cuDNN extension not compiled"
assert torchvision._HAS_OPS, "Torchvision extension not compiled"
x = torch.randn(10, 10, device="cuda")
print("CUDA matrix multiplication norm:", (x @ x).norm().item())
q = torch.randn(1, 128, 8, 64, device="cuda", dtype=torch.float16)
print("Flash Attention 4 output shape:", tuple(flash_attn_func(q, q, q, causal=True).shape))
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
  verify_all
  section "Build complete"
  log "Main log: $MAIN_LOG"
  log "Triton log: $TRITON_BUILD_LOG"
  log "PyTorch log: $PYTORCH_BUILD_LOG"
  log "Flash Attention log: $FLASH_ATTENTION_BUILD_LOG"
  log "Torchvision log: $VISION_BUILD_LOG"
  log "Torchaudio log: $AUDIO_BUILD_LOG"
}

main "$@"
