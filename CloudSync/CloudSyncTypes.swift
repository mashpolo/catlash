import CryptoKit
import Foundation

public struct YAMLSyncReport: Sendable {
    public let files: [YAMLSyncFileResult]
}

public struct YAMLSyncFileResult: Sendable, Equatable {
    public let fileName: String
    public let status: YAMLSyncStatus
}

public enum YAMLSyncStatus: Sendable, Equatable {
    case uploaded
    case downloaded
    case identical
    case missing
    case deletedLocally
    case remoteDeletionConflict(localHash: String)
    case waitingDownload
    case conflict(YAMLConflict)
    case providerConflict([YAMLConflictVersion])
    case failed(String)
}

public struct YAMLConflict: Sendable, Equatable {
    public let localData: Data
    public let remoteData: Data
    public let localHash: String
    public let remoteHash: String
    public let localModified: Date?
    public let remoteModified: Date?
}

public struct YAMLConflictVersion: Sendable, Equatable {
    public let identifier: String
    public let modificationDate: Date?
    public let data: Data?
    public internal(set) var backupURL: URL?
    public let error: String?

    public init(identifier: String, modificationDate: Date?, data: Data?, error: String? = nil) {
        self.identifier = identifier
        self.modificationDate = modificationDate
        self.data = data
        self.error = error
    }
}

public enum YAMLConflictChoice: Sendable, Equatable { case local, remote }

public enum YAMLSyncError: Error, LocalizedError, Equatable {
    case invalidFileName
    case invalidDirectory
    case invalidFile
    case oversizedFile
    case staleConflict
    case invalidState
    case waitingDownload
    case unresolvedVersions
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: return "Only top-level YAML file names are supported."
        case .invalidDirectory: return "The sync folder is unavailable or is a symbolic link."
        case .invalidFile: return "The YAML item must be a regular file, not a symbolic link."
        case .oversizedFile: return "The YAML file exceeds the 16 MiB limit."
        case .staleConflict: return "A file changed after the conflict was displayed. Refresh the conflict before choosing a version."
        case .invalidState: return "The saved sync baseline is damaged. No files were overwritten."
        case .waitingDownload: return "Waiting for the file provider to download the current file."
        case .unresolvedVersions: return "The file provider has unresolved versions. Automatic writes are paused."
        case .unavailable(let reason): return "The file provider is unavailable: \(reason)"
        }
    }
}

enum YAMLFileAvailability: Sendable { case available, waitingDownload }

struct YAMLFileContent: Sendable {
    let data: Data
    let hash: String
    let modified: Date?
}

enum YAMLObservedFile: Sendable {
    case missing
    case ready(YAMLFileContent)
    case waitingDownload
    case versions([YAMLConflictVersion])

    var content: YAMLFileContent? {
        if case .ready(let content) = self { return content }
        return nil
    }
}

func yamlDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func isYAMLFileName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
        && ["yaml", "yml"].contains((name as NSString).pathExtension.lowercased())
}
