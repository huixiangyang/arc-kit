// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ArcKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArcKitPlatform", targets: ["ArcKitPlatform"]),
        .library(name: "ArcKitFinder", targets: ["ArcKitFinder"]),
        .library(name: "ArcKitWindow", targets: ["ArcKitWindow"]),
        .library(name: "ArcKitMouse", targets: ["ArcKitMouse"]),
        .library(name: "ArcKitApplication", targets: ["ArcKitApplication"]),
        .library(name: "ArcKitWindowRuntime", targets: ["ArcKitWindowRuntime"]),
        .library(name: "ArcKitMouseRuntime", targets: ["ArcKitMouseRuntime"]),
        .library(name: "ArcKitFinderRuntime", targets: ["ArcKitFinderRuntime"]),
        .library(name: "ArcKitFinderSync", targets: ["ArcKitFinderSync"]),
        .executable(name: "ArcKitApp", targets: ["ArcKitApp"]),
        .executable(name: "ArcKitRuntimeHost", targets: ["ArcKitRuntimeHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    // 目录按功能聚合；业务根显式排除 Runtime 和 Extension，三者独立编译，避免主应用链接后台实现。
    targets: [
        .plugin(name: "CompileStringCatalog", capability: .buildTool(), path: "Build/Plugins/CompileStringCatalog"),
        .target(
            name: "ArcKitPlatform",
            path: "Sources/Platform",
            exclude: ["Persistence", "Resources/Localization"],
            resources: [.copy("Resources/Lucide")],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitPersistence",
            dependencies: ["ArcKitPlatform", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Platform/Persistence",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitFinder",
            dependencies: ["ArcKitPlatform"],
            path: "Sources/Features/Finder/Domain",
            exclude: ["Resources/Localization"],
            resources: [.copy("Resources/NewFileTemplates")],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitWindow",
            dependencies: ["ArcKitPlatform"],
            path: "Sources/Features/Window/Domain",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitMouse",
            dependencies: ["ArcKitPlatform"],
            path: "Sources/Features/Mouse/Domain",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitApplication",
            dependencies: ["ArcKitPersistence", "ArcKitPlatform", "ArcKitFinder", "ArcKitWindow", "ArcKitMouse", .product(name: "Sparkle", package: "Sparkle")],
            // 前端按功能归档，仍归同一 UI 模块；运行实现和领域库显式排除。
            path: "Sources",
            exclude: ["Platform", "Application/Resources/Localization",
                "Features/Finder/Domain", "Features/Finder/Runtime", "Features/Finder/Extension",
                "Features/Window/Domain", "Features/Window/Runtime",
                "Features/Mouse/Domain", "Features/Mouse/Runtime"],
            resources: [.copy("Application/Resources/Brand"), .copy("Application/Resources/Aura")],
            // VideoPlayer 的 SwiftUI overlay 不保证加载 AppKit 播放器基类。
            linkerSettings: [.linkedFramework("AVKit")],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitWindowRuntime",
            dependencies: ["ArcKitPlatform", "ArcKitWindow"],
            path: "Sources/Features/Window/Runtime",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitMouseRuntime",
            dependencies: ["ArcKitPlatform", "ArcKitMouse"],
            path: "Sources/Features/Mouse/Runtime",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitFinderRuntime",
            dependencies: ["ArcKitPlatform", "ArcKitFinder"],
            path: "Sources/Features/Finder/Runtime",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .target(
            name: "ArcKitFinderSync",
            dependencies: ["ArcKitPlatform", "ArcKitFinder"],
            path: "Sources/Features/Finder/Extension",
            exclude: ["Resources/Localization"],
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .executableTarget(
            name: "ArcKitApp",
            dependencies: ["ArcKitApplication"],
            path: "Targets/ArcKitApp/Sources",
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .executableTarget(
            name: "ArcKitRuntimeHost",
            dependencies: ["ArcKitPersistence", "ArcKitPlatform", "ArcKitFinder", "ArcKitFinderRuntime", "ArcKitWindow", "ArcKitWindowRuntime", "ArcKitMouse", "ArcKitMouseRuntime"],
            path: "Targets/ArcKitRuntimeHost/Sources",
            plugins: [.plugin(name: "CompileStringCatalog")]
        ),
        .testTarget(
            name: "ArcKitTests",
            dependencies: ["ArcKitPersistence", "ArcKitApplication", "ArcKitPlatform", "ArcKitFinder", "ArcKitFinderSync", "ArcKitFinderRuntime", "ArcKitWindow", "ArcKitWindowRuntime", "ArcKitMouse", "ArcKitMouseRuntime"]
        ),
    ]
)
