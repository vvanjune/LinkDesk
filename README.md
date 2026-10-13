# LinkDesk

为 Mac 与 Windows 键鼠共享制作的原生界面。Mac 使用 SwiftUI，Windows 使用 WPF。当前版本 **0.2.0**，采用 GPL-2.0-only 许可。

> **当前版本需要在两台电脑安装 Deskflow 1.27.0，并先通过原版完成一次加密配对。**
> LinkDesk 0.2.0 调用已有的 Deskflow 连接核心，安装包没有包含该核心。卸载 Deskflow 后，LinkDesk 无法启动共享。
> Windows 包内置 .NET 运行时，这不代表已经内置 Deskflow。

## 功能

- Mac 键盘和鼠标控制 Windows，支持电脑位置设置。
- 开机登录时启动、关闭窗口后留在后台。
- 共享端修饰键映射，接收端独立设置滚轮方向与速度。
- 网络恢复、电脑唤醒后尝试自动恢复连接；手动停止会关闭自动连接。
- Windows 自动发现已配对的 Mac，验证身份后更新地址。
- TLS 加密连接与指纹确认。
- 两个平台的应用图标；Mac 侧栏整块按钮均可点击。

自动发现目前支持 **Mac 共享端 → Windows 接收端**，需要位于同一局域网；其他方向使用手动地址。没有新增切换快捷键。

## 安装与使用

1. 在两台电脑安装 [Deskflow 1.27.0](https://github.com/deskflow/deskflow/releases/tag/v1.27.0)。
2. 在原版完成一次加密连接，随后从菜单栏或托盘彻底退出原版。
3. 打开 LinkDesk，设置两台电脑的名称和用途，在 Mac 授予设备控制权限后启动共享。

详见 [使用说明](使用说明.md)。本仓库提交的是源码、图标与说明，不含编译后的安装包、个人证书、私钥或配对数据库。

## 从源码构建

Mac 需要 Apple Silicon、macOS 13 或更新版本及 Swift 工具链：

```sh
sh source/scripts/build-mac.sh
```

生成的应用位于 `macOS/LinkDesk.app`。脚本使用本地临时签名；更换构建后可能需要重新授予设备控制权限。

Windows 需要 .NET 10 SDK，使用 PowerShell：

```powershell
./source/scripts/build-windows.ps1
```

生成自包含的 x64 程序，输出位于 `Windows/`。两个构建脚本均不会安装或捆绑 Deskflow 核心。

技术说明与测试方法见 [source/README.md](source/README.md)。

## 验证范围

两台实机已验证加密连接、Windows 自动发现已配对的 Mac，以及热点关闭后重新开启时自动恢复连接。Mac 侧栏点击范围已实测。

不同 IP 下的发现已通过签名协议测试；真实 IP 变化及两台电脑实际睡眠、唤醒后的恢复尚未单独实测。完整记录见 [验证记录](验证记录.md)。当前为本地测试版本，尚未验证登录前控制或 Windows UAC 安全桌面。

## 独立安装版本

移除外部安装依赖需要内置 Deskflow 核心及必要运行库，并由 LinkDesk 完成证书生成、首次配对和指纹管理。这些功能 **尚未在 0.2.0 实现**。

## 许可

LinkDesk 源码采用 [GPL-2.0-only](LICENSE)。传输核心来自 [Deskflow](https://github.com/deskflow/deskflow)，本仓库没有分发其二进制程序。打包独立版本时还需保留上游与第三方许可，并提供对应源码。
