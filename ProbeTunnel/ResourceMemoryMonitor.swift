import Foundation
import MihomoBridge
import os

/// Keep enough memory for the running packet flow while optional resources load.
final class ResourceMemoryMonitor: @unchecked Sendable {
    static let reserve = 12 * 1024 * 1024
    static var available: Int { Int(os_proc_available_memory()) }

    private let timer: DispatchSourceTimer

    init(root: URL, onPressure: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "FlClash.ResourceMemory")
        timer = DispatchSource.makeTimerSource(queue: queue)
        let directory = root.appendingPathComponent("Library/Caches")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("resource-memory.json")
        var lowest = Int.max
        var peak: UInt64 = 0
        var warned = false
        timer.setEventHandler {
            let available = Self.available
            let footprint = (try? ProcessMetrics.snapshot().physicalFootprintBytes) ?? 0
            if available < lowest - 512 * 1024 || footprint > peak + 512 * 1024 {
                lowest = min(lowest, available)
                peak = max(peak, footprint)
                var sample = (try? JSONDecoder().decode([String: UInt64].self, from: Data(MobileRuntimeMemoryJSON().utf8))) ?? [:]
                sample["minimumAvailableBytes"] = UInt64(lowest)
                sample["peakFootprintBytes"] = peak
                try? JSONEncoder().encode(sample).write(to: url, options: .atomic)
            }
            if !warned && available <= Self.reserve {
                warned = true
                onPressure()
            }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(150))
        timer.resume()
    }

    deinit { timer.cancel() }
}
