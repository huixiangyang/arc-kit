import ArcKitPlatform
import SwiftUI

/// 保存回执放在窗口右上方工具栏，不遮挡 Tab 和设置内容。
struct SettingsSaveToast: View {
    @ObservedObject var model: SettingsModel
    @State private var event: SettingsPersistenceState?
    @State private var presented: SettingsPersistenceState?
    @State private var showsErrorDetails = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let presented {
                HStack(spacing: 8) {
                    ArcIcon(icon(for: presented), size: 14)
                        .foregroundStyle(color(for: presented))
                    if case let .failed(message) = presented {
                        // 长错误按需展开；不能为了展示原因把标题栏撑高或重新盖住表单。
                        Button(L10n.string(.App.saveSaveFailed)) { showsErrorDetails.toggle() }
                            .buttonStyle(.plain)
                            .help(L10n.string(.App.saveViewErrorDetails(String(describing: message))))
                            .accessibilityLabel(L10n.string(.App.saveSaveViewErrorDetailsFailed))
                            .popover(isPresented: $showsErrorDetails, arrowEdge: .bottom) {
                                ScrollView {
                                    Text(message)
                                        .font(.callout)
                                        .lineLimit(nil)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                }
                                .frame(width: 320, height: 160)
                            }
                    } else {
                        Text(title(for: presented))
                    }
                    if case .failed = presented {
                        Button(L10n.string(.Common.retry)) { model.flush() }
                            .buttonStyle(.borderless)
                    }
                    Button {
                        showsErrorDetails = false
                        self.presented = nil
                    } label: {
                        ArcIcon(.circleX, size: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.string(.App.saveDismissSaveMessage))
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .fixedSize(horizontal: true, vertical: false)
                .background(ArcPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(ArcPalette.panelBorder.opacity(0.5))
                }
                .accessibilityElement(children: .contain)
            }
        }
        // 空回执仍给原生 ToolbarItem 一个有效尺寸，避免零尺寸测量告警。
        .frame(minWidth: 1)
        .frame(height: 28)
        .onAppear {
            // 重开窗口不重复弹出旧的成功回执；未完成或失败的保存仍须可见。
            if case .saved = model.persistenceState { return }
            event = model.persistenceState
        }
        .onChange(of: model.persistenceState) {
            showsErrorDetails = false
            event = $0
        }
        .onDisappear {
            event = nil
            presented = nil
            showsErrorDetails = false
        }
        .task(id: event) {
            // 新改动取消旧的计时，连续调节滑块只更新同一个提示，不堆叠也不误关新提示。
            do {
                switch event {
                case .pending:
                    if presented == nil { try await Task.sleep(for: .milliseconds(600)) }
                    presented = .pending
                case let .saved(date?):
                    presented = .saved(date)
                    try await Task.sleep(for: .seconds(2))
                    presented = nil
                case let .failed(message):
                    presented = .failed(message)
                case .saved(nil), nil:
                    presented = nil
                }
            } catch {
                // task 取消只结束旧计时，不能清除后一次保存的回执。
            }
        }
    }

    private func title(for state: SettingsPersistenceState) -> String {
        switch state {
        case .pending: L10n.string(.App.saveSaving)
        case .saved: L10n.string(.Common.saved)
        case .failed: L10n.string(.App.saveSaveFailed)
        }
    }

    private func icon(for state: SettingsPersistenceState) -> ArcIconName {
        switch state {
        case .pending: .circleInfo
        case .saved: .checkCircle
        case .failed: .triangleAlert
        }
    }

    private func color(for state: SettingsPersistenceState) -> Color {
        switch state {
        case .pending: .secondary
        case .saved: ArcPalette.green
        case .failed: ArcPalette.red
        }
    }
}
