# DefaultOpen

[中文](#中文) | [English](#english)

## 中文

### 简介

DefaultOpen 是一款原生 macOS 文件关联管理工具，用于查看和更改文件扩展名、
UTType、网页链接及常用文件格式组合所使用的默认应用。项目使用 Swift、SwiftUI、
AppKit 和 Launch Services 构建，不依赖 `duti` 或其他第三方命令行工具。

### 主要功能

- 查看扩展名、文件类型、UTType 和当前默认应用。
- 修改单个或批量文件类型的默认打开应用。
- 扫描已安装应用声明的文档类型、UTType 和 URL Scheme。
- 按应用名称、Bundle Identifier、扩展名或文件类型搜索。
- 管理浏览器、视频、音乐、图片、PDF、文本和办公文档等默认应用组合。
- 创建自定义扩展名和自定义默认应用组合。
- 支持简体中文、English 和跟随系统的界面语言设置。

### 系统要求

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本

本项目不提供 Intel（x86_64）构建。

### 下载与安装

正式发布包使用 ad-hoc 签名。项目目前没有 Apple Developer Program 会员资格，
因此应用没有 Developer ID 签名，也没有经过 Apple 公证。

从网络下载后，macOS 可能显示无法验证开发者的 Gatekeeper 提示。请先核对发布页
提供的 SHA-256 校验值，再在 Finder 中按住 Control 点按应用并选择“打开”，或前往
“系统设置 → 隐私与安全性”确认打开。

### 校验发布包

在 ZIP 和 `.sha256` 文件所在目录运行：

```bash
shasum -a 256 -c DefaultOpen-vX.Y.Z-arm64.sha256
```

### 安全与隐私

为了扫描 `/Applications`、`/System/Applications` 和用户应用目录，项目没有启用
App Sandbox。应用不需要管理员权限，不会修改 SIP，也不会安装后台服务或第三方
命令行程序。

修改默认应用时，macOS 可能显示系统确认提示。DefaultOpen 只通过公开的
Launch Services 和 `NSWorkspace` API 请求更改文件关联。

### 从源码构建

1. 使用最新版 Xcode 打开 `FileAssociationManager.xcodeproj`。
2. 选择 `FileAssociationManager` Scheme 和 My Mac。
3. 本地运行可以使用自动签名，也可以在命令行构建时禁用签名。

数值构建号必须使用当前 Git commit 数量：

```bash
git rev-list --count HEAD
```

### 已知限制

- 部分应用只声明抽象 UTType，没有可用于修改关联的文件扩展名。
- 文件类型名称和应用名称由 macOS 提供，可能继续使用系统语言，而不是应用内选择的语言。
- 未使用 Developer ID 签名和 Apple 公证的下载版可能触发 Gatekeeper 提示。

### Launch Services 说明

macOS 目前没有为文档类型提供与 URL Scheme 设置 API 对等的现代替代方法。本项目
使用公开的 `LSCopyDefaultRoleHandlerForContentType`、
`LSCopyAllRoleHandlersForContentType` 与 `LSSetDefaultRoleHandlerForContentType`。
这些 C API 在较新 SDK 中被标记为 deprecated，但仍是不使用私有 API 或外部工具、
同时实现 Finder“全部更改”语义的可靠公开途径。

---

## English

### Overview

DefaultOpen is a native macOS utility for inspecting and changing the default
applications associated with file extensions, UTTypes, web links, and groups
of common file formats. It is built with Swift, SwiftUI, AppKit, and Launch
Services and does not depend on `duti` or other third-party command-line tools.

### Features

- Inspect file extensions, file types, UTTypes, and their current default apps.
- Change the default app for one or multiple file types.
- Scan installed applications for declared document types, UTTypes, and URL schemes.
- Search by app name, bundle identifier, extension, or file type.
- Manage grouped defaults for browsers, video, music, images, PDFs, text, and office documents.
- Create custom extensions and custom default-app groups.
- Use Simplified Chinese, English, or the system-default interface language.

### Requirements

- Apple Silicon Mac (arm64)
- macOS 14 or later

This project does not provide an Intel (x86_64) build.

### Download and Installation

Official downloads use ad-hoc signing. This project does not currently have an
Apple Developer Program membership, so the app is not Developer ID signed or
notarized by Apple.

macOS may show a Gatekeeper warning after the app is downloaded. Verify the
SHA-256 checksum from the release page first. Then Control-click the app in
Finder and choose Open, or approve it in System Settings → Privacy & Security.

### Verifying Downloads

Run this command in the directory containing the ZIP and `.sha256` files:

```bash
shasum -a 256 -c DefaultOpen-vX.Y.Z-arm64.sha256
```

### Security and Privacy

The App Sandbox is disabled so DefaultOpen can scan `/Applications`,
`/System/Applications`, and the user's Applications directory. The app does
not require administrator privileges, modify SIP, install background services,
or install third-party command-line tools.

When changing a default app, macOS may present a system confirmation prompt.
DefaultOpen requests file-association changes only through public Launch
Services and `NSWorkspace` APIs.

### Building from Source

1. Open `FileAssociationManager.xcodeproj` with the latest Xcode.
2. Select the `FileAssociationManager` scheme and My Mac.
3. Local runs may use automatic signing, or command-line builds may disable signing.

The numeric build number must equal the current Git commit count:

```bash
git rev-list --count HEAD
```

### Known Limitations

- Some apps declare only abstract UTTypes and provide no file extension that can be reassigned.
- File type and application names come from macOS and may continue to use the system language.
- Downloads without Developer ID signing and Apple notarization may trigger Gatekeeper warnings.

### Launch Services Notes

macOS currently provides no modern document-type API equivalent to its URL
scheme API. DefaultOpen uses the public
`LSCopyDefaultRoleHandlerForContentType`,
`LSCopyAllRoleHandlersForContentType`, and
`LSSetDefaultRoleHandlerForContentType` APIs. Newer SDKs mark these C APIs as
deprecated, but they remain the reliable public approach for Finder-style
“Change All” behavior without private APIs or external tools.
