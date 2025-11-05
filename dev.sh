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

# 检查分支是否需要更新到最新 main
update_branch_to_main() {
    local branch_name=$1
    
    # 确保我们在目标分支上
    git checkout "$branch_name"
    
    # 检查分支是否基于最新的 main
    if ! git merge-base --is-ancestor main "$branch_name"; then
        echo "🔄 检测到分支 $branch_name 不是基于最新的 main，正在更新..."
        
        # 保存当前分支的更改（如果有）
        if git diff-index --quiet HEAD --; then
            # 没有未提交的更改，直接变基
            git rebase main
        else
            # 有未提交的更改，先暂存
            echo "⚠️  检测到未提交的更改，正在暂存并变基..."
            git stash
            git rebase main
            git stash pop
        fi
        
        # 检查变基是否成功
        if [ $? -eq 0 ]; then
            echo "✅ 分支 $branch_name 已更新到最新 main"
            
            # 检查远程分支是否存在
            if git ls-remote --heads origin "$branch_name" | grep -q "$branch_name"; then
                # 远程分支存在，强制推送
                git push -f origin "$branch_name"
                echo "✅ 已强制推送到远程分支"
            else
                echo "ℹ️  远程分支不存在，跳过推送"
            fi
        else
            echo "❌ 变基过程中出现冲突，请手动解决后继续"
            exit 1
        fi
    else
        echo "✅ 分支 $branch_name 已经基于最新的 main"
    fi
}

# 改进的登录状态检查
check_gh_auth() {
    # 方法1: 使用 auth status 命令
    if gh auth status &>/dev/null; then
        return 0
    fi
    
    # 方法2: 尝试执行一个简单的 API 调用
    if gh api user &>/dev/null; then
        return 0
    fi
    
    # 方法3: 检查是否有 token 配置
    if gh config get oauth_token &>/dev/null; then
        return 0
    fi
    
    return 1
}

