<#
.SYNOPSIS
    奥术前线服务端一键部署工具

.DESCRIPTION
    把本机 tools/relay_server/relay_server.py 推送到云服务器并自动重启。
    服务器地址、路径、启动参数等从同目录 deploy.config.json 读取
    （复制 deploy.config.example.json 得到）。

.EXAMPLE
    .\deploy.ps1 -SetupKey          # 一次性：生成 SSH 密钥并安装到服务器（首次输入一次密码）
    .\deploy.ps1                    # 部署：上传 + 语法校验 + 重启 + 健康检查
    .\deploy.ps1 -Status            # 只查看服务器进程与日志尾部
    .\deploy.ps1 -SkipRestart       # 只上传文件，不重启
    .\deploy.ps1 -DryRun            # 只打印将执行的命令，不真正执行
#>
param(
    [switch]$SetupKey,
    [switch]$Status,
    [switch]$SkipRestart,
    [switch]$DryRun,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "deploy.config.json")
)

$ErrorActionPreference = "Stop"

# ================= 配置加载 =================
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[错误] 找不到配置文件: $ConfigPath" -ForegroundColor Red
    Write-Host "       请先复制 deploy.config.example.json 为 deploy.config.json 并按需修改。" -ForegroundColor Yellow
    exit 1
}
$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json

if (-not $cfg.host -or -not $cfg.user) {
    Write-Host "[错误] 配置缺少 host 或 user 字段。" -ForegroundColor Red
    exit 1
}

$HostName     = $cfg.host
$UserName     = $cfg.user
$Port         = if ($null -ne $cfg.port) { [int]$cfg.port } else { 22 }
$KeyPath      = $cfg.sshKeyPath
if (-not $KeyPath) { $KeyPath = "~/.ssh/id_arcane_relay" }
if ($KeyPath.StartsWith("~/")) { $KeyPath = Join-Path $HOME $KeyPath.Substring(2) }
$RemoteDir    = if ($null -ne $cfg.remoteDir) { $cfg.remoteDir } else { "/opt/relay-server" }
$RemoteFile   = if ($null -ne $cfg.remoteFile) { $cfg.remoteFile } else { "relay_server.py" }
$RemotePath   = "{0}/{1}" -f $RemoteDir.TrimEnd("/"), $RemoteFile
$RemotePython = if ($null -ne $cfg.remotePython) { $cfg.remotePython } else { "python3" }
$LaunchArgs   = if ($null -ne $cfg.launchArgs) { $cfg.launchArgs } else { "--host 0.0.0.0 --port 8765" }
$HealthPort   = if ($null -ne $cfg.healthPort) { [int]$cfg.healthPort } else { 8765 }
$LogFile      = if ($null -ne $cfg.logFile) { $cfg.logFile } else { "relay_server.log" }

$LocalFile = (Get-Item (Join-Path $PSScriptRoot "..\relay_server\relay_server.py")).FullName
$Target    = "$UserName@$HostName"

# ================= 工具函数 =================
function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "    [警告] $m" -ForegroundColor Yellow }
function Write-Fail([string]$m) { Write-Host "    [错误] $m" -ForegroundColor Red }

function Assert-Exit {
    param([int]$Code, [string]$What)
    if ($Code -ne 0) { throw "$What 失败 (exit $Code)" }
}

function Invoke-Ssh {
    param([string]$RemoteCmd, [switch]$Interactive)
    $base = @("-p", "$Port", "-o", "ConnectTimeout=15")
    if (-not $Interactive) { $base += @("-i", $KeyPath, "-o", "BatchMode=yes") }
    if ($DryRun) {
        Write-Host "        [DRY] ssh $($base -join ' ') $Target '$RemoteCmd'" -ForegroundColor DarkGray
        return @()
    }
    $output = & ssh @base $Target $RemoteCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ssh 失败 (exit $LASTEXITCODE): $RemoteCmd`n$($output -join "`n")"
    }
    return $output
}

