#!/usr/bin/env bash
set -euo pipefail

# ===== 可调参数（也可用命令行覆盖）=====
DEPTH="${DEPTH:-20}"     # 默认浅历史深度（10 可能经常不够，20/50 更稳）
JOBS="${JOBS:-8}"        # submodule 并行更新数量
REMOTE="${REMOTE:-origin}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--repo /path/to/pytorch] [--depth N] [--jobs N] [--remote origin]

Env overrides:
  DEPTH=50 JOBS=16 REMOTE=origin $(basename "$0")

Notes:
  - 会更新当前分支对应的远端分支（REMOTE/<branch>）
  - 工作区有未提交改动会退出
  - 若当前目录包含 ./pytorch，将额外尝试更新 vision/audio/flash-attention/triton（存在则更新，不存在则提示）
EOF
}

REPO=""
EXTRA_REPOS=(
  "vision|https://github.com/pytorch/vision"
  "audio|https://github.com/pytorch/audio"
  "flash-attention|https://github.com/Dao-AILab/flash-attention.git"
  "triton|https://github.com/openai/triton.git"
)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2;;
    --depth)  DEPTH="$2"; shift 2;;
    --jobs)   JOBS="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

update_repo() {
  local repo_path="$1"
  local repo_label="$2"

  if [[ ! -d "$repo_path/.git" ]]; then
    echo "==> Skip: $repo_label ($repo_path) not found."
    return 0
  fi

  pushd "$repo_path" >/dev/null
  git rev-parse --show-toplevel >/dev/null

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: $repo_label 工作区有未提交改动（git status 不干净），为安全起见退出。"
    echo "       Repo: $(git rev-parse --show-toplevel)"
    popd >/dev/null
    return 1
  fi

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  echo "==> Repo: $(git rev-parse --show-toplevel)"
  echo "==> Branch: $branch"
  echo "==> Remote: $REMOTE"
  echo "==> Depth: $DEPTH  Jobs: $JOBS"

  echo "==> [1/3] Fetch main repo (shallow)"
  git fetch --depth "$DEPTH" "$REMOTE" "$branch"
  git merge --ff-only "$REMOTE/$branch"

  if [[ -f .gitmodules ]]; then
    echo "==> [2/3] Sync submodules"
    git submodule sync --recursive

    echo "==> [3/3] Update submodules (shallow)"
    try_update_submodules() {
      git submodule update --init --recursive --depth "$DEPTH" --jobs "$JOBS"
    }

    if try_update_submodules; then
      echo "==> Done."
      popd >/dev/null
      return 0
    fi

    echo "==> Submodule update failed. Try deepen and retry..."

    for round in 1 2 3 4 5; do
      echo "==> Retry round $round: deepen submodules by $DEPTH"
      git submodule foreach --recursive '
        set -e
        git fetch --deepen '"$DEPTH"' 2>/dev/null || true
      ' >/dev/null

      if try_update_submodules; then
        echo "==> Done (after deepen retries)."
        popd >/dev/null
        return 0
      fi
    done

    echo "ERROR: 仍然有子模块无法更新到主仓库指定的 commit。"
    echo "建议："
    echo "  1) 把 depth 调大：  $0 --depth 100"
    echo "  2) 或者直接把主仓库/子模块变全量：git fetch --unshallow && git submodule foreach --recursive \"git fetch --unshallow || true\""
    popd >/dev/null
    return 1
  else
    echo "==> No submodules. Done."
    popd >/dev/null
    return 0
  fi
}

# 自动定位 repo：优先 --repo，其次当前目录，其次 ./pytorch
if [[ -n "$REPO" ]]; then
  update_repo "$REPO" "repo"
  exit $?
fi

if [[ -d .git ]]; then
  update_repo "$PWD" "repo"
  exit $?
fi

if [[ -d pytorch/.git ]]; then
  update_repo "$PWD/pytorch" "pytorch"
  for entry in "${EXTRA_REPOS[@]}"; do
    name="${entry%%|*}"
    url="${entry#*|}"
    if [[ -d "$PWD/$name/.git" ]]; then
      update_repo "$PWD/$name" "$name"
    else
      echo "==> Skip: $name ($PWD/$name) not found."
      echo "       Clone: $url"
    fi
  done
  exit 0
fi

echo "ERROR: 找不到 pytorch repo。请用 --repo /path/to/pytorch 指定。"
exit 1
