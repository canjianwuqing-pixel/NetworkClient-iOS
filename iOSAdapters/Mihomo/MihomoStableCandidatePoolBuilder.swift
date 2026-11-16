import Foundation
import Yams

/// Builds a fixed, non-routing set of named outbounds from configurations
/// already validated by SelectedNodeTunnelMapper. It never parses a raw
/// subscription protocol a second time.
enum MihomoStableCandidatePoolBuilder {
    static let maximumCandidates = 128
    static let maximumYAMLBytes = 524_288

    struct Pool {
        let yaml: String
        let candidates: [MihomoCandidateDescriptor]
        let revision: String
    }

    static func build(
        selected: MihomoTunnelConfiguration,
        candidates: [NodeProbeCandidate]
    ) throws -> Pool {
        guard let selectedName = selected.coreName,
              let selectedRevision = selected.configurationRevision,
              !candidates.isEmpty, candidates.count <= maximumCandidates,
              var root = try Yams.load(yaml: selected.yaml) as? [String: Any],
              let groups = root["proxy-groups"] as? [[String: Any]], groups.count == 1,
              groups[0]["name"] as? String == "VPN",
              groups[0]["proxies"] as? [String] == [selectedName],
              let selectedProxies = root["proxies"] as? [[String: Any]],
              selectedProxies.count == 1,
              selectedProxies[0]["name"] as? String == selectedName else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        var seenNames = Set<String>()
        var seenIDs = Set<String>()
        var proxies: [[String: Any]] = []
        var descriptors: [MihomoCandidateDescriptor] = []
        for candidate in candidates {
            guard seenNames.insert(candidate.coreName).inserted,
                  seenIDs.insert(candidate.nodeID).inserted,
                  candidate.nodeID.utf8.count <= 256,
                  candidate.coreName.utf8.count <= 256,
                  candidate.revision.utf8.count == 64,
                  let candidateRoot = try Yams.load(yaml: candidate.yaml) as? [String: Any],
                  let mapped = candidateRoot["proxies"] as? [[String: Any]],
                  mapped.count == 1,
                  mapped[0]["name"] as? String == candidate.coreName,
                  let candidateGroups = candidateRoot["proxy-groups"] as? [[String: Any]],
                  candidateGroups.count == 1,
                  candidateGroups[0]["name"] as? String == "VPN",
                  candidateGroups[0]["proxies"] as? [String] == [candidate.coreName],
                  candidateRoot["proxy-providers"] == nil,
                  let tun = candidateRoot["tun"] as? [String: Any],
                  tun["enable"] as? Bool == false else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            if candidate.coreName == selectedName {
                guard candidate.nodeID == selected.nodeID,
                      candidate.revision == selectedRevision else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
                proxies.append(selectedProxies[0])
            } else {
                proxies.append(mapped[0])
            }
            descriptors.append(.init(
                nodeID: candidate.nodeID, revision: candidate.revision,
                coreName: candidate.coreName
            ))
        }
        guard seenNames.contains(selectedName) else {
            throw SelectedNodeTunnelError.missingNode
        }
        // Keep the active node first so Core starts with the user's verified
        // selection. The remaining fixed outbounds are selector members for
        // an acknowledged in-Core switch and named URLTest only; no automatic
        // policy selects them.
        let orderedNames = [selectedName]
            + descriptors.map(\.coreName).filter { $0 != selectedName }
        root["proxies"] = proxies
        root.removeValue(forKey: "proxy-providers")
        root["proxy-groups"] = [[
            "name": "VPN", "type": "select", "proxies": orderedNames,
        ]]
        let yaml = try Yams.dump(object: root, sortKeys: true)
        guard yaml.utf8.count <= maximumYAMLBytes else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        let identity = descriptors
            .sorted { $0.nodeID < $1.nodeID }
            .map { "\($0.nodeID):\($0.revision):\($0.coreName)" }
            .joined(separator: "\n")
        let dnsIdentity = try Yams.dump(object: root["dns"] ?? [:], sortKeys: true)
        return Pool(yaml: yaml, candidates: descriptors,
                    revision: NodeHash.sha256Hex(identity + "\n" + dnsIdentity))
    }
}
