#!/usr/bin/env bash
set -euo pipefail

# ===== 可调参数（也可用命令行覆盖）=====
DEPTH="${DEPTH:-100}"    # 默认浅历史深度（10 可能经常不够，20/50/100 更稳）
JOBS="${JOBS:-8}"        # submodule 并行更新数量
REMOTE="${REMOTE:-origin}"
RESET_ON_DIVERGENCE="${RESET_ON_DIVERGENCE:-0}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v git &>/dev/null || die "缺少命令: git"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--repo /path/to/repo] [--depth N] [--jobs N] [--remote origin] [--reset-on-divergence]

Env overrides:
  DEPTH=50 JOBS=8 REMOTE=origin RESET_ON_DIVERGENCE=1 $(basename "$0")

Notes:
  - 会更新当前分支对应的远端分支（REMOTE/<branch>）
  - 有未提交的源码改动会退出；仅落后的嵌套子模块会自动检出到父仓库锁定提交
  - detached HEAD 不支持（请先切回分支）
  - 浅克隆历史未覆盖 HEAD 导致误报 divergent 时，会自动按日期扩大历史（必要时 unshallow）后重查
  - --reset-on-divergence 仅用于上游已重写历史的确认场景；会先创建 update-backup/<timestamp> 备份分支，再重置到远端
  - 若当前目录包含 ./pytorch，将额外尝试更新 vision/audio/flash-attention/triton/mslk/xformers（存在则更新，不存在则提示）
EOF
}

REPO=""
EXTRA_REPOS=(
  "pytorch|https://github.com/pytorch/pytorch"
  "vision|https://github.com/pytorch/vision"
  "audio|https://github.com/pytorch/audio"
  "flash-attention|https://github.com/Dao-AILab/flash-attention.git"
  "triton|https://github.com/openai/triton.git"
  "mslk|https://github.com/meta-pytorch/MSLK.git"
  "xformers|https://github.com/facebookresearch/xformers.git"
)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2;;
    --depth)  DEPTH="$2"; shift 2;;
    --jobs)   JOBS="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    --reset-on-divergence) RESET_ON_DIVERGENCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ "$DEPTH" =~ ^[1-9][0-9]*$ ]] || die "DEPTH must be a positive integer: $DEPTH"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer: $JOBS"
[[ "$RESET_ON_DIVERGENCE" == "0" || "$RESET_ON_DIVERGENCE" == "1" ]] \
  || die "RESET_ON_DIVERGENCE must be 0 or 1: $RESET_ON_DIVERGENCE"

submodules_are_content_clean() {
  local repo_label="$1"
  local dirty_submodules

  dirty_submodules="$(git submodule foreach --quiet --recursive '
    tracked_changes="$(git status --porcelain --untracked-files=no --ignore-submodules=all)"
    untracked_sources="$(git ls-files --others --exclude-standard | sed -e "/[.]egg-info\\//d")"
    if [[ -n "$tracked_changes" || -n "$untracked_sources" ]]; then
      printf "%s\\n" "$sm_path"
    fi
  ' 2>/dev/null | sort -u)"

  if [[ -n "$dirty_submodules" ]]; then
    echo "ERROR: $repo_label 的嵌套子模块有未提交源码改动，无法安全同步。"
    printf '%s\\n' "$dirty_submodules" | sed 's/^/       /'
    return 1
  fi
}

worktree_has_source_changes() {
  local tracked_changes
  local untracked_sources

  tracked_changes="$(git status --porcelain --untracked-files=no --ignore-submodules=all)"
  untracked_sources="$(git ls-files --others --exclude-standard | sed -e "/[.]egg-info\\//d")"
  [[ -n "$tracked_changes" || -n "$untracked_sources" ]]
}

sync_submodules() {
  local repo_label="$1"
  local round

  [[ -f .gitmodules ]] || return 0

  git submodule sync --recursive
  # Upstream branch renames into a sub-namespace (foo -> foo/bar) leave stale
  # remote-tracking refs that make the submodule fetch fail with a
  # directory/file ref-lock error ("cannot lock ref ... exists"). Prune them
  # first so a plain fetch can create the new namespace.
  REMOTE="$REMOTE" git submodule foreach --quiet --recursive '
    git remote prune "$REMOTE" >/dev/null 2>&1 || true
  ' >/dev/null 2>&1 || true
  if git submodule update --init --recursive --depth "$DEPTH" --jobs "$JOBS"; then
    return 0
  fi

  echo "==> $repo_label 子模块目标不在浅历史内；逐步加深后重试..."
  for round in 1 2 3 4 5; do
    echo "==> Retry round $round: deepen submodules by $DEPTH"
    git submodule foreach --recursive 'git fetch --deepen '"$DEPTH"' 2>/dev/null || true' >/dev/null
    if git submodule update --init --recursive --depth "$DEPTH" --jobs "$JOBS"; then
      return 0
    fi
  done

  echo "ERROR: 仍然有子模块无法更新到父仓库指定的 commit。"
  return 1
}

