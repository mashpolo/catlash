import Foundation

struct LibraryRuleDraft: Sendable {
    let profile: ProfileRecord
    let document: ProfileRuleDocument
}

extension LibraryModel {
    func loadRules() async throws -> LibraryRuleDraft {
        guard let profile = selectedProfile else { throw LibraryError.noProfile }
        let bytes = try await currentProfileData(id: profile.id, revision: profile.revisionSHA)
        let document = try await Task.detached(priority: .userInitiated) { try ProfileRuleDocument(data: bytes) }.value
        try Task.checkCancellation()
        guard selectedID == profile.id else { throw CancellationError() }
        return LibraryRuleDraft(profile: profile, document: document)
    }

    @discardableResult
    func saveRules(_ rules: [ProfileRule], draft: LibraryRuleDraft) async -> Bool {
        do {
            let bytes = try await Task.detached(priority: .userInitiated) { try draft.document.replacingRules(rules) }.value
            try Task.checkCancellation()
            return await save(String(decoding: bytes, as: UTF8.self), profile: draft.profile)
        } catch is CancellationError { return false }
        catch { message = error.localizedDescription; return false }
    }
}
