import Foundation
import Testing
@testable import ArcKitApplication

@Suite("输入法小工具")
@MainActor
struct InputSourceToolTests {
    @Test("会话状态与保留勾选独立，缺失和歧义不误报未启用，父项按模式汇总")
    func sessionState() throws {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        let sogou = InputSourcePreviewAccess.sogou, pinyin = InputSourcePreviewAccess.pinyin
        let inactive = access.available[2]
        access.available[2] = InputSourceDescriptor(id: inactive.id, bundleID: inactive.bundleID,
            modeID: inactive.modeID, name: inactive.name, enabled: false, selectable: true)
        model.refresh()
        #expect(model.sessionState(for: sogou) == .enabled)
        #expect(model.sessionState(for: pinyin) == .disabled)
        #expect(model.selectedIDs.contains(pinyin.selectionID))
        model.setKept(false, record: sogou)
        #expect(model.sessionState(for: sogou) == .enabled)
        access.available.removeLast(); model.refresh()
        #expect(model.sessionState(for: pinyin) == .unknown)
        let duplicate = access.available[0]
        access.available.append(InputSourceDescriptor(id: "another.registration", bundleID: duplicate.bundleID,
            modeID: duplicate.modeID, name: duplicate.name, enabled: true, selectable: true)); model.refresh()
        #expect(model.sessionState(for: sogou) == .unknown)

        let parent = InputSourceRecord(raw: ["InputSourceKind": "Keyboard Input Method", "Bundle ID": sogou.bundleID!])
        let otherMode = InputSourceRecord(raw: ["InputSourceKind": "Input Mode", "Bundle ID": sogou.bundleID!, "Input Mode": "sogou.english"])
        access.configuration = try InputSourceConfiguration(propertyList: [InputSourceConfiguration.enabledKey: [parent.raw, sogou.raw, otherMode.raw]])
        access.available = [InputSourcePreviewAccess().available[0]]
        model.refresh()
        #expect(model.rows == [parent] && model.sessionState(for: parent) == .enabled)
        #expect(access.writes == 0 && access.recovery == nil)
    }

    @Test("系统重复返回同一输入源时可精简并恢复，显示名称不重复")
    func duplicateRegistrations() throws {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        let sogou = access.available[0]
        access.available += [sogou, sogou] // 远端实测：同一搜狗模式返回三条相同记录。
        model.refresh(); choose([InputSourcePreviewAccess.sogou], on: model)
        #expect(model.canApply && model.sessionState(for: InputSourcePreviewAccess.sogou) == .enabled)
        #expect(model.name(for: InputSourcePreviewAccess.sogou) == sogou.name)
        #expect(model.sources.filter { $0 == sogou }.count == 1)
        model.apply()
        #expect(model.failure == nil && access.writes == 1 && access.recovery != nil)
        access.available = [sogou, sogou, sogou]; model.refresh()
        #expect(model.applied && model.activeNames == sogou.name)
        model.restore()
        #expect(model.restored && access.configuration == InputSourcePreviewAccess.initial && access.recovery == nil)
    }

    @Test("重复身份存在启用或可选择状态冲突时仍拒绝写入", arguments: [true, false])
    func conflictingRegistrations(enabledConflict: Bool) {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        let sogou = access.available[0]
        access.available.append(InputSourceDescriptor(id: sogou.id, bundleID: sogou.bundleID, modeID: sogou.modeID,
            name: sogou.name, enabled: !enabledConflict, selectable: enabledConflict))
        model.refresh(); choose([InputSourcePreviewAccess.sogou], on: model)
        #expect(!model.canApply && model.sessionState(for: InputSourcePreviewAccess.sogou) == .unknown)
        model.apply()
        #expect(access.writes == 0 && access.recovery == nil)
    }

