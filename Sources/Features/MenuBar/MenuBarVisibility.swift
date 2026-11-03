import AppKit
import ArcKitPlatform
import Darwin

/// 直接修改系统的“允许在菜单栏显示”；不制造溢出，也不启用考试模式。
/// 每次写入合并最新注册表，仅处理身份明确、所有图标均属于同一应用的条目。
struct MenuBarVisibilityStore {
    private let domain: CFString
    private let inputMenu: MenuBarInputMenu

    init(domain: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter").path,
         inputMenu: MenuBarInputMenu = .init()) {
        self.domain = domain as CFString; self.inputMenu = inputMenu
    }
    private let key = "trackedApplications" as CFString

    func read() throws -> [Any] {
        guard CFPreferencesAppSynchronize(domain), let data = CFPreferencesCopyAppValue(key, domain) as? Data,
              let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any], rows.count.isMultiple(of: 2) else {
            throw MenuBarVisibilityError.unavailable
        }
        return rows
    }

    static func index(of bundle: String, in rows: [Any]) throws -> Int {
        let location = ["bundle": ["_0": bundle]] as NSDictionary
        let matches = stride(from: 0, to: rows.count, by: 2).filter { (rows[$0] as? NSDictionary) == location }
        guard matches.count == 1, let index = matches.first,
              let row = rows[index + 1] as? [String: Any], (row["location"] as? NSDictionary) == location,
              let locations = row["menuItemLocations"] as? [NSDictionary], !locations.isEmpty,
              locations.allSatisfy({ $0 == location }), row["isAllowed"] is Bool else {
            throw MenuBarVisibilityError.identity(bundle)
        }
        return index
    }

    static func allowed(_ bundle: String, in rows: [Any]) throws -> Bool {
        let index = try index(of: bundle, in: rows)
        return (rows[index + 1] as! [String: Any])["isAllowed"] as! Bool
    }

    func snapshot(_ bundles: Set<String>) throws -> [String: Bool] {
        let applications = bundles.subtracting([MenuBarInputMenu.bundleIdentifier])
        let rows = applications.isEmpty ? [] : try read()
        var values = try Dictionary(uniqueKeysWithValues: applications.map { ($0, try Self.allowed($0, in: rows)) })
        if bundles.contains(MenuBarInputMenu.bundleIdentifier) {
            values[MenuBarInputMenu.bundleIdentifier] = try inputMenu.isVisible()
        }
        return values
    }

    func set(_ updates: [String: Bool]) throws {
        guard !updates.isEmpty else { return }
        let applications = updates.filter { $0.key != MenuBarInputMenu.bundleIdentifier }
        if !applications.isEmpty {
            var rows = try read()
            for (bundle, value) in applications {
                let index = try Self.index(of: bundle, in: rows)
                var row = rows[index + 1] as! [String: Any]
                row["isAllowed"] = value; rows[index + 1] = row
            }
            let data = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
            CFPreferencesSetAppValue(key, data as CFData, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw MenuBarVisibilityError.unavailable }
        }
        if let visible = updates[MenuBarInputMenu.bundleIdentifier] { try inputMenu.setVisible(visible) }
        guard try snapshot(Set(updates.keys)) == updates else { throw MenuBarVisibilityError.unconfirmed }
    }

}

enum MenuBarVisibilityError: Error, LocalizedError {
    case unavailable, unconfirmed, guardian, inputMenuUnavailable, emptyCollection, identity(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.string(.MenuBar.visibilityUnavailable)
        case .unconfirmed: L10n.string(.MenuBar.visibilityUnconfirmed)
        case .guardian: L10n.string(.MenuBar.visibilityGuardian)
        case .emptyCollection: L10n.string(.MenuBar.collectionEmpty)
        case .inputMenuUnavailable: L10n.string(.MenuBar.inputMenuUnavailable)
        case let .identity(bundle): L10n.string(.MenuBar.visibilityIdentity(bundle))
        }
    }
}