ensure_ancestry_decidable() {
  local remote="$1"
  local branch="$2"

  git merge-base --is-ancestor HEAD "$remote/$branch" 2>/dev/null && return 0
  [[ "$(git rev-parse --is-shallow-repository)" == "true" ]] || return 1

  # A shallow fetch window can end before HEAD, which makes an ordinary
  # behind-the-remote checkout look divergent. Widen the fetched history
  # by date (then fully) and retest before declaring divergence. The
  # extra objects are exactly the ones the fast-forward checkout needs.
  local head_ts widen_ts widen_date
  head_ts="$(git log -1 --format=%ct HEAD)"
  echo "==> 浅历史未覆盖 HEAD；按日期扩大历史后重查祖先关系..."
  for widen_ts in $((head_ts - 7 * 86400)) $((head_ts - 120 * 86400)); do
    widen_date="$(date -u -d "@${widen_ts}" --iso-8601)"
    if git fetch --shallow-since="$widen_date" "$remote" "$branch" 2>/dev/null; then
      git merge-base --is-ancestor HEAD "$remote/$branch" && return 0
    fi
  done

  echo "==> 仍需完整历史才能判定；执行 git fetch --unshallow ..."
  git fetch --unshallow "$remote" "$branch" 2>/dev/null || return 1
  git merge-base --is-ancestor HEAD "$remote/$branch"
}

update_repo() {
  local repo_path="$1"
  local repo_label="$2"

  if [[ ! -e "$repo_path/.git" ]]; then
    echo "==> Skip: $repo_label ($repo_path) not found."
    return 0
  fi

  pushd "$repo_path" >/dev/null
  git rev-parse --show-toplevel >/dev/null

  if worktree_has_source_changes || ! submodules_are_content_clean "$repo_label"; then
    echo "ERROR: $repo_label 工作区有未提交改动（git status 不干净），为安全起见退出。"
    echo "       Repo: $(git rev-parse --show-toplevel)"
    popd >/dev/null
    return 1
  fi

  # A parent commit switch can leave clean nested submodules at old gitlinks.
  # Reconcile them before treating the repository as dirty or advancing it.
  if ! sync_submodules "$repo_label"; then
    popd >/dev/null
    return 1
  fi

  # Re-check after submodule sync using the same source-change definition as
  # the pre-sync check, so build artifacts (e.g. *.egg-info/) that the first
  # check already tolerated do not trigger a false dirty exit here.
  if worktree_has_source_changes; then
    echo "ERROR: $repo_label 工作区有未提交改动（git status 不干净），为安全起见退出。"
    echo "       Repo: $(git rev-parse --show-toplevel)"
    popd >/dev/null
    return 1
  fi

  local branch
  branch="$(git symbolic-ref --short -q HEAD || true)"
  if [[ -z "$branch" ]]; then
    local release_tag
    release_tag="$(git describe --exact-match --tags 2>/dev/null || true)"
    if [[ -n "$release_tag" ]]; then
      echo "==> Skip: $repo_label is pinned at release tag $release_tag."
      popd >/dev/null
      return 0
    fi
    echo "ERROR: $repo_label 处于 detached HEAD，无法更新远端分支。"
    echo "       Repo: $(git rev-parse --show-toplevel)"
    popd >/dev/null
    return 1
  fi
  echo "==> Repo: $(git rev-parse --show-toplevel)"
  echo "==> Branch: $branch"
  echo "==> Remote: $REMOTE"
  echo "==> Depth: $DEPTH  Jobs: $JOBS"

  echo "==> [1/3] Fetch main repo (shallow)"
  if ! git ls-remote --exit-code --heads "$REMOTE" "$branch" >/dev/null 2>&1; then
    echo "ERROR: 远端不存在分支 $REMOTE/$branch"
    popd >/dev/null
    return 1
  fi
  git fetch --depth "$DEPTH" "$REMOTE" "$branch"
  if ! ensure_ancestry_decidable "$REMOTE" "$branch"; then
    if [[ "$RESET_ON_DIVERGENCE" != "1" ]]; then
      echo "ERROR: cannot fast-forward to $REMOTE/$branch; local history is divergent or unrelated."
      echo "       No reset was performed. Re-run with --reset-on-divergence only after reviewing the remote rewrite."
      popd >/dev/null
      return 1
    fi

    local backup_branch
    backup_branch="update-backup/$(date -u +%Y%m%dT%H%M%SZ)-${branch}"
    git branch "$backup_branch" HEAD
    echo "==> Upstream history changed; saved $backup_branch at $(git rev-parse --short HEAD)"
    git reset --hard "$REMOTE/$branch"
  else
    git merge --ff-only "$REMOTE/$branch"
  fi

  if ! sync_submodules "$repo_label"; then
    popd >/dev/null
    return 1
  fi

  echo "==> Done."
  popd >/dev/null
  return 0
}

# 自动定位 repo：优先 --repo，其次当前目录，其次 ./pytorch
if [[ -n "$REPO" ]]; then
  update_repo "$REPO" "repo"
  exit $?
fi

found_any_repo=0
for entry in "${EXTRA_REPOS[@]}"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  if [[ -e "$PWD/$name/.git" ]]; then
    found_any_repo=1
    update_repo "$PWD/$name" "$name"
  else
    echo "==> Skip: $name ($PWD/$name) not found."
    echo "       Clone: $url"
  fi
done
if [[ "${found_any_repo}" -eq 1 ]]; then
  exit 0
fi

if [[ -d .git ]]; then
  update_repo "$PWD" "repo"
  exit $?
fi

echo "ERROR: 找不到 pytorch repo。请用 --repo /path/to/pytorch 指定。"
exit 1
