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
  <a href="https://github.com/MisakiHCL/Muralume/releases/tag/v0.1.0"><strong>下载 v0.1.0</strong></a>
  · Apple 芯片 · macOS 14+
</p>

<p align="center">
  <img
    src=".github/assets/muralume-player.jpg"
    width="1200"
    alt="Muralume 正在播放本地视频并显示播放列表"
  >
</p>

Muralume 直接将本地视频文件夹整理为播放列表，既可在原生播放器中观看，也可把当前队列切换为动态桌面。文件始终保留在原处，无需云端账号，也没有行为追踪。

## 为什么选择 Muralume

### 你的视频始终属于你

Muralume 直接使用你主动选择的文件夹，并以只读权限访问其中的视频。应用不会上传、移动、重命名或删除源文件，也不包含账号系统、使用分析和自动崩溃上传。

### 注重能耗的动态桌面

只需一次点击，即可将当前播放队列置于桌面文件和小组件之后。动态桌面始终静音，桌面文件与小组件可正常交互，不主动阻止显示器休眠，并会在锁屏或显示器休眠时自动暂停。

### 文件夹就是播放列表

添加一个或多个本机或外置磁盘文件夹，Muralume 会递归发现其中的视频并生成缩略图。你可以按名称、创建时间或文件大小排序，无需重新整理磁盘上的源文件。

### 简洁的原生播放体验

支持播放、进度跳转、音量、倍速、顺序播放、每轮全部播完前不重复的随机播放和全屏。观看时控制界面会自然隐去，常用播放偏好也会在下次打开 Muralume 时继续使用。

## 下载

[下载 `Muralume.dmg`](https://github.com/MisakiHCL/Muralume/releases/download/v0.1.0/Muralume.dmg)，打开后将 Muralume 拖入“应用程序”文件夹。

v0.1.0 DMG 使用 Developer ID 证书签名并通过 Apple 公证，并同时提供对应的 [SHA-256 校验文件](https://github.com/MisakiHCL/Muralume/releases/download/v0.1.0/Muralume.dmg.sha256)。

## 快速开始

1. 添加一个或多个保存视频的文件夹。
2. 从播放列表选择视频，或按名称、创建时间和文件大小调整排序。
3. 使用播放器控制台进行进度跳转、音量、倍速、全屏以及顺序或随机播放。
4. 点击显示器按钮，把当前播放队列切换为动态桌面；通过菜单栏中的 Muralume 图标暂停、切换视频、调整倍速或显示方式，并返回播放器。

Muralume 会在下次启动时继续使用此前的音量、静音状态、播放次序、倍速、列表排序和界面语言。界面支持 English、简体中文与跟随系统。

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 添加文件夹 | `⌘O` |
| 播放 / 暂停 | `Space` |
| 后退 / 前进 10 秒 | `←` / `→` |
| 上一部 / 下一部 | `⌘←` / `⌘→` |
| 调低 / 调高音量 | `↓` / `↑` |
| 静音 / 取消静音 | `M` |
| 进入 / 退出全屏 | `F` |
| 打开设置 | `⌘,` |

## 系统要求

- 搭载 Apple 芯片的 Mac
- macOS 14 或更高版本
- MP4、MOV 或 M4V 视频
- 动态桌面当前使用主显示器

实际播放能力取决于 macOS AVFoundation 对视频内部编码的支持；H.264 与 HEVC 是常见的兼容选择。

## 从源码构建

安装支持 Swift 6 的 Xcode 与 [ripgrep](https://github.com/BurntSushi/ripgrep)，然后运行：

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
make package-macos
```

`make package-macos` 会在 `dist/macos-local/` 生成 ad-hoc 签名的 DMG，仅供本机安装验证。

## 隐私与开源

Muralume 不包含账号系统、云端上传、产品遥测或自动崩溃上报。从 Muralume 中移除文件夹不会删除任何源视频。

源代码使用 [MIT License](LICENSE)。Muralume 名称、Logo、App Icon 与菜单栏图标不包含在 MIT 授权范围内，详见[品牌资产声明](BRAND_ASSETS.md)。
