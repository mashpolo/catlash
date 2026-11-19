import Foundation
import MihomoBridge

struct CapacityResult: Encodable {
    let environment = "macOS command-line process; not an iOS extension measurement"
    let coreVersion: String
    let operatingSystem: String
    let nodes: Int
    let rules: Int
    let configurationBytes: Int
    let creationMilliseconds: Double
    let selections: Int
    let before: ProcessMemorySample
    let active: ProcessMemorySample
    let afterClose: ProcessMemorySample
}

let arguments = Array(CommandLine.arguments.dropFirst())
let nodes = arguments.isEmpty ? 1000 : Int(arguments[0]) ?? 0
let ruleCount = arguments.count > 1 ? Int(arguments[1]) ?? -1 : 50000
guard arguments.isEmpty || arguments.count == 2,
      (1...1000).contains(nodes), (0...50000).contains(ruleCount) else {
    throw NSError(domain: "Usage: host-capacity [nodes:1...1000 rules:0...50000]", code: 1)
}
var lines = ["proxies:"]
for index in 0..<nodes {
    lines.append(" - {name: node\(index), type: socks5, server: 127.0.0.1, port: 9, udp: true}")
}
lines += ["proxy-groups:", " - name: selection", "   type: select",
          "   proxies: [" + (0..<nodes).map { "node\($0)" }.joined(separator: ",") + "]", "rules:"]
for index in 0..<ruleCount {
    lines.append(" - IP-CIDR,10.\(index / 256).\(index % 256).0/24,selection,no-resolve")
}
lines.append(" - MATCH,REJECT")
let yaml = lines.joined(separator: "\n")
lines.removeAll(keepingCapacity: false)
let version = MobileVersion()
let before = try ProcessMetrics.snapshot()
let started = DispatchTime.now().uptimeNanoseconds
var error: NSError?
guard let session = MobileNewYAMLSession(yaml, "{}", 1280, &error) else {
    throw error ?? CocoaError(.fileReadCorruptFile)
}
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
for index in 0..<100 { try session.selectProxy("selection", name: "node\(index % nodes)") }
let active = try ProcessMetrics.snapshot()
try session.close()
let afterClose = try ProcessMetrics.snapshot()
let result = CapacityResult(coreVersion: version,
                            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            nodes: nodes, rules: ruleCount + 1, configurationBytes: yaml.utf8.count,
                            creationMilliseconds: elapsed, selections: 100,
                            before: before, active: active, afterClose: afterClose)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
try FileHandle.standardOutput.write(contentsOf: encoder.encode(result))
