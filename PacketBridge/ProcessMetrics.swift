import Darwin
import Foundation

public enum ProcessMetrics {
    public static func snapshot() throws -> ProcessMemorySample {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw POSIXError(.EIO) }
        return ProcessMemorySample(physicalFootprintBytes: information.phys_footprint,
                                   residentBytes: information.resident_size)
    }
}
