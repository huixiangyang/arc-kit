import ArcKitPlatform
import ArcKitWindow
import ApplicationServices
@preconcurrency import AppKit
import Foundation

// 系统 AX 适配和边界类型检查集中在此，运行编排不直接操作 CF 对象。
@MainActor
protocol WindowAccessibilityClient {
    func validateAccessibilityOperational() async throws
    func sceneWindows(isValid: @MainActor () -> Bool) async throws -> [WindowSceneAXWindow]
    func focusWindow(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws
    func validateSceneWindowVisible(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws
    func frontmostApplication() -> AppConfigurationCandidate?
    func isApplicationTerminated(pid: pid_t) -> Bool
    func windowTarget(for pid: pid_t, bundleIdentifier: String?) async throws -> WindowActionTarget?
    func windowTarget(at point: CGPoint) async -> WindowHitTestTarget?
    func validateWindowAdjustable(_ target: WindowActionTarget) async throws
    func isWindowFullScreen(_ target: WindowActionTarget) async throws -> Bool
    func setWindowFullScreen(_ enabled: Bool, for target: WindowActionTarget) async throws
    func frame(of target: WindowActionTarget) async throws -> CGRect
    func setFrame(_ frame: CGRect, for target: WindowActionTarget) async throws
}

extension WindowAccessibilityClient {
    func validateAccessibilityOperational() async throws {}
    func sceneWindows(isValid: @MainActor () -> Bool) async throws -> [WindowSceneAXWindow] { throw WindowManagementExecutionError.accessibilityAPIUnavailable }
    func focusWindow(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws { throw WindowManagementExecutionError.unwritableWindow }
    func validateSceneWindowVisible(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws { throw WindowManagementExecutionError.unreadableWindow }
}

@MainActor
struct SystemWindowAccessibilityClient: WindowAccessibilityClient {
    private let executor = WindowAXExecutor()

    func validateAccessibilityOperational() async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication.map { [$0] } ?? []
        var seen = Set<pid_t>()
        let pids = (frontmost + NSWorkspace.shared.runningApplications).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular && !$0.isTerminated && seen.insert($0.processIdentifier).inserted
        }.map(\.processIdentifier)
        try await executor.perform { kernel in
            kernel.candidatePIDs = pids
            try kernel.validateAccessibilityOperational()
        }
    }

    func sceneWindows(isValid: @MainActor () -> Bool) async throws -> [WindowSceneAXWindow] {
        try await sceneWindows(onlyProcess: nil, isValid: isValid)
    }

    private func sceneWindows(onlyProcess: pid_t?, isValid: @MainActor () -> Bool) async throws -> [WindowSceneAXWindow] {
        // CGWindowList 只读取当前桌面窗口的编号/几何元数据，不捕获像素或请求录屏权限。
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { item -> WindowSceneVisibleWindow? in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let number = item[kCGWindowNumber as String] as? Int,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return WindowSceneVisibleWindow(pid: pid, number: number, frame: frame)
        }
        var windows: [WindowSceneAXWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated && (onlyProcess == nil || onlyProcess == app.processIdentifier) {
            guard isValid() else { throw CancellationError() }
            guard let bundle = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            let appVisible = visible.filter { $0.pid == pid }
            guard !appVisible.isEmpty else { continue }
            let name = app.localizedName ?? bundle
            let launched = app.launchDate
            do {
                let targets = try await executor.perform { try $0.sceneTargets(pid: pid, bundleIdentifier: bundle, visible: appVisible) }
                windows += targets.map { .init(target: $0, applicationName: name, applicationLaunchDate: launched) }
            } catch {
                guard isValid() else { throw CancellationError() }
                // 某个应用 AX 无响应不能阻塞其他应用；只记 PID，不记录窗口标题。
                ArcKitLog.append("window scene enumeration skipped unresponsive pid=\(pid)")
            }
        }
        return windows
    }

    func focusWindow(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            throw WindowManagementExecutionError.captureApplicationUnavailable
        }
        try await validateSceneWindowVisible(target, isValid: isValid)
        guard isValid() else { throw CancellationError() }
        // 只显式激活用户选定的一个窗口；不改变全屏、Space 或其他应用状态。
        guard app.activate(options: []) else { throw WindowManagementExecutionError.unwritableWindow }
        try await executor.perform { try $0.focusWindow(target) }
    }

    func validateSceneWindowVisible(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws {
        // 只复核固定 AX 引用仍属于当前桌面，绝不重新选择同标题或前台窗口。
        let visible = try await sceneWindows(onlyProcess: target.pid, isValid: isValid)
        guard isValid() else { throw CancellationError() }
        guard visible.contains(where: { $0.target.pid == target.pid && CFEqual($0.target.element, target.element) }) else {
            throw WindowManagementExecutionError.unreadableWindow
        }
    }

    func frontmostApplication() -> AppConfigurationCandidate? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return nil }
        return AppConfigurationCandidate(
            displayName: app.localizedName ?? bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(app.processIdentifier)
        )
    }

    func isApplicationTerminated(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isTerminated != false
    }

    func windowTarget(for pid: pid_t, bundleIdentifier: String?) async throws -> WindowActionTarget? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              bundleIdentifier == nil || app.bundleIdentifier == bundleIdentifier else {
            throw WindowManagementExecutionError.captureApplicationUnavailable
        }
        return try await executor.perform { try $0.windowTarget(for: pid, bundleIdentifier: bundleIdentifier) }
    }