# 改进的 PR 状态检查函数
get_pr_status() {
    local pr_url=$1
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        # 方法1: 使用完整的 PR 信息查询
        pr_info=$(gh pr view "$pr_url" --json state,merged,url,number 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$pr_info" ]; then
            state=$(echo "$pr_info" | jq -r '.state')
            merged=$(echo "$pr_info" | jq -r '.merged')
            pr_number=$(echo "$pr_info" | jq -r '.number')
            
            echo "$state,$merged,$pr_number"
            return 0
        fi
        
        # 方法2: 如果上面失败，尝试分别获取状态和合并状态
        state=$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)
        merged=$(gh pr view "$pr_url" --json merged --jq '.merged' 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$state" ] && [ -n "$merged" ]; then
            echo "$state,$merged,0"
            return 0
        fi
        
        # 方法3: 使用 PR API 直接查询
        if command -v jq >/dev/null 2>&1; then
            # 从 PR URL 提取仓库和 PR 编号
            if [[ "$pr_url" =~ https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
                owner="${BASH_REMATCH[1]}"
                repo="${BASH_REMATCH[2]}"
                pr_num="${BASH_REMATCH[3]}"
                
                api_result=$(gh api "repos/$owner/$repo/pulls/$pr_num" --jq '{state: .state, merged: .merged}' 2>/dev/null)
                if [ $? -eq 0 ]; then
                    state=$(echo "$api_result" | jq -r '.state')
                    merged=$(echo "$api_result" | jq -r '.merged')
                    echo "$state,$merged,$pr_num"
                    return 0
                fi
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "⚠️  获取 PR 状态失败，重试中... ($retry_count/$max_retries)"
            sleep 2
        fi
    done
    
    return 1
}

# 等待 PR 合并的函数
wait_for_pr_merge() {
    local pr_url=$1
    local check_interval=10  # 每10秒检查一次
    
    echo "PR 链接: $pr_url"
    echo "按 Ctrl+C 可中断等待并手动确认"
    echo "----------------------------------------"
    
    # 简化 GitHub CLI 检查
    if ! command -v gh &> /dev/null; then
        echo "❌ GitHub CLI (gh) 未安装，请先安装: https://cli.github.com/"
        read -p "PR 已合并? (y/n): " manual_confirm
        if [ "$manual_confirm" = "y" ] || [ "$manual_confirm" = "Y" ]; then
            return 0
        else
            echo "❌ 操作已取消"
            exit 1
        fi
    fi
    
    # 简化的登录检查 - 直接测试能否执行 API 调用
    echo "🔐 检查 GitHub 认证状态..."
    if ! check_gh_auth; then
        echo "❌ GitHub CLI 认证失败，请运行: gh auth login"
        echo "或者检查是否使用了正确的认证方式 (token 或 GitHub.com)"
        read -p "继续尝试获取 PR 状态? (y/n): " continue_confirm
        if [ "$continue_confirm" != "y" ] && [ "$continue_confirm" != "Y" ]; then
            exit 1
        fi
    else
        echo "✅ GitHub CLI 已认证"
    fi
    
    local start_time=$(date +%s)
    local spinner=("⣷" "⣯" "⣟" "⡿" "⢿" "⣻" "⣽" "⣾")
    local spin_index=0
    
    echo -n "⏳ 等待 PR 合并中..."
    
    while true; do
        # 获取 PR 状态
        pr_status=$(get_pr_status "$pr_url")
        
        if [ $? -ne 0 ] || [ -z "$pr_status" ]; then
            # 清空当前行并显示错误信息
            echo -ne "\r\033[K"
            echo "⚠️  无法获取 PR 状态，可能的原因："
            echo "   - PR URL 不正确"
            echo "   - 网络连接问题"
            echo "   - 没有访问该 PR 的权限"
            echo "   - GitHub API 限制"
            read -p "PR 已合并? (y/n): " manual_confirm
            if [ "$manual_confirm" = "y" ] || [ "$manual_confirm" = "Y" ]; then
                echo -ne "\r\033[K"
                echo "✅ 手动确认 PR 已合并"
                return 0
            else
                echo -ne "\r\033[K"
                echo -n "⏳ 继续等待 PR 状态检查..."
                sleep $check_interval
                continue
            fi
        fi
        
        state=$(echo "$pr_status" | cut -d',' -f1)
        merged=$(echo "$pr_status" | cut -d',' -f2)
        pr_number=$(echo "$pr_status" | cut -d',' -f3)
        
        # 计算已等待的时间
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        local minutes=$((elapsed_time / 60))
        local seconds=$((elapsed_time % 60))
        
        if [ "$merged" = "true" ]; then
            # 清空当前行并显示成功信息
            echo -ne "\r\033[K"
            echo "✅ PR 已成功合并! (等待时间: ${minutes}分${seconds}秒)"
            return 0
        elif [ "$state" = "CLOSED" ]; then
            # 清空当前行并显示关闭信息
            echo -ne "\r\033[K"
            echo "⚠️  PR 已关闭但未合并 (等待时间: ${minutes}分${seconds}秒)"
            read -p "是否继续执行后续操作? (y/n): " continue_confirm
            if [ "$continue_confirm" = "y" ] || [ "$continue_confirm" = "Y" ]; then
                return 0
            else
                echo "❌ 操作已取消"
                exit 1
            fi
        else
            # 更新旋转动画
            spin_index=$(( (spin_index + 1) % ${#spinner[@]} ))
            
            # 清空当前行并更新状态
            echo -ne "\r\033[K"
            echo -n "${spinner[$spin_index]} 等待中... (${minutes}分${seconds}秒)"
            
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
        
        # 更新现有分支到最新的 main
        update_branch_to_main "$existing_branch"
        
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
        pr_create_output=$(gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main \
            --repo "$UPSTREAM_REPO" 2>&1)
        
        # 改进的 PR URL 提取
        if [[ "$pr_create_output" =~ (https://github.com/[^[:space:]]+) ]]; then
            pr_url="${BASH_REMATCH[1]}"
            echo "✅ Pull Request 已创建到上游仓库: $pr_url"
        else
            echo "⚠️  无法提取 PR URL，输出为: $pr_create_output"
            # 尝试从输出中手动提取
            pr_url=$(echo "$pr_create_output" | grep -o 'https://github.com/[^ ]*' | head -1)
        fi
        
        echo -e "\033[1;33;5m⚠️  (2/2) 快去通知baobao你新建了PR! 期间你不需要做任何操作! PR被merged之后本脚本会自动执行后续指令! 等待期间也不要再编辑笔记!\033[0m"
    else
        # 非 Fork 项目：创建 PR 到本仓库的 main 分支
        echo "正在创建 Pull Request 到本仓库..."
        pr_create_output=$(gh pr create \
            --title "$branch_name" \
            --body " " \
            --base main 2>&1)
        
        # 改进的 PR URL 提取
        if [[ "$pr_create_output" =~ (https://github.com/[^[:space:]]+) ]]; then
            pr_url="${BASH_REMATCH[1]}"
            echo "✅ Pull Request 已创建: $pr_url"
        else
            echo "⚠️  无法提取 PR URL，输出为: $pr_create_output"
            # 尝试从输出中手动提取
            pr_url=$(echo "$pr_create_output" | grep -o 'https://github.com/[^ ]*' | head -1)
        fi
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