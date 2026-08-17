# 服务端一键部署工具（tools/deploy_relay/）

把本地 `tools/relay_server/relay_server.py` 推送到云服务器并自动重启，一条命令完成。
本工具只推送服务端单文件，服务器的 `match_results.jsonl` 等运行时数据不受影响。

## 快速开始

1. 复制配置（用编辑器另存为 `deploy.config.json` 或直接复制）：

   ```
   copy deploy.config.example.json deploy.config.json
   ```

   按需修改 `host` / `user` / `remoteDir` / `launchArgs` 等字段（说明见下方表格）。
   **不做这一步，工具会拒绝运行。**

2. 首次设置免密登录（只需一次；会提示输入一次服务器 root 密码）：
   **直接双击 `setup-key.cmd`**，或在命令行运行：

   ```
   .\deploy.ps1 -SetupKey
   ```

   该命令会生成专用密钥 `~/.ssh/id_arcane_relay`，并把公钥安装到服务器
   `~/.ssh/authorized_keys`，然后验证免密登录。看到"免密登录验证通过"即成功。

3. 以后每次改完服务端：**直接双击 `deploy.cmd`**，或在命令行运行：

   ```
   .\deploy.ps1
   ```

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `.\deploy.ps1 -SetupKey` | 一次性：生成密钥并安装到服务器（只需输一次密码） |
| `.\deploy.ps1` | 部署：上传 + 语法校验 + 重启 + 健康检查 |
| `.\deploy.ps1 -Status` | 查看服务器进程与日志尾部 |
| `.\deploy.ps1 -SkipRestart` | 只上传文件，不重启 |
| `.\deploy.ps1 -DryRun` | 只打印将执行的命令，不真正执行 |

也可以双击或命令行运行 `deploy.cmd`（自动带 `-ExecutionPolicy Bypass`），等价于 `deploy.ps1`。

## 部署流程（deploy 做了什么事）

1. 确保远端目录存在（`mkdir -p`）。
2. `scp` 上传到 `relay_server.py.new`（不直接覆盖，保证原子性）。
3. 远端 `python3 -m py_compile` 语法校验：
   - 通过 → 原子替换为 `relay_server.py`（旧文件保留为 `relay_server.py.prev` 供回滚）；
   - 失败 → 自动恢复上一版并中止，**不会重启**，线上服务不受影响。
4. `pkill` 旧进程 + `nohup` 拉起新进程，日志追加到远端
   `/opt/relay-server/relay_server.log`。
5. 健康检查：进程是否存活 + 本机 TCP 能否连上 `host:healthPort`。
   若进程没起来，自动回滚到上一版（`relay_server.py.prev`）并重新拉起，避免服务长期下线。

说明：

- 重启会清空服务器上的房间与对局缓存（服务器进程重启即清空，与原来在 screen 里
  Ctrl+C 效果相同）；`match_results.jsonl` 历史结果文件保留。
- 部署后旧 screen 会话里的进程已结束，可以关掉那个终端；新进程脱离终端运行，
  看日志用 `.\deploy.ps1 -Status` 或服务器上 `tail -f /opt/relay-server/relay_server.log`。

## 配置字段说明（deploy.config.json）

| 字段 | 说明 | 默认值 |
| --- | --- | --- |
| `host` | 服务器 IP / 域名 | `64.90.30.36` |
| `user` | SSH 用户名 | `root` |
| `port` | SSH 端口 | `22` |
| `sshKeyPath` | 本地私钥路径 | `~/.ssh/id_arcane_relay` |
| `remoteDir` | 远端部署目录 | `/opt/relay-server` |
| `remoteFile` | 远端文件名 | `relay_server.py` |
| `remotePython` | 远端 python 命令 | `python3` |
| `launchArgs` | 服务启动参数 | `--host 0.0.0.0 --port 8765` |
| `healthPort` | 健康检查端口 | `8765` |
| `logFile` | 远端日志文件名 | `relay_server.log` |

`deploy.config.json` 已被 `.gitignore` 排除（含服务器地址与密钥路径），**不要提交到仓库**；
提交的模板是 `deploy.config.example.json`。

## 安全说明

- 使用专用密钥 `id_arcane_relay`（空口令），与 GitHub 使用的密钥分开，只供本工具使用；
  若需要吊销，从服务器 `~/.ssh/authorized_keys` 删除对应公钥即可。
- 首次连接服务器时 SSH 会提示确认主机指纹（`Host key verification failed` / `yes/no`），
  确认指纹后输入 `yes` 即可，之后不再提示。
- 密码只会在 `-SetupKey` 安装公钥时输入一次，之后部署全程免密，本机不保存服务器密码。

## 故障排查

- 提示 `SSH 密钥未配置或未通过验证` → 先运行 `.\deploy.ps1 -SetupKey`。
- 提示 `端口不可连接` → 检查服务器防火墙是否放行 `healthPort/tcp`，以及 `launchArgs`
  的绑定地址是否为 `0.0.0.0`。
- 回滚后仍无法启动 → 登录服务器查看 `tail -n 100 /opt/relay-server/relay_server.log`。
- 本地 PowerShell 版本过低（Windows PowerShell 5.1 以下）→ 用 `deploy.cmd` 或升级 PowerShell。