    func validateWindowAdjustable(_ target: WindowActionTarget) async throws -> Void {
        try await executor.perform { try $0.validateWindowAdjustable(target) }
    }

    func isWindowFullScreen(_ target: WindowActionTarget) async throws -> Bool {
        try await executor.perform { try $0.isWindowFullScreen(target) }
    }

    func setWindowFullScreen(_ enabled: Bool, for target: WindowActionTarget) async throws -> Void {
        try await executor.perform { try $0.setWindowFullScreen(enabled, for: target) }
    }

    func frame(of target: WindowActionTarget) async throws -> CGRect {
        try await executor.perform { try $0.frame(of: target) }
    }

    func setFrame(_ frame: CGRect, for target: WindowActionTarget) async throws -> Void {
        try await executor.perform { try $0.setFrame(frame, for: target) }
    }

    func windowTarget(at point: CGPoint) async -> WindowHitTestTarget? {
        try? await executor.perform { $0.windowTarget(at: point) }
    }
}

/// 同步 AX 调用只在专用串行队列执行，绝不占用输入线程或 MainActor。
private final class WindowAXExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.archalo.arckit.window.ax", qos: .userInitiated)
    private let kernel = WindowAXKernel()

    func perform<T: Sendable>(_ operation: @escaping @Sendable (WindowAXKernel) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(3)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    guard Date() < deadline else { throw CancellationError() }
                    kernel.deadline = deadline
                    return try operation(kernel)
                })
            }
        }
    }
}

/// 所有可变状态及 AX 原生引用仅由 WindowAXExecutor 串行访问。
private final class WindowAXKernel {

    private let frameWriter = WindowAXFrameWriter()
    var candidatePIDs: [pid_t] = []
    var deadline = Date.distantFuture
    private var expired: Bool { Date() >= deadline }

    func validateAccessibilityOperational() throws {
        for attempt in 0..<2 {
            if focusedApplicationIsReadable() || externalApplicationIsReadable() {
                return
            }
            if attempt < 1 {
                // 后台 LaunchAgent 或独立烟测刚启动时可能短暂没有 focused application，给 Workspace/AX 一次收敛时间。
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        throw WindowManagementExecutionError.accessibilityAPIUnavailable
    }

    private func focusedApplicationIsReadable() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &value
        ) == .success,
        let value,
        let application = WindowAXTypeSafety.axElement(value as AnyObject)
        else { return false }
        return stringAttribute(kAXRoleAttribute as CFString, from: application) == "AXApplication"
    }

    private func externalApplicationIsReadable() -> Bool {
        for pid in candidatePIDs.prefix(4) {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            if stringAttribute(kAXRoleAttribute as CFString, from: element) == "AXApplication" { return true }
        }
        return false
    }

