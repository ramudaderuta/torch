#!/usr/bin/env bash
# Ubuntu 一键编译本地源码：PyTorch-Triton, PyTorch, Torchvision, Torchaudio (CUDA 13.1)
# 请在源码目录 (./triton, ./pytorch, ./vision, ./audio) 的父目录运行
set -euo pipefail

# ----------------------------
# 1. 全局配置 (可通过环境变量覆盖)
# ----------------------------
: "${BUILD_NUMBER:=$(date +%Y%m%d)}"    # 统一构建版本号
: "${PYTHON:=/home/build/.venv/bin/python}"    # Python 可执行命令
: "${MAX_JOBS:=12}"               # 全局最大并行编译线程数
: "${USE_CLANG:=1}"                     # 使用 clang-21 (1=启用)
: "${CLEAR_PIP_CACHE:=0}"              # 清除 pip 缓存(1=启用)
: "${CLEAN_BUILD:=1}"                  # 清理旧构建(1=启用)
: "${VERIFY_INSTALL:=1}"               # 验证安装(1=启用)
: "${INSTALL_GLOBAL_PIP_DEPS:=1}"      # 安装全局 pip 依赖(1=启用)

# 源码目录
: "${PYTORCH_SOURCE_DIR:=./pytorch}"
: "${VISION_SOURCE_DIR:=./vision}"
: "${AUDIO_SOURCE_DIR:=./audio}"
: "${TRITON_SOURCE_DIR:=./triton}"

# 日志文件
MAIN_LOG="$(pwd)/alltorch_build.log"
TRITON_BUILD_LOG="$(pwd)/triton_build.log"
PYTORCH_BUILD_LOG="$(pwd)/pytorch_build.log"
VISION_BUILD_LOG="$(pwd)/vision_build.log"
AUDIO_BUILD_LOG="$(pwd)/audio_build.log"
> "${MAIN_LOG}"
> "${TRITON_BUILD_LOG}"
> "${PYTORCH_BUILD_LOG}"
> "${VISION_BUILD_LOG}"
> "${AUDIO_BUILD_LOG}"

die() {
  echo "❌ $*" | tee -a "${MAIN_LOG}" >&2
  exit 1
}

log() {
  echo -e "$*" | tee -a "${MAIN_LOG}"
}

run_with_log() {
  local log_file="$1"
  shift
  "$@" 2>&1 | tee -a "${log_file}"
}

require_cmd() {
  command -v "$1" &>/dev/null || die "缺少命令: $1"
}

# ----------------------------
# 2. 环境准备
# ----------------------------
echo -e "\n=== [ALL] 配置全局编译环境 ===" | tee -a "${MAIN_LOG}"

# 基础命令检查
if [[ -x "${PYTHON}" ]]; then
  :
elif command -v "${PYTHON}" &>/dev/null; then
  :
else
  die "Python 不可用: ${PYTHON}"
fi
require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd gcc
require_cmd nvcc
require_cmd nvidia-smi
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PYTHON_HOME="${PYTHON_HOME:-/home/build/.venv}"
export WSL_HOME="/usr/lib/wsl"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-13.1}"
export MAGMA_ROOT="${MAGMA_ROOT:-/usr/local/magma}"
export OPENMPI_ROOT="${OPENMPI_ROOT:-/usr/local/ompi}"
export NVCODEC_HOME="${NVCODEC_HOME:-/usr/local/nvcodec}"

export PATH="${PYTHON_HOME}/bin:${WSL_HOME}/lib:${CUDA_HOME}/bin:${OPENMPI_ROOT}/bin:${PATH:-}"
export LD_LIBRARY_PATH="${PYTHON_HOME}/lib64:${WSL_HOME}/lib:${CUDA_HOME}/lib64:${MAGMA_ROOT}/lib:${OPENMPI_ROOT}/lib:${NVCODEC_HOME}/lib:${LD_LIBRARY_PATH:-}"

# 打印版本信息
{
    echo -n "PATH:"           ; echo "${PATH}" | tr ':' '\n' | sed 's/^/  /'
    echo -n "LD_LIBRARY_PATH:"; echo "${LD_LIBRARY_PATH}" | tr ':' '\n' | sed 's/^/  /'
    echo -n "Python:     "; $PYTHON --version
    echo -n "GCC:        "; gcc -dumpfullversion -dumpversion
    echo -n "Clang:      "; clang-21 --version | head -n1
    echo -n "CMake:      "; cmake --version | head -n1
    echo -n "Ninja:      "; ninja --version
    echo -n "nvcc:       "; nvcc --version | grep "release"
    echo -n "nvidia-smi: "; nvidia-smi --query-gpu=driver_version,name --format=csv,noheader
    echo -n "Git:        "; git --version
    echo -e "=====================\n"
} | tee -a "${MAIN_LOG}"

