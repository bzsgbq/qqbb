#!/bin/bash
# ===============================================
# 自动化 Git 工作流脚本 (支持 fork 和非 fork 仓库)
# ===============================================

set -euo pipefail

# ----------------------------
# 获取默认分支
# ----------------------------
get_default_branch() {
    git remote show origin | grep 'HEAD branch' | awk '{print $NF}'
}

DEFAULT_BRANCH=$(get_default_branch)
echo "默认分支: $DEFAULT_BRANCH"

# ----------------------------
# 检测是否为 fork 项目
# ----------------------------
IS_FORK=false
UPSTREAM_REPO=""

if git remote get-url upstream &>/dev/null; then
    IS_FORK=true
    UPSTREAM_REPO=$(git remote get-url upstream)
    echo "✅ 检测到 fork 项目，已存在 upstream: $UPSTREAM_REPO"
elif git remote | grep -q "origin"; then
    if command -v gh &>/dev/null; then
        ORIGIN_URL=$(git remote get-url origin)
        REPO_PATH=$(echo "$ORIGIN_URL" | sed -E 's#(git@|https://)github.com[:/](.*).git#\2#')
        FORK_STATUS=$(gh api "repos/$REPO_PATH" --jq '.fork' 2>/dev/null || echo "false")
        if [ "$FORK_STATUS" = "true" ]; then
            IS_FORK=true
            echo "✅ 检测到 fork 项目，通过 GitHub API 配置 upstream..."
            PARENT_REPO=$(gh api "repos/$REPO_PATH" --jq '.parent.full_name' 2>/dev/null)
            if [ -n "$PARENT_REPO" ]; then
                git remote add upstream "https://github.com/$PARENT_REPO"
                UPSTREAM_REPO="https://github.com/$PARENT_REPO"
                echo "✅ 已添加 upstream: $UPSTREAM_REPO"
            fi
        fi
    fi
fi

if [ "$IS_FORK" = false ]; then
    echo "✅ 检测到非 fork 项目，将直接在本地仓库工作"
fi

# ----------------------------
# 同步函数
# ----------------------------
sync_repo() {
    if [ "$IS_FORK" = true ]; then
        echo "🔄 从 upstream 同步..."
        git fetch upstream
        git checkout "$DEFAULT_BRANCH"
        git merge --ff-only upstream/"$DEFAULT_BRANCH" || {
            echo "❌ 合并冲突，请手动解决后继续"
            exit 1
        }
        git push origin "$DEFAULT_BRANCH"
        echo "✅ fork 已同步到 upstream 最新状态"
    else
        echo "🔄 拉取最新代码..."
        git checkout "$DEFAULT_BRANCH"
        git pull origin "$DEFAULT_BRANCH"
        echo "✅ 已拉取最新代码"
    fi
}

# ----------------------------
# 更新分支到最新 main
# ----------------------------
update_branch_to_main() {
    local branch_name=$1
    git checkout "$branch_name"

    if ! git merge-base --is-ancestor "$DEFAULT_BRANCH" "$branch_name"; then
        echo "🔄 分支 $branch_name 不是基于最新 $DEFAULT_BRANCH，准备变基..."
        
        if ! git diff-index --quiet HEAD --; then
            git stash push -m "auto-stash"
            STASHED=true
        else
            STASHED=false
        fi

        if ! git rebase "$DEFAULT_BRANCH"; then
            echo "❌ 变基冲突，请手动解决"
            [ "$STASHED" = true ] && git stash pop
            exit 1
        fi

        [ "$STASHED" = true ] && git stash pop || true
        git push -f origin "$branch_name"
        echo "✅ 分支 $branch_name 已更新并强制推送"
    else
        echo "✅ 分支 $branch_name 已基于最新 $DEFAULT_BRANCH"
    fi
}

# ----------------------------
# GitHub CLI 登录检查
# ----------------------------
check_gh_auth() {
    gh auth status &>/dev/null || gh api user &>/dev/null || gh config get oauth_token &>/dev/null
}

