import ArcKitFinder
import ArcKitPlatform
import Foundation

struct FinderNewFileCommandExecutor {
    let creationService: NewFileCreationService
    let opener: FinderApplicationOpener
    let newFileIconApplier: @Sendable (URL, ConfigurableNewFileTemplate) -> Bool

    init(
        creationService: NewFileCreationService = NewFileCreationService(),
        opener: FinderApplicationOpener = FinderApplicationOpener(),
        newFileIconApplier: @escaping @Sendable (URL, ConfigurableNewFileTemplate) -> Bool = {
            NewFileDocumentIconService().applyIcon(to: $0, template: $1)
        }
    ) {
        self.creationService = creationService
        self.opener = opener
        self.newFileIconApplier = newFileIconApplier
    }

    func execute(_ request: FinderCommandRequest, settings: FinderRuntimeSettings, targets: FinderCommandTargets) throws -> FinderCommandExecutionResult? {
        guard case let .createNewFile(payload) = request.payload else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.newFileNewFileExecutorReceivedUnexpectedCommand(String(describing: request.kind.rawValue))))
        }
        let templateID = payload.templateID
        let resolvedDirectory = try targets.resolveTargetDirectory(for: request, actionName: L10n.string(.FinderActions.pageNewFile))
        ArcKitLog.append("processor resolved target id=\(request.id.uuidString) kind=\(request.kind.rawValue) resolvedTargetPath=\(resolvedDirectory.path) resolutionSource=\(resolvedDirectory.source)")
        let result = try creationService.createFile(templateID: templateID, directoryPath: resolvedDirectory.path, settings: settings)
        let template = settings.menuConfiguration.fileTemplates.first { $0.id == templateID }
        if let template {
            _ = newFileIconApplier(result.fileURL, template)
        }
        if template?.openAfterCreate == true || settings.menuConfiguration.openNewFileAfterCreate {
            try opener.openURLs([result.fileURL], applicationURL: nil, label: L10n.string(.FinderActions.pageNewFile))
        }
        return FinderCommandExecutionResult(createdPaths: [result.fileURL.path])
    }
}
