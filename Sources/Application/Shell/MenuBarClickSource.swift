@preconcurrency import AppKit
import ApplicationServices
import ArcKitPlatform
import ArcKitWindow

/// 菜单栏代理转发点击前保存来源；只读事件、单条内存快照，不拦截或重放输入。
final class MenuBarClickSource: @unchecked Sendable {
    struct Origin: Sendable {
        let application: AppConfigurationCandidate
        let location: CGPoint
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var latest: Origin?
    private var latestInputTimestamp: CGEventTimestamp?
    private var foregroundChanges: [(application: AppConfigurationCandidate?, timestamp: TimeInterval)] = []
    @MainActor private var tap: EventTap?
    @MainActor private var foregroundObserver: NSKeyValueObservation?
    @MainActor var onForegroundChange: ((pid_t?) -> Void)?

    @MainActor init() {}

    @MainActor
    func stop() {
        tap?.invalidate()
        tap = nil
        foregroundObserver?.invalidate()
        foregroundObserver = nil
        lock.withLock {
            latest = nil
            latestInputTimestamp = nil
            foregroundChanges.removeAll()
        }
    }

    @MainActor
    func startIfAuthorized() {
        guard ProcessPermissions.canListenToInput() else { stop(); return }
        if tap?.isEnabled == true { return }
        stop()
        observeForeground(in: .shared)
        do {
            tap = try EventTap(events: [.leftMouseDown, .rightMouseDown], tapLocation: .cgSessionEventTap,
                               options: .listenOnly, handler: makeHandler())
            ArcKitLog.append("menu click source started mode=listen-only stage=session foreground=workspace-kvo")
        } catch {
            stop()
            ArcKitLog.append("menu click source unavailable")
        }
    }

    @MainActor
    func observeForeground(in workspace: NSWorkspace) {
        foregroundObserver?.invalidate()
        // 激活通知描述参与激活的应用，菜单代理可通知 Arc Kit 激活但键盘焦点仍在外部应用。
        // 只观察实际接收键盘输入的 frontmostApplication；它随主 RunLoop 在 common modes 更新。
        foregroundObserver = workspace.observe(\.frontmostApplication, options: [.initial, .new]) { [weak self] workspace, _ in
            MainActor.assumeIsolated {
                self?.recordForeground(workspace.frontmostApplication)
            }
        }
    }

    @MainActor
    private func recordForeground(_ application: NSRunningApplication?) {
        let candidate = application.flatMap { app -> AppConfigurationCandidate? in
            guard let bundle = app.bundleIdentifier else { return nil }
            return .init(displayName: app.localizedName ?? bundle, bundleIdentifier: bundle,
                         processIdentifier: app.processIdentifier)
        }
        if recordForeground(candidate, at: ProcessInfo.processInfo.systemUptime) {
            onForegroundChange?(candidate?.processIdentifier)
        }
    }

    @discardableResult
    func recordForeground(_ application: AppConfigurationCandidate?, at timestamp: TimeInterval) -> Bool {
        lock.withLock {
            guard foregroundChanges.last?.application != application || foregroundChanges.isEmpty else { return false }
            foregroundChanges.append((application, timestamp))
            // 仅留少量身份与时间，不记录窗口内容；快速切换过多而失去证据时拒绝捕获。
            if foregroundChanges.count > 16 { foregroundChanges.removeFirst(foregroundChanges.count - 16) }
            return true
        }
    }

    // 工厂必须位于非隔离上下文；不能让 @MainActor 启动方法的闭包隔离泄漏到输入线程。
    func makeHandler() -> @Sendable (CGEventTapProxy, CGEvent) -> CGEvent? {
        { [weak self] _, event in
            guard let self else { return event }
            self.lock.withLock {
                // 重复或迟到转发不能覆盖来源；消费后也不能再次使用同一条输入。
                guard event.timestamp > (self.latestInputTimestamp ?? 0) else { return }
                self.latestInputTimestamp = event.timestamp
                let timestamp = Double(event.timestamp) / 1_000_000_000
                let foreground = self.foregroundChanges.last(where: { $0.timestamp <= timestamp })
                self.latest = foreground?.application.map {
                    Origin(application: $0, location: event.location, timestamp: timestamp)
                }
            }
            return event
        }
    }

    /// 屏幕坐标与菜单栏范围属于输入来源适配，控制器只消费已验证的来源。
    @MainActor
    func consumeMenuClick() -> Origin? {
        guard ProcessPermissions.canListenToInput(), tap?.isEnabled == true else { stop(); return nil }
        let point = CGEvent(source: nil)?.location ?? .zero
        let frames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let frame = CGDisplayBounds(id)
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                          height: max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        let origin = consume(at: point, now: ProcessInfo.processInfo.systemUptime, menuBarFrames: frames)
        let history = lock.withLock {
            foregroundChanges.suffix(4).map { "\($0.application?.processIdentifier ?? 0)@\($0.timestamp)" }.joined(separator: ",")
        }
        // 仅在打开菜单时记录少量 PID 与时间，便于区分焦点变化和输入转发，不记录窗口内容。
        ArcKitLog.append("menu click source consumed origin=\(origin?.application.processIdentifier ?? 0) foregroundHistory=\(history)")
        return origin
    }

    /// 仅消费本次菜单栏点击；普通窗口点击、旧点击、指针移走均不能成为布局来源。
    func consume(at location: CGPoint, now: TimeInterval, menuBarFrames: [CGRect]) -> Origin? {
        lock.withLock {
            defer { latest = nil }
            return Self.match(latest, at: location, now: now, menuBarFrames: menuBarFrames)
        }
    }

    static func match(_ origin: Origin?, at location: CGPoint, now: TimeInterval,
                      menuBarFrames: [CGRect]) -> Origin? {
        guard let origin, now >= origin.timestamp, now - origin.timestamp <= 1,
              abs(origin.location.x - location.x) <= 4, abs(origin.location.y - location.y) <= 4,
              menuBarFrames.contains(where: { $0.contains(origin.location) }) else { return nil }
        return origin
    }
}
