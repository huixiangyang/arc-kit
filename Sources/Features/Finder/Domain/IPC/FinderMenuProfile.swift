import ArcKitPlatform
import Foundation

public struct FinderMenuProfile: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var modules: [FinderMenuModuleConfiguration]
    public var defaultTerminal: TerminalApp
    public var openNewFileAfterCreate: Bool
    public var highRiskActionsEnabled: Bool
    public var additionalObservedDirectoryPaths: [String]

    public init(
        isEnabled: Bool = true,
        modules: [FinderMenuModuleConfiguration] = FinderMenuConfiguration.defaultModules,
        defaultTerminal: TerminalApp = .terminal,
        openNewFileAfterCreate: Bool = false,
        highRiskActionsEnabled: Bool = false,
        additionalObservedDirectoryPaths: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.modules = modules
        self.defaultTerminal = defaultTerminal
        self.openNewFileAfterCreate = openNewFileAfterCreate
        self.highRiskActionsEnabled = highRiskActionsEnabled
        self.additionalObservedDirectoryPaths = additionalObservedDirectoryPaths
    }

    public init(
        configuration: FinderMenuConfiguration,
        defaultTerminal: TerminalApp = .terminal
    ) {
        self.init(
            isEnabled: configuration.isEnabled,
            modules: configuration.modules,
            defaultTerminal: defaultTerminal,
            openNewFileAfterCreate: configuration.openNewFileAfterCreate,
            highRiskActionsEnabled: configuration.highRiskActionsEnabled,
            additionalObservedDirectoryPaths: configuration.additionalObservedDirectoryPaths
        )
    }

    public init(settings: FinderRuntimeSettings) {
        self.init(
            configuration: settings.menuConfiguration,
            defaultTerminal: settings.defaultTerminal
        )
    }
}

public struct FinderTemplateSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var template: ConfigurableNewFileTemplate
    public var isVisible: Bool
    public var disabledReason: String?

    public var id: String { template.id }

    public init(template: ConfigurableNewFileTemplate, isVisible: Bool, disabledReason: String? = nil) {
        self.template = template
        self.isVisible = isVisible
        self.disabledReason = disabledReason
    }
}

public struct FinderFavoriteDirectorySnapshot: Codable, Equatable, Sendable, Identifiable {
    public var favorite: FavoriteDirectory
    public var isVisible: Bool
    public var disabledReason: String?
    public var children: [FinderMenuDirectoryChild]

    public var id: UUID { favorite.id }

    public init(
        favorite: FavoriteDirectory,
        isVisible: Bool,
        disabledReason: String? = nil,
        children: [FinderMenuDirectoryChild] = []
    ) {
        self.favorite = favorite
        self.isVisible = isVisible
        self.disabledReason = disabledReason
        self.children = children
    }
}

public struct FinderFavoriteApplicationSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var application: FavoriteApplication
    public var isVisible: Bool
    public var disabledReason: String?

    public var id: UUID { application.id }

    public init(application: FavoriteApplication, isVisible: Bool, disabledReason: String? = nil) {
        self.application = application
        self.isVisible = isVisible
        self.disabledReason = disabledReason
    }
}
