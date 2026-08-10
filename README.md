# DefaultOpen

一个原生 SwiftUI macOS 文件默认打开方式管理工具。项目不依赖 `duti` 或其他第三方命令行程序。

## 运行

1. 使用最新版 Xcode 打开 `FileAssociationManager.xcodeproj`。
2. 在 Signing & Capabilities 中选择自己的开发团队（本地直接运行通常可使用自动签名）。
3. 选择 My Mac 后运行。

最低系统版本为 macOS 14。为了扫描 `/Applications`、`/System/Applications` 和用户应用目录，项目没有启用 App Sandbox；应用不需要管理员权限，也不会修改 SIP。

## MVP 功能

- 按扩展名读取 UTType、当前默认 App，以及 Launch Services 注册的所有可用 App。
- 修改一种或批量多种扩展名的默认打开 App。
- 自动扫描已安装 App 的 `CFBundleDocumentTypes`、`LSItemContentTypes`、导入/导出的 UTType 声明。
- 按 App、Bundle Identifier、UTType 或扩展名搜索。
- 在 App 详情中查看支持类型和当前默认项，并反向设置单项或多项关联。
- 手动添加扩展名并记住管理列表。

## Launch Services 说明

macOS 目前没有为文档类型提供与 URL Scheme 设置 API 对等的现代替代方法。本项目使用公开的
`LSCopyDefaultRoleHandlerForContentType`、`LSCopyAllRoleHandlersForContentType` 与
`LSSetDefaultRoleHandlerForContentType`。这些 C API 在较新 SDK 中被标记为 deprecated，但仍是无需私有 API、无需外部工具，且能实现 Finder“全部更改”语义的可靠公开途径。

应用扫描依据 Bundle 声明，Launch Services 的候选应用列表则依据系统注册数据库；两者共享同一 UTType/扩展名模型。部分应用只声明抽象 UTType 而没有扩展名，此类条目可以展示，但无法可靠执行“按扩展名”修改。
