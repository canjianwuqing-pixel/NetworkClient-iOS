import CryptoKit
import Foundation

struct NodeIdentitySource: Hashable, Sendable {
    let originalName: String
    let displayName: String?
    let type: String
    let server: String
    let port: Int
    let uuid: String
    let password: String
    let cipher: String
    let sni: String
    let serverName: String
    let network: String
    let security: String
    let countryCode: String?
    let available: Bool
    // Full original-proxy digest, used only after every legacy key ties.
    let collisionKey: String?

    init(
        originalName: String,
        displayName: String? = nil,
        type: String,
        server: String,
        port: Int,
        uuid: String = "",
        password: String = "",
        cipher: String = "",
        sni: String = "",
        serverName: String = "",
        network: String = "",
        security: String = "",
        countryCode: String? = nil,
        available: Bool = true,
        collisionKey: String? = nil
    ) {
        self.originalName = originalName
        self.displayName = displayName
        self.type = type
        self.server = server
        self.port = port
        self.uuid = uuid
        self.password = password
        self.cipher = cipher
        self.sni = sni
        self.serverName = serverName
        self.network = network
        self.security = security
        self.countryCode = countryCode
        self.available = available
        self.collisionKey = collisionKey
    }
}

struct NodeIdentity: Codable, Hashable, Sendable {
    let id: String
    let fingerprint: String
    let coreName: String
}

enum NodeIdentityError: Error, Equatable, Sendable {
    case missingName(index: Int)
    case missingType(index: Int)
    case missingServer(index: Int)
    case invalidPort(index: Int)
}

enum NodeIdentityFactory {
    static func makeNodes(from sources: [NodeIdentitySource]) throws -> [ProxyNode] {
        try buildCandidates(from: sources).map { candidate in
            ProxyNode(
                id: candidate.identity.id,
                fingerprint: candidate.identity.fingerprint,
                originalName: candidate.originalName,
                displayName: candidate.displayName,
                coreName: candidate.identity.coreName,
                protocolType: candidate.protocolType,
                server: candidate.server,
                port: candidate.port,
                countryCode: candidate.countryCode,
                available: candidate.available
            )
        }
    }

    private static func buildCandidates(from sources: [NodeIdentitySource]) throws -> [ResolvedCandidate] {
        let prepared = try sources.enumerated().map(prepare)
        let nameCounts = Dictionary(grouping: prepared, by: \.originalName).mapValues(\.count)

        let candidates = prepared.map { item in
            Candidate(
                prepared: item,
                provisionalID: nameCounts[item.originalName, default: 0] > 1
                    ? item.fingerprint
                    : item.shortStableID,
                coreBaseName: "ky-\(item.fingerprint.prefix(16))"
            )
        }
        let resolvedIDs = resolveCollisions(
            candidates: candidates,
            baseValue: \.provisionalID
        )
        let resolvedCoreNames = resolveCollisions(
            candidates: candidates,
            baseValue: \.coreBaseName
        )

        return candidates.indices.map { index in
            let item = candidates[index].prepared
            return ResolvedCandidate(
                identity: NodeIdentity(
                    id: resolvedIDs[index],
                    fingerprint: item.fingerprint,
                    coreName: resolvedCoreNames[index]
                ),
                originalName: item.originalName,
                displayName: item.displayName,
                protocolType: item.protocolType,
                server: item.server,
                port: item.port,
                countryCode: item.countryCode,
                available: item.available
            )
        }
    }

    private static func prepare(_ offset: Int, _ source: NodeIdentitySource) throws -> PreparedSource {
        let originalName = source.originalName.nodeIdentityTrimmed
        guard !originalName.isEmpty else { throw NodeIdentityError.missingName(index: offset) }

        let rawType = source.type.nodeIdentityTrimmed
        guard !rawType.isEmpty else { throw NodeIdentityError.missingType(index: offset) }

        let server = source.server.nodeIdentityTrimmed
        guard !server.isEmpty else { throw NodeIdentityError.missingServer(index: offset) }
        guard (1...65_535).contains(source.port) else {
            throw NodeIdentityError.invalidPort(index: offset)
        }

        let protocolType = rawType.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let displayName = source.displayName?.nodeIdentityTrimmed.nodeIdentityNilIfEmpty ?? originalName
        let fingerprintBody = [
            rawType,
            originalName,
            server,
            String(source.port),
            source.uuid.nodeIdentityTrimmed,
            source.password.nodeIdentityTrimmed,
            source.cipher.nodeIdentityTrimmed,
            source.sni.nodeIdentityTrimmed,
            source.serverName.nodeIdentityTrimmed,
            source.network.nodeIdentityTrimmed,
            source.security.nodeIdentityTrimmed
        ].joined(separator: "\0")
        let completeFingerprint = NodeHash.sha256Hex(fingerprintBody)

        return PreparedSource(
            sourceIndex: offset,
            originalName: originalName,
            displayName: displayName,
            protocolType: protocolType,
            server: server,
            port: source.port,
            countryCode: source.countryCode?.nodeIdentityTrimmed.nodeIdentityNilIfEmpty?.uppercased(),
            available: source.available,
            shortStableID: String(NodeHash.sha256Hex("\(protocolType)\0\(originalName)").prefix(24)),
            fingerprint: String(completeFingerprint.prefix(24)),
            completeFingerprint: completeFingerprint,
            canonicalFingerprintBody: fingerprintBody,
            collisionKey: source.collisionKey
        )
    }

    private static func resolveCollisions(
        candidates: [Candidate],
        baseValue: KeyPath<Candidate, String>
    ) -> [String] {
        var resolved = candidates.map { $0[keyPath: baseValue] }
        let groups = Dictionary(grouping: candidates.indices) { candidates[$0][keyPath: baseValue] }

        for (base, indices) in groups where indices.count > 1 {
            let stableOrder = indices.sorted { left, right in
                let lhs = candidates[left].prepared
                let rhs = candidates[right].prepared
                if lhs.completeFingerprint != rhs.completeFingerprint {
                    return lhs.completeFingerprint < rhs.completeFingerprint
                }
                if lhs.canonicalFingerprintBody != rhs.canonicalFingerprintBody {
                    return lhs.canonicalFingerprintBody < rhs.canonicalFingerprintBody
                }
                if lhs.collisionKey != rhs.collisionKey {
                    // Also keep a total order for legacy callers without keys.
                    return (lhs.collisionKey ?? "") < (rhs.collisionKey ?? "")
                }
                // Identical configurations have no provable occurrence identity.
                return lhs.sourceIndex < rhs.sourceIndex
            }
            for (ordinal, index) in stableOrder.enumerated() {
                resolved[index] = ordinal == 0 ? base : "\(base)-\(ordinal + 1)"
            }
        }
        return resolved
    }
}

extension NodeIdentityFactory {
    private struct PreparedSource {
        let sourceIndex: Int
        let originalName: String
        let displayName: String
        let protocolType: String
        let server: String
        let port: Int
        let countryCode: String?
        let available: Bool
        let shortStableID: String
        let fingerprint: String
        let completeFingerprint: String
        let canonicalFingerprintBody: String
        let collisionKey: String?
    }

    private struct Candidate {
        let prepared: PreparedSource
        let provisionalID: String
        let coreBaseName: String
    }

    private struct ResolvedCandidate {
        let identity: NodeIdentity
        let originalName: String
        let displayName: String
        let protocolType: String
        let server: String
        let port: Int
        let countryCode: String?
        let available: Bool
    }
}

enum NodeHash {
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension String {
    var nodeIdentityTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nodeIdentityNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
