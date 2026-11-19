import Foundation

public enum ProxyDelayBatch {
    @MainActor
    public static func run<Node: Hashable & Sendable>(nodes: [Node], test: @escaping @Sendable (Node) async throws -> Int64,
                           receive: @escaping @MainActor (Node, ProxyDelayResult) -> Void) async {
        var seen = Set<Node>()
        var remaining = nodes.filter { seen.insert($0).inserted }.makeIterator()
        await withTaskGroup(of: (Node, ProxyDelayResult?).self) { group in
            func enqueue(_ node: Node) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (node, .measured(try await test(node)))
                    } catch is CancellationError { return (node, nil) }
                    catch ProxyDelayFailure.timeout { return (node, .timedOut) }
                    catch ProxyDelayFailure.cancelled { return (node, nil) }
                    catch { return (node, .failed) }
                }
            }
            for _ in 0..<4 { if let node = remaining.next() { enqueue(node) } }
            while let (node, result) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let result { receive(node, result) }
                if let next = remaining.next() { enqueue(next) }
            }
        }
    }
}
