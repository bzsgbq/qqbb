#!/bin/bash

# 自动化 Git 工作流脚本 (支持 fork 和非 fork 项目)

# 检测是否为 fork 项目
IS_FORK=false
if git remote get-url upstream &> /dev/null; then
    IS_FORK=true
    echo "✅ 检测到这是一个 fork 项目"
elif git remote | grep -q "origin"; then
    # 尝试通过 GitHub API 检测是否为 fork
    REPO_URL=$(git remote get-url origin | sed 's/.*github.com[:/]//' | sed 's/\.git$//')
    if command -v gh &> /dev/null; then
        FORK_STATUS=$(gh api "repos/$REPO_URL" --jq '.fork' 2>/dev/null)
        if [ "$FORK_STATUS" = "true" ]; then
            IS_FORK=true
            echo "✅ 检测到这是一个 fork 项目，正在配置上游仓库..."
            # 获取父仓库 URL
            PARENT_REPO=$(gh api "repos/$REPO_URL" --jq '.parent.full_name' 2>/dev/null)
            if [ -n "$PARENT_REPO" ]; then
                git remote add upstream "https://github.com/$PARENT_REPO"
                echo "✅ 已自动添加上游仓库: https://github.com/$PARENT_REPO"
            fi
        fi
    fi
fi

if [ "$IS_FORK" = false ]; then
    echo "✅ 检测到这是一个非 fork 项目，将直接在本地仓库工作"
fi

# 同步函数 (仅用于 fork 项目)
sync_fork() {
    if [ "$IS_FORK" = true ]; then
        echo "正在从上游仓库同步..."
        git fetch upstream
        git checkout main
        git merge upstream/main
        git push origin main
        echo "✅ Fork 已同步到上游最新状态"
    else
        echo "正在拉取最新代码..."
        git checkout main
        git pull origin main
        echo "✅ 已拉取最新代码"
    fi
}

# 首次同步
sync_fork

while true; do
    # 检查是否已有以 update_ 开头的分支
    existing_branch=$(git branch --list "update_*" | head -n 1 | sed 's/* //;s/ //g')

    if [ -n "$existing_branch" ]; then
        echo "🔁 检测到已存在的更新分支: $existing_branch"
        git checkout "$existing_branch"
        branch_name="$existing_branch"
    else
        # 如果没有，就新建一个
        branch_name="update_$(date +%Y%m%d_%H%M%S)"
        git checkout -b "$branch_name"
        echo "✅ 已创建并切换到分支: $branch_name"
    fi
    
    # 开发阶段
    echo -e "\033[1;33;5m⚠️  (1/2) 开始打开logseq更新笔记吧! 更新完成后请按回车继续...\033[0m"
    read -p ""
    
    # 提交更改
    git add .
    git commit -m "update"
    git push -u origin "$branch_name"
    
    echo "✅ 代码已提交并推送到远程分支"
    
    # 创建 PR
    if [ "$IS_FORK" = true ]; then
        # Fork 项目：创建 PR 到上游仓库
        echo "正在创建 Pull Request 到上游仓库..."
        UPSTREAM_REPO=$(git remote get-url upstream | sed 's/.*github.com[:/]//' | sed 's/\.git$//')
        gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main \
            --repo "$UPSTREAM_REPO"
        
        echo "✅ Pull Request 已创建到上游仓库"
        echo -e "\033[1;35;5m⏳  (2/2) 快去通知baobao你新建了PR! 并等待baobao合并完成! 合并完成后按回车继续...\033[0m"
    else
        # 非 Fork 项目：创建 PR 到本仓库的 main 分支
        echo "正在创建 Pull Request 到本仓库..."
        gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main
        
        echo "✅ Pull Request 已创建"
        echo -e "\033[1;35;5m⏳  (2/2) 请审查并合并 PR! 合并完成后按回车继续...\033[0m"
    fi
    
    read -p ""
    
    # 同步最新代码
    sync_fork
    
    echo "✅ 已同步最新的合并内容"
    
    # 清理分支
    git branch -d "$branch_name"
    git push origin --delete "$branch_name"
    
    echo "✅ 分支 $branch_name 已清理"
    echo "=== 流程完成 ==="
    echo "----------------------------------------"
done