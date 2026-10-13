# LinkDesk

Mac 与 Windows 键鼠共享的原生界面，当前版本 **0.3.0 独立版**。Mac 使用 SwiftUI，Windows 使用 WPF。

**两端无需安装 Deskflow。** 安装包内置 Deskflow 1.27.0 连接核心及必要运行库。Windows 同时包含 .NET 运行时。证书由 LinkDesk 本地生成，首次配对在两端核对指纹后完成；升级可迁移原有证书和配对记录。

## 下载与使用

完整程序和上游源码资料见 [v0.3.0 发布页](https://github.com/vvanjune/LinkDesk/releases/tag/v0.3.0)。这是本地测试版本，Mac 使用临时签名，尚未公证。

- Mac：解压后把完整 LinkDesk.app 放入应用程序目录，并授予设备控制权限。
- Windows：完整解压后运行 LinkDesk.exe，保留旁边的 core 和 ThirdParty 文件夹。不要只复制 EXE。
- 首次连接：Mac 共享、Windows 接收；核对两端电脑名称，Windows 填 Mac 显示的地址并启动。出现配对提示时核对另一端的本机指纹。

详见 [使用说明](使用说明.md)。

## 功能

- 登录后自启动、关闭窗口留在后台。
- 网络恢复和唤醒后尝试自动恢复连接，尊重手动停止。
- Windows 自动发现已配对的 Mac，验证身份后更新地址。
- 按键映射、远程滚轮方向与速度设置。
- 必须使用 TLS 加密和指纹验证；两端可查看本机指纹。
- 原生图标与 Mac 侧栏完整点击范围。

自动发现支持同一 IPv4 局域网内的 Mac 共享端 → Windows 接收端；首次配对和反向角色使用手动地址。没有新增切换快捷键。

## 数据位置

Mac：`~/Library/Application Support/LinkDesk/`；Windows：`%LOCALAPPDATA%/LinkDesk/`。证书、私钥和配对数据库在各自用户目录创建，均不上传到本仓库，也不随安装包分发。

## 开发与构建

源码位于 source。macOS 需要 Swift 工具链及 Python 3；Windows 需要 .NET 10 SDK、PowerShell 与 Python 3。**构建时**需要官方 Deskflow 二进制包作为嵌入核心的输入，最终安装包不依赖外部安装。

```sh
LINKDESK_DESKFLOW_APP=/path/to/Deskflow.app sh source/scripts/build-mac.sh
```

```powershell
$env:LINKDESK_DESKFLOW_WINDOWS = 'C:\path\to\official-portable-folder'
./source/scripts/build-windows.ps1
```

测试、内置文件布局及发现协议见 [技术说明](source/README.md)；实测结果和限制见 [验证记录](验证记录.md)。

## 许可与上游

LinkDesk 源码采用 [GPL-2.0-only](LICENSE)。传输核心来自 [Deskflow](https://github.com/deskflow/deskflow)。核心源码行为未修改；macOS 将嵌入程序与运行库一起进行本地签名。上游许可、Qt/OpenSSL/.NET/C++ 运行库声明见 [third-party](source/third-party/README.md)。上游源码档案与安装包在同一发布页提供。

0.2.0 曾依赖已有 Deskflow 安装，0.3.0 已将该依赖移入安装包并增加独立身份管理。
