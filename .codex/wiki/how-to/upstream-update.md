---
title: 上游同步与子模块更新
type: how-to
status: current
scope: root-orchestration
related_scopes: []
related_files:
  - update.sh
  - .gitmodules
source_docs: []
tags:
  - git
  - submodule
  - compatibility
last_checked: 2026-07-18
updated: 2026-07-18T16:00:00Z
---

# 上游同步与子模块更新

`update.sh` 是本仓库更新上游源码和子模块指针的唯一入口；它不参与
wheel 构建。运行前必须确认根仓库和各子模块没有本地修改。

## 安全行为

- 仅更新当前分支的同名远端分支，并使用 `git merge --ff-only`；分支分叉
  或没有共同历史会失败退出，绝不会执行 `git reset --hard`。
- 更新根仓库后执行 `git submodule sync --recursive`，再以配置的浅历史深度
  递归初始化和更新子模块。
- 如果子模块目标提交不在浅历史内，脚本最多五轮逐步加深历史后重试；仍失败
  时保持现有工作树并给出人工处理建议。
- `DEPTH` 与 `JOBS` 必须是正整数；可通过环境变量或命令行参数覆盖。

## 使用方式

在仓库根目录运行 `./update.sh`。它会更新根仓库并根据根仓库记录的指针
更新所有子模块。也可使用 `--repo /path/to/repo` 更新一个独立仓库。

更新后应审查 `git status --short`、`git submodule status --recursive` 和
指针差异，再运行 `./build.sh` 重新生成本地 wheel。不要把 `.env`、`.venv/`、
`dist/` 或 `.build/` 提交到 Git。
