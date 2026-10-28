import ArcKitPlatform
import AppKit
import ApplicationServices

/// 发现始终只读。交互界面在后台读取 AX，原生引用仅在快照交付后移交主线程动作会话。
@MainActor
final class MenuBarInspector {
    private struct ProcessDescriptor: Sendable {
        let id: Int32
        let launchDate: Date?
        let bundle: String?
        let name: String
    }
    // AX 引用在发现期间只由一个任务访问；交付完成后才允许主线程使用，不并发读写。
    private struct Discovery: @unchecked Sendable {
        var items: [MenuBarObservedItem] = []
        var references: [UUID: AXUIElement] = [:]
        var issues: [MenuBarInspectionIssue] = []
    }
    private struct Context: Sendable {
        let id = UUID()
        let date = Date()
        let displays: [MenuBarDisplay]
        let displayIssues: [MenuBarInspectionIssue]
        let trusted: Bool
        let processes: [ProcessDescriptor]
    }

    func capture() -> MenuBarInventory {
        let context = prepare()
        return finish(context, discovery: Self.discover(context, cancelled: { false }), session: nil)
    }

    func captureForInteraction(session: MenuBarItemAccessSession? = nil, processIDs: Set<Int32>? = nil) async throws -> MenuBarInventory {
        session?.invalidate()
        let context = prepare(processIDs: processIDs)
        let task = Task.detached(priority: .userInitiated) {
            Self.discover(context, cancelled: { Task.isCancelled })
        }
        let discovery = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return finish(context, discovery: discovery, session: session)
    }