# 启用 ccache
if command -v ccache &>/dev/null; then
  echo "✅ 启用 ccache 编译缓存" | tee -a "${MAIN_LOG}"
  export CCACHE_ROOT="/usr/lib/ccache"
  export PATH="${CCACHE_ROOT}:${PATH}"

  # 确保nvcc通过ccache调用
  if [[ -d "${CCACHE_ROOT}" ]]; then
  # 检查是否已有nvcc链接，如果没有则创建
    if [[ ! -e "${CCACHE_ROOT}/nvcc" ]]; then
      echo "✅ 创建nvcc到ccache的链接" | tee -a "${MAIN_LOG}"
      if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        sudo ln -sf /usr/bin/ccache "${CCACHE_ROOT}/nvcc"
      else
        echo "⚠️ 无法无密码 sudo，跳过创建 nvcc 链接" | tee -a "${MAIN_LOG}"
      fi
    fi
  fi
  export CMAKE_C_COMPILER_LAUNCHER=ccache
  export CMAKE_CXX_COMPILER_LAUNCHER=ccache
  export CMAKE_CUDA_COMPILER_LAUNCHER=ccache
  ccache -z
  # 验证nvcc是否通过ccache调用
  if [[ "$(which nvcc 2>/dev/null)" == "${CCACHE_ROOT}/nvcc" ]]; then
    echo "✅ nvcc通过ccache调用" | tee -a "${MAIN_LOG}"
  else
    echo "⚠️ nvcc未通过ccache调用: $(which nvcc 2>/dev/null)" | tee -a "${MAIN_LOG}"
  fi
else
  echo "⚠️ ccache 未检测到，跳过缓存" | tee -a "${MAIN_LOG}"
fi

# 选择编译器
if [[ "${USE_CLANG}" == "1" ]] && command -v clang-21 &>/dev/null; then
   export CC=clang-21 CXX=clang++-21
   echo "✅ 使用 clang-21 编译" | tee -a "${MAIN_LOG}"
else
   export CC=gcc CXX=g++
   echo "✅ 使用 GCC 编译" | tee -a "${MAIN_LOG}"
fi

# 设置并行
export MAX_JOBS