    func windowTarget(for pid: pid_t, bundleIdentifier: String?) throws -> WindowActionTarget? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var receivedApplicationPayload = false
        if let focused = copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: app) {
            if stringAttribute(kAXRoleAttribute as CFString, from: focused) != "AXApplication" {
                return try makeWindowTarget(focused, pid: pid, bundleIdentifier: bundleIdentifier)
            }
            receivedApplicationPayload = true
            // macOS 26 偶尔会把 kAXFocusedWindow 错回传为应用元素。仅此畸形值允许继续读取
            // main/windows；真实 focused 窗口若被拒绝仍必须原样失败，不能偷偷操作后台窗口。
            ArcKitLog.append("window focused attribute returned application payload pid=\(pid) fallback=main")
        }
        if let main = copyElementAttribute(kAXMainWindowAttribute as CFString, from: app) {
            if stringAttribute(kAXRoleAttribute as CFString, from: main) != "AXApplication" {
                return try makeWindowTarget(main, pid: pid, bundleIdentifier: bundleIdentifier)
            }
            receivedApplicationPayload = true
            ArcKitLog.append("window main attribute returned application payload pid=\(pid) fallback=windows")
        }
        let candidates = copyArrayAttribute(kAXWindowsAttribute as CFString, from: app) ?? []
        var preferredError: WindowManagementExecutionError?
        for window in candidates.prefix(64) {
            guard !expired else { break }
            do {
                return try makeWindowTarget(window, pid: pid, bundleIdentifier: bundleIdentifier)
            } catch let error as WindowManagementExecutionError {
                if case .accessibilityAPIUnavailable = error {
                    receivedApplicationPayload = true
                }
                if preferredError.map({ rejectionPriority(error) > rejectionPriority($0) }) ?? true {
                    preferredError = error
                }
            }
        }
        if receivedApplicationPayload,
           let target = hitTestWindowTarget(for: pid, bundleIdentifier: bundleIdentifier) {
            ArcKitLog.append(
                "window target recovered from pid-bound hit test pid=\(pid) identity=\(target.restoreKey.diagnosticDescription)"
            )
            return target
        }
        if let preferredError {
            throw preferredError
        }
        return nil
    }

    func sceneTargets(pid: pid_t, bundleIdentifier: String, visible: [WindowSceneVisibleWindow]) throws -> [WindowActionTarget] {
        let app = AXUIElementCreateApplication(pid)
        let windows = copyArrayAttribute(kAXWindowsAttribute as CFString, from: app) ?? []
        var targets: [WindowActionTarget] = []
        for window in windows.prefix(128) {
            guard !expired else { throw CancellationError() }
            if let target = try? makeWindowTarget(window, pid: pid, bundleIdentifier: bundleIdentifier) { targets.append(target) }
        }
        var candidates: [(WindowActionTarget, CGRect, [Int])] = []
        for target in targets {
            guard !expired else { throw CancellationError() }
            guard (try? validateWindowAdjustable(target)) != nil,
                  let window = try? axElement(from: target),
                  let frame = try? frame(of: target) else { continue }
            var positionSettable = DarwinBoolean(false)
            var sizeSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success,
                  AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
                  positionSettable.boolValue, sizeSettable.boolValue else { continue }
            let matching = visible.filter { item in
                if let number = target.restoreKey.windowNumber { return item.number == number }
                return abs(frame.minX - item.frame.minX) <= 2 && abs(frame.minY - item.frame.minY) <= 2
                    && abs(frame.width - item.frame.width) <= 2 && abs(frame.height - item.frame.height) <= 2
            }.map(\.number)
            candidates.append((target, frame, matching))
        }
        // 没有 AXWindowNumber 时，仅接受 AX 与当前桌面 CG 几何的一对一对应。
        // 多个 Space 窗口重叠会被排除，不能猜测后搬动其他桌面的窗口。
        return candidates.compactMap { candidate in
            guard candidate.2.count == 1, let number = candidate.2.first,
                  candidates.filter({ $0.2.contains(number) }).count == 1 else { return nil }
            return candidate.0
        }
    }

    func focusWindow(_ target: WindowActionTarget) throws {
        let window = try axElement(from: target)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw WindowManagementExecutionError.unwritableWindow
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let focused = copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: app), CFEqual(focused, window) else {
            throw WindowManagementExecutionError.unreadableWindow
        }
    }

    func windowTarget(at point: CGPoint) -> WindowHitTestTarget? {
        guard let hitElement = element(at: point) else { return nil }
        guard let resolved = enclosingWindowAndRoles(for: hitElement) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(resolved.window, &pid) == .success,
              let target = try? makeWindowTarget(resolved.window, pid: pid)
        else { return nil }
        return WindowHitTestTarget(target: target, hitTestRoles: resolved.roles)
    }

    func validateWindowAdjustable(_ target: WindowActionTarget) throws {
        let window = try axElement(from: target)
        if (try? boolAttribute(kAXMinimizedAttribute as CFString, from: window)) == true {
            throw WindowManagementExecutionError.minimizedWindow
        }
        if (try? boolAttribute("AXFullScreen" as CFString, from: window)) == true {
            throw WindowManagementExecutionError.fullScreenWindow
        }
    }

    func isWindowFullScreen(_ target: WindowActionTarget) throws -> Bool {
        try boolAttribute("AXFullScreen" as CFString, from: axElement(from: target))
    }

    func setWindowFullScreen(_ enabled: Bool, for target: WindowActionTarget) throws {
        let window = try axElement(from: target)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success,
              settable.boolValue
        else {
            throw WindowManagementExecutionError.fullScreenUnavailable
        }
        let result = AXUIElementSetAttributeValue(
            window,
            "AXFullScreen" as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard result == .success else {
            throw WindowManagementExecutionError.fullScreenUnavailable
        }
    }

    func frame(of target: WindowActionTarget) throws -> CGRect {
        let window = try axElement(from: target)
        return try frameWriter.frame(of: window, deadline: deadline)
    }

    func setFrame(_ frame: CGRect, for target: WindowActionTarget) throws {
        let window = try axElement(from: target)
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
              positionSettable.boolValue,
              sizeSettable.boolValue
        else {
            throw WindowManagementExecutionError.unwritableWindow
        }
        try frameWriter.setFrame(frame, for: window, deadline: deadline)
    }

    private func makeWindowTarget(_ window: AXUIElement, pid: pid_t, bundleIdentifier: String? = nil) throws -> WindowActionTarget {
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(window, &actualPID) == .success, actualPID == pid else {
            throw WindowManagementExecutionError.unreadableWindow
        }
        AXUIElementSetMessagingTimeout(window, 0.25)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: window)
        do {
            try WindowAXCandidateGuard.validate(role: role)
        } catch {
            ArcKitLog.append(
                "window target invalid ax payload pid=\(pid) role=AXApplication reason=accessibility-api-unavailable"
            )
            throw error
        }
        let metadata: WindowCandidateMetadata
        do {
            metadata = try makeCandidateMetadata(window)
        } catch {
            ArcKitLog.append(
                "window target candidate unreadable pid=\(pid) role=\(stringAttribute(kAXRoleAttribute as CFString, from: window) ?? "-") " +
                "subrole=\(stringAttribute(kAXSubroleAttribute as CFString, from: window) ?? "-") error=\(error.localizedDescription)"
            )
            throw error
        }
        if let rejection = WindowCandidateFilter.rejectionReason(for: metadata) {
            // 仅记结构元数据，避免窗口标题、文件名或页面内容进入诊断日志。
            ArcKitLog.append("window target candidate classified pid=\(pid) role=\(metadata.role ?? "-") subrole=\(metadata.subrole ?? "-") modal=\(metadata.isModal) minimized=\(metadata.isMinimized) fullScreen=\(metadata.isFullScreen) size=\(metadata.frame.width)x\(metadata.frame.height) reason=\(rejection.rawValue)")
            switch rejection {
            case .minimized:
                throw WindowManagementExecutionError.minimizedWindow
            case .fullScreen:
                // 全屏窗口仍是合法动作目标；几何动作会在 validateWindowAdjustable 中拒绝，
                // 真实全屏动作则需要拿到同一 AXWindow 才能退出全屏。
                break
            case .nonWindow, .modal, .tooSmall, .unsupportedSubrole:
                throw WindowManagementExecutionError.unsupportedWindow(rejection)
            }
        }
        let title = stringAttribute(kAXTitleAttribute as CFString, from: window)
        let key = WindowRestoreIdentity(
            pid: Int32(pid),
            windowNumber: intAttribute("AXWindowNumber" as CFString, from: window),
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "-",
            role: metadata.role ?? "-",
            subrole: metadata.subrole ?? "-"
        )
        let resolvedBundleIdentifier = bundleIdentifier ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return WindowActionTarget(element: window, restoreKey: key, pid: pid, bundleIdentifier: resolvedBundleIdentifier)
    }

    private func rejectionPriority(_ error: WindowManagementExecutionError) -> Int {
        switch error {
        case .accessibilityAPIUnavailable, .captureApplicationUnavailable: 5
        case .fullScreenWindow: 4
        case .minimizedWindow: 3
        case .unsupportedWindow: 2
        case .unreadableWindow: 1
        case .unwritableWindow, .fullScreenUnavailable, .fullScreenVerificationFailed, .frameVerificationFailed: 0
        }
    }

    private func makeCandidateMetadata(_ window: AXUIElement) throws -> WindowCandidateMetadata {
        let frame = try rawFrame(of: window)
        return WindowCandidateMetadata(
            role: stringAttribute(kAXRoleAttribute as CFString, from: window),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: window),
            isModal: (try? boolAttribute("AXModal" as CFString, from: window)) == true,
            isMinimized: (try? boolAttribute(kAXMinimizedAttribute as CFString, from: window)) == true,
            isFullScreen: (try? boolAttribute("AXFullScreen" as CFString, from: window)) == true,
            frame: frame
        )
    }

    private func rawFrame(of window: AXUIElement) throws -> CGRect {
        try frame(of: WindowActionTarget(
            element: window,
            restoreKey: WindowRestoreIdentity(pid: 0, windowNumber: nil, title: "-", role: "-", subrole: "-"),
            pid: 0,
            bundleIdentifier: nil
        ))
    }

    private func axElement(from target: WindowActionTarget) throws -> AXUIElement {
        guard !expired else { throw CancellationError() }
        guard let element = WindowAXTypeSafety.axElement(target.element) else {
            throw WindowManagementExecutionError.unreadableWindow
        }
        var actualPID: pid_t = 0
        // rawFrame 只用于候选元数据读取；已捕获目标在每次读写前核对真实所有者。
        if target.pid != 0 {
            guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == target.pid else {
                throw WindowManagementExecutionError.unreadableWindow
            }
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) throws -> Bool {
        guard !expired else { throw CancellationError() }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let boolValue = value as? Bool
        else {
            throw WindowManagementExecutionError.unreadableWindow
        }
        return boolValue
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard !expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        return WindowAXTypeSafety.axElement(value)
    }

    private func copyArrayAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement]? {
        guard !expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let array = value as? [AnyObject]
        else { return nil }
        return array.compactMap { WindowAXTypeSafety.axElement($0) }
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard !expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        return value as? String
    }

    private func intAttribute(_ attribute: CFString, from element: AXUIElement) -> Int? {
        guard !expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        guard result == .success else { return nil }
        return element
    }

    private func enclosingWindowAndRoles(for element: AXUIElement) -> (window: AXUIElement, roles: [String])? {
        var current: AXUIElement? = element
        var roles: [String] = []
        // Chrome / Electron / Finder 列表等复杂视图的 AX 子节点可能很深；
        // 这里必须尽量追到窗口，避免只拿到内部文字节点后误判为可拖拽标题区域。
        for _ in 0..<24 {
            guard !expired else { return nil }
            guard let candidate = current else { return nil }
            if let role = stringAttribute(kAXRoleAttribute as CFString, from: candidate) {
                roles.append(role)
                if role == "AXWindow" {
                    return (candidate, roles)
                }
            }
            current = copyElementAttribute(kAXParentAttribute as CFString, from: candidate)
        }
        return nil
    }

    private func hitTestWindowTarget(
        for pid: pid_t,
        bundleIdentifier: String?
    ) -> WindowActionTarget? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(kCGNullWindowID)
        ) as? [[CFString: Any]] else {
            return nil
        }

        for info in windowInfo.prefix(128) {
            guard !expired else { return nil }
            guard let ownerPID = info[kCGWindowOwnerPID] as? NSNumber,
                  ownerPID.int32Value == pid,
                  let layer = info[kCGWindowLayer] as? NSNumber,
                  layer.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 80,
                  bounds.height >= 60
            else { continue }

            for point in WindowHitTestProbe.points(in: bounds) {
                guard let hitElement = element(at: point),
                      let resolved = enclosingWindowAndRoles(for: hitElement)
                else { continue }
                var resolvedPID: pid_t = 0
                guard AXUIElementGetPid(resolved.window, &resolvedPID) == .success,
                      resolvedPID == pid,
                      let target = try? makeWindowTarget(
                          resolved.window,
                          pid: pid,
                          bundleIdentifier: bundleIdentifier
                      )
                else { continue }
                return target
            }
        }
        return nil
    }

}

