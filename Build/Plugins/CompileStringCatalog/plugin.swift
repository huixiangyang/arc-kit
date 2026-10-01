import Foundation
import PackagePlugin

/// SwiftPM 使用与 Xcode 相同的 Apple 工具；符号和译文都归当前 target 的 Bundle。
@main
struct CompileStringCatalog: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        // 资源按编译 Bundle 归属；Application 的源码覆盖多个功能目录。
        let root: URL
        if target.name == "ArcKitApplication" {
            root = context.package.directoryURL.appending(path: "Sources/Application")
        } else if target.directoryURL.lastPathComponent == "Sources" {
            root = target.directoryURL.deletingLastPathComponent()
        } else {
            root = target.directoryURL
        }
        let directory = root.appending(path: "Resources/Localization")
        var catalogs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" && $0.lastPathComponent != "InfoPlist.xcstrings" }
        let common = context.package.directoryURL.appending(path: "Sources/Platform/Resources/Localization/Common.xcstrings")
        if !catalogs.contains(common) { catalogs.append(common) }
        let compiler = context.package.directoryURL.appending(path: "Build/Scripts/compile-string-catalog.sh")

        catalogs.sort { $0.path < $1.path }
        // SwiftPM 按目录复制 lproj；同一 target 必须一次产出完整语言目录，不能逐表覆盖。
        let resources = context.pluginWorkDirectoryURL.appending(path: "Resources")
        let compile = Command.prebuildCommand(
            displayName: "Compile \(target.name) String Catalogs",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [compiler.path, resources.path] + catalogs.map(\.path),
            outputFilesDirectory: resources
        )
        return [compile] + catalogs.map { catalog -> Command in
            let table = catalog.deletingPathExtension().lastPathComponent
            let symbols = context.pluginWorkDirectoryURL.appending(path: "Symbols/\(table)")
            return .buildCommand(
                displayName: "Generate \(target.name)/\(table) symbols",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xcstringstool", "generate-symbols", catalog.path, "-o", symbols.path, "-l", "swift"],
                inputFiles: [catalog],
                outputFiles: [symbols.appending(path: "GeneratedStringSymbols_\(table).swift")]
            )
        }
    }
}
