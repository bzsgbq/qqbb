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

# 等待 PR 合并的函数
wait_for_pr_merge() {
    local pr_url=$1
    local check_interval=10  # 每10秒检查一次
    
    echo -e "\033[1;35;5m⏳  正在等待 PR 合并...\033[0m"
    echo "PR 链接: $pr_url"
    echo "提示: 你可以按 Ctrl+C 中断等待，手动确认后继续"
    echo "----------------------------------------"
    
    while true; do
        # 获取 PR 状态
        pr_state=$(gh pr view "$pr_url" --json state,merged --jq '.state + "," + (.merged | tostring)' 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            echo "⚠️  无法获取 PR 状态，请手动确认 PR 是否已合并"
            read -p "PR 已合并? (y/n): " manual_confirm
            if [ "$manual_confirm" = "y" ] || [ "$manual_confirm" = "Y" ]; then
                echo "✅ 手动确认 PR 已合并"
                return 0
            else
                echo "继续等待..."
                sleep $check_interval
                continue
            fi
        fi
        
        state=$(echo "$pr_state" | cut -d',' -f1)
        merged=$(echo "$pr_state" | cut -d',' -f2)
        
        if [ "$merged" = "true" ]; then
            echo "✅ PR 已成功合并!"
            return 0
        elif [ "$state" = "CLOSED" ]; then
            echo "⚠️  PR 已关闭但未合并"
            read -p "是否继续执行后续操作? (y/n): " continue_confirm
            if [ "$continue_confirm" = "y" ] || [ "$continue_confirm" = "Y" ]; then
                return 0
            else
                echo "❌ 操作已取消"
                exit 1
            fi
        else
            # PR 仍在 OPEN 状态
            echo "⏳ PR 状态: $state - 等待合并中... (每${check_interval}秒检查一次)"
            sleep $check_interval
        fi
    done
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
    
    # 创建 PR 并获取 PR URL
    pr_url=""
    if [ "$IS_FORK" = true ]; then
        # Fork 项目：创建 PR 到上游仓库
        echo "正在创建 Pull Request 到上游仓库..."
        UPSTREAM_REPO=$(git remote get-url upstream | sed 's/.*github.com[:/]//' | sed 's/\.git$//')
        pr_url=$(gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main \
            --repo "$UPSTREAM_REPO" 2>&1 | grep -o 'https://github.com[^ ]*')
        
        echo "✅ Pull Request 已创建到上游仓库"
        echo -e "\033[1;35;5m⏳  (2/2) 快去通知baobao你新建了PR!\033[0m"
    else
        # 非 Fork 项目：创建 PR 到本仓库的 main 分支
        echo "正在创建 Pull Request 到本仓库..."
        pr_url=$(gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main 2>&1 | grep -o 'https://github.com[^ ]*')
        
        echo "✅ Pull Request 已创建"
        echo -e "\033[1;35;5m⏳  (2/2) 请审查并合并 PR!\033[0m"
    fi
    
    # 等待 PR 合并
    if [ -n "$pr_url" ]; then
        wait_for_pr_merge "$pr_url"
    else
        echo "⚠️  无法获取 PR URL，请手动确认 PR 已合并后按回车继续..."
        read -p ""
    fi
    
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