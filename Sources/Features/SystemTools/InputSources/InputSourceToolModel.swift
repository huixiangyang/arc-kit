import ArcKitPlatform
import Foundation

@MainActor
final class InputSourceToolModel: ObservableObject {
    @Published private(set) var configuration: InputSourceConfiguration?
    @Published private(set) var sources: [InputSourceDescriptor] = []
    @Published private(set) var recovery: InputSourceRecovery?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var failure: String?
    @Published private(set) var restored = false
    private let access: any InputSourceAccess

    init(access: any InputSourceAccess) { self.access = access }
    var rows: [InputSourceRecord] {
        var seen = Set<String>()
        return (configuration?.keyboards ?? []).filter { seen.insert($0.selectionID).inserted }
    }
    var removed: [InputSourceRecord] { rows.filter { !selectedIDs.contains($0.selectionID) } }
    var hasUsableSelection: Bool { usableRetainedSource(in: sources) != nil }
    var canApply: Bool { configuration != nil && hasUsableSelection && !removed.isEmpty && recovery == nil }
    var activeNames: String { sources.filter { $0.enabled && $0.selectable }.map(\.name).joined(separator: "、") }
    var applied: Bool {
        guard configurationMatchesRecovery, let current = configuration else { return false }
        let active = sources.filter { $0.enabled && $0.selectable }
        let mapped = active.compactMap { source in current.keyboards.first { $0.matches(source) }?.selectionID }
        return !active.isEmpty && mapped.count == active.count && Set(mapped) == Set(current.keyboards.map(\.selectionID))
    }
    func setKept(_ keep: Bool, record: InputSourceRecord) {
        guard recovery == nil, rows.contains(record) else { return }
        if keep { selectedIDs.insert(record.selectionID) }
        else { selectedIDs.remove(record.selectionID) }
        restored = false; failure = nil
    }
    private func usableRetainedSource(in inventory: [InputSourceDescriptor]) -> InputSourceRecord? {
        configuration?.keyboards.first { record in
            guard selectedIDs.contains(record.selectionID) else { return false }
            let matches = inventory.filter { record.matches($0) && $0.selectable }
            return matches.count == 1 && matches[0].enabled
        }
    }
    var configurationMatchesRecovery: Bool {
        guard let recovery, let expected = try? recovery.configuration(before: false) else { return false }
        return configuration?.enabled == expected.enabled
    }
    var canRestore: Bool {
        guard let recovery, let before = try? recovery.configuration(before: true), let after = try? recovery.configuration(before: false) else { return false }
        return configuration?.enabled == before.enabled || configuration?.enabled == after.enabled
    }
    func descriptor(for record: InputSourceRecord) -> InputSourceDescriptor? {
        let matches = sources.filter { record.matches($0) && $0.selectable }
        return matches.count == 1 ? matches[0] : nil
    }
    func name(for record: InputSourceRecord) -> String {
        let names = (configuration?.keyboards ?? []).filter { $0.selectionID == record.selectionID }
            .compactMap { descriptor(for: $0)?.name }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? (record.raw["KeyboardLayout Name"] as? String) ?? record.modeID ?? record.bundleID ?? record.kind : unique.joined(separator: "、")
    }

    func refresh() {
        do {
            let current = try access.read(), recovery = try access.loadRecovery()
            // 首次进入或系统清单变化时保持全部现有项；普通刷新不丢掉用户尚未应用的勾选。
            if configuration?.enabled != current.enabled || recovery != nil {
                selectedIDs = Set(current.keyboards.map(\.selectionID))
            }
            configuration = current; sources = access.inventory(); self.recovery = recovery; failure = nil
        } catch { configuration = nil; failure = error.localizedDescription }
    }

    func apply() {
        do {
            guard let shown = configuration, canApply else { throw InputSourceToolError.targetUnavailable }
            let current = try access.read()
            guard current == shown, try access.loadRecovery() == nil else { throw InputSourceToolError.changed }
            guard let fallback = usableRetainedSource(in: access.inventory()) else { throw InputSourceToolError.targetUnavailable }
            let desired = try current.keeping(selectedIDs, fallback: fallback)
            let receipt = try InputSourceRecovery(before: current, after: desired)
            try access.saveRecovery(receipt)
            do {
                try access.write(desired)
                guard try access.read() == desired else { throw InputSourceToolError.writeFailed }
            } catch {
                // 同步失败也可能已有部分字段写入；仅在字段仍是本次前/后值时回滚。
                do {
                    let latest = try access.read()
                    guard InputSourceConfiguration.keys.allSatisfy({ latest.values[$0] == current.values[$0] || latest.values[$0] == desired.values[$0] }) else { throw InputSourceToolError.changed }
                    try access.write(current)
                    guard try access.read() == current else { throw InputSourceToolError.writeFailed }
                    try access.clearRecovery()
                } catch { throw InputSourceToolError.recoveryRequired }
                throw InputSourceToolError.rolledBack
            }
            restored = false; refresh()
        } catch {
            let message = error.localizedDescription
            refresh(); failure = message
        }
    }

    func discardRecovery() {
        do { try access.clearRecovery(); refresh(); restored = false }
        catch { failure = error.localizedDescription }
    }

    func restore() {
        do {
            guard let receipt = try access.loadRecovery() else { throw InputSourceToolError.invalidRecovery }
            let before = try receipt.configuration(before: true), after = try receipt.configuration(before: false)
            let current = try access.read()
            // 允许恢复中断写入，但不覆盖用户后来添加、删除或重新排列的输入源。
            guard current.enabled == after.enabled || current.enabled == before.enabled else { throw InputSourceToolError.changed }
            try access.write(before)
            guard try access.read() == before else { throw InputSourceToolError.recoveryRequired }
            try access.clearRecovery()
            refresh(); restored = true
        } catch {
            let message = error.localizedDescription
            refresh(); failure = message
        }
    }
}
