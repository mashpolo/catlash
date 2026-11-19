import Foundation

public enum DirectoryBookmarkError: Error, LocalizedError {
    case missing
    case stale
    case permissionDenied
    case invalid

    public var errorDescription: String? {
        switch self {
        case .missing: return "Choose a sync folder."
        case .stale: return "The saved folder authorization has expired. Choose the folder again."
        case .permissionDenied: return "The sync folder permission was revoked. Choose the folder again."
        case .invalid: return "The saved folder authorization cannot be restored. Choose the folder again."
        }
    }
}

public final class ScopedDirectoryAccess: Sendable {
    public let url: URL

    public init(url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw DirectoryBookmarkError.permissionDenied }
        do { try CoordinatedYAMLFiles.checkDirectory(url) }
        catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
        self.url = url
    }

    deinit { url.stopAccessingSecurityScopedResource() }
}

public struct DirectoryBookmarkStore: Sendable {
    private let bookmarkURL: URL

    public init(bookmarkURL: URL) { self.bookmarkURL = bookmarkURL }

    public func save(_ url: URL) throws {
        let access = try ScopedDirectoryAccess(url: url)
        try withExtendedLifetime(access) {
            var options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #if os(macOS)
            options = [.withSecurityScope]
            #endif
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            try CoordinatedYAMLFiles.createDirectory(bookmarkURL.deletingLastPathComponent())
            try CoordinatedYAMLFiles.atomicWrite(data, to: bookmarkURL)
        }
    }

    public func restore() throws -> URL {
        guard let data = try CoordinatedYAMLFiles.readBytes(bookmarkURL) else { throw DirectoryBookmarkError.missing }
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI]
        #if os(macOS)
        options.insert(.withSecurityScope)
        #endif
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw DirectoryBookmarkError.invalid }
        guard !stale else { throw DirectoryBookmarkError.stale }
        let access = try ScopedDirectoryAccess(url: url)
        return withExtendedLifetime(access) { url }
    }

    public func restoreAccess() throws -> ScopedDirectoryAccess {
        try ScopedDirectoryAccess(url: restore())
    }

    public func clear() throws {
        do { try FileManager.default.removeItem(at: bookmarkURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }
}
