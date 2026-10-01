import Foundation
import Security
import XPC

public enum ArcKitXPCPeerIdentityError: LocalizedError, Equatable, Sendable {
    case malformedMessage
    case identityUnavailable(String)
    case identityMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:
            L10n.string(.Platform.identityInvalidXpcMessageFormat)
        case let .identityUnavailable(message):
            L10n.string(.Platform.identityVerificationFailed(String(describing: message)))
        case let .identityMismatch(message):
            L10n.string(.Platform.identityComponentIdentityMismatch(String(describing: message)))
        }
    }
}

/// 使用内核 audit token、代码目录哈希和绝对路径校验 XPC 对端，禁止各业务模块自行弱化身份检查。
public enum ArcKitXPCPeerIdentityVerifier {
    public static func verify(
        message: xpc_object_t,
        expectedBundleURL: URL,
        expectedBundleIdentifier: String
    ) throws {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            throw ArcKitXPCPeerIdentityError.malformedMessage
        }

        var runningCode: SecCode?
        let runningStatus = SecCodeCreateWithXPCMessage(message, SecCSFlags(), &runningCode)
        guard runningStatus == errSecSuccess, let runningCode else {
            throw ArcKitXPCPeerIdentityError.identityUnavailable(L10n.string(.Platform.identitySenderSignatureUnreadable(String(describing: runningStatus))))
        }

        try verify(runningCode: runningCode, expectedBundleURL: expectedBundleURL, expectedBundleIdentifier: expectedBundleIdentifier)
    }

    public static func verifyProcess(_ pid: Int32, expectedBundleURL: URL, expectedBundleIdentifier: String) throws {
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw ArcKitXPCPeerIdentityError.identityUnavailable(L10n.string(.Platform.identityMainAppVerificationFailed))
        }
        try verify(runningCode: code, expectedBundleURL: expectedBundleURL, expectedBundleIdentifier: expectedBundleIdentifier)
    }

    private static func verify(runningCode: SecCode, expectedBundleURL: URL, expectedBundleIdentifier: String) throws {
        var installedCode: SecStaticCode?
        let installedStatus = SecStaticCodeCreateWithPath(
            expectedBundleURL.standardizedFileURL as CFURL,
            SecCSFlags(),
            &installedCode
        )
        guard installedStatus == errSecSuccess, let installedCode else {
            throw ArcKitXPCPeerIdentityError.identityUnavailable(
                L10n.string(.Platform.identityInstalledComponentMissingUnreadable(String(describing: expectedBundleURL.path), String(describing: installedStatus)))
            )
        }

        guard SecCodeCheckValidity(runningCode, SecCSFlags(), nil) == errSecSuccess,
              SecStaticCodeCheckValidity(installedCode, SecCSFlags(), nil) == errSecSuccess
        else {
            throw ArcKitXPCPeerIdentityError.identityMismatch(L10n.string(.Platform.identityInvalidComponentCodeSignature))
        }

        var runningStaticCode: SecStaticCode?
        let runningStaticStatus = SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode)
        guard runningStaticStatus == errSecSuccess, let runningStaticCode else {
            throw ArcKitXPCPeerIdentityError.identityUnavailable(
                L10n.string(.Platform.identitySignatureUnreadable(String(describing: runningStaticStatus)))
            )
        }

        let runningInfo = try signingInformation(for: runningStaticCode)
        let installedInfo = try signingInformation(for: installedCode)
        let runningIdentifier = runningInfo[kSecCodeInfoIdentifier] as? String
        let installedIdentifier = installedInfo[kSecCodeInfoIdentifier] as? String
        guard runningIdentifier == expectedBundleIdentifier,
              installedIdentifier == expectedBundleIdentifier
        else {
            throw ArcKitXPCPeerIdentityError.identityMismatch(
                L10n.string(.Platform.identityExpectedActual(String(describing: expectedBundleIdentifier), String(describing: runningIdentifier ?? L10n.string(.Common.unknown))))
            )
        }

        guard let runningHash = runningInfo[kSecCodeInfoUnique] as? Data,
              let installedHashes = installedInfo[kSecCodeInfoCdHashes] as? [Data],
              installedHashes.contains(runningHash)
        else {
            throw ArcKitXPCPeerIdentityError.identityMismatch(L10n.string(.Platform.identityInstallationMismatch))
        }

        var runningPath: CFURL?
        let pathStatus = SecCodeCopyPath(runningStaticCode, SecCSFlags(), &runningPath)
        guard pathStatus == errSecSuccess,
              let runningPath = runningPath as URL?,
              runningPath.standardizedFileURL.path == expectedBundleURL.standardizedFileURL.path
        else {
            throw ArcKitXPCPeerIdentityError.identityMismatch(
                L10n.string(.Platform.identityPathMismatch(String(describing: (runningPath as URL?)?.path ?? L10n.string(.Common.unknown))))
            )
        }
    }

    private static func signingInformation(for code: SecStaticCode) throws -> [CFString: Any] {
        var rawInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard status == errSecSuccess,
              let information = rawInformation as? [CFString: Any]
        else {
            throw ArcKitXPCPeerIdentityError.identityUnavailable(L10n.string(.Platform.identitySignatureInfoUnreadable(String(describing: status))))
        }
        return information
    }
}