# ----------------------------
# 获取 PR 状态
# ----------------------------
get_pr_status() {
    local pr_url=$1
    local retries=3
    for i in $(seq 1 $retries); do
        if pr_info=$(gh pr view "$pr_url" --json state,merged,url --jq '.'); then
            local state=$(echo "$pr_info" | jq -r '.state')
            local merged=$(echo "$pr_info" | jq -r '.merged')
            local number=$(echo "$pr_info" | jq -r '.url' | grep -o '[0-9]\+$')
            echo "$state,$merged,$number"
            return 0
        fi
        echo "⚠️ 获取 PR 状态失败，重试 ($i/$retries)..."
        sleep 2
    done
    return 1
}

# ----------------------------
# 等待 PR 合并
# ----------------------------
wait_for_pr_merge() {
    local pr_url=$1
    local interval=10

    if ! command -v gh &>/dev/null; then
        read -p "PR 已合并? (y/n): " manual
        [[ "$manual" =~ ^[yY]$ ]] && return 0
        echo "❌ 操作取消"
        exit 1
    fi

    check_gh_auth || {
        read -p "GitHub CLI 未认证, 继续? (y/n): " manual
        [[ "$manual" =~ ^[yY]$ ]] || exit 1
    }

    echo "⏳ 等待 PR 合并..."
    while true; do
        pr_status=$(get_pr_status "$pr_url")
        if [ $? -ne 0 ]; then
            read -p "无法获取 PR 状态, 是否手动确认已合并? (y/n): " manual
            [[ "$manual" =~ ^[yY]$ ]] && return 0
            sleep $interval
            continue
        fi

        state=$(echo "$pr_status" | cut -d',' -f1 | tr '[:upper:]' '[:lower:]')
        merged=$(echo "$pr_status" | cut -d',' -f2)
        if [ "$merged" = "true" ]; then
            echo "✅ PR 已合并"
            return 0
        elif [ "$state" = "closed" ]; then
            read -p "PR 已关闭未合并, 是否继续? (y/n): " manual
            [[ "$manual" =~ ^[yY]$ ]] && return 0
            echo "❌ 操作取消"
            exit 1
        fi
        sleep $interval
    done
}

# ----------------------------
# 首次同步
# ----------------------------
sync_repo

# ----------------------------
# 主流程
# ----------------------------
while true; do
    existing_branch=$(git branch --list "update_*" | head -n1 | sed 's/* //;s/ //g')
    
    if [ -n "$existing_branch" ]; then
        echo "🔁 检测到已有分支: $existing_branch"
        branch_name="$existing_branch"
        update_branch_to_main "$branch_name"
    else
        branch_name="update_$(date +%Y%m%d_%H%M%S)"
        git checkout -b "$branch_name"
        echo "✅ 已创建分支: $branch_name"
    fi

    read -p "⚠️ 开始更新笔记后按回车继续..."

    git add .
    git commit -m "update"
    git push -u origin "$branch_name"

    # 创建 PR
    pr_url=""
    if [ "$IS_FORK" = true ]; then
        repo_path=$(git remote get-url upstream | sed -E 's#(git@|https://)github.com[:/](.*).git#\2#')
        pr_url=$(gh pr create --title "$branch_name" --body " " --base "$DEFAULT_BRANCH" --repo "$repo_path" --json url | jq -r '.url')
        echo "✅ PR 创建到 upstream: $pr_url"
    else
        pr_url=$(gh pr create --title "$branch_name" --body " " --base "$DEFAULT_BRANCH" --json url | jq -r '.url')
        echo "✅ PR 创建: $pr_url"
    fi

    [ -n "$pr_url" ] && wait_for_pr_merge "$pr_url"

    sync_repo

    git branch -d "$branch_name" || true
    git push origin --delete "$branch_name" || true
    echo "✅ 分支 $branch_name 已清理"

    read -p "是否继续创建下一个更新分支? (y/n): " continue_main
    [[ "$continue_main" =~ ^[nN]$ ]] && break
done

echo "=== 流程完成 ==="
