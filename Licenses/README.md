# 第三方许可证

本目录记录实际使用的第三方代码、图标与其他资源。Arc Kit 源码采用根目录的 [MIT License](../LICENSE)；以下依赖保留各自授权，在线图片和视频不受项目许可证覆盖。

| 项目 | 使用范围 | 许可证 |
| --- | --- | --- |
| [Lucide](https://github.com/lucide-icons/lucide)，资源取自 [lucide-icons-swift 1.28.0](https://github.com/JakubMazur/lucide-icons-swift/tree/e4f7c76d6a16f2fb4a414dd6c5c83fc04216bdf8) | 界面使用的 84 个 PDF 图标 | [ISC / MIT](Lucide-ISC-MIT.txt) |
| [LinearMouse](https://github.com/linearmouse/linearmouse/tree/ef541a5cf5b89e17167b773a545010a454632c08) | EventTap 生命周期与回调、滚轮事件字段封装的参考改写 | [MIT](LinearMouse-MIT.txt) |
| [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0) | 软件更新框架、安装助手、更新签名与订阅工具 | [许可证及第三方声明](Sparkle.txt) |
| [GRDB.swift 7.11.1](https://github.com/groue/GRDB.swift/tree/v7.11.1) | SQLite 连接、事务、迁移与原生备份；仅主应用和 Runtime Host 链接 | [MIT](GRDB-MIT.txt) |

Lucide 部分图标继承自 [Feather](https://github.com/feathericons/feather)，其 MIT 版权声明与授权正文已包含在上述文件中。LinearMouse 对应源文件另有版权声明：Copyright (c) 2021-2026 LinearMouse。

## 品牌与文档图片

应用品牌由项目维护者提供，运行资源与设计导出分别位于 `Sources/Application/Resources/Brand/` 和 `Targets/ArcKitApp/Resources/Brand/`。不将品牌商标权视为第三方开源许可的一部分。

README 使用《国产凌凌漆》中的「要你命 3000」电影截图说明命名出处，文件为 `Documentation/Images/yao-ni-ming-3000.png`，与官网使用同一图片。电影截图版权归原权利人所有，不适用项目 MIT 许可，不随应用安装包提供。

README 中的实际界面截图保存在 `Documentation/Images/`。图库截图包含 Dietmar Rabich 的两张 CC BY-SA 4.0 照片缩略图及 NASA 视频缩略图，原作品链接、署名、截图版本与使用范围见[图片说明](../Documentation/Images/README.md)。这些第三方内容不适用项目 MIT 许可。

## 在线素材

壁纸来源包括 Wallhaven、Wikimedia Commons、Bing、Lorem Picsum、MotionBGS、MoeWalls、NASA，以及用户添加的链接与订阅。图片和视频不随应用分发，其归属与使用条件以作品来源页为准；NASA 素材另参见[媒体使用指南](https://www.nasa.gov/nasa-brand-center/images-and-media/)。

本目录的开源许可证不适用于这些在线素材。

## 内置文件模板

Finder 随包提供本项目维护的文本和空白 OOXML 模板，按项目 MIT 许可证分发。首个公开版本不打包缺少来源记录的 iWork/WPS 模板，也不提供对应的默认菜单项。用户仍可自行导入合法持有的模板；导入功能不会赋予文件额外的再分发授权。

`word.docx`、`excel.xlsx`、`powerPoint.pptx` 已于 2026-10-01 使用本项目的 [生成脚本](../Build/Scripts/generate-office-templates.py) 重新生成。脚本直接定义最小 OOXML 文档结构，仅依赖 Python 标准库，不复制 Office 安装资源、外部主题或文档内容，不包含个人元数据；输出时间、权限和条目顺序固定，可逐字节重现。CI 使用 `--check` 校验提交的三个文件与脚本一致。文本模板按仓库源码维护。

## 随包声明

本目录随主应用一并分发，位于 `Arc Kit.app/Contents/Resources/Licenses/`，覆盖主应用及随包的 Runtime Host、Finder 扩展所使用的上述第三方内容。