enum WindowHitTestProbe {
    static func points(in bounds: CGRect) -> [CGPoint] {
        guard !bounds.isNull, !bounds.isEmpty else { return [] }
        let insetX = min(24, max(1, bounds.width / 4))
        let insetY = min(24, max(1, bounds.height / 4))
        // 标题栏、内容中央和四角内侧都探测；复杂 App 的中央可能被无 AX 语义的渲染层覆盖。
        return [
            CGPoint(x: bounds.midX, y: bounds.minY + insetY),
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.minX + insetX, y: bounds.minY + insetY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.minY + insetY),
            CGPoint(x: bounds.minX + insetX, y: bounds.maxY - insetY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.maxY - insetY),
        ]
    }
}

enum WindowAXTypeSafety {
    static func axValue(_ value: CFTypeRef, expectedType: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // CFTypeID 已精确验证；避免 Swift 强制类型转换在边界数据上触发 trap。
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == expectedType else { return nil }
        return axValue
    }

    static func axElement(_ value: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

enum WindowAXCandidateGuard {
    static func validate(role: String?) throws {
        guard role != "AXApplication" else {
            throw WindowManagementExecutionError.accessibilityAPIUnavailable
        }
    }
}

/// AX 引用只由专用执行器解引用，主线程仅持有不透明目标和不可变元数据。
struct WindowActionTarget: @unchecked Sendable {
    var element: AnyObject
    var restoreKey: WindowRestoreIdentity
    var pid: pid_t
    var bundleIdentifier: String?
}

struct WindowHitTestTarget: Sendable {
    var target: WindowActionTarget
    var hitTestRoles: [String]
}

struct WindowSnapPreviewFrame {
    var accessibilityFrame: CGRect
    var appKitFrame: CGRect
}

enum WindowManagementExecutionError: Error, LocalizedError {
    case accessibilityAPIUnavailable
    case captureApplicationUnavailable
    case unreadableWindow
    case unwritableWindow
    case unsupportedWindow(WindowCandidateRejectionReason)
    case minimizedWindow
    case fullScreenWindow
    case fullScreenUnavailable
    case fullScreenVerificationFailed(expected: Bool, actual: Bool)
    case frameVerificationFailed(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .accessibilityAPIUnavailable:
            L10n.string(.WindowRuntime.accessibilityAccessibilityAccessGrantedWindow)
        case .captureApplicationUnavailable:
            L10n.string(.WindowRuntime.accessibilityAppUnavailable)
        case .unreadableWindow:
            L10n.string(.WindowRuntime.accessibilityFrameReadFailed)
        case .unwritableWindow:
            L10n.string(.WindowRuntime.accessibilityNotResizable)
        case .unsupportedWindow(let reason):
            switch reason {
            case .nonWindow: L10n.string(.WindowRuntime.accessibilityTargetMissing)
            case .modal: L10n.string(.WindowRuntime.accessibilityCurrentWindowDialogClose)
            default: L10n.string(.WindowRuntime.accessibilityUnsupportedType)
            }
        case .minimizedWindow:
            L10n.string(.WindowRuntime.accessibilityMinimized)
        case .fullScreenWindow:
            L10n.string(.WindowRuntime.accessibilityCurrentWindowFullScreen)
        case .fullScreenUnavailable:
            L10n.string(.WindowRuntime.accessibilityFullScreenUnsupported)
        case .fullScreenVerificationFailed(let expected, let actual):
            L10n.string(.WindowRuntime.accessibilityFullScreenUnconfirmed(String(describing: expected ? L10n.string(.WindowRuntime.layoutFullScreen) : L10n.string(.WindowRuntime.accessibilityRegularWindow)), String(describing: actual ? L10n.string(.WindowRuntime.layoutFullScreen) : L10n.string(.WindowRuntime.accessibilityRegularWindow))))
        case .frameVerificationFailed(let expected, let actual):
            L10n.string(.WindowRuntime.accessibilityFrameUnconfirmed(String(describing: expected), String(describing: actual)))
        }
    }
}

struct WindowSceneAXWindow: Sendable {
    var target: WindowActionTarget
    var applicationName: String
    var applicationLaunchDate: Date?
}

private struct WindowSceneVisibleWindow: Sendable {
    var pid: Int32
    var number: Int
    var frame: CGRect
}
