import Foundation

public actor YAMLSyncEngine {
    private let worker: YAMLSyncWorker
    private var inFlight: (id: UUID, scan: Bool, task: Task<YAMLSyncReport, Error>)?

    public init(localDirectory: URL, remoteDirectory: URL, stateDirectory: URL,
                validate: @escaping @Sendable (Data) throws -> Void) {
        worker = YAMLSyncWorker(local: localDirectory, remote: remoteDirectory, state: stateDirectory,
                               files: CoordinatedYAMLFiles(), validate: validate,
                               persist: { try CoordinatedYAMLFiles.atomicWrite($0, to: $1) })
    }

    init(localDirectory: URL, remoteDirectory: URL, stateDirectory: URL,
         validate: @escaping @Sendable (Data) throws -> Void,
         availability: @escaping @Sendable (URL) throws -> YAMLFileAvailability,
         versions: @escaping @Sendable (URL) throws -> [YAMLConflictVersion],
         persistState: @escaping @Sendable (Data, URL) throws -> Void) {
        worker = YAMLSyncWorker(local: localDirectory, remote: remoteDirectory, state: stateDirectory,
                               files: CoordinatedYAMLFiles(availability: availability, versions: versions),
                               validate: validate, persist: persistState)
    }

    public func synchronize() async throws -> YAMLSyncReport {
        if let current = inFlight {
            let result = try await current.task.value
            if current.scan { return result }
            if inFlight?.id == current.id { inFlight = nil }
            return try await synchronize()
        }
        let worker = worker
        return try await perform(scan: true) { try worker.synchronize() }
    }

    public func resolve(file: String, choice: YAMLConflictChoice, expectedL: String, expectedR: String) async throws -> YAMLSyncFileResult {
        if let current = inFlight {
            _ = try await current.task.value
            if inFlight?.id == current.id { inFlight = nil }
            return try await resolve(file: file, choice: choice, expectedL: expectedL, expectedR: expectedR)
        }
        let worker = worker
        let report = try await perform(scan: false) {
            YAMLSyncReport(files: [try worker.resolve(file: file, choice: choice, expectedL: expectedL, expectedR: expectedR)])
        }
        return report.files[0]
    }

    public func resolveRemoteDeletion(file: String, choice: YAMLConflictChoice,
                                      expectedLocalHash: String) async throws -> YAMLSyncFileResult {
        if let current = inFlight {
            _ = try await current.task.value
            if inFlight?.id == current.id { inFlight = nil }
            return try await resolveRemoteDeletion(file: file, choice: choice, expectedLocalHash: expectedLocalHash)
        }
        let worker = worker
        let report = try await perform(scan: false) {
            YAMLSyncReport(files: [try worker.resolveRemoteDeletion(file: file, choice: choice, expectedLocalHash: expectedLocalHash)])
        }
        return report.files[0]
    }

    private func perform(scan: Bool, operation: @escaping @Sendable () throws -> YAMLSyncReport) async throws -> YAMLSyncReport {
        let id = UUID()
        let task = Task.detached(priority: .utility) { try operation() }
        inFlight = (id, scan, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await task.value
    }
}

private struct YAMLSyncWorker: Sendable {
    let local: URL
    let remote: URL
    let state: URL
    let files: CoordinatedYAMLFiles
    let validate: @Sendable (Data) throws -> Void
    let persist: @Sendable (Data, URL) throws -> Void
    private var backups: URL { state.appendingPathComponent("backups", isDirectory: true) }

    func synchronize() throws -> YAMLSyncReport {
        var baseline = try loadState()
        let names = try files.names(in: local).union(files.names(in: remote)).union(baseline.hashes.keys)
        var results: [YAMLSyncFileResult] = []
        for name in names.sorted() {
            let status: YAMLSyncStatus
            let hash: String?
            do {
                (status, hash) = try synchronizeFile(name, state: &baseline)
            } catch YAMLSyncError.waitingDownload {
                results.append(YAMLSyncFileResult(fileName: name, status: .waitingDownload))
                continue
            } catch {
                results.append(YAMLSyncFileResult(fileName: name, status: .failed(error.localizedDescription)))
                continue
            }
            if status == .deletedLocally || (hash != nil && (baseline.hashes[name] != hash || baseline.removals?[name] != nil)) {
                baseline.hashes[name] = hash
                baseline.removals?[name] = nil
                try save(baseline)
            }
            results.append(YAMLSyncFileResult(fileName: name, status: status))
        }
        return YAMLSyncReport(files: results)
    }

    func resolve(file: String, choice: YAMLConflictChoice, expectedL: String, expectedR: String) throws -> YAMLSyncFileResult {
        guard isYAMLFileName(file) else { throw YAMLSyncError.invalidFileName }
        var baseline = try loadState()
        try CoordinatedYAMLFiles.checkDirectory(local)
        try CoordinatedYAMLFiles.checkDirectory(remote)
        let source = choice == .local ? local : remote
        let destination = choice == .local ? remote : local
        let sourceHash = choice == .local ? expectedL : expectedR
        let destinationHash = choice == .local ? expectedR : expectedL
        let hash = try files.transfer(from: source.appendingPathComponent(file), to: destination.appendingPathComponent(file),
                                      expectedSource: sourceHash, expectedDestination: destinationHash,
                                      backups: backups, validate: validate)
        baseline.hashes[file] = hash
        baseline.removals?[file] = nil
        try save(baseline)
        return YAMLSyncFileResult(fileName: file, status: choice == .local ? .uploaded : .downloaded)
    }

    func resolveRemoteDeletion(file: String, choice: YAMLConflictChoice, expectedLocalHash: String) throws -> YAMLSyncFileResult {
        guard isYAMLFileName(file) else { throw YAMLSyncError.invalidFileName }
        var baseline = try loadState()
        guard let synced = baseline.hashes[file], synced != expectedLocalHash else { throw YAMLSyncError.staleConflict }
        try CoordinatedYAMLFiles.checkDirectory(local)
        try CoordinatedYAMLFiles.checkDirectory(remote)
        let localURL = local.appendingPathComponent(file)
        let status: YAMLSyncStatus
        switch choice {
        case .local:
            let hash = try files.transfer(from: localURL, to: remote.appendingPathComponent(file), expectedSource: expectedLocalHash,
                                          expectedDestination: nil, backups: backups, validate: validate)
            baseline.hashes[file] = hash
            status = .uploaded
        case .remote:
            try removeLocal(file, hash: expectedLocalHash, state: &baseline)
            baseline.hashes[file] = nil
            status = .deletedLocally
        }
        baseline.removals?[file] = nil
        try save(baseline)
        return YAMLSyncFileResult(fileName: file, status: status)
    }

    private func removeLocal(_ name: String, hash: String, state: inout Baseline) throws {
        try files.removeLocal(local.appendingPathComponent(name), whenMissingFrom: remote,
                              expectedHash: hash, backups: backups) {
            // A restart must distinguish this unlink from the user's local-only removal.
            if state.removals?[name] != hash {
                var next = state
                if next.removals == nil { next.removals = [:] }
                next.removals?[name] = hash
                try save(next)
                state = next
            }
        }
    }

    private func synchronizeFile(_ name: String, state: inout Baseline) throws -> (YAMLSyncStatus, String?) {
        let localURL = local.appendingPathComponent(name)
        let remoteURL = remote.appendingPathComponent(name)
        let localFile = try files.read(localURL)
        let remoteFile = try files.read(remoteURL)
        if let blocked = try blockedStatus(localFile, remoteFile, name: name) { return (blocked, nil) }
        let lhs = localFile.content
        let rhs = remoteFile.content
        let baseline = state.hashes[name]
        let removing = state.removals?[name]
        if let baseline, rhs == nil {
            guard let lhs else { return (.deletedLocally, nil) }
            guard lhs.hash == baseline || lhs.hash == removing else {
                return (.remoteDeletionConflict(localHash: lhs.hash), nil)
            }
            try removeLocal(name, hash: lhs.hash, state: &state)
            return (.deletedLocally, nil)
        }
        if let lhs { try validate(lhs.data) }
        if let rhs { try validate(rhs.data) }
        if let lhs, let rhs, lhs.hash == rhs.hash { return (.identical, lhs.hash) }
        if lhs == nil && rhs == nil { return (.missing, nil) }
        if baseline != nil && lhs == nil && removing == nil { return (.missing, nil) }
        if let lhs, removing == nil, rhs == nil || rhs?.hash == baseline {
            let hash = try files.transfer(from: localURL, to: remoteURL, expectedSource: lhs.hash,
                                          expectedDestination: rhs?.hash, backups: backups, validate: validate)
            return (.uploaded, hash)
        }
        if let rhs, lhs == nil || lhs?.hash == baseline || lhs?.hash == removing {
            let hash = try files.transfer(from: remoteURL, to: localURL, expectedSource: rhs.hash,
                                          expectedDestination: lhs?.hash, backups: backups, validate: validate)
            return (.downloaded, hash)
        }
        guard let lhs, let rhs else { return (.missing, nil) }
        return (.conflict(YAMLConflict(localData: lhs.data, remoteData: rhs.data,
                                       localHash: lhs.hash, remoteHash: rhs.hash,
                                       localModified: lhs.modified, remoteModified: rhs.modified)), nil)
    }

    private func blockedStatus(_ lhs: YAMLObservedFile, _ rhs: YAMLObservedFile, name: String) throws -> YAMLSyncStatus? {
        var versions: [YAMLConflictVersion] = []
        if case .versions(let items) = lhs { versions += items }
        if case .versions(let items) = rhs { versions += items }
        if !versions.isEmpty {
            return .providerConflict(try files.preserveVersions(versions, in: backups))
        }
        if case .waitingDownload = lhs { return .waitingDownload }
        if case .waitingDownload = rhs { return .waitingDownload }
        return nil
    }

    private struct Baseline: Codable {
        var version = 1
        let remoteDirectory: String
        var hashes: [String: String] = [:]
        var removals: [String: String]?
    }

    private func loadState() throws -> Baseline {
        try CoordinatedYAMLFiles.createDirectory(state)
        guard let bytes = try CoordinatedYAMLFiles.readBytes(state.appendingPathComponent("baseline.json")) else {
            return Baseline(remoteDirectory: remote.standardizedFileURL.path)
        }
        guard let baseline = try? JSONDecoder().decode(Baseline.self, from: bytes), baseline.version == 1,
              (baseline.removals ?? [:]).allSatisfy({ baseline.hashes[$0.key] != nil && Self.isHash($0.value) }),
              baseline.hashes.allSatisfy({ name, hash in
                  isYAMLFileName(name) && Self.isHash(hash)
              }) else { throw YAMLSyncError.invalidState }
        guard baseline.remoteDirectory == remote.standardizedFileURL.path else {
            return Baseline(remoteDirectory: remote.standardizedFileURL.path)
        }
        return baseline
    }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func save(_ baseline: Baseline) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try persist(encoder.encode(baseline), state.appendingPathComponent("baseline.json"))
    }
}
