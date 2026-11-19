import Foundation

/// Choices supplied for this extension session. Saved revisions remain unchanged.
public final class RuntimeSelectionOverrides: @unchecked Sendable {
    private let lock = NSLock()
    private struct Entry {
        let generation: UInt64
        var selections: [String: String]
    }
    private var generation: UInt64 = 0
    private var choices: [String: Entry] = [:]

    public init() {}

    public static func decode(_ data: Data) throws -> [String: String] {
        guard data.count <= 16_384 else { throw SnapshotStoreError.invalidConfiguration }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    public func reset() { lock.withLock { choices.removeAll() } }

    public func set(_ selections: [String: String]?, revision: String) throws {
        if let selections { _ = try Self.decode(JSONEncoder().encode(selections)) }
        lock.withLock {
            generation &+= 1
            choices[revision] = selections.map { Entry(generation: generation, selections: $0) }
        }
    }

    public func configuration(_ baseline: Data, revision: String) throws -> Data {
        guard let entry = lock.withLock({ choices[revision] }) else { return baseline }
        return try Self.replacingSelections(in: baseline, with: entry.selections)
    }

    public func select(group: String, node: String, revision: String) {
        lock.withLock {
            var selections = choices[revision]?.selections ?? [:]
            selections[group] = node
            generation &+= 1
            choices[revision] = Entry(generation: generation, selections: selections)
        }
    }

    public func rememberPrepared(source: String, prepared: String, configuration: Data) throws {
        guard source != prepared else { return }
        let runtime = try RuntimeConfiguration.decode(configuration)
        guard case let .mihomo(_, selections) = runtime.outbound else { return }
        lock.withLock {
            // A late preparation must not replace a newer request's choices.
            guard let supplied = choices[source], supplied.selections.allSatisfy({ selections[$0.key] == $0.value }),
                  (choices[prepared]?.generation ?? 0) <= supplied.generation else { return }
            choices[prepared] = Entry(generation: supplied.generation, selections: selections)
        }
    }

    private static func replacingSelections(in data: Data, with selections: [String: String]) throws -> Data {
        let saved = try RuntimeConfiguration.decode(data)
        guard case let .mihomo(yaml, stored) = saved.outbound else { return data }
        let active = RuntimeConfiguration(version: saved.version, mtu: saved.mtu,
            outbound: .mihomo(yaml: yaml, selections: stored.merging(selections) { _, current in current }), resources: saved.resources, profileID: saved.profileID,
            allowDeferredResources: saved.allowDeferredResources)
        try active.validate()
        return try JSONEncoder().encode(active)
    }
}
