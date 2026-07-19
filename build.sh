#!/usr/bin/env bash
# Build local PyTorch, Triton, xFormers, Flash Attention 4, SageAttention3, Torchvision, and Torchaudio sources for CUDA.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PATCH_DIR="${ROOT_DIR}/patches"
readonly TRITON_DISTRIBUTION_NAME="pytorch-triton"
readonly FA4_DISTRIBUTION_NAME="flash-attn-4"
readonly XFORMERS_DISTRIBUTION_NAME="xformers"
readonly SAGEATTENTION3_DISTRIBUTION_NAME="sageattn3"
export TRITON_DISTRIBUTION_NAME FA4_DISTRIBUTION_NAME XFORMERS_DISTRIBUTION_NAME SAGEATTENTION3_DISTRIBUTION_NAME

# Required local configuration. Keep this trusted shell-compatible KEY=VALUE file local.
readonly ENV_FILE="${ROOT_DIR}/.env"
[[ -f "${ENV_FILE}" ]] || {
  printf 'ERROR: local build configuration is unavailable: %s\n' "${ENV_FILE}" >&2
  exit 1
}
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

MAIN_LOG="${ROOT_DIR}/${MAIN_LOG_FILE:-alltorch_build.log}"
TRITON_BUILD_LOG="${ROOT_DIR}/${TRITON_BUILD_LOG_FILE:-triton_build.log}"
PYTORCH_BUILD_LOG="${ROOT_DIR}/${PYTORCH_BUILD_LOG_FILE:-pytorch_build.log}"
XFORMERS_BUILD_LOG="${ROOT_DIR}/${XFORMERS_BUILD_LOG_FILE:-xformers_build.log}"
FLASH_ATTENTION_BUILD_LOG="${ROOT_DIR}/${FLASH_ATTENTION_BUILD_LOG_FILE:-flash_attention_build.log}"
SAGEATTENTION3_BUILD_LOG="${ROOT_DIR}/${SAGEATTENTION3_BUILD_LOG_FILE:-sageattention3_build.log}"
VISION_BUILD_LOG="${ROOT_DIR}/${VISION_BUILD_LOG_FILE:-vision_build.log}"
AUDIO_BUILD_LOG="${ROOT_DIR}/${AUDIO_BUILD_LOG_FILE:-audio_build.log}"

CURRENT_STAGE="initialization"
LOGS_INITIALIZED=0
APPLIED_SUBMODULE_PATCHES=()
BUILD_CHAIN_KEY=""
COMPONENT_BUILD_KEY=""

cleanup_submodule_patches() {
  local entry
  local source_dir
  local patch_file

  for entry in "${APPLIED_SUBMODULE_PATCHES[@]}"; do
    IFS=$'\t' read -r source_dir patch_file <<<"$entry"
    if ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null \
      || ! git -C "$source_dir" apply --reverse "$patch_file"; then
      printf 'WARNING: could not remove build-time patch: %s\n' "$patch_file" >&2
    fi
  done
}

on_exit() {
  local exit_code="$?"
  trap - EXIT
  cleanup_submodule_patches
  exit "$exit_code"
}

