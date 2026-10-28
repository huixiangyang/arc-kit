#if DEBUG
import AppKit
import ArcKitPlatform
import Darwin
import ScreenCaptureKit

/// 仅在明确授权后运行的短时实机检查。所有写入局限于新证据目录和本进程拥有的 UI。
@MainActor
final class MenuBarNativeCheck {
    private let directory: URL
    private let measuresWidths: Bool
    private let driver: NativeMenuBarPartitions
    private var fixtures: [NSStatusItem] = []
    private var signals: [DispatchSourceSignal] = []
    private var report: [String: Any] = [:]
    private var stages: [[String: Any]] = []
    private var completed = false

    init(directory: URL, measuresWidths: Bool = false) {
        self.directory = directory
        self.measuresWidths = measuresWidths
        driver = NativeMenuBarPartitions(namespace: "menu-bar-native-check.\(UUID())", savesPositions: false,
                                         mode: measuresWidths ? .offscreen : .current)
    }

    func run() async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            report = ["pid": ProcessInfo.processInfo.processIdentifier,
                      "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                      "screenCaptureGranted": CGPreflightScreenCaptureAccess(),
                      "startedAt": ISO8601DateFormatter().string(from: Date()),
                      "scope": measuresWidths ? "temporary-owned-widths-only" : "temporary-owned-partitions; no production storage or Host"]
            armCleanup()
            defer { cleanup() }
            guard let screens = MenuBarScreenSnapshot.capture() else { throw MenuBarPartitionError.unavailable }
            report["screens"] = NSScreen.screens.map { ["frame": NSStringFromRect($0.frame), "visibleFrame": NSStringFromRect($0.visibleFrame)] }
            let baselineWindows = windowReadings()
            report["baselineWindows"] = baselineWindows
            // 截图只记录顶部菜单栏区域，不导出桌面和其他窗口内容。
            for display in screens.displays { await capture("baseline-\(display.id)", display: display) }

