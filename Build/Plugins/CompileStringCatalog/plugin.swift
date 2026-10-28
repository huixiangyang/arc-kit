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
        // 显式声明 Catalog 输入与 Apple 编译器的实际输出，增量改文案必须触发资源重编译。
        // 仍按 target 一次编译，避免多个命令互相清空同一个资源目录。
        let resources = context.pluginWorkDirectoryURL.appending(path: "Resources")
        let outputFiles = try catalogs.flatMap { try compilationOutputs(catalog: $0, directory: resources) }
        let compile = Command.buildCommand(
            displayName: "Compile \(target.name) String Catalogs",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [compiler.path, resources.path] + catalogs.map(\.path),
            inputFiles: catalogs + [compiler],
            outputFiles: outputFiles
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

    private func compilationOutputs(catalog: URL, directory: URL) throws -> [URL] {
        // strings/stringsdict 的生成规则由 Apple 决定，不在插件中复制复数或语言推断逻辑。
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcstringstool", "compile", catalog.path, "--output-directory", directory.path, "--dry-run"]
        process.standardOutput = output
        // stderr 直接交给 SwiftPM；避免等待进程退出时被未排空的错误管道阻塞。
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CatalogError(message: "xcstringstool failed (\(process.terminationStatus)): \(catalog.path)")
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0)) }
    }

    private struct CatalogError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