/// 先落盘恢复清单，再隐藏；主进程退出时独立守护进程恢复，重启时也会补偿未完成事务。
struct MenuBarVisibilityRecovery {
    struct Journal: Codable { let token: UUID; var bundles: Set<String> }
    let file: URL
    init(file: URL = ArcKitStoragePaths.current.runtime.appendingPathComponent("menu-bar-visibility.json")) { self.file = file }
    func read() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try ArcKitStoragePaths.validateFile(file)
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
    }
    func write(_ journal: Journal) throws { try ArcKitAtomicFile.writeAtomically(JSONEncoder().encode(journal), to: file) }
    func locked<T>(_ operation: () throws -> T) throws -> T {
        guard let lock = ArcKitProcessLock.acquire(for: .worker, lockPath: file.deletingPathExtension().appendingPathExtension("lock").path) else {
            throw MenuBarVisibilityError.unavailable
        }
        defer { lock.release() }
        return try operation()
    }
    func restore(token: UUID? = nil, visibility: MenuBarVisibilityStore = .init()) throws {
        try locked {
            guard let journal = try read(), token == nil || token == journal.token else { return }
            var remaining = journal.bundles
            var failure: Error?
            // 一个应用卸载或身份改变不能阻止其他应用恢复；未恢复项保留在清单内。
            for bundle in journal.bundles {
                do {
                    if try visibility.snapshot([bundle])[bundle] == false { try visibility.set([bundle: true]) }
                    remaining.remove(bundle)
                } catch { failure = error }
            }
            if remaining.isEmpty { try FileManager.default.removeItem(at: file) }
            else { try write(.init(token: journal.token, bundles: remaining)) }
            if let failure { throw failure }
        }
    }
}

@MainActor
final class MenuBarVisibilitySession {
    nonisolated static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.ControlCenter", "com.apple.systemuiserver"]
    private let token = UUID()
    private let recovery = MenuBarVisibilityRecovery()
    private var guardian: Process?

    static func hiddenBundles(collectedApplications: Set<String>, owner: String, running: Set<String>) -> Set<String> {
        collectedApplications.intersection(running).subtracting(systemOwners).subtracting([owner])
    }

    func conceal(collectedApplications: Set<String>, owner: String) throws {
        guard !collectedApplications.isEmpty else { throw MenuBarVisibilityError.emptyCollection }
        let targets = Self.hiddenBundles(collectedApplications: collectedApplications, owner: owner,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
        // 再次收起先恢复本次持有的允许状态，保留用户原本就关闭的项目。
        try recovery.restore(token: token)
        guard !targets.isEmpty else { return }
        try startGuardian()
        try recovery.locked {
            guard try recovery.read() == nil else { throw MenuBarVisibilityError.unconfirmed }
            let registry = MenuBarVisibilityStore()
            let before = try registry.snapshot(targets)
            let changed = Set(before.filter(\.value).keys)
            guard !changed.isEmpty else { return }
            try recovery.write(.init(token: token, bundles: changed))
            try registry.set(Dictionary(uniqueKeysWithValues: changed.map { ($0, false) }))
        }
    }

    func reveal(recoverOrphans: Bool = false) throws { try recovery.restore(token: recoverOrphans ? nil : token) }

    private func startGuardian() throws {
        if guardian?.isRunning == true { return }
        guard let executable = Bundle.main.executableURL else { throw MenuBarVisibilityError.guardian }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = [MenuBarVisibilityGuardian.argument, String(getpid()), token.uuidString]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // 守护进程确认已登记父进程退出事件后，主进程才允许写系统偏好。
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 3000) > 0,
              pipe.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8), process.isRunning else {
            if process.isRunning { process.terminate() }
            throw MenuBarVisibilityError.guardian
        }
        try? pipe.fileHandleForReading.close()
        guardian = process
    }
}

/// 正式运行的恢复子进程，不创建 AppKit 窗口、状态项或数据库连接。
public enum MenuBarVisibilityGuardian {
    public static let argument = "--menu-bar-visibility-guardian"
    public static func handle(arguments: [String]) -> Int32? {
        guard arguments.contains(argument) else { return nil }
        guard arguments.count == 4, arguments[1] == argument, let parent = Int32(arguments[2]),
              parent > 1, parent == getppid(), let token = UUID(uuidString: arguments[3]) else { return 2 }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setRegistrationHandler { FileHandle.standardOutput.write(Data("ready".utf8)) }
        source.setEventHandler {
            do { try MenuBarVisibilityRecovery().restore(token: token); Darwin.exit(0) }
            catch { ArcKitLog.append("menu-bar visibility recovery failed: \(error.localizedDescription)"); Darwin.exit(1) }
        }
        source.resume()
        withExtendedLifetime(source) { dispatchMain() }
    }
}
