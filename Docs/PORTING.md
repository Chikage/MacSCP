# WinSCP → MacSCP 移植说明

参考附件：`/Volumes/Files/Github/winscp`，提交 `e13157118a064261cb3b707cdc601d4d325359cf`。

WinSCP 使用 C++Builder/VCL、Windows HANDLE/线程与 Windows PuTTY 集成，不能直接用 Apple Clang 编译。MacSCP 依据附件中的模块职责和协议行为进行原生重建；没有将完整 Windows 工程、加密实现或图标复制进来。

| WinSCP 参考模块 | MacSCP 实现 | 处理方式 |
| --- | --- | --- |
| `source/core/SessionData.h` | `Models.swift`、`SiteStore.swift` | 站点、协议、认证和初始路径；Codable 本地存储 |
| `source/core/FileSystems.h` | `RemoteFileSystem.swift` | 文件系统抽象，浏览、属性、创建、重命名、删除、传输 |
| `source/core/SftpFileSystem.cpp` | `SFTPPacket.swift`、`SFTPClient.swift` | v3 大端编码、请求编号、属性、目录句柄、STATUS/EOF、分块读写；16 请求流水线 |
| `source/core/ScpFileSystem.cpp` 的 `SCPSource` / `SCPSink` / `SCPResponse` | `SCPTransfer.swift`、`ShellFileSystem.swift` | C/T 记录、确认字节、文件长度与文件名校验；Shell 元数据改为 NUL 分隔 |
| `source/core/Queue.h` | `TransferEngine.swift`、`AppModel.swift` | 顺序队列、统计、冲突策略、取消、重试、完成状态 |
| VCL 双栏窗口和站点对话框 | `Sources/MacSCP/` | SwiftUI Table、NavigationSplitView、原生菜单与表单 |
| Windows SSH/PuTTY 适配 | `SSHSession.swift`、`ProcessChannel.swift`、`MacSCPAskPass` | 系统 OpenSSH，严格主机验证，独立认证助手与钥匙串 |

## 实现约束

界面状态隔离在 MainActor；网络与目录 I/O 在后台任务执行。一个 SSH master 管理连接，浏览和传输各用独立 channel。传输取消通过锁保护的标志和非阻塞 poll 生效，不阻塞界面等待远程响应。

SFTP 不执行 Shell 命令；SCP 使用单引号转义的 POSIX Shell 命令并通过 NUL 分隔元数据，避免按 `ls` 可见文本猜测文件名。来自服务器的路径、控制行、包长度、请求编号和文件名均校验。下载 SCP 文件必须与请求文件名和预期大小匹配。

应用不关闭主机密钥检查，不在参数、日志、JSON 或环境变量中传递密码。未知服务器需用户核验；变更的密钥由 OpenSSH 拒绝。SSH slave 禁止在控制连接丢失时自动降级为新的独立连接。

临时文件与最终文件位于同一目录。下载用排他创建与原子 rename；SFTP 上传使用 EXCL 和安全 rename 扩展；SCP 上传用唯一临时名和服务器 `mv`。远程并发目录变动不具备事务保障。

## 未纳入首版

完整 WinSCP 协议矩阵、同步/目录比较、内置编辑器、多标签站点、断点续传、后台持久队列、传输限速、代理/跳板机、配置导入和自动化脚本接口。当前版本聚焦 SCP/SFTP 的可运行桌面传输流程。

## 验证入口

`swift test --arch arm64 -Xswiftc -warnings-as-errors` 使用 macOS 原生 `/usr/libexec/sftp-server` 和 `/usr/bin/scp`，覆盖协议编码、恶意路径、递归往返、特殊名称、隐藏/空文件夹、冲突策略、符号链接保护、取消延迟及失败时保留原文件。完整 SSH 集成测试通过 `Scripts/test_ssh.sh` 在回环地址的临时 sshd 中执行，不修改系统远程登录设置。
