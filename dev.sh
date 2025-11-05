#!/bin/bash

# 自动化 Git 工作流脚本 (兼容 fork 和自己仓库，自动设置 upstream)

# --------------------------
# 1. 判断是否为 fork
# --------------------------
IS_FORK=false
PARENT_REPO_URL=""

repo_info=$(gh repo view --json isFork,parent 2>/dev/null)

if echo "$repo_info" | jq -e '.isFork' &>/dev/null; then
    if echo "$repo_info" | jq -r '.isFork' | grep -q true; then
        IS_FORK=true
        PARENT_REPO_URL=$(echo "$repo_info" | jq -r '.parent.sshUrl')
    fi
fi

# --------------------------
# 2. fork 情况：检查 upstream
# --------------------------
if [ "$IS_FORK" = true ]; then
    if ! git remote get-url upstream &>/dev/null; then
        git remote add upstream "$PARENT_REPO_URL"
        echo "✅ 已添加 upstream: $PARENT_REPO_URL"
    else
        echo "✅ upstream 已存在，保持不变"
    fi
fi

# --------------------------
# 3. 同步 fork 或自己仓库
# --------------------------
echo "正在同步最新代码..."

git fetch origin
git checkout main

if [ "$IS_FORK" = true ]; then
    git fetch upstream
    git merge upstream/main
fi

git push origin main
echo "✅ 主分支已同步"

# --------------------------
# 4. 循环处理更新分支
# --------------------------
while true; do
    # 检查是否已有以 update_ 开头的分支
    existing_branch=$(git branch --list "update_*" | head -n 1 | sed 's/* //;s/ //g')

    if [ -n "$existing_branch" ]; then
        echo "🔁 检测到已存在的更新分支: $existing_branch"
        git checkout "$existing_branch"
        branch_name="$existing_branch"
    else
        branch_name="update_$(date +%Y%m%d_%H%M%S)"
        git checkout -b "$branch_name"
        echo "✅ 已创建并切换到分支: $branch_name"
    fi

    # 开发阶段
    echo -e "\033[1;33;5m⚠️  (1/2) 开始更新内容吧! 完成后请按回车继续...\033[0m"
    read -p ""

    # 提交更改
    git add .
    git commit -m "update"
    git push -u origin "$branch_name"
    echo "✅ 代码已提交并推送到远程分支"

    # --------------------------
    # 5. 创建 PR
    # --------------------------
    echo "正在创建 Pull Request..."

    if [ "$IS_FORK" = true ]; then
        # fork：PR 目标为 upstream，分支在自己的 fork 上
        gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main \
            --repo "$(git remote get-url upstream | sed 's/.*github.com[:/]//' | sed 's/\.git$//')" \
            --head "$(git config user.login):$branch_name"
    else
        # 自己仓库：PR 目标为当前仓库
        gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main \
            --head "$branch_name"
    fi

    echo "✅ Pull Request 已创建"

    # 等待 PR 审查和合并
    echo "请等待 PR 审查和合并..."
    echo -e "\033[1;33;5m⚠️  (2/2) 完成后按回车继续...\033[0m"
    read -p ""

    # 再次同步主分支
    git checkout main
    git fetch origin
    if [ "$IS_FORK" = true ]; then
        git fetch upstream
        git merge upstream/main
    fi
    git push origin main
    echo "✅ 已同步最新内容"

    # 清理分支
    git branch -d "$branch_name"
    git push origin --delete "$branch_name"
    echo "✅ 分支 $branch_name 已清理"

    echo "=== 流程完成 ==="
    echo "----------------------------------------"
done
