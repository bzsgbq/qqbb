#!/bin/bash

# 自动化 Git 工作流脚本 (包含 fork 同步)

# 首先检查是否已配置上游仓库
if ! git remote get-url upstream &> /dev/null; then
    # echo "未配置上游仓库，请先设置上游仓库:"
    # read -p "请输入上游仓库URL: " upstream_url
    # git remote add upstream "$upstream_url"
    # echo "✅ 已添加上游仓库: $upstream_url"
    git remote add upstream "https://github.com/bzsgbq/qqbb"
fi

# 1. 同步 fork：从上游仓库获取最新代码
echo "正在从上游仓库同步..."
git fetch upstream

# 2. 切换到主分支并合并上游更改
git checkout main
git merge upstream/main

# 3. 将同步后的代码推送到自己的 fork
git push origin main

echo "✅ Fork 已同步到上游最新状态"

while true; do
    # 4. 创建特性分支
    branch_name="update_$(date +%Y%m%d_%H%M%S)"
    git checkout -b "$branch_name"
    
    echo "✅ 已创建并切换到分支: $branch_name"

    echo "=== 已经准备好! 您现在可以开始更新 qqbb 空间... ==="
    
    # 5. 开发阶段
    read -p "更新完成后请按回车继续..."
    
    # 6. 提交更改
    git add .
    git commit -m "update"
    git push -u origin "$branch_name"
    
    echo "✅ 代码已提交并推送到远程分支"
    
    # 7. 创建 PR（指向上游仓库）
    echo "正在创建 Pull Request..."
    gh pr create \
        --title "$branch_name" \
        --body " " \
        --base main \
        --repo "$(git remote get-url upstream | sed 's/.*github.com[:/]//' | sed 's/\.git$//')"
    
    echo "✅ Pull Request 已创建"
    
    # 8. 等待 PR 审查和合并
    echo "请等待 PR 审查和合并..."
    read -p "PR 合并完成后按回车继续..."
    
    # 9. 再次同步 fork（获取刚刚合并的更改）
    git checkout main
    git fetch upstream
    git merge upstream/main
    git push origin main
    
    echo "✅ 已同步最新的合并内容"
    
    # 10. 清理分支
    git branch -d "$branch_name"
    git push origin --delete "$branch_name"
    
    echo "✅ 分支 $branch_name 已清理"
    echo "=== 流程完成 ==="
    echo "----------------------------------------"
done