            if measuresWidths {
                let plan = try MenuBarOverflowPlan(displays: screens.displays)
                report["spacingPlan"] = ["segmentLength": plan.segmentLength, "segmentCount": plan.segmentCount]
                driver.install(deepSectionEnabled: false)
                let spacers = (1..<plan.segmentCount).map { _ in addFixture(nil, label: "Arc Kit temporary spacer", length: 0) }
                addFixture(.sun, label: "Arc Kit temporary width fixture")
                try await Task.sleep(for: .milliseconds(1000))
                for collapsed in [false, true, false] {
                    driver.nativeCheckSetSpacerLength(collapsed ? plan.segmentLength : 18)
                    for item in spacers { item.length = collapsed ? plan.segmentLength : 0 }
                    try await Task.sleep(for: .milliseconds(700))
                    let name = "segments-\(collapsed ? "collapsed" : "expanded")-\(stages.count)"
                    await record(name)
                    for display in screens.displays { await capture("\(name)-\(display.id)", display: display) }
                }
            } else {
                driver.install(deepSectionEnabled: false)
                addFixture(.gauge, label: "Arc Kit temporary collected fixture")
                if MenuBarPartitionMode.current.supportsSections {
                    driver.install(deepSectionEnabled: true)
                    addFixture(.sun, label: "Arc Kit temporary deep fixture")
                }
                try await Task.sleep(for: .milliseconds(1400))
                await record("installed")
                for display in screens.displays { await capture("installed-\(display.id)", display: display) }
                for state in MenuBarPartitionMode.current.presentations {
                    let name = state.rawValue
                    do {
                        try await driver.present(state)
                        try await Task.sleep(for: .milliseconds(state == .all ? 1200 : 700))
                        await record(name)
                    } catch {
                        await record(name, error: error.localizedDescription)
                        driver.revealAll()
                    }
                    for display in screens.displays { await capture("\(name)-\(display.id)", display: display) }
                }
            }
            cleanup()
            try await Task.sleep(for: .milliseconds(500))
            await record("removed")
            for display in screens.displays { await capture("removed-\(display.id)", display: display) }
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            let failures = stages.filter { $0["error"] != nil }
            report["partitionRequestsConfirmed"] = measuresWidths ? NSNull() : failures.isEmpty
            report["visualAcceptance"] = "Review per-display screenshots for actual icon visibility and recovery"
            completed = true
            try writeReport()
            print("MENU_BAR_NATIVE_CHECK report=\(directory.appendingPathComponent("report.json").path) cleanup=completed mode=\(measuresWidths ? "width-measurement" : "partitions")")
            return failures.isEmpty ? 0 : 4
        } catch {
            cleanup()
            report["failure"] = error.localizedDescription
            // 输出目录已存在时不能覆盖其他检查的报告。
            if !report.isEmpty, report["startedAt"] != nil { try? writeReport() }
            print("MENU_BAR_NATIVE_CHECK failed: \(error.localizedDescription)")
            return 1
        }
    }

    @discardableResult
    private func addFixture(_ icon: ArcIconName?, label: String, length: CGFloat = 22) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        let image = icon.map { ArcIconImage.image($0) }
        image?.size = NSSize(width: 14, height: 14)
        item.autosaveName = .init("menu-bar-native-check.\(UUID()).fixture")
        item.button?.image = image
        item.button?.setAccessibilityLabel(label)
        fixtures.append(item)
        return item
    }

    private func cleanup() {
        driver.remove()
        for item in fixtures { item.autosaveName = nil; NSStatusBar.system.removeStatusItem(item) }
        fixtures.removeAll()
        report["cleanup"] = ["ownedItemsRemaining": fixtures.count + driver.nativeCheckReadings().count]
    }

    private func armCleanup() {
        // 主线程可以继续运行时先恢复长度再撤除；外层监督进程另有硬超时，涵盖主线程卡死。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
            guard !completed else { return }
            cleanup()
            report["failure"] = "30-second deadline exceeded; owned UI removed"
            try? writeReport()
            Darwin.exit(124)
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [self] in
                cleanup()
                report["failure"] = "Interrupted; owned UI removed"
                try? writeReport()
                Darwin.exit(128 + number)
            }
            source.resume()
            signals.append(source)
        }
    }

    private func record(_ name: String, error: String? = nil) async {
        var stage: [String: Any] = ["stage": name, "items": driver.nativeCheckReadings(), "windows": windowReadings()]
        stage["error"] = error
        do {
            let layout = try driver.layoutSnapshot()
            stage["layout"] = ["displayID": layout.displayID, "control": NSStringFromRect(layout.control),
                               "hidden": NSStringFromRect(layout.hidden), "deep": layout.deep.map(NSStringFromRect) ?? "none"]
        } catch { stage["layoutError"] = error.localizedDescription }
        stage["fixtures"] = fixtures.map { item -> [String: Any] in
            guard let button = item.button, let window = button.window else { return ["hasWindow": false] }
            return ["length": item.length, "windowID": window.windowNumber, "frame": NSStringFromRect(window.convertToScreen(button.convert(button.bounds, to: nil)))]
        }
        // 实测 AX 读取前后代理映射的显示器不同；在深度区检查结束后记录，再单独检查普通区。
        if name == "all" || measuresWidths,
           let inventory = try? await MenuBarInspector().captureForInteraction(processIDs: [ProcessInfo.processInfo.processIdentifier]) {
            let owned = inventory.items.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier ||
                $0.accessibilityIdentifier?.hasPrefix("menu-bar-native-check.") == true ||
                $0.label?.hasPrefix("Arc Kit temporary") == true
            }
            stage["ownedAXItems"] = owned.map { item -> [String: Any] in
                ["pid": item.processID, "identifier": item.accessibilityIdentifier ?? "", "label": item.label ?? "",
                 "frame": item.frame.map(NSStringFromRect) ?? "missing"]
            }
            stage["AXAccess"] = inventory.accessibility.rawValue
            stage["itemsAfterAX"] = driver.nativeCheckReadings()
            stage["AXAttributes"] = await MenuBarInspector().nativeCheckAttributes()
        }
        stages.append(stage)
        try? writeReport()
    }

    private func writeReport() throws {
        report["stages"] = stages
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }

    private func windowReadings() -> [[String: Any]] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { value in
            guard let level = value[kCGWindowLayer as String] as? Int, (23...25).contains(level) else { return nil }
            return ["id": value[kCGWindowNumber as String] ?? 0, "level": level,
                    "pid": value[kCGWindowOwnerPID as String] ?? 0, "owner": value[kCGWindowOwnerName as String] ?? "",
                    "bounds": value[kCGWindowBounds as String] ?? [:]]
        }
    }

    private func capture(_ name: String, display: MenuBarDisplay) async {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else {
            report["captureUnavailable"] = "Screen capture permission or macOS 14 required; no permission prompt requested"
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let native = content.displays.first(where: { $0.displayID == display.id }) else { throw MenuBarPartitionError.unavailable }
            let filter = SCContentFilter(display: native, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let height = display.topBand.height + 12
            configuration.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
            configuration.width = Int(display.frame.width * display.scale)
            configuration.height = Int(height * display.scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        } catch { report["captureError-\(name)"] = error.localizedDescription }
    }
}

#endif
