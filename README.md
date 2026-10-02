# MacSCP

参照附件 WinSCP 源码重建的原生 macOS SCP / SFTP 文件传输工具。使用 Swift 6、SwiftUI 和 macOS 自带 OpenSSH，只发布 **arm64（Apple Silicon）**。

支持 macOS 14 或更新版本。当前为 0.1.0 首版，已实现常用文件传输流程，完整移植范围见 [Docs/PORTING.md](Docs/PORTING.md)。

## 安装和使用

1. 打开 `dist/MacSCP-0.1.0-arm64.dmg`，将 MacSCP 拖入 Applications。也可以直接打开 `build/MacSCP.app`。
2. 点击「新建连接」，填写主机、端口、用户名与认证方式，选择 SFTP 或 SCP。
3. 首次连接时核对服务器 SHA256 指纹，再点击「信任并连接」。密码和私钥口令在独立认证窗口输入，可选择保存到系统钥匙串。
4. 左侧浏览本地文件，右侧浏览远程文件。双击进入文件夹，选择项目后点击上传或下载。
5. 确认目标位置与同名策略，加入队列。队列支持进度、取消和重试。

发行包采用本机 ad-hoc 签名，**尚未使用 Apple Developer ID 签名或公证**。从其他设备下载后，macOS 可能需要在系统设置的「隐私与安全性」中允许打开。

## 已实现

- 原生双栏文件表格、排序、路径跳转、名称筛选、隐藏文件切换。
- 保存站点；SSH Agent / 默认密钥、OpenSSH 私钥、密码及交互式认证。
- 严格 SSH 主机密钥验证；指纹变化时拒绝连接。
- SFTP v3；独立 SCP 协议，SCP 模式不依赖 SFTP 子系统。
- 文件与目录递归上传、下载，保留普通文件权限和修改时间。
- 队列、实时字节进度、取消、同站点重试；同名文件跳过或替换。
- 先写临时文件，再提交目标。下载中断不覆盖已有文件；上传失败保留原目标。
- 新建文件夹、重命名、远程递归删除、本地移到废纸篓。
- 系统浅色/深色外观、原生菜单、中文界面。

快捷键：`⌘N` 新建连接；`⌘U` 上传；`⇧⌘D` 下载；`⌘R` 刷新；`⇧⌘.` 隐藏文件；`⌘J` 队列。

## 构建和验证

需要 Xcode Command Line Tools，Swift 6.0 或更新版本。无需 Homebrew、第三方 Swift 包或网络下载。

```sh
swift test --arch arm64 -Xswiftc -warnings-as-errors
./Scripts/test_ssh.sh
./Scripts/launch.sh
./Scripts/package_release.sh
```

产物位于 `build/` 和 `dist/`。发布脚本生成 `.app`、DMG、ZIP、对应源代码 ZIP 与 SHA256 校验文件，逐一检查两个可执行文件仅含 arm64，并验证代码签名。设置 `APP_IDENTITY` 可使用已有 Developer ID 签名；公证需由发行者另行完成。

## 配置与边界

- 站点与已信任指纹：`~/Library/Application Support/MacSCP/`。JSON 中不包含密码。
- 可选保存的认证信息位于系统钥匙串，service 为 `app.macscp.credentials`。
- 每个连接建立独立 SSH 主连接；文件浏览和传输使用独立复用通道。断开会取消当前队列。
- SCP 服务器需要 POSIX `/bin/sh`、`scp` 和 GNU/BSD `stat`；SFTP 服务器需支持 v3。
- 远程名称需为 UTF-8。拒绝带换行或 NUL 的操作路径；递归传输跳过符号链接和特殊文件。
- 传输队列仅在当前运行期间保留，不支持断点续传。目录会合并，目录本身的权限和时间不复制。
- 上传中断或失联时可能留下 `.macscp-<UUID>.part`；确认没有对应传输后可手动删除。
- SFTP 覆盖已有文件需要服务器支持 `posix-rename@openssh.com`，否则会保留原文件并报告错误。
- 远程文件系统在操作期间应保持稳定；不提供针对其他进程同时修改目录的事务隔离。
- 当前不读取 `~/.ssh/config`，不支持 ProxyJump、FTP/FTPS、WebDAV、S3、同步、远程编辑器、WinSCP 配置导入或 Windows 的 .NET 接口。
- 支持标准 DNS/IP（包括 IPv6），用户名限常见 Unix ASCII 字符。中文为当前界面语言。

## 源码与许可

沿用本仓库的 GPL-3.0 许可。参考源码版本与模块映射见 [NOTICE](NOTICE) 和 [Docs/PORTING.md](Docs/PORTING.md)。MacSCP 是原生实现，非官方 WinSCP macOS 发行版。分发二进制时应同时提供对应源代码。
