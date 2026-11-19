import Foundation
import Yams

enum EffectiveYAML {
    static func compose(data: Data) throws -> Node {
        guard data.count <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
        guard let yaml = String(data: data, encoding: .utf8) else { throw ProfileStoreError.invalidUTF8 }
        do {
            let preserving = Constructor(Constructor.defaultScalarMap.mapValues { _ in { Node.scalar($0) } })
            guard let document = try Yams.compose(yaml: yaml, .default, preserving, .utf8), document.mapping != nil else {
                throw ProfileStoreError.invalidYAML
            }
            var pending = [document]
            let mergeTag = Tag(.merge)
            var hasMerge = false
            var hasComplexKey = false
            while let node = pending.popLast() {
                if let mapping = node.mapping {
                    for (key, value) in mapping {
                        hasMerge = hasMerge || key.tag == mergeTag
                        hasComplexKey = hasComplexKey || key.scalar == nil
                        pending.append(value)
                    }
                } else if let sequence = node.sequence { pending.append(contentsOf: sequence) }
            }
            guard hasMerge else { return document }
            guard !hasComplexKey, let represented = document.any as? NodeRepresentable else { throw ProfileStoreError.invalidYAML }
            return try represented.represented()
        } catch { throw ProfileStoreError.invalidYAML }
    }
}
