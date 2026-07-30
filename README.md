<p align="center">
  <img
    src="Muralume/Resources/Assets.xcassets/BrandMark.imageset/BrandMark.png"
    width="112"
    height="112"
    alt="Muralume Logo"
  >
</p>

<h1 align="center">Muralume</h1>

<p align="center"><strong>管理本地视频，随时播放，也让它们成为桌面。</strong></p>

<p align="center">
  v0.1.0 · 原生 macOS 本地视频播放器 · 动态桌面
</p>

<p align="center">
  <img
    src=".github/assets/muralume-player.jpg"
    width="1200"
    alt="Muralume 播放器与播放列表"
  >
</p>

Muralume 是一款为 macOS 打造的本地视频播放器。添加保存视频的文件夹，即可获得带缩略图的播放列表、常用播放控制，以及可以一键切换的动态桌面。视频始终留在原来的位置，Muralume 不会移动或修改源文件。

## 功能亮点

| | |
|---|---|
| **文件夹即播放列表** | 添加一个或多个本机、外置磁盘文件夹，递归发现其中的视频；按名称、创建时间或大小排序。 |
| **常用播放控制** | 播放、暂停、进度跳转、音量、静音、倍速、上一部、下一部和全屏，鼠标闲置后控制界面自动隐去。 |
| **顺序或随机播放** | 自由切换播放次序；随机播放在一轮内不会重复，并自动进入下一轮。 |
| **内置动态桌面** | 把当前播放队列切换到主显示器桌面层。桌面模式保持静音，文件、小组件、鼠标和键盘照常使用。 |
| **原生单窗口体验** | `⌘W` 隐藏主画面并保留进程内状态，点击程序坞即可立即回来；只有 `⌘Q` 才会完整退出。 |
| **本地优先** | 无账号、无云端上传、无产品遥测；App Sandbox 只读访问你主动选择的文件夹。 |

## 下载与安装

前往 [GitHub Releases](https://github.com/MisakiHCL/Muralume/releases) 下载 `Muralume.dmg`：

1. 打开 DMG。
2. 将 Muralume 拖入“应用程序”文件夹。
3. 启动 Muralume，点击“添加文件夹”开始使用。

官方 DMG 使用 Developer ID 签名，并已通过 Apple 公证。

## 使用 Muralume

1. 添加一个或多个保存视频的文件夹。
2. 从右侧播放列表选择视频，或调整名称、创建时间和大小排序。
3. 使用底部控制台播放、跳转、调节音量和倍速，或切换顺序与随机播放。
4. 点击显示器图标进入动态桌面；通过菜单栏中的 Muralume 图标暂停、切换视频、调整显示方式或返回播放器。

播放列表会跟随当前视频自动定位；音量、静音、播放次序、倍速、排序方式和界面语言会在下次启动时继续使用。界面支持跟随系统、简体中文与 English。

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 添加文件夹 | `⌘O` |
| 播放 / 暂停 | `Space` |
| 后退 / 前进 10 秒 | `←` / `→` |
| 上一部 / 下一部 | `⌘←` / `⌘→` |
| 调低 / 调高音量 | `↓` / `↑` |
| 静音 / 取消静音 | `M` |
| 全屏 / 退出全屏 | `F` |
| 打开设置 | `⌘,` |
| 隐藏主窗口 | `⌘W` |
| 退出 Muralume | `⌘Q` |

## 系统要求

- 搭载 Apple 芯片的 Mac
- macOS 14 或更高版本
- MP4、MOV、M4V

视频能否播放取决于 macOS AVFoundation 对文件内部编码的支持；H.264 与 HEVC 是常见的兼容选择。

## 从源码构建

需要安装支持 Swift 6 的 Xcode 与 [ripgrep](https://github.com/BurntSushi/ripgrep)。

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
make package-macos
```

`make package-macos` 会在 `dist/macos-local/` 生成仅供本机安装验证的 ad-hoc 签名 DMG。

## 隐私与开源

Muralume 不需要账号，不上传视频、文件路径或使用数据，也不包含自动遥测与崩溃上传。应用以只读权限访问你选择的媒体文件夹，从播放列表移除文件夹不会删除源视频。

源代码与文档使用 [MIT License](LICENSE)。Muralume 名称、Logo、App Icon 与菜单栏图标不包含在 MIT 授权范围内，详见 [品牌资产声明](BRAND_ASSETS.md)。