    private func prepare(processIDs: Set<Int32>? = nil) -> Context {
        let screens = MenuBarScreenSnapshot.capture()
        let displays = screens?.displays ?? []
        let issues: [MenuBarInspectionIssue] = screens == nil ? [.init(kind: .displayChanged, processID: nil, attribute: nil, errorCode: nil)] : []
        let trusted = AXIsProcessTrusted()
        let processes: [ProcessDescriptor] = trusted ? NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && (processIDs?.contains($0.processIdentifier) ?? true)
        }.map {
            .init(id: $0.processIdentifier, launchDate: $0.launchDate, bundle: $0.bundleIdentifier,
                  name: $0.localizedName ?? $0.bundleIdentifier ?? String($0.processIdentifier))
        } : []
        return Context(displays: displays, displayIssues: issues, trusted: trusted, processes: processes)
    }

    private func finish(_ context: Context, discovery: Discovery, session: MenuBarItemAccessSession?) -> MenuBarInventory {
        var items = discovery.items
        var issues = context.displayIssues + discovery.issues
        if !context.trusted { issues.append(.init(kind: .permissionDenied, processID: nil, attribute: nil, errorCode: nil)) }
        let screens = MenuBarScreenSnapshot.capture()
        let displays = screens?.displays ?? []
        if screens == nil || displays != context.displays {
            issues.append(.init(kind: .displayChanged, processID: nil, attribute: nil, errorCode: nil))
        }
        MenuBarItemKey.assignUniqueCandidates(to: &items)
        if context.trusted && !issues.contains(where: { $0.kind == .displayChanged }) {
            session?.begin(id: context.id, displays: displays)
            for item in items {
                if let element = discovery.references[item.id] { session?.add(.native(item: item, element: element)) }
            }
        } else { session?.invalidate() }
        return .init(id: context.id, capturedAt: context.date, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibility: context.trusted ? .granted : .denied, displays: context.displays, items: items, issues: issues)
    }

    nonisolated private static func discover(_ context: Context, cancelled: @Sendable () -> Bool) -> Discovery {
        var result = Discovery()
        for process in context.processes {
            if cancelled() { break }
            let root = AXUIElementCreateApplication(process.id)
            let menu = read(root, kAXExtrasMenuBarAttribute)
            if menu.error == .attributeUnsupported || menu.error == .noValue { continue }
            guard menu.error == .success, let value = menu.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                result.issues.append(.init(kind: .attributeFailed, processID: process.id,
                    attribute: kAXExtrasMenuBarAttribute, errorCode: menu.error.rawValue))
                continue
            }
            var budget = 256
            let issueStart = result.issues.count
            let itemStart = result.items.count
            inspect(value as! AXUIElement, process: process, displays: context.displays, depth: 0,
                budget: &budget, result: &result, cancelled: cancelled)
            if result.issues.count != issueStart {
                for index in itemStart..<result.items.count { result.items[index].identityEligible = false }
            }
        }
        return result
    }

    nonisolated private static func inspect(_ element: AXUIElement, process: ProcessDescriptor, displays: [MenuBarDisplay],
        depth: Int, budget: inout Int, result: inout Discovery, cancelled: @Sendable () -> Bool) {
        if cancelled() { return }
        guard budget > 0, depth <= 6 else {
            result.issues.append(.init(kind: .traversalLimit, processID: process.id, attribute: nil, errorCode: nil)); return
        }
        budget -= 1
        let role = read(element, kAXRoleAttribute)
        guard role.error == .success, let name = role.value as? String else {
            result.issues.append(.init(kind: .attributeFailed, processID: process.id,
                attribute: kAXRoleAttribute, errorCode: role.error.rawValue)); return
        }
        if name == kAXMenuBarItemRole {
            var actions: CFArray?
            let actionError = AXUIElementCopyActionNames(element, &actions)
            if actionError != .success {
                result.issues.append(.init(kind: .attributeFailed, processID: process.id, attribute: "AXActions", errorCode: actionError.rawValue))
            }
            let names = actions as? [String] ?? []
            var settable: DarwinBoolean = false
            let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable)
            let rect = frame(element)
            let item = MenuBarObservedItem(id: UUID(), processID: process.id, processLaunchDate: process.launchDate,
                bundleIdentifier: process.bundle, applicationName: process.name,
                accessibilityIdentifier: read(element, kAXIdentifierAttribute).value as? String,
                frame: rect, displayID: rect.flatMap { MenuBarDisplay.containing($0, in: displays) },
                declaresPress: names.contains(kAXPressAction), declaresShowMenu: names.contains(kAXShowMenuAction),
                positionSettable: positionError == .success && settable.boolValue,
                label: (read(element, kAXDescriptionAttribute).value as? String).map { String($0.prefix(160)) })
            result.items.append(item)
            result.references[item.id] = element
            return // 不遍历展开后的菜单，避免读取消息、路径等无关内容。
        }
        guard name == kAXMenuBarRole || name == kAXGroupRole else { return }
        let children = read(element, kAXChildrenAttribute)
        guard children.error == .success, let values = children.value as? [AXUIElement] else {
            result.issues.append(.init(kind: .attributeFailed, processID: process.id,
                attribute: kAXChildrenAttribute, errorCode: children.error.rawValue)); return
        }
        for (index, child) in values.enumerated() {
            if cancelled() { break }
            inspect(child, process: process, displays: displays, depth: depth + 1, budget: &budget, result: &result, cancelled: cancelled)
            if budget == 0, index < values.count - 1 {
                result.issues.append(.init(kind: .traversalLimit, processID: process.id, attribute: kAXChildrenAttribute, errorCode: nil)); break
            }
        }
    }

    nonisolated private static func read(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value, error)
    }

    #if DEBUG
    /// 只记录本测试进程自有状态项的可见性属性，不读取第三方菜单内容。
    func nativeCheckAttributes() async -> [[String: Any]] {
        let context = prepare(processIDs: [ProcessInfo.processInfo.processIdentifier])
        let discovery = await Task.detached { Self.discover(context, cancelled: { Task.isCancelled }) }.value
        return discovery.items.compactMap { item in
            guard let element = discovery.references[item.id] else { return nil }
            var attributes: CFArray?
            AXUIElementCopyAttributeNames(element, &attributes)
            let hidden = Self.read(element, kAXHiddenAttribute)
            return ["label": item.label ?? "", "identifier": item.accessibilityIdentifier ?? "",
                    "attributes": attributes as? [String] ?? [], "hiddenError": hidden.error.rawValue,
                    "hidden": hidden.value as? Bool ?? NSNull()]
        }
    }
    #endif

    nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute).value, let size = read(element, kAXSizeAttribute).value,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              [point.x, point.y, extent.width, extent.height].allSatisfy(\.isFinite), extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

}
