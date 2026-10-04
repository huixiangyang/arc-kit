import Foundation

public struct WindowSceneClientError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
