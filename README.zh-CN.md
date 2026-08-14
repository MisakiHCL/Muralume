<p align="center">
  <img
    src="Muralume/Resources/Assets.xcassets/BrandMark.imageset/BrandMark.png"
    width="112"
    height="112"
    alt="Muralume Logo"
  >
</p>

<h1 align="center">Muralume</h1>

<p align="center"><strong>你的视频，你的 Mac，让桌面动起来。</strong></p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <a href="https://github.com/MisakiHCL/Muralume/releases/latest"><strong>下载最新版本</strong></a>
  · Apple 芯片 · macOS 14+
</p>

<p align="center">
  <img
    src=".github/assets/muralume-player-v1-zh.png"
    width="1200"
    alt="Muralume 正在播放本地视频并显示媒体库"
  >
</p>

Muralume 是一款私密、原生的 macOS 应用，可以把你自己的视频变成动态桌面。
它将专注的本地播放器、可搜索的媒体库、自定义播放列表与多显示器桌面播放整合
在一起，无需账号、云端上传、广告或行为追踪。

## 看看实际效果

这段简短演示展示了如何把本地视频设为动态桌面，同时保留桌面文件、小组件与
正常交互。

https://github.com/user-attachments/assets/9a6f92f6-ec13-476c-a863-55134aa03f3a

## 功能

- **使用本地媒体：** 添加单个视频、文件夹或两者的组合。源文件始终保留在原处，
  Muralume 只访问你主动选择的内容。
- **媒体库：** 浏览缩略图、排序内容、按名称或位置搜索，并在应用运行期间自动发现
  已授权文件夹中的变化。
- **自定义播放列表：** 创建自定义分组，添加和排序视频，在播放列表内搜索，并在
  重新打开应用后继续使用上次的播放列表。
- **专注的播放体验：** 支持顺序播放、随机播放、循环当前视频、进度跳转、音量、
  倍速、全屏，以及独立呈现真实顺序的播放队列。
- **动态桌面：** 将视频放在桌面文件与小组件后方；多块显示器可以同步使用同一队列，
  也可以分别循环不同视频。
- **私密且原生：** 本地处理、只读媒体访问，无账号、上传、产品遥测或自动崩溃上报。
- **会话恢复：** 重新打开 Muralume 后可恢复当前会话；启用“登录时启动”后，也可
  在登录系统时恢复动态桌面。

## 开始使用

1. 选择“添加媒体…”，或从访达拖入视频和文件夹。
2. 浏览或搜索媒体库，直接播放视频，或将其整理到自定义播放列表。
3. 在播放器中选择顺序播放、随机播放或循环当前视频。
4. 按 `⌘D` 将当前播放内容设为动态桌面，或按 `⇧⌘D` 自定义显示器。

## 下载

[下载 `Muralume.dmg`](https://github.com/MisakiHCL/Muralume/releases/latest/download/Muralume.dmg)，
打开后将 Muralume 拖入“应用程序”文件夹。每个版本的正式说明与校验文件统一发布在
[GitHub Releases](https://github.com/MisakiHCL/Muralume/releases) 页面。

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 添加视频或文件夹 | `⌘O` |
| 搜索视频 | `⌘F` |
| 设为动态桌面 | `⌘D` |
| 自定义显示器布局 | `⇧⌘D` |
| 播放 / 暂停 | `Space` |
| 后退 / 前进 10 秒 | `←` / `→` |
| 上一个视频 / 下一个视频 | `⌘←` / `⌘→` |
| 调低 / 调高音量 | `↓` / `↑` |
| 静音 / 取消静音 | `M` |
| 进入 / 退出全屏 | `F` |
| 打开设置 | `⌘,` |

## 系统要求

- 搭载 Apple 芯片的 Mac
- macOS 14 或更高版本
- AVFoundation 支持的视频格式，包括常见的 MP4、MOV、M4V、MPEG、MPEG-TS、
  3GP、3G2、AVI 和 DV 文件

实际播放能力取决于 macOS 提供的编解码器。

## 从源码构建

安装支持 Swift 6 的 Xcode 与
[ripgrep](https://github.com/BurntSushi/ripgrep)，然后运行：

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
make package-macos
```

`make package-macos` 会生成供开发与本机安装测试使用的 ad-hoc 签名 DMG，
它不是正式分发版本。

## 开源

源代码使用 [MIT License](LICENSE)。参与项目前请阅读[贡献指南](CONTRIBUTING.md)、
[安全政策](SECURITY.md)与[社区行为规范](CODE_OF_CONDUCT.md)。构建工具中随仓库提供的
第三方组件保留各自许可，详见[第三方声明](THIRD_PARTY_NOTICES.md)。Muralume 名称与
视觉资产不包含在 MIT 授权范围内，详见[品牌资产声明](BRAND_ASSETS.md)。
