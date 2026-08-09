<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Yorune">
</p>

<h1 align="center">Yorune</h1>

<p align="center">
  专为 Navidrome 打造的原生 macOS 音乐客户端<br>
  专辑浏览、在线播放、播放队列、AirPlay，以及贴合系统的桌面体验
</p>

<p align="center">
  <a href="#连接-navidrome">连接 Navidrome</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/Navidrome-Subsonic%20API-6b5cff" alt="Navidrome Subsonic API">
</p>

---

<p align="center">
  <img alt="Yorune 音乐客户端" src=".github/assets/app.png" width="860">
</p>

## 简介

Yorune 是一款为 Navidrome 自托管音乐库设计的原生 macOS 客户端。它直接通过 Subsonic API 读取专辑、曲目和封面，并以 SwiftUI、AppKit、AVFoundation 构建完整的桌面播放体验。

应用以专辑为核心组织音乐库：打开后可以搜索和浏览专辑，进入详情查看曲目并开始播放；底部播放栏负责进度、音量和播放模式，右侧队列则用于查看和整理接下来播放的内容。

## 为什么开发 Yorune

Navidrome 提供稳定的自托管音乐服务，但浏览器播放器很难完全融入 macOS。Yorune 将远端音乐库重新做成一个原生桌面应用，让窗口、快捷键、系统音频路由与设置都遵循 Mac 的使用方式。

- **原生界面**：SwiftUI 导航、专辑网格与 macOS 26 Liquid Glass 播放栏
- **完整播放控制**：播放、暂停、上一首、下一首、进度拖动与音量控制
- **播放模式**：随机播放、列表循环与单曲循环
- **队列管理**：查看、跳转、移除和重新组织当前播放队列
- **系统音频能力**：支持 AirPlay 输出与键盘空格播放 / 暂停
- **安全连接信息**：服务器地址和用户名保存在本地，密码写入 Keychain

## 音乐库与播放

Yorune 分页读取 Navidrome 专辑数据，按需加载专辑曲目，并缓存当前会话中已请求的曲目列表。封面与音频流都由服务器直接提供，不需要预先同步整套音乐库。

播放界面支持专辑搜索、曲目时长、实时进度、缓冲状态、音量、随机与循环模式。播放队列可以在独立面板中展开，当前曲目、待播内容和播放顺序保持同步。

## 其他功能

- 跟随系统、浅色与深色三种外观
- 简体中文与英文界面
- 登录时启动
- 连接失败与播放失败后的重试流程
- 使用临时 `URLSession` 访问服务器，不持久化网络缓存与 Cookie

## 连接 Navidrome

打开 **设置 → 服务器**，填写 Navidrome 地址、用户名和密码，然后选择 **保存并连接**。服务器需要能够通过当前网络访问，并提供兼容的 Subsonic API。

## 从源码构建

需要 Xcode 26 或兼容 Swift 6 的新版 Xcode，以及 macOS 15 或更高版本。

```bash
git clone https://github.com/imeelinew/Yorune.git
cd Yorune
open Yorune.xcodeproj
```

在 Xcode 中选择 **Yorune** scheme，然后执行 **Product → Run**。
