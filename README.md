# Arc Kit

**macOS 下的「要你命 3000」。**

[官网](https://arc-kit.com) · [下载](https://arc-kit.com/download/) · [GitHub](https://github.com/huixiangyang/arc-kit)

Arc Kit 是一个 macOS 工具箱，包含 Finder 增强、窗口管理、鼠标设置和壁纸功能。各项功能可以单独开启，设置集中在同一个窗口中。

项目定位就是个「缝合怪」：把常用工具放到一起，后续也会加入其他功能。「要你命 3000」的名字借自《国产凌凌漆》。

使用 Swift、SwiftUI、AppKit 与 SQLite，最低支持 macOS 13。

## 现在能做什么

| 能力 | 功能 |
| --- | --- |
| Finder 增强 | 新建文件、常用目录与应用、打开终端、复制路径、文件信息、批量重命名、文件整理及图像工具 |
| 窗口管理 | 台前调度模式、半屏、四角、三分屏、居中、铺满、全屏、跨屏移动、位置恢复、快捷键与拖拽吸附 |
| 鼠标增强 | 平滑、反向与横向滚动、按应用设置参数、右键手势；预置可修改或删除的 UU 远程规则 |
| 壁纸与个性化 | 本地图片与视频、在线与动态图源、订阅下载、循环编辑、多屏壁纸与轮换、应用背景与柔光主题 |
| 系统便捷设置 | Finder 隐藏文件、截图保存位置、登录启动、菜单栏与 Dock 图标显示、中英文与外观设置 |
| 数据与诊断 | 功能状态、权限检查、备份恢复、空间占用、缓存清理和诊断导出 |

日常操作从 Finder 右键菜单、菜单栏、快捷键或手势进入；设置集中在原生侧栏与 Tab 中，支持 `⌘K` 快速查找。Finder 菜单可选择项目并调整顺序，鼠标可按应用设置行为，菜单栏与 Dock 图标可按需隐藏。

窗口的台前调度模式将当前窗口放在可用区域的右侧 85%，左侧留出缩略图空间。这是手动布局预设，不改变 macOS 的台前调度开关。

具体入口、权限和操作方式见[使用](Documentation/使用.md)。Finder Sync 受系统回调范围限制，**iCloud Drive 原生右键菜单仍不保证出现**；已提供工具栏入口，目标缺失时相关操作不可用。其他实机场景与待验收事项见[规划](Documentation/规划.md)。

## 还想加入什么

下面是一些备选方向，尚未排期。具体进展见[规划](Documentation/规划.md)。

| 方向 | 可以探索的功能 |
| --- | --- |
| 效率与自动化 | 剪贴板历史、快捷启动、文本片段、串联多个动作的工作流 |
| 文件与内容 | 文件预览、格式转换、批量处理、截图标注与文字识别 |
| 系统与设备 | 音频设备切换、显示器控制、电池与系统状态、专注场景 |
| 开发与智能工具 | 文本与编码处理、接口调试、本地 AI 辅助、自然语言触发工具 |
| 桌面与趣味 | 桌面小组件、交互效果、情境主题 |

## 开发约定

- 新功能的入口和设置放在对应的功能页，提供可直接使用的默认配置。
- 功能可以单独关闭，规则可以修改或删除。权限按需申请，数据支持备份恢复。
- 后台任务按需运行；新增功能时检查内存、能耗、空闲释放与退出行为。
- 在真实应用和设备上验证，包含文件、多屏和异常情况；失败时给出具体原因。
- 各功能独立维护，共用设置、存储和运行管理。

## 项目状态

当前版本为 **0.1.0**，支持 macOS 13+、Apple Silicon 与 Intel，界面提供简体中文和 English。[官网下载](https://arc-kit.com/download/)与 [GitHub Releases](https://github.com/huixiangyang/arc-kit/releases)提供同一份 GitHub Actions 构建的 DMG / ZIP。

**安装包未使用 Apple Developer ID 签名或公证。** macOS 可能阻止首次打开，下载和安装条件见[交付说明](Documentation/交付.md)。应用使用 Sparkle 自动检查更新、校验签名并完成安装与重启；可在“系统设置 → 关于”关闭自动检查，或开启自动下载并在退出时安装。从旧开发版升级需要先手动安装一次。

已知限制包括 iCloud Drive 的 Finder Sync 回调范围、部分应用的窗口控制限制，以及需要真实设备验证的滚动行为。详细进展见[版本说明](Documentation/版本说明.md)和[规划](Documentation/规划.md)。

## 数据与运行方式

生产数据统一存于 `~/.arc-kit/`。`app.sqlite` 保存配置与资源索引，素材、日志、缓存、备份及运行状态按职责分目录。主应用是数据库唯一写入者；Runtime Host 只读已提交配置，Finder 扩展通过可信 XPC 获取菜单快照。

只有一个统一 Runtime Host。窗口或鼠标启用时保留后台；仅 Finder 启用时按需唤醒、空闲退出。Finder 文件动作使用临时 Worker，系统可能创建多个 Finder 扩展实例；两者不等于重复常驻 Host。关闭设置窗口保留功能，正常退出应用会注销后台。

## 开发入口

需要完整 Xcode 26+、随附 Swift 工具链、XcodeGen 和 Python 3。在仓库根目录启动隔离的界面调试：

```sh
swift build --product ArcKitApp
.build/debug/ArcKitApp --ui-debug
```

Debug 数据位于 `.build/ui-debug/data/`，不修改安装版配置，不启动 Host，不更改真实桌面。完整产品构建、按需回归和本地化资源流程见[开发](Documentation/开发.md)。

```text
Sources/          Application、Features、Platform、UI
Targets/          主应用、Runtime Host、Finder 扩展入口与配置
Tests/ArcKitTests/ 关键行为回归
Build/            XcodeGen 声明与本地化构建支持
Documentation/    目录结构、使用、架构、开发、交付、版本说明、规划
Licenses/         第三方归属及许可证原文
Package.swift     SwiftPM 模块声明
project.yml       XcodeGen 根配置
```

## 参与贡献

欢迎提交缺陷、翻译、交互改进，也欢迎带来新的工具想法。先描述具体使用场景和可观察的效果；涉及较大设计调整时先开 Issue 讨论。开发流程见[贡献指南](CONTRIBUTING.md)，安全问题见[安全说明](SECURITY.md)。

项目源码采用 [MIT License](LICENSE)。第三方依赖保留各自的许可证，在线素材不属于项目开源授权范围；实际依赖、品牌和模板的归属见[许可证说明](Licenses/README.md)。

## 文档入口

| 文档 | 用途 |
| --- | --- |
| [目录结构](Documentation/目录结构.md) | 带职责说明的源码、构建与运行数据目录树 |
| [使用](Documentation/使用.md) | 功能入口、权限、备份恢复和故障处理 |
| [架构](Documentation/架构.md) | 模块边界、进程、配置提交与功能执行链路 |
| [开发](Documentation/开发.md) | 调试、构建、必要回归、资源和修改规则 |
| [交付](Documentation/交付.md) | 源码发布、签名、升级及离线恢复流程 |
| [版本说明](Documentation/版本说明.md) | 已交付变更及关键历史修正 |
| [规划](Documentation/规划.md) | 尚未交付或验收的事项、优先级和完成条件 |
| [第三方许可证](Licenses/README.md) | 实际使用范围、授权正文与素材边界 |

功能变更同步对应文档；个人设备、安装日志和临时诊断不进入公开仓库。