function Invoke-Scp {
    param([string]$LocalPath, [string]$RemoteDest)
    $argList = @("-i", $KeyPath, "-P", "$Port", $LocalPath, "${Target}:$RemoteDest")
    if ($DryRun) {
        Write-Host "        [DRY] scp $($argList -join ' ')" -ForegroundColor DarkGray
        return
    }
    & scp @argList
    Assert-Exit $LASTEXITCODE "scp 上传"
}

function Test-SshKey {
    if ($DryRun) {
        if (Test-Path $KeyPath) { return $true }
        Write-Host "        [DRY] 密钥不存在，实际执行时提示先运行 -SetupKey" -ForegroundColor DarkGray
        return $false
    }
    if (-not (Test-Path $KeyPath)) { return $false }
    & ssh -i $KeyPath -p $Port -o BatchMode=yes -o ConnectTimeout=10 $Target "echo __OK__" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-TcpPort {
    param([string]$HostAddr, [int]$TcpPort, [int]$TimeoutMs = 6000)
    if ($DryRun) {
        Write-Host "        [DRY] 检测端口 ${HostAddr}:$TcpPort（跳过）" -ForegroundColor DarkGray
        return $true
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostAddr, $TcpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Setup-Key {
    if ($DryRun) {
        Write-Warn "-SetupKey 与 -DryRun 同时使用无意义，忽略 -DryRun。"
    }
    if (-not (Test-Path $KeyPath)) {
        $keyDir = Split-Path $KeyPath
        if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        Write-Step "生成新密钥: $KeyPath"
        & ssh-keygen -t ed25519 -N '""' -f $KeyPath -C "arcane-relay-deploy"
        Assert-Exit $LASTEXITCODE "ssh-keygen"
        Write-Ok "已生成密钥对"
    } else {
        Write-Ok "使用已有密钥: $KeyPath"
    }
    if (-not (Test-Path "$KeyPath.pub")) { throw "缺少公钥文件: $KeyPath.pub" }

    $pubContent = Get-Content "$KeyPath.pub" -Raw
    if (-not $pubContent) { throw "公钥文件为空: $KeyPath.pub" }
    $pub = $pubContent.Trim()
    Write-Step "安装公钥到 ${Target}:~/.ssh/authorized_keys（首次会提示输入服务器密码）"
    $installCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
        "grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; " +
        "chmod 600 ~/.ssh/authorized_keys && echo PUBKEY_INSTALLED"
    Invoke-Ssh -RemoteCmd $installCmd -Interactive

    Write-Step "验证免密登录..."
    if (Test-SshKey) {
        Write-Ok "免密登录验证通过，之后直接运行 .\deploy.ps1 即可部署。"
    } else {
        throw "免密登录验证失败：请确认服务器 sshd 允许 pubkey 认证（/etc/ssh/sshd_config 的 PubkeyAuthentication yes）。"
    }
}

function Deploy {
    if (-not (Test-Path $LocalFile)) { throw "找不到本地服务端文件: $LocalFile" }

    Write-Step "检查 SSH 免密登录"
    if (-not (Test-SshKey)) {
        Write-Fail "SSH 密钥未配置或未通过验证，首次使用请先运行: .\deploy.ps1 -SetupKey"
        exit 1
    }

    $localSize = (Get-Item $LocalFile).Length
    $localHash = (Get-FileHash $LocalFile -Algorithm MD5).Hash
    Write-Step "确保远端目录存在"
    Invoke-Ssh -RemoteCmd "mkdir -p '$RemoteDir'"

    Write-Step "上传 $((Split-Path $LocalFile -Leaf))（$localSize 字节, MD5 $localHash）"
    Invoke-Scp -LocalPath $LocalFile -RemoteDest "$RemoteDir/$RemoteFile.new"

    Write-Step "远端语法校验 + 原子替换（失败自动回滚到上一版）"
    $checkCmd = "set -e; " +
        "cp '$RemotePath' '$RemotePath.prev' 2>/dev/null || true; " +
        "mv '$RemotePath.new' '$RemotePath'; " +
        "if $RemotePython -m py_compile '$RemotePath'; then echo COMPILE_OK; " +
        "else echo COMPILE_FAIL; mv '$RemotePath.prev' '$RemotePath'; exit 1; fi"
    $checkOut = Invoke-Ssh -RemoteCmd $checkCmd
    $checkOut | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }

    if (-not $DryRun) {
        $remoteSize = (Invoke-Ssh -RemoteCmd "wc -c < '$RemotePath'").Trim()
        Write-Ok "服务器文件已更新（$remoteSize 字节）"
        if ($remoteSize -ne $localSize) {
            Write-Warn "服务器文件大小与本地不一致（$remoteSize vs $localSize），请检查。"
        }
    } else {
        Write-Ok "服务器文件已更新（DRY，未实际执行）"
    }

    if ($SkipRestart) {
        Write-Ok "已跳过重启（-SkipRestart）。"
        return
    }

    Write-Step "重启服务（先杀旧进程，再 nohup 拉起；日志: $RemoteDir/$LogFile）"
    Invoke-Ssh -RemoteCmd "pkill -f '[r]elay_server.py' 2>/dev/null; sleep 1; echo KILLED_NEW"
    Invoke-Ssh -RemoteCmd "nohup $RemotePython $RemotePath $LaunchArgs >> '$RemoteDir/$LogFile' 2>&1 < /dev/null & echo RELAUNCHED_NEW"
    if (-not $DryRun) { Start-Sleep -Seconds 2 }

    Write-Step "健康检查"
    $aliveOut = Invoke-Ssh -RemoteCmd "pgrep -f '[r]elay_server.py' && echo __ALIVE__ || echo __DEAD__"
    $alive = $DryRun -or (($aliveOut -join "`n") -match "__ALIVE__")
    $tcpOk  = Test-TcpPort -HostAddr $HostName -TcpPort $HealthPort

    if ($alive -and $tcpOk) {
        Write-Ok "服务已重启并监听 ${HostName}:$HealthPort，部署完成 ✓"
        return
    }
    if ($alive -and -not $tcpOk) {
        Write-Warn "进程已启动，但 ${HostName}:$HealthPort 端口不通（检查服务器防火墙 / 绑定地址）。"
        return
    }

    Write-Warn "进程未存活，自动回滚到上一个版本..."
    Invoke-Ssh -RemoteCmd "mv '$RemotePath.prev' '$RemotePath' && echo RESTORED"
    Invoke-Ssh -RemoteCmd "pkill -f '[r]elay_server.py' 2>/dev/null; sleep 1; echo KILLED_OLD"
    Invoke-Ssh -RemoteCmd "nohup $RemotePython $RemotePath $LaunchArgs >> '$RemoteDir/$LogFile' 2>&1 < /dev/null & echo RELAUNCHED_OLD"
    if (-not $DryRun) { Start-Sleep -Seconds 2 }
    $alive2 = $DryRun -or (((Invoke-Ssh -RemoteCmd "pgrep -f '[r]elay_server.py' && echo __ALIVE__ || echo __DEAD__") -join "`n") -match "__ALIVE__")
    if ($alive2) {
        Write-Warn "已回滚到上一个版本并恢复运行。新版本启动失败，请检查代码（依赖、端口占用等）。"
    } else {
        throw "回滚后仍无法启动，请登录服务器手动排查（日志: $RemoteDir/$LogFile）。"
    }
}

function Show-Status {
    Write-Step "服务器进程"
    Invoke-Ssh -RemoteCmd "ps -eo pid,etime,cmd | grep '[r]elay_server.py' | grep -v grep || echo '(未运行)'"
    Write-Step "日志尾部（$RemoteDir/$LogFile）"
    Invoke-Ssh -RemoteCmd "tail -n 30 '$RemoteDir/$LogFile' 2>/dev/null || echo '(无日志文件)'"
    Write-Step "端口检查（本机视角）"
    if (Test-TcpPort -HostAddr $HostName -TcpPort $HealthPort) {
        Write-Ok "${HostName}:$HealthPort 可连接"
    } else {
        Write-Warn "${HostName}:$HealthPort 不可连接"
    }
}

# ================= 入口 =================
if ($SetupKey) {
    Setup-Key
    exit 0
}
if ($Status) {
    Show-Status
    exit 0
}
Deploy
