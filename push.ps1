# =====================================================================
# 一键推送 impala-to-doris skill 到 GitHub
#
# 用法（在本目录下用 PowerShell 跑）：
#   .\push.ps1                    # 默认公开仓库 + 用网页流程
#   .\push.ps1 -UseGhCli          # 如果你装了 gh CLI 并已登录, 一行搞定
#   .\push.ps1 -Private           # 创建为私有仓库（需 gh CLI）
#
# 默认假设：
#   - GitHub 用户名: zhoumengyang002
#   - 仓库名:        impala-to-doris
#   - 默认分支:      main
#   - 默认可见性:    public
# =====================================================================

param(
    [string]$User = "zhoumengyang002",
    [string]$Repo = "impala-to-doris",
    [switch]$UseGhCli,
    [switch]$Private
)

$ErrorActionPreference = "Stop"

# 颜色输出
function Write-Step($msg) { Write-Host ">>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

# ---- 0. 前置检查 ----
Write-Step "检查 git 是否安装"
try {
    $gitVer = git --version
    Write-Ok $gitVer
} catch {
    Write-Warn "git 未安装。请先去 https://git-scm.com/download/win 装一下再回来。"
    exit 1
}

# ---- 1. git 初始化 + 提交 ----
if (-not (Test-Path ".git")) {
    Write-Step "初始化 git 仓库"
    git init -b main | Out-Null
} else {
    Write-Warn ".git 已存在, 跳过 init"
}

Write-Step "添加文件并提交"
git add .
$status = git status --porcelain
if ($status) {
    git commit -m "Initial commit: impala-to-doris migration skill"
    Write-Ok "已提交"
} else {
    Write-Warn "没有变更可提交（可能已经提交过）"
}

# ---- 2. 配置远端 ----
$remoteUrl = "https://github.com/$User/$Repo.git"

$existingRemote = git remote
if ($existingRemote -contains "origin") {
    Write-Warn "已有 origin remote, 跳过 add"
    git remote set-url origin $remoteUrl
} else {
    git remote add origin $remoteUrl
    Write-Ok "remote 设置为 $remoteUrl"
}

# ---- 3. 推送 ----
if ($UseGhCli) {
    # gh CLI 自动创建 + 推送
    Write-Step "用 gh CLI 创建并推送（需要先 gh auth login）"
    try {
        gh --version | Out-Null
    } catch {
        Write-Warn "gh CLI 未安装。可以从 https://cli.github.com/ 下载，或者去掉 -UseGhCli 走手动流程"
        exit 1
    }

    $visibility = if ($Private) { "--private" } else { "--public" }
    gh repo create "$User/$Repo" $visibility --source=. --remote=origin --push --description "Agent Skill for migrating PHP projects from Impala SQL to Apache Doris"

    Write-Ok "完成！仓库地址: https://github.com/$User/$Repo"
} else {
    # 手动流程
    Write-Host ""
    Write-Step "下面是手动流程（不用 gh CLI 的话）"
    Write-Host ""
    Write-Host "1. 浏览器打开:  https://github.com/new" -ForegroundColor White
    Write-Host "   - Repository name:  $Repo" -ForegroundColor White
    Write-Host "   - Description:      Agent Skill for migrating PHP projects from Impala SQL to Apache Doris" -ForegroundColor White
    Write-Host "   - 选 Public" -ForegroundColor White
    Write-Host "   - 不要勾选 'Add a README'/'gitignore'/'license' (我们已经有了)" -ForegroundColor White
    Write-Host "   - 点 Create repository" -ForegroundColor White
    Write-Host ""
    Write-Host "2. 创建好后, 回到这个 PowerShell 窗口, 按回车继续推送..." -ForegroundColor White
    Read-Host

    Write-Step "推送到 origin/main"
    git push -u origin main

    Write-Ok "完成！仓库地址: https://github.com/$User/$Repo"
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host " 完成! 别人现在可以用下面的命令来安装这个 skill:"        -ForegroundColor Green
Write-Host ""
Write-Host "   npx skills add github:$User/$Repo"                       -ForegroundColor White
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
