import CryptoKit
import Foundation

public struct CoreStateStore: Sendable {
    private let root: URL

    public init(root: URL) { self.root = root }

    public func directory(profileID: String) throws -> URL {
        try Self.validateProfileID(profileID)
        try prepareDirectory(root)
        let directory = root.appendingPathComponent(Self.identifier(profileID: profileID), isDirectory: true)
        try prepareDirectory(directory)
        return directory
    }

    static func identifier(profileID: String) -> String {
        SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validateProfileID(_ id: String) throws {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              id.utf8.count <= 255, ["yaml", "yml"].contains((id as NSString).pathExtension.lowercased()) else {
            throw CoreStateError.invalidProfileID
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CoreStateError.unsafeDirectory }
        } catch CocoaError.fileReadNoSuchFile {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }
}

public enum CoreStateError: Error, Equatable, LocalizedError {
    case invalidProfileID, unsafeDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidProfileID: return "The persistent profile identifier is invalid."
        case .unsafeDirectory: return "The core state location must be a directory without symbolic links."
        }
    }
}