# 获取 GPU 计算能力
mapfile -t cc_list < <(
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | sort -u
)
if [[ ${#cc_list[@]} -eq 0 ]]; then
  die "未检测到 GPU 计算能力，检查 nvidia-smi 与驱动是否正常"
fi
export TORCH_CUDA_ARCH_LIST="$(IFS=';'; echo "${cc_list[*]}")"
echo "✅ TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}" | tee -a "${MAIN_LOG}"

# NVCC 编译标志
NVCC_FLAGS=""
for cc in "${cc_list[@]}"; do
    NVCC_FLAGS+=" -gencode arch=compute_${cc//./},code=sm_${cc//./}"
done
export NVCC_FLAGS
echo "✅ NVCC_FLAGS=${NVCC_FLAGS}" | tee -a "${MAIN_LOG}"

# ----------------------------
# 3. 系统依赖检查
# ----------------------------
echo -e "\n=== [ALL] 检查所有系统依赖 ===" | tee -a "${MAIN_LOG}"
missing_sysdeps=()
pkg_list=(
    # 核心构建工具
    build-essential ninja-build gcc clang-21 ccache cmake git pkg-config
    # PyTorch 依赖
    cudnn9-cuda-13 cudss nvshmem libnccl-dev libcutensor-dev libcusparselt-dev
    libopenblas-dev liblapack-dev libomp-21-dev intel-mkl-full
    libprotobuf-dev protobuf-compiler zlib1g-dev libssl-dev
    # TorchVision 依赖
    ffmpeg libjpeg-dev libpng-dev libwebp-dev libavcodec-dev libavformat-dev
    libavutil-dev libswresample-dev libswscale-dev
    # Torchaudio 依赖
    libsndfile1-dev libsox-dev libsamplerate0-dev
)
for pkg in "${pkg_list[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        missing_sysdeps+=("$pkg")
    fi
done

if [[ ${#missing_sysdeps[@]} -eq 0 ]]; then
    echo "✅ 所有系统依赖已满足" | tee -a "${MAIN_LOG}"
else
    echo "⚠️ 缺少以下依赖包：" | tee -a "${MAIN_LOG}"
    for pkg in "${missing_sysdeps[@]}"; do
        echo "   - $pkg" | tee -a "${MAIN_LOG}"
    done
fi

# 检查 cuDNN 头文件
if [[ ! -f /usr/include/cudnn_version.h && ! -f /usr/include/x86_64-linux-gnu/cudnn_version.h ]]; then
  echo "❌ 错误：未找到 cuDNN 头文件，请 sudo apt-get -y install cudnn9-cuda-13" | tee -a "${MAIN_LOG}" >&2
  exit 1
fi

# 可选：清 pip 缓存
if [[ "${CLEAR_PIP_CACHE}" == "1" ]]; then
    echo "🔄 正在清除 pip 缓存..." | tee -a "${MAIN_LOG}"
    $PYTHON -m pip cache purge || true
fi

# 全局 pip 依赖（减少重复安装）
if [[ "${INSTALL_GLOBAL_PIP_DEPS}" == "1" ]]; then
    echo "🔧 安装全局 pip 依赖..." | tee -a "${MAIN_LOG}"
    $PYTHON -m pip install -U pip setuptools wheel
    $PYTHON -m pip install pybind11 uv
fi

# ======================================================================================
# =                                PyTorch-Triton 构建流程                              =
# ======================================================================================
echo -e "\n\n\n=== [1/4] 开始构建 PyTorch-Triton ===" | tee -a "${MAIN_LOG}"

# 检查源码目录
if [[ ! -d "${TRITON_SOURCE_DIR}" || ! -f "${TRITON_SOURCE_DIR}/setup.py" ]]; then
  echo "❌ 错误：未找到 Triton 源码目录 '${TRITON_SOURCE_DIR}' 与 setup.py 文件。" | tee -a "${MAIN_LOG}" >&2
  echo "   请确保本地路径存在：${TRITON_SOURCE_DIR}" >&2
  exit 1
fi

# 清理旧构建
echo -e "\n--- [Triton] 清理旧构建 ---" | tee -a "${MAIN_LOG}"
cd "${TRITON_SOURCE_DIR}"
$PYTHON -m pip uninstall -y triton pytorch-triton &>/dev/null || true
if [[ "${CLEAN_BUILD}" == "1" ]]; then
  if [[ -d .git ]]; then
    git clean -ffdx
  else
    rm -rf build/ dist/ ./*.egg-info .eggs/
  fi
  echo "✅ 清理完成" | tee -a "${MAIN_LOG}"
else
  echo "⏭️ 跳过清理 (CLEAN_BUILD=0)" | tee -a "${MAIN_LOG}"
fi


# 修复 MLIR API 兼容性问题 (LLVM 22)
echo -e "\n--- [Triton] 修复 MLIR API 兼容性 ---" | tee -a "${MAIN_LOG}"
if command -v sed >/dev/null 2>&1; then
  sed -i 's/loc, 0, builder\.getI64Type()/loc, builder.getI64Type(), 0/g' lib/Dialect/Triton/Transforms/RewriteTensorPointer.cpp
  sed -i 's/loc, 0, builder\.getI64Type()/loc, builder.getI64Type(), 0/g' lib/Dialect/Triton/Transforms/RewriteTensorDescriptorToPointer.cpp
  sed -i 's/predOp\.getLoc(), 0, predOp\.getResult()\.getType()/predOp.getLoc(), predOp.getResult().getType(), 0/g' lib/Dialect/TritonGPU/Transforms/Pipeliner/SoftwarePipeliner.cpp
  sed -i 's/predOp\.getLoc(), 1, predOp\.getResult()\.getType()/predOp.getLoc(), predOp.getResult().getType(), 1/g' lib/Dialect/TritonGPU/Transforms/Pipeliner/SoftwarePipeliner.cpp

  # 修复 NVVM::ElectSyncOp 构造函数 (需要添加可选的membermask参数)
  sed -i 's/return rewriter\.create<NVVM::ElectSyncOp>(loc, i1_ty)/return rewriter.create<NVVM::ElectSyncOp>(loc, i1_ty, mlir::Value())/g' third_party/nvidia/lib/TritonNVIDIAGPUToLLVM/Utility.cpp

  # 修复 llvm::Function 类型错误 (还原错误的修改)
  sed -i 's/void runScalarizePackedFOpsPass(mlir::FunctionOpInterface F)/void runScalarizePackedFOpsPass(llvm::Function &F)/g' third_party/amd/include/TritonAMDGPUToLLVM/Passes.h

  echo "✅ MLIR API 兼容性修复完成" | tee -a "${MAIN_LOG}"
else
  echo "⚠️  sed 未找到，跳过 MLIR API 修复" | tee -a "${MAIN_LOG}"
fi

# 安装依赖 & 编译
echo -e "\n--- [Triton] 安装 pip 依赖 ---" | tee -a "${MAIN_LOG}"
if [[ "${INSTALL_GLOBAL_PIP_DEPS}" != "1" ]]; then
  $PYTHON -m pip install pybind11 uv
else
  echo "✅ 已使用全局 pip 依赖" | tee -a "${MAIN_LOG}"
fi

echo -e "\n--- [Triton] 开始编译 Triton ---" | tee -a "${MAIN_LOG}"

# 设置环境变量
export TRITON_HOME="${HOME}"
export TRITON_CACHE_DIR="${TRITON_HOME}/.triton/cache"
export TRITON_CUPTI_INCLUDE_PATH="${CUDA_HOME}/include"
export TRITON_CUPTI_LIB_PATH="${CUDA_HOME}/lib64"
export TRITON_LIBDEVICE_PATH="${CUDA_HOME}/nvvm/libdevice"
export TRITON_LIBCUDA_PATH="${CUDA_HOME}/lib64"
export TRITON_PTXAS_PATH="${CUDA_HOME}/bin/ptxas"
export TRITON_CUOBJDUMP_PATH="${CUDA_HOME}/bin/cuobjdump"
export TRITON_NVDISASM_PATH="${CUDA_HOME}/bin/nvdisasm"
export TRITON_F32_DEFAULT="tf32"
export TRITON_DEFAULT_FP_FUSION=1
export TRITON_INTERPRET=0

export TRITON_WHEEL_NAME="pytorch-triton"
export TRITON_WHEEL_VERSION_SUFFIX=".post${BUILD_NUMBER}"
export MAX_JOBS="${MAX_JOBS}"
export TRITON_BUILD_WITH_CCACHE=1
export TRITON_PARALLEL_LINK_JOBS=${MAX_JOBS}
export TRITON_OFFLINE_BUILD=1
export TRITON_BUILD_PROTON=0
export TRITON_BUILD_UT=0
export LLVM_CONFIG_PATH="/usr/lib/llvm-21/bin/llvm-config"
export LLVM_SYSPATH="/usr/lib/llvm-21"

# 构建 wheel
echo "✅ 开始构建 Triton wheel..." | tee -a "${TRITON_BUILD_LOG}"
run_with_log "${TRITON_BUILD_LOG}" $PYTHON -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir
run_with_log "${TRITON_BUILD_LOG}" $PYTHON -m pip install dist/*.whl

# 验证
if [[ "${VERIFY_INSTALL}" == "1" ]]; then
  echo -e "\n--- [Triton] 验证安装 ---" | tee -a "${MAIN_LOG}"
  cd ..
  ${PYTHON} -c "import triton; print('Triton:', triton.__version__); print('✅ Triton 验证通过')" | tee -a "${MAIN_LOG}"
else
  cd ..
  echo "⏭️ 跳过 Triton 验证 (VERIFY_INSTALL=0)" | tee -a "${MAIN_LOG}"
fi


# ======================================================================================
# =                                  PyTorch 构建流程                                  =
# ======================================================================================
echo -e "\n\n\n=== [2/4] 开始构建 PyTorch ===" | tee -a "${MAIN_LOG}"

# 检查源码目录
if [[ ! -d "${PYTORCH_SOURCE_DIR}" || ! -f "${PYTORCH_SOURCE_DIR}/setup.py" ]]; then
  echo "❌ 错误：未找到 PyTorch 源码目录 '${PYTORCH_SOURCE_DIR}' 与 setup.py 文件。" | tee -a "${MAIN_LOG}" >&2
  echo "   请确保本地路径存在：${PYTORCH_SOURCE_DIR}" >&2
  exit 1
fi

# 清理旧构建
echo -e "\n--- [PyTorch] 清理旧构建 ---" | tee -a "${MAIN_LOG}"
cd "${PYTORCH_SOURCE_DIR}"
$PYTHON -m pip uninstall -y torch &>/dev/null || true
if [[ "${CLEAN_BUILD}" == "1" ]]; then
  if [[ -d .git ]]; then
    git clean -ffdx
  else
    rm -rf build/ dist/ ./*.egg-info .eggs/
  fi
  echo "✅ 清理完成" | tee -a "${MAIN_LOG}"
else
  echo "⏭️ 跳过清理 (CLEAN_BUILD=0)" | tee -a "${MAIN_LOG}"
fi


# --- 使用外部 flash-attention ---
echo -e "\n--- [PyTorch] 替换为外部 flash-attention ---" | tee -a "${MAIN_LOG}"
FLASH_ATTENTION_SUBMODULE_PATH="${PYTORCH_SOURCE_DIR}/third_party/flash-attention"
FLASH_ATTENTION_BACKUP_PATH="${FLASH_ATTENTION_SUBMODULE_PATH}_bak"
EXTERNAL_FLASH_ATTENTION_DIR="../flash-attention"

# 设置退出时恢复的 trap, 无论脚本成功或失败都会执行
trap 'echo -e "\nℹ️ 正在恢复 PyTorch flash-attention 子模块..."; rm -f "${FLASH_ATTENTION_SUBMODULE_PATH}"; if [ -d "${FLASH_ATTENTION_BACKUP_PATH}" ]; then mv "${FLASH_ATTENTION_BACKUP_PATH}" "${FLASH_ATTENTION_SUBMODULE_PATH}"; fi; echo "✅ 已恢复."' EXIT

# 备份旧的子模块目录并创建链接
if [ -d "${FLASH_ATTENTION_SUBMODULE_PATH}" ]; then
    echo "📦 备份 ${FLASH_ATTENTION_SUBMODULE_PATH}" | tee -a "${MAIN_LOG}"
    mv "${FLASH_ATTENTION_SUBMODULE_PATH}" "${FLASH_ATTENTION_BACKUP_PATH}"
fi
echo "🔗 链接 ${EXTERNAL_FLASH_ATTENTION_DIR} -> ${FLASH_ATTENTION_SUBMODULE_PATH}" | tee -a "${MAIN_LOG}"
ln -s "${EXTERNAL_FLASH_ATTENTION_DIR}" "${FLASH_ATTENTION_SUBMODULE_PATH}"

# 安装依赖 & 编译
echo -e "\n--- [PyTorch] 安装 pip 依赖 ---" | tee -a "${MAIN_LOG}"
if [[ "${INSTALL_GLOBAL_PIP_DEPS}" != "1" ]]; then
  $PYTHON -m pip install pybind11 uv
else
  echo "✅ 已使用全局 pip 依赖" | tee -a "${MAIN_LOG}"
fi
$PYTHON -m uv pip install -r requirements-build.txt

echo -e "\n--- [PyTorch] 开始编译 PyTorch ---" | tee -a "${MAIN_LOG}"
export PYTORCH_BUILD_VERSION=2.9.0
export PYTORCH_BUILD_NUMBER="${BUILD_NUMBER}"
export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_NCCL=1 USE_CUSPARSELT=1 USE_CUDSS=1
export USE_CUFILE=1 USE_MKLDNN=1 USE_OPENMP=1 USE_FLASH_ATTENTION=1 USE_MEM_EFF_ATTENTION=1
export USE_DISTRIBUTED=1 USE_XPU=0 USE_ROCM=0 FORCE_CUDA=1 BUILD_TEST=0
export CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5

run_with_log "${PYTORCH_BUILD_LOG}" $PYTHON -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir
run_with_log "${PYTORCH_BUILD_LOG}" $PYTHON -m pip install dist/*.whl
echo "✅ PyTorch 编译完成" | tee -a "${MAIN_LOG}"

# 验证
if [[ "${VERIFY_INSTALL}" == "1" ]]; then
  echo -e "\n--- [PyTorch] 验证安装 ---" | tee -a "${MAIN_LOG}"
  cd ..
  ${PYTHON} -c "import torch; print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda); assert torch.cuda.is_available(), 'CUDA not enabled'; print('Device :', torch.cuda.get_device_name(0));" | tee -a "${MAIN_LOG}"
  echo "✅ PyTorch 验证通过" | tee -a "${MAIN_LOG}"
else
  cd ..
  echo "⏭️ 跳过 PyTorch 验证 (VERIFY_INSTALL=0)" | tee -a "${MAIN_LOG}"
fi


# ======================================================================================
# =                                TorchVision 构建流程                                =
# ======================================================================================
echo -e "\n\n\n=== [3/4] 开始构建 TorchVision ===" | tee -a "${MAIN_LOG}"

if [[ ! -d "${VISION_SOURCE_DIR}" || ! -f "${VISION_SOURCE_DIR}/setup.py" ]]; then
  echo "❌ 错误：未找到 Torchvision 源码目录 '${VISION_SOURCE_DIR}' 与 setup.py 文件。" | tee -a "${MAIN_LOG}" >&2
  echo "   请确保本地路径存在：${VISION_SOURCE_DIR}" >&2
  exit 1
fi

# 清理
echo -e "\n--- [TorchVision] 清理旧构建 ---" | tee -a "${MAIN_LOG}"
$PYTHON -m pip uninstall -y torchvision &>/dev/null || true
cd "${VISION_SOURCE_DIR}"
if [[ "${CLEAN_BUILD}" == "1" ]]; then
  if [[ -d .git ]]; then git clean -ffdx; else rm -rf build/ dist/ ./*.egg-info .eggs/; fi
  echo "✅ 清理完成" | tee -a "${MAIN_LOG}"
else
  echo "⏭️ 跳过清理 (CLEAN_BUILD=0)" | tee -a "${MAIN_LOG}"
fi


# 依赖 & 编译
echo -e "\n--- [TorchVision] 安装 pip 依赖 ---" | tee -a "${MAIN_LOG}"
$PYTHON -m pip install pillow>=10.3.0 gdown>=4.7.3 scipy
[[ -f requirements.txt ]] && $PYTHON -m uv pip install -r requirements.txt

echo -e "\n--- [TorchVision] 开始编译 TorchVision ---" | tee -a "${MAIN_LOG}"
export BUILD_VERSION="0.24.0.post${BUILD_NUMBER}"
export USE_NATIVE_ARCH=1 USE_CUDA=1 USE_CUDNN=1 USE_XPU=0 USE_ROCM=0
export USE_GPU_VIDEO_DECODER=1 USE_CPU_VIDEO_DECODER=1
export TORCHVISION_USE_PNG=1 TORCHVISION_USE_JPEG=1 TORCHVISION_USE_WEBP=1 TORCHVISION_USE_NVJPEG=1
export FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release CMAKE_POLICY_VERSION_MINIMUM=3.5
export TORCHVISION_INCLUDE="${TORCHVISION_INCLUDE:-${NVCODEC_HOME}/include}"
export TORCHVISION_LIBRARY="${TORCHVISION_LIBRARY:-${WSL_HOME}/lib}"

run_with_log "${VISION_BUILD_LOG}" $PYTHON -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir --no-deps
run_with_log "${VISION_BUILD_LOG}" $PYTHON -m pip install dist/*.whl
echo "✅ TorchVision 编译完成" | tee -a "${MAIN_LOG}"

# 验证
if [[ "${VERIFY_INSTALL}" == "1" ]]; then
  echo -e "\n--- [TorchVision] 验证安装 ---" | tee -a "${MAIN_LOG}"
  cd ..
  ${PYTHON} -c "import torchvision; print('Torchvision:', torchvision.__version__); from torchvision.ops import nms" | tee -a "${MAIN_LOG}"
  echo "✅ TorchVision 验证通过" | tee -a "${MAIN_LOG}"
else
  cd ..
  echo "⏭️ 跳过 TorchVision 验证 (VERIFY_INSTALL=0)" | tee -a "${MAIN_LOG}"
fi


# ======================================================================================
# =                                Torchaudio 构建流程                                 =
# ======================================================================================
echo -e "\n\n\n=== [4/4] 开始构建 Torchaudio ===" | tee -a "${MAIN_LOG}"

if [[ ! -d "${AUDIO_SOURCE_DIR}" || ! -f "${AUDIO_SOURCE_DIR}/setup.py" ]]; then
  echo "❌ 错误：未找到 Torchaudio 源码目录 '${AUDIO_SOURCE_DIR}' 与 setup.py 文件。" | tee -a "${MAIN_LOG}" >&2
  echo "   请确保本地路径存在：${AUDIO_SOURCE_DIR}" >&2
  exit 1
fi

# 清理
echo -e "\n--- [Torchaudio] 清理旧构建 ---" | tee -a "${MAIN_LOG}"
cd "${AUDIO_SOURCE_DIR}"
$PYTHON -m pip uninstall -y torchaudio &>/dev/null || true
if [[ "${CLEAN_BUILD}" == "1" ]]; then
  if [[ -d .git ]]; then git clean -ffdx; else rm -rf build/ dist/ ./*.egg-info .eggs/ src/torchaudio.egg-info; fi
  echo "✅ 清理完成" | tee -a "${MAIN_LOG}"
else
  echo "⏭️ 跳过清理 (CLEAN_BUILD=0)" | tee -a "${MAIN_LOG}"
fi


# 依赖 & 编译
echo -e "\n--- [Torchaudio] 安装 pip 依赖 ---" | tee -a "${MAIN_LOG}"
[[ -f requirements.txt ]] && $PYTHON -m uv pip install -r requirements.txt


echo -e "\n--- [Torchaudio] 开始编译 Torchaudio ---" | tee -a "${MAIN_LOG}"
export BUILD_VERSION="2.8.0.post${BUILD_NUMBER}"
export USE_CUDA=1 FORCE_CUDA=1 BUILD_TEST=0 CMAKE_BUILD_TYPE=Release

run_with_log "${AUDIO_BUILD_LOG}" $PYTHON -m pip wheel . -v --wheel-dir dist/ --no-build-isolation --no-cache-dir --no-deps
run_with_log "${AUDIO_BUILD_LOG}" $PYTHON -m pip install dist/*.whl
echo "✅ Torchaudio 编译完成" | tee -a "${MAIN_LOG}"

# 验证
if [[ "${VERIFY_INSTALL}" == "1" ]]; then
  echo -e "\n--- [Torchaudio] 验证安装 ---" | tee -a "${MAIN_LOG}"
  cd ..
  ${PYTHON} -c "import torchaudio; print('Torchaudio:', torchaudio.__version__); print('Torchaudio backends:', torchaudio.list_audio_backends())" | tee -a "${MAIN_LOG}"
  echo "✅ Torchaudio 验证通过" | tee -a "${MAIN_LOG}"
else
  cd ..
  echo "⏭️ 跳过 Torchaudio 验证 (VERIFY_INSTALL=0)" | tee -a "${MAIN_LOG}"
fi


# ----------------------------
# 6. 最终验证
# ----------------------------
if [[ "${VERIFY_INSTALL}" == "1" ]]; then
  echo -e "\n\n\n=== [ALL] 最终整体验证 ===" | tee -a "${MAIN_LOG}"
  ${PYTHON} - <<EOF
import torch, torchvision, torchaudio, triton, sys
print('--- Final Verification ---')
print('Python:', sys.version)
print('Triton:', triton.__version__)
print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda)
print('Torchvision:', torchvision.__version__)
print('Torchaudio:', torchaudio.__version__)
assert torch.cuda.is_available(), 'CUDA not enabled'
print('Device :', torch.cuda.get_device_name(0))
x = torch.randn(10,10, device='cuda')
print('CUDA matrix multiplication norm:', (x @ x).norm().item())
assert torch._C._has_cudnn, 'CUDNN extension not compiled'
assert torchvision._HAS_OPS, 'Torchvision CUDA extension not compiled'
print('Torchaudio backends:', torchaudio.list_audio_backends())
assert hasattr(torchaudio, 'sox_effects'), 'sox_effects not available'
print('✅✅✅ All components verified successfully! ✅✅✅')
EOF
else
  echo -e "\n\n⏭️ 跳过最终验证 (VERIFY_INSTALL=0)" | tee -a "${MAIN_LOG}"
fi

echo -e "\n\n主日志文件：${MAIN_LOG}" | tee -a "${MAIN_LOG}"
echo "Triton 日志: ${TRITON_BUILD_LOG}" | tee -a "${MAIN_LOG}"
echo "PyTorch 日志: ${PYTORCH_BUILD_LOG}" | tee -a "${MAIN_LOG}"
echo "TorchVision 日志: ${VISION_BUILD_LOG}" | tee -a "${MAIN_LOG}"
echo "Torchaudio 日志: ${AUDIO_BUILD_LOG}" | tee -a "${MAIN_LOG}"
