<#
.SYNOPSIS
    奥术前线 V0.45 ENet 服务端一键部署工具

.DESCRIPTION
    把本地 tools/relay_server_enet/ 的 Go ENet 中继服务器部署到云服务器。
    支持两种模式：
      1. 本地已构建出 relay_server_enet 二进制：直接上传二进制。
      2. 只有源码：上传 go.mod/main.go，在服务器上用 go build 构建（服务器需安装 Go 和 libenet-dev）。

    健康检查使用进程 + UDP 监听检查（ss -ulpn），不再使用 TCP 探测。

.EXAMPLE
    .\deploy_enet.ps1 -SetupKey          # 复用/安装 SSH 密钥
    .\deploy_enet.ps1                    # 部署：上传 + 远端构建/校验 + 重启 + 健康检查
    .\deploy_enet.ps1 -Status            # 查看服务器进程与日志尾部
    .\deploy_enet.ps1 -DryRun            # 只打印命令
#>
param(
    [switch]$SetupKey,
    [switch]$Status,
    [switch]$SkipRestart,
    [switch]$DryRun,
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

# ================= 配置加载 =================
if ($ConfigPath -eq "") {
    $enetDefault = Join-Path $PSScriptRoot "deploy_enet.config.json"
    if (Test-Path $enetDefault) {
        $ConfigPath = $enetDefault
    } else {
        $ConfigPath = Join-Path $PSScriptRoot "deploy.config.json"
    }
}
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[错误] 找不到配置文件: $ConfigPath" -ForegroundColor Red
    exit 1
}
$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$HostName = $cfg.host
$UserName = $cfg.user
$Port = if ($null -ne $cfg.port) { [int]$cfg.port } else { 22 }
$KeyPath = $cfg.sshKeyPath
if (-not $KeyPath) { $KeyPath = "~/.ssh/id_arcane_relay" }
if ($KeyPath.StartsWith("~/")) { $KeyPath = Join-Path $HOME $KeyPath.Substring(2) }
$RemoteDir = if ($null -ne $cfg.remoteDir) { $cfg.remoteDir } else { "/opt/relay-server-enet" }
$RemoteFile = if ($null -ne $cfg.remoteFile) { $cfg.remoteFile } else { "relay_server_enet" }
$RemotePath = "{0}/{1}" -f $RemoteDir.TrimEnd("/"), $RemoteFile
# pgrep/pkill 模式：避免第一个字符被 shell 自身匹配，例如 relay_server_enet -> [r]elay_server_enet
$ProcPattern = "[" + $RemoteFile.Substring(0, 1) + "]" + $RemoteFile.Substring(1)
if ($RemoteFile -ne "relay_server_enet") {
    Write-Warn "当前 remoteFile 是 '$RemoteFile'，不是默认的 'relay_server_enet'；如果这是旧 deploy.config.json，请改用 deploy_enet.config.json。"
}
$LaunchArgs = if ($null -ne $cfg.launchArgs) { $cfg.launchArgs } else { "--host 0.0.0.0 --port 8765 --results /opt/relay-server-enet/match_results.jsonl" }
$LogFile = if ($null -ne $cfg.logFile) { $cfg.logFile } else { "relay_server_enet.log" }
$HealthPort = if ($null -ne $cfg.healthPort) { $cfg.healthPort } else { 8765 }
$Target = "$UserName@$HostName"

$SrcDir = (Resolve-Path (Join-Path $PSScriptRoot "..\relay_server_enet")).Path
$LocalBin = Join-Path $SrcDir "relay_server_enet.exe"
if (-not (Test-Path $LocalBin)) { $LocalBin = Join-Path $SrcDir "relay_server_enet" }

function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "    [警告] $m" -ForegroundColor Yellow }
function Write-Fail([string]$m) { Write-Host "    [错误] $m" -ForegroundColor Red }

function Invoke-Ssh {
    param([string]$RemoteCmd, [switch]$Interactive)
    $base = @("-p", "$Port", "-o", "ConnectTimeout=30", "-o", "ServerAliveInterval=15")
    if (-not $Interactive) { $base += @("-i", $KeyPath, "-o", "BatchMode=yes") }
    if ($DryRun) {
        Write-Host "        [DRY] ssh $($base -join ' ') $Target '$RemoteCmd'" -ForegroundColor DarkGray
        return @()
    }
    $output = & ssh @base $Target $RemoteCmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh 失败 (exit $LASTEXITCODE): $RemoteCmd`n$($output -join "`n")" }
    return $output
}

function Invoke-Scp {
    param([string]$LocalPath, [string]$RemoteDest)
    $argList = @("-i", $KeyPath, "-P", "$Port", $LocalPath, "${Target}:$RemoteDest")
    if ($DryRun) { Write-Host "        [DRY] scp $($argList -join ' ')" -ForegroundColor DarkGray; return }
    & scp @argList
    if ($LASTEXITCODE -ne 0) { throw "scp 上传失败" }
}

