import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import Foundation

/// 支持报告只在用户主动选择的位置写出；状态用于偏好页就地展示进度、成功和可恢复失败。
@MainActor
public final class SupportDiagnosticsService: ObservableObject {
    enum ExportState: Equatable {
        case idle
        case working
        case succeeded(fileName: String)
        case failed(message: String)
    }

    typealias ReportWriter = @Sendable (SupportDiagnosticReport, URL) throws -> Void
    typealias FileExists = (URL) -> Bool
    typealias FileRevealer = (URL) -> Void

    @Published private(set) var exportState: ExportState = .idle

    private let reportWriter: ReportWriter
    private let fileExists: FileExists
    private let fileRevealer: FileRevealer
    private var exportedFileURL: URL?

    init(
        reportWriter: @escaping ReportWriter = { report, url in
            try SupportDiagnosticPackage.save(report, to: url)
        },
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0.path) },
        fileRevealer: @escaping FileRevealer = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.reportWriter = reportWriter
        self.fileExists = fileExists
        self.fileRevealer = fileRevealer
    }

    func export(_ report: SupportDiagnosticReport, to url: URL) {
        if case .working = exportState { return }
        exportState = .working
        exportedFileURL = nil
        let writer = reportWriter
        let fileName = url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try writer(report, url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.exportedFileURL = url
                    self.exportState = .succeeded(fileName: fileName)
                case let .failure(error):
                    self.exportedFileURL = nil
                    self.exportState = .failed(
                        message: L10n.string(.Diagnostics.exportFailed(String(describing: error.localizedDescription)))
                    )
                }
            }
        }
    }

    func revealExportedReport() {
        guard case .succeeded = exportState,
              let exportedFileURL
        else { return }
        guard fileExists(exportedFileURL) else {
            self.exportedFileURL = nil
            exportState = .failed(message: L10n.string(.Diagnostics.exportDiagnosticReportMoved))
            return
        }
        fileRevealer(exportedFileURL)
    }

    func clearFeedback() {
        guard case .working = exportState else {
            exportState = .idle
            return
        }
    }
}