on_error() {
  local exit_code="$1"
  local line_number="$2"
  local command="$3"
  trap - ERR
  write_provenance "failed"
  if ((LOGS_INITIALIZED)); then
    printf 'ERROR: stage=%s line=%s exit=%s command=%q\n' "$CURRENT_STAGE" "$line_number" "$exit_code" "$command" | tee -a "$MAIN_LOG" >&2
    printf 'Logs: main=%s triton=%s pytorch=%s xformers=%s flash-attention=%s sageattention3=%s vision=%s audio=%s\n' \
      "$MAIN_LOG" "$TRITON_BUILD_LOG" "$PYTORCH_BUILD_LOG" "$XFORMERS_BUILD_LOG" "$FLASH_ATTENTION_BUILD_LOG" "$SAGEATTENTION3_BUILD_LOG" "$VISION_BUILD_LOG" "$AUDIO_BUILD_LOG" | tee -a "$MAIN_LOG" >&2
  else
    printf 'ERROR: stage=%s line=%s exit=%s command=%q\n' "$CURRENT_STAGE" "$line_number" "$exit_code" "$command" >&2
  fi
  exit "$exit_code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

die() {
  if ((LOGS_INITIALIZED)); then
    printf 'ERROR: %s\n' "$*" | tee -a "$MAIN_LOG" >&2
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

initialize_logs() {
  local log_file
  for log_file in "$MAIN_LOG" "$TRITON_BUILD_LOG" "$PYTORCH_BUILD_LOG" "$XFORMERS_BUILD_LOG" "$FLASH_ATTENTION_BUILD_LOG" "$SAGEATTENTION3_BUILD_LOG" "$VISION_BUILD_LOG" "$AUDIO_BUILD_LOG"; do
    : >"$log_file"
  done
  LOGS_INITIALIZED=1
}

require_configuration() {
  local variable
  local -a required_variables=(
    BUILD_NUMBER VENV_DIR PYTHON PYTHON_VERSION BUILD_CONSTRAINTS_FILE DIST_DIR MAX_JOBS USE_CLANG USE_CCACHE CLEAR_PIP_CACHE CLEAN_BUILD VERIFY_INSTALL
    INSTALL_BUILD_PYTHON_DEPS PYTORCH_SOURCE_DIR VISION_SOURCE_DIR AUDIO_SOURCE_DIR
    TRITON_SOURCE_DIR XFORMERS_SOURCE_DIR FLASH_ATTENTION_SOURCE_DIR FLASH_ATTENTION_CUTE_SOURCE_DIR SAGEATTENTION_SOURCE_DIR SAGEATTENTION3_SOURCE_DIR
    CUDA_HOME MAGMA_ROOT OPENMPI_ROOT NVCODEC_HOME
    LLVM_CONFIG_PATH PYTORCH_BUILD_VERSION VISION_BUILD_VERSION
    AUDIO_BUILD_VERSION
    MAIN_LOG_FILE TRITON_BUILD_LOG_FILE PYTORCH_BUILD_LOG_FILE XFORMERS_BUILD_LOG_FILE FLASH_ATTENTION_BUILD_LOG_FILE SAGEATTENTION3_BUILD_LOG_FILE VISION_BUILD_LOG_FILE AUDIO_BUILD_LOG_FILE
    BUILD_PKG_CONFIG_PREFIX GCC_COMMAND GXX_COMMAND CLANG_COMMAND CLANGXX_COMMAND CMAKE_COMMAND NINJA_COMMAND NVCC_COMMAND NVIDIA_SMI_COMMAND CCACHE_COMMAND
    TRITON_HOME TRITON_CACHE_DIR TRITON_CUPTI_INCLUDE_PATH TRITON_CUPTI_LIB_PATH TRITON_LIBDEVICE_PATH TRITON_LIBCUDA_PATH
    TRITON_PTXAS_PATH TRITON_CUOBJDUMP_PATH TRITON_NVDISASM_PATH TRITON_WHEEL_NAME TRITON_WHEEL_VERSION_SUFFIX
    TRITON_BUILD_WITH_CCACHE TRITON_PARALLEL_LINK_JOBS TRITON_OFFLINE_BUILD TRITON_BUILD_PROTON TRITON_BUILD_UT
    XDG_CACHE_HOME UV_CACHE_DIR PIP_CACHE_DIR TMPDIR PYTHONPYCACHEPREFIX TORCH_EXTENSIONS_DIR
    PYTORCH_USE_NATIVE_ARCH PYTORCH_USE_CUDA PYTORCH_USE_CUDNN PYTORCH_USE_NCCL PYTORCH_USE_CUSPARSELT PYTORCH_CUSPARSELT_INCLUDE_DIR PYTORCH_CUSPARSELT_LIBRARY
    PYTORCH_USE_CUDSS
    PYTORCH_USE_CUFILE PYTORCH_USE_MKLDNN PYTORCH_USE_OPENMP PYTORCH_USE_FLASH_ATTENTION PYTORCH_USE_MEM_EFF_ATTENTION
    PYTORCH_USE_DISTRIBUTED PYTORCH_USE_XPU PYTORCH_USE_ROCM PYTORCH_FORCE_CUDA PYTORCH_BUILD_TEST PYTORCH_CMAKE_BUILD_TYPE PYTORCH_CMAKE_POLICY_VERSION_MINIMUM
    FLASH_ATTENTION_CUTLASS_DSL_REQUIREMENT FLASH_ATTENTION_EINOPS_REQUIREMENT FLASH_ATTENTION_TYPING_EXTENSIONS_REQUIREMENT
    FLASH_ATTENTION_TVM_FFI_REQUIREMENT FLASH_ATTENTION_TORCH_C_DLPACK_REQUIREMENT FLASH_ATTENTION_QUACK_KERNELS_REQUIREMENT
    SAGEATTENTION3_EXT_PARALLEL
    XFORMERS_BUILD_TYPE XFORMERS_ENABLE_DEBUG_ASSERTIONS XFORMERS_ENABLE_TRITON XFORMERS_FORCE_DISABLE_TRITON
    VISION_PILLOW_REQUIREMENT VISION_GDOWN_REQUIREMENT VISION_SCIPY_REQUIREMENT VISION_USE_NATIVE_ARCH VISION_USE_CUDA VISION_USE_CUDNN VISION_USE_XPU VISION_USE_ROCM
    VISION_USE_GPU_VIDEO_DECODER VISION_USE_CPU_VIDEO_DECODER VISION_USE_PNG VISION_USE_JPEG VISION_USE_WEBP VISION_USE_NVJPEG
    VISION_FORCE_CUDA VISION_BUILD_TEST VISION_CMAKE_BUILD_TYPE VISION_CMAKE_POLICY_VERSION_MINIMUM VISION_INCLUDE VISION_LIBRARY
    AUDIO_USE_CUDA AUDIO_FORCE_CUDA AUDIO_BUILD_TEST AUDIO_CMAKE_BUILD_TYPE
    VERIFY_FA4_DTYPES VERIFY_FA4_BATCH_SIZE VERIFY_FA4_SEQUENCE_LENGTH VERIFY_FA4_HEADS VERIFY_FA4_HEAD_DIM VERIFY_FA4_ALLOWED_HEAD_DIMS
    VERIFY_FA4_MAX_TENSOR_ELEMENTS VERIFY_FA4_RTOL VERIFY_FA4_ATOL
  )

  for variable in "${required_variables[@]}"; do
    [[ -n "${!variable:-}" ]] || die "Missing required configuration in $ENV_FILE: $variable"
  done
}

reject_python_environment_overrides() {
  local variable
  local -a blocked_variables=(
    PYTHONHOME PYTHONPATH PYTHONUSERBASE PIP_PREFIX PIP_TARGET PIP_USER UV_SYSTEM_PYTHON
  )

  for variable in "${blocked_variables[@]}"; do
    [[ -z "${!variable:-}" ]] || die "$variable must be unset to preserve the project venv boundary"
  done
}

configure_project_local_paths() {
  local build_root
  local path_name
  local path_value
  local resolved_path
  local -a project_local_paths=(
    TRITON_HOME TRITON_CACHE_DIR XDG_CACHE_HOME UV_CACHE_DIR PIP_CACHE_DIR TMPDIR PYTHONPYCACHEPREFIX TORCH_EXTENSIONS_DIR
  )

  build_root="$(realpath -m -- "${ROOT_DIR}/.build")"
  for path_name in "${project_local_paths[@]}"; do
    path_value="${!path_name}"
    resolved_path="$(realpath -m -- "$path_value")"
    case "$resolved_path" in
      "$build_root"/*) ;;
      *) die "$path_name escapes the project build directory: $resolved_path" ;;
    esac
    printf -v "$path_name" '%s' "$resolved_path"
    export "$path_name"
  done

  [[ "$(realpath -m -- "$VENV_DIR")" == "$(realpath -m -- "${ROOT_DIR}/.venv")" ]] \
    || die "VENV_DIR must be the project venv: ${ROOT_DIR}/.venv"
  [[ "$(realpath -m -- "$PYTHON")" == "$(realpath -m -- "${VENV_DIR}/bin/python")" ]] \
    || die "PYTHON must be the interpreter in VENV_DIR: ${VENV_DIR}/bin/python"
  [[ -z "${LLVM_SYSPATH:-}" ]] || die "LLVM_SYSPATH must be unset so Triton can obtain its pinned LLVM"
  [[ "$TRITON_OFFLINE_BUILD" == "0" ]] || die "TRITON_OFFLINE_BUILD must be 0 when Triton downloads its pinned LLVM"
  mkdir -p "$TRITON_HOME" "$TRITON_CACHE_DIR" "$XDG_CACHE_HOME" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$TMPDIR" "$PYTHONPYCACHEPREFIX" "$TORCH_EXTENSIONS_DIR"
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

apply_submodule_patch() {
  local name="$1"
  local source_dir="$2"
  local patch_file="$3"

  [[ -f "$patch_file" ]] || die "[$name] required patch is unavailable: $patch_file"
  if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    log "[$name] applying $(basename "$patch_file")"
    git -C "$source_dir" apply "$patch_file"
    APPLIED_SUBMODULE_PATCHES=("$source_dir"$'\t'"$patch_file" "${APPLIED_SUBMODULE_PATCHES[@]}")
  elif git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    log "[$name] patch is already applied: $(basename "$patch_file")"
  else
    die "[$name] patch does not match the checked-out source: $patch_file"
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
  local distribution_name="$4"
  local -a wheels=("$wheel_dir"/$wheel_pattern)
  local wheel_metadata

  compgen -G "$wheel_dir/$wheel_pattern" >/dev/null || die "[$package_name] no wheel produced in $wheel_dir"
  ((${#wheels[@]} == 1)) || die "[$package_name] ambiguous wheel selection in $wheel_dir: $wheel_pattern"
  wheel_metadata="$("$PYTHON" "$ROOT_DIR/scripts/validate_wheel_metadata.py" "${wheels[0]}" "$distribution_name")" \
    || die "[$package_name] wheel metadata validation failed"
  printf '%s\t%s\t%s\n' "$package_name" "$wheel_metadata" "$(basename "${wheels[0]}")" >>"${ROOT_DIR}/.build/manifests/wheels.tsv"
  cp -f -- "${wheels[0]}" "$DIST_DIR/"
  [[ -f "$DIST_DIR/$(basename "${wheels[0]}")" ]] || die "[$package_name] wheel was not retained in $DIST_DIR"
  # Reinstall even at an unchanged version so validation cannot reuse an older wheel.
  run_with_log "$MAIN_LOG" "$PYTHON" -m pip --isolated install --force-reinstall --no-deps "${wheels[0]}"
}

component_build_key() {
  local component="$1"
  local source_dir="$2"
  local component_config="$3"
  local source_state
  local nvcc_version
  local cc_version
  local cxx_version

  source_state="$(git -C "$source_dir" rev-parse HEAD; git -C "$source_dir" submodule status --recursive 2>/dev/null || true)"
  nvcc_version="$("$NVCC_COMMAND" --version | tr '\n' ' ')"
  cc_version="$("$CC" --version | sed -n '1p')"
  cxx_version="$("$CXX" --version | sed -n '1p')"
  printf '%s\0' "component=${component}" "source_state=${source_state}" "upstream=${BUILD_CHAIN_KEY}" \
    "python=$($PYTHON --version 2>&1)" "nvcc=${nvcc_version}" "cc=${cc_version}" "cxx=${cxx_version}" \
    "cuda_arches=${TORCH_CUDA_ARCH_LIST}" "config=${component_config}" | sha256sum | awk '{print $1}'
}

component_cache_hit() {
  local component="$1"
  local source_dir="$2"
  local component_config="$3"
  local verification_code="$4"
  local stamp_file="${ROOT_DIR}/.build/manifests/${component}-build.key"

  COMPONENT_BUILD_KEY="$(component_build_key "$component" "$source_dir" "$component_config")"
  if [[ -f "$stamp_file" && "$(<"$stamp_file")" == "$COMPONENT_BUILD_KEY" ]] \
    && "$PYTHON" -c "$verification_code" >/dev/null 2>&1; then
    BUILD_CHAIN_KEY="$COMPONENT_BUILD_KEY"
    log "[${component}] source and upstream build inputs are unchanged; skipping rebuild"
    return 0
  fi
  return 1
}

component_build_complete() {
  local component="$1"
  local verification_code="$2"
  local stamp_file="${ROOT_DIR}/.build/manifests/${component}-build.key"

  "$PYTHON" -c "$verification_code" >/dev/null || die "[${component}] installation verification failed"
  printf '%s\n' "$COMPONENT_BUILD_KEY" >"$stamp_file"
  BUILD_CHAIN_KEY="$COMPONENT_BUILD_KEY"
}

write_runtime_requirements() {
  local requirements_file="${DIST_DIR}/requirements-runtime.txt"

  section "Runtime requirements"
  run_with_log "$MAIN_LOG" "$PYTHON" "$ROOT_DIR/scripts/write_runtime_requirements.py" "$requirements_file"
  [[ -s "$requirements_file" ]] || die "Runtime requirements were not written: $requirements_file"
}

ensure_project_venv() {
  if [[ ! -x "$PYTHON" ]]; then
    [[ ! -e "$VENV_DIR" ]] || die "Project venv is incomplete: $VENV_DIR"
    require_cmd uv
    uv venv --python "$PYTHON_VERSION" "$VENV_DIR" | tee -a "$MAIN_LOG"
  fi

  "$PYTHON" "$ROOT_DIR/scripts/validate_venv.py" || die "Configured Python is not an isolated virtual environment: $PYTHON"
}

validate_versions() {
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be a non-negative integer"
  local variable
  for variable in MAX_JOBS VERIFY_FA4_BATCH_SIZE VERIFY_FA4_SEQUENCE_LENGTH VERIFY_FA4_HEADS VERIFY_FA4_HEAD_DIM VERIFY_FA4_MAX_TENSOR_ELEMENTS; do
    [[ "${!variable}" =~ ^[1-9][0-9]*$ ]] || die "$variable must be a positive integer"
  done
  "$PYTHON" "$ROOT_DIR/scripts/validate_build_config.py" || die "Configured build validation is invalid"
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
    "$NVCC_COMMAND" --version 2>/dev/null | grep 'release' | sed 's/^/nvcc=/' || true
    printf 'cc=%s\n' "${CC:-unavailable}"
    printf 'cxx=%s\n' "${CXX:-unavailable}"
    printf 'torch_cuda_arch_list=%s\n' "${TORCH_CUDA_ARCH_LIST:-unavailable}"
    if [[ -d "$DIST_DIR" ]]; then
      find "$DIST_DIR" -maxdepth 1 -type f -name '*.whl' -print0 | sort -z | xargs -0r sha256sum
    fi
    if [[ -d "$PATCH_DIR" ]]; then
      find "$PATCH_DIR" -type f -name '*.patch' -print0 | sort -z | xargs -0r sha256sum | sed 's|  |  patch=|'
    fi
  } >"${manifest_dir}/build-provenance.txt"
}

configure_paths() {
  export PKG_CONFIG_PATH="${BUILD_PKG_CONFIG_PREFIX}:${PKG_CONFIG_PATH:-}"
  export PATH="${CUDA_HOME}/bin:${OPENMPI_ROOT}/bin:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${MAGMA_ROOT}/lib:${OPENMPI_ROOT}/lib:${NVCODEC_HOME}/lib:${LD_LIBRARY_PATH:-}"
}

configure_compiler() {
  if [[ "$USE_CLANG" == "1" ]]; then
    require_cmd "$CLANG_COMMAND"
    require_cmd "$CLANGXX_COMMAND"
    export CC="$CLANG_COMMAND" CXX="$CLANGXX_COMMAND"
    log "Using $CLANG_COMMAND"
  else
    require_cmd "$GCC_COMMAND"
    require_cmd "$GXX_COMMAND"
    export CC="$GCC_COMMAND" CXX="$GXX_COMMAND"
    log "Using $GCC_COMMAND"
  fi
}

configure_ccache() {
  [[ "$USE_CCACHE" == "1" ]] || {
    log "ccache disabled (USE_CCACHE=$USE_CCACHE)"
    return
  }
  if ! command -v "$CCACHE_COMMAND" >/dev/null 2>&1; then
    log "ccache not found; continuing without compiler cache"
    return
  fi

  export CMAKE_C_COMPILER_LAUNCHER="$CCACHE_COMMAND"
  export CMAKE_CXX_COMPILER_LAUNCHER="$CCACHE_COMMAND"
  export CMAKE_CUDA_COMPILER_LAUNCHER="$CCACHE_COMMAND"
  "$CCACHE_COMMAND" -z
  log "Enabled ccache"
}

configure_cuda_architectures() {
  local -a compute_caps=()
  mapfile -t compute_caps < <("$NVIDIA_SMI_COMMAND" --query-gpu=compute_cap --format=csv,noheader,nounits | sort -u)
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
    cudnn9-cuda-13 cudss nvshmem libnccl-dev cutensor-cuda-13 cusparselt-cuda-13
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
  "$GCC_COMMAND" -dumpfullversion -dumpversion | sed 's/^/GCC: /' | tee -a "$MAIN_LOG"
  "$CLANG_COMMAND" --version | head -n1 | sed 's/^/Clang: /' | tee -a "$MAIN_LOG"
  "$CMAKE_COMMAND" --version | head -n1 | sed 's/^/CMake: /' | tee -a "$MAIN_LOG"
  "$NINJA_COMMAND" --version | sed 's/^/Ninja: /' | tee -a "$MAIN_LOG"
  "$NVCC_COMMAND" --version | grep 'release' | sed 's/^/nvcc: /' | tee -a "$MAIN_LOG"
  "$NVIDIA_SMI_COMMAND" --query-gpu=driver_version,name --format=csv,noheader | sed 's/^/GPU: /' | tee -a "$MAIN_LOG"
  git --version | tee -a "$MAIN_LOG"
}

preflight() {
  require_cmd uv
  ensure_project_venv
  [[ -f "$BUILD_CONSTRAINTS_FILE" ]] || die "Build constraints are unavailable: $BUILD_CONSTRAINTS_FILE"
  mkdir -p "$DIST_DIR" "${ROOT_DIR}/.build/manifests"
  : >"${ROOT_DIR}/.build/manifests/wheels.tsv"
  require_cmd git
  require_cmd tar
  require_cmd "$CMAKE_COMMAND"
  require_cmd "$NINJA_COMMAND"
  require_cmd "$GCC_COMMAND"
  require_cmd "$GXX_COMMAND"
  require_cmd "$NVCC_COMMAND"
  require_cmd "$NVIDIA_SMI_COMMAND"
  [[ -x "$LLVM_CONFIG_PATH" ]] || die "llvm-config is unavailable: $LLVM_CONFIG_PATH"
  [[ -f /usr/include/cudnn_version.h || -f /usr/include/x86_64-linux-gnu/cudnn_version.h ]] || die "cuDNN headers are unavailable"

  configure_paths
  print_environment
  configure_compiler
  configure_ccache
  configure_cuda_architectures
  check_system_dependencies

  if [[ "$CLEAR_PIP_CACHE" == "1" ]]; then
    run_with_log "$MAIN_LOG" "$PYTHON" -m pip --isolated cache purge || true
  fi
  if [[ "$INSTALL_BUILD_PYTHON_DEPS" == "1" ]]; then
    run_with_log "$MAIN_LOG" uv pip install --python "$PYTHON" --require-hashes -r "$BUILD_CONSTRAINTS_FILE"
  fi
  "$PYTHON" -m pip --version >/dev/null || die "pip is unavailable in project venv: $PYTHON"
  validate_versions
}

build_triton() {
  section "[1/7] Triton"
  require_source Triton "$TRITON_SOURCE_DIR"
  if component_cache_hit triton "$TRITON_SOURCE_DIR" \
    "$TRITON_WHEEL_NAME|$TRITON_WHEEL_VERSION_SUFFIX|$TRITON_BUILD_WITH_CCACHE|$TRITON_PARALLEL_LINK_JOBS|$TRITON_BUILD_PROTON|$TRITON_BUILD_UT" \
    'import triton'; then
    return
  fi
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir triton)"
  run_with_log "$TRITON_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y triton pytorch-triton || true
  clean_source Triton "$TRITON_SOURCE_DIR"
  apply_submodule_patch Triton "$TRITON_SOURCE_DIR" "$PATCH_DIR/triton/ignore-generated-wheel-metadata.patch"

  (
    cd "$TRITON_SOURCE_DIR"
    export TRITON_HOME TRITON_CACHE_DIR TRITON_CUPTI_INCLUDE_PATH TRITON_CUPTI_LIB_PATH
    export TRITON_LIBDEVICE_PATH TRITON_LIBCUDA_PATH TRITON_PTXAS_PATH TRITON_CUOBJDUMP_PATH TRITON_NVDISASM_PATH
    export TRITON_WHEEL_NAME TRITON_WHEEL_VERSION_SUFFIX TRITON_BUILD_WITH_CCACHE TRITON_PARALLEL_LINK_JOBS
    export TRITON_OFFLINE_BUILD TRITON_BUILD_PROTON TRITON_BUILD_UT
    export TRITON_APPEND_CMAKE_ARGS="-DTRITON_BUILD_UT=${TRITON_BUILD_UT}"
    run_with_log "$TRITON_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir
  )
  stage_and_install_wheel Triton "$wheel_dir" 'pytorch_triton*.whl' "$TRITON_DISTRIBUTION_NAME"
  component_build_complete triton 'import triton'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import triton; print('Triton:', triton.__version__)" | tee -a "$MAIN_LOG"
}

build_pytorch() {
  section "[2/7] PyTorch"
  require_source PyTorch "$PYTORCH_SOURCE_DIR"
  if component_cache_hit pytorch "$PYTORCH_SOURCE_DIR" \
    "$BUILD_NUMBER|$PYTORCH_BUILD_VERSION|$PYTORCH_USE_NATIVE_ARCH|$PYTORCH_USE_CUDA|$PYTORCH_USE_CUDNN|$PYTORCH_USE_NCCL|$PYTORCH_USE_CUSPARSELT|$PYTORCH_USE_CUDSS|$PYTORCH_USE_CUFILE|$PYTORCH_USE_MKLDNN|$PYTORCH_USE_OPENMP|$PYTORCH_USE_FLASH_ATTENTION|$PYTORCH_USE_MEM_EFF_ATTENTION|$PYTORCH_USE_DISTRIBUTED|$PYTORCH_CMAKE_BUILD_TYPE" \
    'import torch; torch.cuda.is_available() or exit(1)'; then
    return
  fi
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir pytorch)"
  run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y torch || true
  clean_source PyTorch "$PYTORCH_SOURCE_DIR"
  apply_submodule_patch PyTorch "$PYTORCH_SOURCE_DIR" "$PATCH_DIR/pytorch/cuda-13-clang21-compat.patch"
  if [[ "$PYTORCH_USE_CUDSS" == "1" ]]; then
    apply_submodule_patch PyTorch "$PYTORCH_SOURCE_DIR" "$PATCH_DIR/pytorch/cudss-0.8-api-compat.patch"
  fi

  (
    cd "$PYTORCH_SOURCE_DIR"
    [[ -f requirements-build.txt ]] && run_with_log "$PYTORCH_BUILD_LOG" uv pip install --python "$PYTHON" --require-hashes -r "$BUILD_CONSTRAINTS_FILE"
    export PYTORCH_BUILD_VERSION PYTORCH_BUILD_NUMBER="$BUILD_NUMBER"
    export USE_NATIVE_ARCH="$PYTORCH_USE_NATIVE_ARCH" USE_CUDA="$PYTORCH_USE_CUDA" USE_CUDNN="$PYTORCH_USE_CUDNN"
    export USE_NCCL="$PYTORCH_USE_NCCL" USE_CUSPARSELT="$PYTORCH_USE_CUSPARSELT" USE_CUDSS="$PYTORCH_USE_CUDSS"
    export CUSPARSELT_INCLUDE_DIR="$PYTORCH_CUSPARSELT_INCLUDE_DIR" CUSPARSELT_LIBRARY="$PYTORCH_CUSPARSELT_LIBRARY"
    export USE_CUFILE="$PYTORCH_USE_CUFILE" USE_MKLDNN="$PYTORCH_USE_MKLDNN" USE_OPENMP="$PYTORCH_USE_OPENMP"
    export USE_FLASH_ATTENTION="$PYTORCH_USE_FLASH_ATTENTION" USE_MEM_EFF_ATTENTION="$PYTORCH_USE_MEM_EFF_ATTENTION"
    export USE_DISTRIBUTED="$PYTORCH_USE_DISTRIBUTED" USE_XPU="$PYTORCH_USE_XPU" USE_ROCM="$PYTORCH_USE_ROCM"
    export FORCE_CUDA="$PYTORCH_FORCE_CUDA" BUILD_TEST="$PYTORCH_BUILD_TEST"
    export CMAKE_BUILD_TYPE="$PYTORCH_CMAKE_BUILD_TYPE" CMAKE_POLICY_VERSION_MINIMUM="$PYTORCH_CMAKE_POLICY_VERSION_MINIMUM"
    run_with_log "$PYTORCH_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir
  )
  stage_and_install_wheel PyTorch "$wheel_dir" 'torch-*.whl' torch
  component_build_complete pytorch 'import torch; torch.cuda.is_available() or exit(1)'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torch; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda); torch.cuda.is_available() or exit('CUDA not enabled'); print(torch.cuda.get_device_name(0))" | tee -a "$MAIN_LOG"
}

build_xformers() {
  section "[3/7] xFormers"
  require_source xFormers "$XFORMERS_SOURCE_DIR"
  require_directory "xFormers CUTLASS" "$XFORMERS_SOURCE_DIR/third_party/cutlass/include"
  if component_cache_hit xformers "$XFORMERS_SOURCE_DIR" \
    "$PYTORCH_FORCE_CUDA|$XFORMERS_BUILD_TYPE|$XFORMERS_ENABLE_DEBUG_ASSERTIONS|$XFORMERS_ENABLE_TRITON|$XFORMERS_FORCE_DISABLE_TRITON" \
    'import xformers'; then
    return
  fi
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir xformers)"
  run_with_log "$XFORMERS_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y xformers || true
  clean_source xFormers "$XFORMERS_SOURCE_DIR"
  apply_submodule_patch xFormers "$XFORMERS_SOURCE_DIR" "$PATCH_DIR/xformers/fa4-namespace-compat.patch"

  (
    cd "$XFORMERS_SOURCE_DIR"
    export FORCE_CUDA="$PYTORCH_FORCE_CUDA" MAX_JOBS
    export XFORMERS_BUILD_TYPE XFORMERS_ENABLE_DEBUG_ASSERTIONS XFORMERS_ENABLE_TRITON XFORMERS_FORCE_DISABLE_TRITON
    run_with_log "$XFORMERS_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel xFormers "$wheel_dir" 'xformers-*.whl' "$XFORMERS_DISTRIBUTION_NAME"
  component_build_complete xformers 'import xformers'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import xformers; print('xFormers:', xformers.__version__)" | tee -a "$MAIN_LOG"
}

build_flash_attention() {
  section "[4/7] Flash Attention 4"
  require_directory "Flash Attention 4" "$FLASH_ATTENTION_CUTE_SOURCE_DIR"
  if component_cache_hit flash-attention-4 "$FLASH_ATTENTION_SOURCE_DIR" \
    "$FLASH_ATTENTION_CUTLASS_DSL_REQUIREMENT|$FLASH_ATTENTION_EINOPS_REQUIREMENT|$FLASH_ATTENTION_TYPING_EXTENSIONS_REQUIREMENT|$FLASH_ATTENTION_TVM_FFI_REQUIREMENT|$FLASH_ATTENTION_TORCH_C_DLPACK_REQUIREMENT|$FLASH_ATTENTION_QUACK_KERNELS_REQUIREMENT" \
    'from flash_attn.cute import flash_attn_func'; then
    return
  fi
  local wheel_dir
  local constraints_dir="${ROOT_DIR}/.build/constraints"
  local constraints_file="${constraints_dir}/local-torch.txt"
  local torch_version

  torch_version="$("$PYTHON" -c 'import torch; print(torch.__version__)')"
  wheel_dir="$(prepare_wheel_dir flash-attention-4)"
  mkdir -p "$constraints_dir"
  printf 'torch==%s\n' "$torch_version" >"$constraints_file"

  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y flash-attn flash-attn-4 || true
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" uv pip install --python "$PYTHON" \
    --prerelease=allow \
    --constraint "$constraints_file" \
    "$FLASH_ATTENTION_CUTLASS_DSL_REQUIREMENT" "$FLASH_ATTENTION_EINOPS_REQUIREMENT" "$FLASH_ATTENTION_TYPING_EXTENSIONS_REQUIREMENT" \
    "$FLASH_ATTENTION_TVM_FFI_REQUIREMENT" "$FLASH_ATTENTION_TORCH_C_DLPACK_REQUIREMENT" "$FLASH_ATTENTION_QUACK_KERNELS_REQUIREMENT"
  run_with_log "$FLASH_ATTENTION_BUILD_LOG" "$PYTHON" -m pip --isolated wheel \
    "$FLASH_ATTENTION_CUTE_SOURCE_DIR" --wheel-dir "$wheel_dir" \
    --no-build-isolation --no-deps

  stage_and_install_wheel "Flash Attention 4" "$wheel_dir" 'flash_attn_4*.whl' "$FA4_DISTRIBUTION_NAME"
  component_build_complete flash-attention-4 'from flash_attn.cute import flash_attn_func'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "from flash_attn.cute import flash_attn_func; print('Flash Attention 4 import verified:', flash_attn_func)" | tee -a "$MAIN_LOG"
}

prepare_sageattention3_source() {
  local staging_dir="${ROOT_DIR}/.build/sources/sageattention3"

  rm -rf -- "$staging_dir"
  mkdir -p "$staging_dir"
  git -C "$SAGEATTENTION_SOURCE_DIR" archive --format=tar HEAD:sageattention3_blackwell | tar -x -C "$staging_dir"
  printf '%s\n' "$staging_dir"
}

build_sageattention3() {
  section "[5/7] SageAttention3 (Blackwell)"
  require_source SageAttention3 "$SAGEATTENTION3_SOURCE_DIR"
  if component_cache_hit sageattention3 "$SAGEATTENTION_SOURCE_DIR" "$SAGEATTENTION3_EXT_PARALLEL" \
    'from sageattn3 import sageattn3_blackwell'; then
    return
  fi
  local wheel_dir
  local staging_dir

  wheel_dir="$(prepare_wheel_dir sageattention3)"
  staging_dir="$(prepare_sageattention3_source)"
  run_with_log "$SAGEATTENTION3_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y "$SAGEATTENTION3_DISTRIBUTION_NAME" || true
  (
    cd "$staging_dir"
    export MAX_JOBS="$SAGEATTENTION3_EXT_PARALLEL"
    run_with_log "$SAGEATTENTION3_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel SageAttention3 "$wheel_dir" 'sageattn3-*.whl' "$SAGEATTENTION3_DISTRIBUTION_NAME"
  component_build_complete sageattention3 'from sageattn3 import sageattn3_blackwell'
  "$PYTHON" -c 'from sageattn3 import sageattn3_blackwell; print("SageAttention3:", sageattn3_blackwell)' | tee -a "$MAIN_LOG"
}

build_vision() {
  section "[6/7] Torchvision"
  require_source Torchvision "$VISION_SOURCE_DIR"
  if component_cache_hit vision "$VISION_SOURCE_DIR" \
    "$BUILD_NUMBER|$VISION_BUILD_VERSION|$VISION_PILLOW_REQUIREMENT|$VISION_GDOWN_REQUIREMENT|$VISION_SCIPY_REQUIREMENT|$VISION_USE_NATIVE_ARCH|$VISION_USE_CUDA|$VISION_USE_CUDNN|$VISION_USE_GPU_VIDEO_DECODER|$VISION_USE_CPU_VIDEO_DECODER|$VISION_USE_PNG|$VISION_USE_JPEG|$VISION_USE_WEBP|$VISION_USE_NVJPEG|$VISION_FORCE_CUDA|$VISION_CMAKE_BUILD_TYPE" \
    'import torchvision; from torchvision.ops import nms'; then
    return
  fi
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir vision)"
  run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y torchvision || true
  clean_source Torchvision "$VISION_SOURCE_DIR"

  (
    cd "$VISION_SOURCE_DIR"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip --isolated install "$VISION_PILLOW_REQUIREMENT" "$VISION_GDOWN_REQUIREMENT" "$VISION_SCIPY_REQUIREMENT"
    [[ -f requirements.txt ]] && run_with_log "$VISION_BUILD_LOG" uv pip install --python "$PYTHON" -r requirements.txt
    export BUILD_VERSION="${VISION_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_NATIVE_ARCH="$VISION_USE_NATIVE_ARCH" USE_CUDA="$VISION_USE_CUDA" USE_CUDNN="$VISION_USE_CUDNN"
    export USE_XPU="$VISION_USE_XPU" USE_ROCM="$VISION_USE_ROCM"
    export USE_GPU_VIDEO_DECODER="$VISION_USE_GPU_VIDEO_DECODER" USE_CPU_VIDEO_DECODER="$VISION_USE_CPU_VIDEO_DECODER"
    export TORCHVISION_USE_PNG="$VISION_USE_PNG" TORCHVISION_USE_JPEG="$VISION_USE_JPEG"
    export TORCHVISION_USE_WEBP="$VISION_USE_WEBP" TORCHVISION_USE_NVJPEG="$VISION_USE_NVJPEG"
    export FORCE_CUDA="$VISION_FORCE_CUDA" BUILD_TEST="$VISION_BUILD_TEST"
    export CMAKE_BUILD_TYPE="$VISION_CMAKE_BUILD_TYPE" CMAKE_POLICY_VERSION_MINIMUM="$VISION_CMAKE_POLICY_VERSION_MINIMUM"
    export TORCHVISION_INCLUDE="$VISION_INCLUDE" TORCHVISION_LIBRARY="$VISION_LIBRARY"
    run_with_log "$VISION_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel Torchvision "$wheel_dir" 'torchvision-*.whl' torchvision
  component_build_complete vision 'import torchvision; from torchvision.ops import nms'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchvision; print('Torchvision:', torchvision.__version__); from torchvision.ops import nms" | tee -a "$MAIN_LOG"
}

build_audio() {
  section "[7/7] Torchaudio"
  require_source Torchaudio "$AUDIO_SOURCE_DIR"
  if component_cache_hit audio "$AUDIO_SOURCE_DIR" \
    "$BUILD_NUMBER|$AUDIO_BUILD_VERSION|$AUDIO_USE_CUDA|$AUDIO_FORCE_CUDA|$AUDIO_BUILD_TEST|$AUDIO_CMAKE_BUILD_TYPE" \
    'import torchaudio; from torchaudio import _extension; _extension._IS_TORCHAUDIO_EXT_AVAILABLE or exit(1)'; then
    return
  fi
  local wheel_dir
  wheel_dir="$(prepare_wheel_dir audio)"
  run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip --isolated uninstall -y torchaudio || true
  clean_source Torchaudio "$AUDIO_SOURCE_DIR"

  (
    cd "$AUDIO_SOURCE_DIR"
    [[ -f requirements.txt ]] && run_with_log "$AUDIO_BUILD_LOG" uv pip install --python "$PYTHON" -r requirements.txt
    export BUILD_VERSION="${AUDIO_BUILD_VERSION}.post${BUILD_NUMBER}"
    export USE_CUDA="$AUDIO_USE_CUDA" FORCE_CUDA="$AUDIO_FORCE_CUDA" BUILD_TEST="$AUDIO_BUILD_TEST"
    export CMAKE_BUILD_TYPE="$AUDIO_CMAKE_BUILD_TYPE"
    run_with_log "$AUDIO_BUILD_LOG" "$PYTHON" -m pip --isolated wheel . -v --wheel-dir "$wheel_dir" --no-build-isolation --no-cache-dir --no-deps
  )
  stage_and_install_wheel Torchaudio "$wheel_dir" 'torchaudio-*.whl' torchaudio
  component_build_complete audio 'import torchaudio; from torchaudio import _extension; _extension._IS_TORCHAUDIO_EXT_AVAILABLE or exit(1)'
  [[ "$VERIFY_INSTALL" != "1" ]] || "$PYTHON" -c "import torchaudio; from torchaudio import _extension; print('Torchaudio:', torchaudio.__version__, 'extension:', _extension._IS_TORCHAUDIO_EXT_AVAILABLE)" | tee -a "$MAIN_LOG"
}

verify_all() {
  [[ "$VERIFY_INSTALL" == "1" ]] || return
  section "Final verification"
  local verification_dir="${TMPDIR}/verify-install"
  rm -rf -- "$verification_dir"
  mkdir -p "$verification_dir"
  (
    cd -- "$verification_dir"
    "$PYTHON" "$ROOT_DIR/scripts/verify_install.py"
  )
}

main() {
  require_configuration
  reject_python_environment_overrides
  configure_project_local_paths
  initialize_logs
  preflight
  # This entry point intentionally builds and verifies all seven components.
  build_triton
  build_pytorch
  build_xformers
  build_flash_attention
  build_sageattention3
  build_vision
  build_audio
  write_runtime_requirements
  write_provenance "built"
  verify_all
  write_provenance "verified"
  section "Build complete"
  log "Main log: $MAIN_LOG"
  log "Triton log: $TRITON_BUILD_LOG"
  log "PyTorch log: $PYTORCH_BUILD_LOG"
  log "xFormers log: $XFORMERS_BUILD_LOG"
  log "Flash Attention log: $FLASH_ATTENTION_BUILD_LOG"
  log "SageAttention3 log: $SAGEATTENTION3_BUILD_LOG"
  log "Torchvision log: $VISION_BUILD_LOG"
  log "Torchaudio log: $AUDIO_BUILD_LOG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