function Test-SshKey {
    if ($DryRun) {
        if (Test-Path $KeyPath) { return $true }
        Write-Host "        [DRY] 密钥不存在，实际执行时提示先运行 -SetupKey" -ForegroundColor DarkGray
        return $false
    }
    if (-not (Test-Path $KeyPath)) { return $false }
    & ssh -i $KeyPath -p $Port -o BatchMode=yes -o ConnectTimeout=30 $Target "echo __OK__" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Setup-Key {
    if (-not (Test-Path $KeyPath)) {
        $keyDir = Split-Path $KeyPath
        if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        Write-Step "生成新密钥: $KeyPath"
        & ssh-keygen -t ed25519 -N '""' -f $KeyPath -C "arcane-relay-enet-deploy"
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 失败" }
    } else {
        Write-Ok "使用已有密钥: $KeyPath"
    }
    $pub = (Get-Content "$KeyPath.pub" -Raw).Trim()
    Write-Step "安装公钥到 ${Target}"
    Invoke-Ssh -RemoteCmd "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys && echo PUBKEY_INSTALLED" -Interactive
    Write-Step "验证免密登录..."
    if (Test-SshKey) { Write-Ok "免密登录验证通过" } else { throw "免密登录验证失败" }
}

function Deploy {
    if (-not (Test-Path $SrcDir)) { throw "找不到服务端源码目录: $SrcDir" }
    if (-not (Test-Path (Join-Path $SrcDir "main.go"))) { throw "缺少 main.go" }
    if (-not (Test-SshKey)) {
        Write-Fail "SSH 密钥未配置或未通过验证，首次请运行: .\deploy_enet.ps1 -SetupKey"
        exit 1
    }
    Write-Step "确保远端目录存在"
    Invoke-Ssh -RemoteCmd "mkdir -p '$RemoteDir'"

    $useLocalBin = Test-Path $LocalBin
    if ($useLocalBin) {
        Write-Step "上传本地二进制 $($LocalBin)"
        Invoke-Scp -LocalPath $LocalBin -RemoteDest "$RemotePath.new"
        Invoke-Ssh -RemoteCmd "chmod +x '$RemotePath.new' && cp '$RemotePath' '$RemotePath.prev' 2>/dev/null || true; mv '$RemotePath.new' '$RemotePath'"
    } else {
        Write-Step "上传 Go 源码（未找到本地二进制，远端 go build）"
        Invoke-Scp -LocalPath (Join-Path $SrcDir "main.go") -RemoteDest "$RemoteDir/main.go.new"
        Invoke-Scp -LocalPath (Join-Path $SrcDir "go.mod") -RemoteDest "$RemoteDir/go.mod.new"
        Invoke-Ssh -RemoteCmd "cd '$RemoteDir' && mv main.go.new main.go && mv go.mod.new go.mod && cp '$RemotePath' '$RemotePath.prev' 2>/dev/null || true; go mod tidy && go build -o '$RemotePath' main.go && chmod +x '$RemotePath' && echo BUILD_OK"
    }

    if ($SkipRestart) {
        Write-Ok "已跳过重启（-SkipRestart）。"
        return
    }

    Write-Step "重启服务"
    Invoke-Ssh -RemoteCmd "pkill -f '$ProcPattern' 2>/dev/null; sleep 1; echo KILLED"
    Invoke-Ssh -RemoteCmd "nohup '$RemotePath' $LaunchArgs >> '$RemoteDir/$LogFile' 2>&1 < /dev/null & echo LAUNCHED"
    if (-not $DryRun) { Start-Sleep -Seconds 2 }

    Write-Step "健康检查"
    $aliveOut = Invoke-Ssh -RemoteCmd "pgrep -f '$ProcPattern' && echo __ALIVE__ || echo __DEAD__"
    $alive = $DryRun -or (($aliveOut -join "`n") -match "__ALIVE__")
    $udpOut = Invoke-Ssh -RemoteCmd "ss -ulpn 2>/dev/null | grep ':$HealthPort ' && echo __UDP_OK__ || echo __UDP_DEAD__"
    $udpOk = $DryRun -or (($udpOut -join "`n") -match "__UDP_OK__")
    if ($alive -and $udpOk) {
        Write-Ok "ENet 服务已重启并监听 UDP ${HostName}:$HealthPort，部署完成 ✓"
    } else {
        Write-Warn "进程或 UDP 监听未通过；请查看日志: $RemoteDir/$LogFile"
        Write-Warn "回滚：cp '$RemotePath.prev' '$RemotePath' 后重新运行本脚本 -SkipRestart 并手动重启。"
    }
}

function Show-Status {
    Write-Step "服务器进程"
    Invoke-Ssh -RemoteCmd "ps -eo pid,etime,cmd | grep '$ProcPattern' | grep -v grep || echo '(未运行)'"
    Write-Step "日志尾部（$RemoteDir/$LogFile）"
    Invoke-Ssh -RemoteCmd "tail -n 30 '$RemoteDir/$LogFile' 2>/dev/null || echo '(无日志文件)'"
    Write-Step "UDP 监听"
    Invoke-Ssh -RemoteCmd "ss -ulpn 2>/dev/null | grep ':$HealthPort ' || echo '(未监听)'"
}

if ($SetupKey) { Setup-Key; exit 0 }
if ($Status) { Show-Status; exit 0 }
Deploy