    @Test("精简保留同一输入法的模式、父项和非键盘服务，模式 ID 不混用")
    func plan() throws {
        let target = InputSourcePreviewAccess.sogou
        let asciiMode = InputSourceRecord(raw: ["InputSourceKind": "Input Mode", "Bundle ID": target.bundleID!, "Input Mode": "sogou.english", "Extra": "preserve"])
        let parent = InputSourceRecord(raw: ["InputSourceKind": "Keyboard Input Method", "Bundle ID": target.bundleID!])
        var plist = InputSourcePreviewAccess.initial.propertyList
        plist[InputSourceConfiguration.enabledKey] = InputSourcePreviewAccess.initial.enabled.map(\.raw) + [parent.raw, asciiMode.raw]
        let original = try InputSourceConfiguration(propertyList: plist), desired = try original.keeping([target.selectionID], fallback: target)
        #expect(desired.enabled == [InputSourcePreviewAccess.character, target, parent, asciiMode])
        #expect(desired.values[InputSourceConfiguration.selectedKey] == [target])
        #expect(desired.values[InputSourceConfiguration.historyKey] == [target])
        #expect(target.matches(InputSourcePreviewAccess().available[0]))
        let sources = InputSourcePreviewAccess().available
        #expect(!sources[0].requiringEnabledParent(in: []).enabled)
        #expect(sources[0].requiringEnabledParent(in: [target.bundleID!]).enabled)
        #expect(sources[1].requiringEnabledParent(in: []).enabled) // 独立键盘布局没有父输入法。
        #expect(!sources[2].requiringEnabledParent(in: [target.bundleID!]).enabled)
        let abc = InputSourcePreviewAccess.abc
        let both = try original.keeping([target.selectionID, abc.selectionID], fallback: abc)
        #expect(both.enabled == [InputSourcePreviewAccess.character, abc, target, parent, asciiMode])
        #expect(both.values[InputSourceConfiguration.historyKey] == [abc, target])
        #expect(abc.matches(sources[1]))
        #expect(throws: InputSourceToolError.self) { try original.keeping([], fallback: abc) }
        #expect(throws: InputSourceToolError.self) {
            try InputSourceConfiguration(propertyList: [InputSourceConfiguration.enabledKey: [["InputSourceKind": "future-kind"]]])
        }
    }

    @Test("写入与会话生效分开，恢复点可跨模型恢复且不重复精简")
    func lifecycle() throws {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        model.refresh()
        #expect(!model.canApply && model.selectedIDs == Set(model.rows.map(\.selectionID)))
        model.setKept(false, record: InputSourcePreviewAccess.pinyin)
        model.refresh() // 普通刷新保留用户草稿，不重新替用户选择。
        #expect(model.canApply && model.selectedIDs == [InputSourcePreviewAccess.abc.selectionID, InputSourcePreviewAccess.sogou.selectionID])
        model.apply()
        #expect(model.failure == nil && model.configurationMatchesRecovery && !model.applied)
        #expect(access.writes == 1 && access.recovery != nil && !model.canApply)
        access.available = Array(access.available.prefix(2))
        let reopened = InputSourceToolModel(access: access); reopened.refresh()
        #expect(reopened.applied)
        reopened.restore()
        #expect(reopened.failure == nil && reopened.restored && access.recovery == nil)
        #expect(access.configuration == InputSourcePreviewAccess.initial && access.writes == 2)
        choose([InputSourcePreviewAccess.abc], on: reopened)
        #expect(reopened.canApply) // 允许只保留英文键盘，不强制保留任何中文输入法。
        reopened.apply()
        #expect(reopened.configuration?.keyboards == [InputSourcePreviewAccess.abc])
        #expect(reopened.configuration?.values[InputSourceConfiguration.selectedKey] == [InputSourcePreviewAccess.abc])
    }

    @Test("失效目标、展示后配置变化与备份失败均不写系统")
    func preconditions() throws {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        model.refresh(); choose([], on: model); model.apply()
        #expect(access.writes == 0 && model.failure != nil)
        choose([InputSourcePreviewAccess.sogou], on: model); access.available = []; model.apply()
        #expect(access.writes == 0 && access.recovery == nil && model.failure != nil)
        access.available = InputSourcePreviewAccess().available; model.refresh()
        access.configuration = try access.configuration.keeping([InputSourcePreviewAccess.pinyin.selectionID], fallback: InputSourcePreviewAccess.pinyin)
        model.apply(); #expect(access.writes == 0 && access.recovery == nil && model.failure != nil)
        access.configuration = InputSourcePreviewAccess.initial; model.refresh(); choose([InputSourcePreviewAccess.pinyin], on: model); access.failBackup = true
        model.apply(); #expect(access.writes == 0 && access.recovery == nil && model.failure != nil)
    }

    @Test("部分写入失败回滚，回滚失败保留恢复点供重启后处理")
    func failures() {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        access.failWrites = [1]; model.refresh(); choose([InputSourcePreviewAccess.sogou], on: model); model.apply()
        #expect(access.writes == 2 && access.configuration == InputSourcePreviewAccess.initial && access.recovery == nil)
        #expect(model.failure != nil)
        access.failWrites = [3, 4]; model.refresh(); choose([InputSourcePreviewAccess.sogou], on: model); model.apply()
        #expect(access.recovery != nil && model.failure != nil)
        let reopened = InputSourceToolModel(access: access); reopened.refresh(); reopened.restore()
        #expect(reopened.failure == nil && reopened.restored && access.recovery == nil)
    }

    @Test("恢复不覆盖外部新增输入源，放弃旧恢复点不修改系统")
    func externalChange() throws {
        let access = FixtureAccess(), model = InputSourceToolModel(access: access)
        model.refresh(); choose([InputSourcePreviewAccess.sogou], on: model); model.apply()
        var plist = access.configuration.propertyList
        plist[InputSourceConfiguration.enabledKey] = access.configuration.enabled.map(\.raw) + [InputSourcePreviewAccess.abc.raw]
        access.configuration = try InputSourceConfiguration(propertyList: plist)
        let external = access.configuration
        model.refresh(); #expect(!model.canRestore); model.restore()
        #expect(model.failure != nil && access.writes == 1 && access.recovery != nil && access.configuration == external)
        model.discardRecovery()
        #expect(access.writes == 1 && access.recovery == nil && access.configuration == external)
    }

    @Test("恢复点原子保存与重读，只访问临时目录、不调用真实输入源读写")
    func recoveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("recovery.plist")
        let access = NativeInputSourceAccess(recoveryURL: file)
        let before = InputSourcePreviewAccess.initial
        let after = try before.keeping([InputSourcePreviewAccess.sogou.selectionID], fallback: InputSourcePreviewAccess.sogou)
        try access.saveRecovery(InputSourceRecovery(before: before, after: after))
        let reopened = NativeInputSourceAccess(recoveryURL: file)
        let receipt = try #require(try reopened.loadRecovery())
        #expect(try receipt.configuration(before: true) == before)
        #expect(try receipt.configuration(before: false) == after)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try reopened.clearRecovery(); #expect(try reopened.loadRecovery() == nil)
        #expect(ApplicationFeatureCatalog.primary.contains { $0.section == .tools })
        #expect(ArcKitQuickCommandCatalog.results(for: "Sogou").contains { $0.action == .section(.tools) })
    }

    @Test("原生偏好读写使用独立临时域，恢复缺省字段且不覆盖其他偏好")
    func nativePreferences() throws {
        let domain = "com.archalo.arckit.tests.input-sources.\(UUID().uuidString)"
        let cfDomain = domain as CFString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let access = NativeInputSourceAccess(recoveryURL: directory.appendingPathComponent("recovery.plist"), preferenceDomain: domain)
        defer {
            // 只清理本测试随机域，不调用真实 HIToolbox 或 TIS 写入。
            for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
                for key in InputSourceConfiguration.keys + ["Untouched"] {
                    CFPreferencesSetValue(key as CFString, nil, cfDomain, kCFPreferencesCurrentUser, host)
                }
                CFPreferencesSynchronize(cfDomain, kCFPreferencesCurrentUser, host)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        CFPreferencesSetValue("Untouched" as CFString, "preserved" as CFString, cfDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let original = InputSourcePreviewAccess.initial
        try access.write(original)
        #expect(try access.read() == original)
        let target = InputSourcePreviewAccess.abc
        let desired = try original.keeping([target.selectionID], fallback: target)
        try access.saveRecovery(InputSourceRecovery(before: original, after: desired))
        try access.write(desired)
        let reopened = NativeInputSourceAccess(recoveryURL: directory.appendingPathComponent("recovery.plist"), preferenceDomain: domain)
        #expect(try reopened.read() == desired)
        let receipt = try #require(try reopened.loadRecovery())
        try reopened.write(receipt.configuration(before: true))
        #expect(try access.read() == original)
        let absentHistory = try InputSourceConfiguration(propertyList: [InputSourceConfiguration.enabledKey: original.enabled.map(\.raw)])
        try access.write(absentHistory)
        #expect(try reopened.read() == absentHistory)
        #expect(CFPreferencesCopyValue("Untouched" as CFString, cfDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String == "preserved")
        CFPreferencesSetValue(InputSourceConfiguration.enabledKey as CFString, desired.propertyList[InputSourceConfiguration.enabledKey] as CFPropertyList?, cfDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(cfDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        #expect(throws: InputSourceToolError.self) { try access.read() }
        try access.clearRecovery()
    }
    private func choose(_ records: [InputSourceRecord], on model: InputSourceToolModel) {
        let ids = Set(records.map(\.selectionID))
        for row in model.rows { model.setKept(ids.contains(row.selectionID), record: row) }
    }

}

@MainActor
private final class FixtureAccess: InputSourcePreviewAccess {
    var writes = 0
    var failWrites = Set<Int>()
    var failBackup = false
    override func write(_ configuration: InputSourceConfiguration) throws {
        writes += 1
        self.configuration = configuration // 模拟同步报错前已经发生写入。
        if failWrites.contains(writes) { throw InputSourceToolError.writeFailed }
    }
    override func saveRecovery(_ recovery: InputSourceRecovery) throws {
        if failBackup { throw CocoaError(.fileWriteNoPermission) }
        try super.saveRecovery(recovery)
    }
}
