import Foundation
import Yams

/// Hash only the selected original proxy. Unrelated subscription edits do not
/// interrupt a running tunnel; a changed or removed selected proxy does.
enum SelectedNodeConfigurationIdentity {
    static func revision(in subscription: ParsedSubscription?, nodeID: String?) throws -> String? {
        guard let subscription, let nodeID,
              let record = subscription.runtimeProxyRecords[nodeID] else { return nil }
        return try OriginalProxyCanonicalization.digest(record.originalProxy)
    }
}

enum SubscriptionParserError: Error, Equatable, Sendable {
    case invalidYAML
    case invalidRootStructure
    case noValidNodes
    case identityFailure

    var userFacingKey: String {
        switch self {
        case .noValidNodes: "nodes.error.no_supported_nodes"
        case .invalidYAML, .invalidRootStructure, .identityFailure: "nodes.error.invalid_format"
        }
    }
}

protocol SubscriptionParsing: Sendable {
    func parse(_ rawYAML: String) throws -> ParsedSubscription
}

struct SubscriptionParser: SubscriptionParsing, Sendable {
    func parse(_ rawYAML: String) throws -> ParsedSubscription {
        guard !rawYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubscriptionParserError.invalidYAML
        }

        let loaded: Any
        do {
            guard let value = try Yams.load(yaml: rawYAML) else {
                throw SubscriptionParserError.invalidRootStructure
            }
            loaded = value
        } catch let error as SubscriptionParserError {
            throw error
        } catch {
            throw SubscriptionParserError.invalidYAML
        }

        let yamlRoot: YAMLValue
        do {
            yamlRoot = try YAMLValue(any: loaded)
        } catch {
            throw SubscriptionParserError.invalidRootStructure
        }

        guard case let .object(root) = yamlRoot, let proxyValue = root["proxies"] else {
            throw SubscriptionParserError.invalidRootStructure
        }
        guard case let .array(proxyItems) = proxyValue else {
            throw SubscriptionParserError.invalidRootStructure
        }
        guard !proxyItems.isEmpty else { return .empty }

        let candidates = proxyItems.compactMap(Self.candidate)
        guard !candidates.isEmpty else { throw SubscriptionParserError.noValidNodes }

        let nodes: [ProxyNode]
        do {
            nodes = try NodeIdentityFactory.makeNodes(from: candidates.map(\.source))
        } catch {
            throw SubscriptionParserError.identityFailure
        }

        let namesToCoreNames = Dictionary(grouping: nodes, by: \.originalName)
            .mapValues { $0.map(\.coreName) }
        var runtimeRecords: [String: RuntimeProxyRecord] = [:]
        runtimeRecords.reserveCapacity(nodes.count)

        for (index, node) in nodes.enumerated() {
            let originalProxy = candidates[index].proxy
            let rewritten = Self.runtimeProxy(
                originalProxy,
                coreName: node.coreName,
                namesToCoreNames: namesToCoreNames
            )
            runtimeRecords[node.id] = RuntimeProxyRecord(
                nodeID: node.id,
                originalName: node.originalName,
                coreName: node.coreName,
                originalProxy: originalProxy,
                runtimeProxy: rewritten.proxy,
                issue: rewritten.issue
            )
        }

        return ParsedSubscription(nodes: nodes, runtimeProxyRecords: runtimeRecords)
    }

    private static func candidate(from value: YAMLValue) -> Candidate? {
        guard case let .object(proxy) = value,
              let name = scalarString(proxy["name"])?.subscriptionTrimmed.subscriptionNilIfEmpty,
              !informationalNodeNamePrefixes.contains(where: { name.hasPrefix($0) }),
              let type = scalarString(proxy["type"])?.subscriptionTrimmed.subscriptionNilIfEmpty,
              let server = scalarString(proxy["server"])?.subscriptionTrimmed.subscriptionNilIfEmpty,
              let port = portValue(proxy["port"]) else {
            return nil
        }

        return Candidate(
            source: NodeIdentitySource(
                originalName: name,
                type: type,
                server: server,
                port: port,
                uuid: scalarString(proxy["uuid"])?.subscriptionTrimmed ?? "",
                password: scalarString(proxy["password"])?.subscriptionTrimmed ?? "",
                cipher: scalarString(proxy["cipher"])?.subscriptionTrimmed ?? "",
                sni: scalarString(proxy["sni"])?.subscriptionTrimmed ?? "",
                serverName: scalarString(proxy["servername"])?.subscriptionTrimmed ?? "",
                network: scalarString(proxy["network"])?.subscriptionTrimmed ?? "",
                security: scalarString(proxy["security"])?.subscriptionTrimmed ?? "",
                countryCode: CountryFlagResolver.countryCode(from: name),
                available: PendingProtocolCapabilities.recognizes(type),
                collisionKey: try? OriginalProxyCanonicalization.digest(proxy)
            ),
            proxy: proxy
        )
    }

    private static func runtimeProxy(
        _ original: [String: YAMLValue],
        coreName: String,
        namesToCoreNames: [String: [String]]
    ) -> (proxy: [String: YAMLValue]?, issue: RuntimeProxyRecordIssue?) {
        var proxy = original
        proxy["name"] = .string(coreName)

        guard let reference = scalarString(proxy["dialer-proxy"])?
            .subscriptionTrimmed.subscriptionNilIfEmpty else {
            return (proxy, nil)
        }
        if Self.builtInProxyNames.contains(reference.uppercased()) {
            return (proxy, nil)
        }
        guard let candidates = namesToCoreNames[reference] else {
            return (nil, .unresolvedReference(field: "dialer-proxy"))
        }
        guard candidates.count == 1, let target = candidates.first else {
            return (nil, .ambiguousReference(field: "dialer-proxy"))
        }
        proxy["dialer-proxy"] = .string(target)
        return (proxy, nil)
    }

    private static func scalarString(_ value: YAMLValue?) -> String? {
        switch value {
        case let .string(text):
            text
        case let .bool(flag):
            flag ? "true" : "false"
        case let .integer(number):
            String(number)
        case let .double(number):
            String(number)
        default:
            nil
        }
    }

    private static func portValue(_ value: YAMLValue?) -> Int? {
        guard let text = scalarString(value)?.subscriptionTrimmed, !text.isEmpty else { return nil }
        let port: Int?
        if let integer = Int(text) {
            port = integer
        } else if let number = Double(text), number.rounded() == number {
            port = Int(exactly: number)
        } else {
            port = nil
        }
        guard let port, (1...65_535).contains(port) else { return nil }
        return port
    }

    private static let builtInProxyNames = Set([
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"
    ])

    private static let informationalNodeNamePrefixes = [
        "剩余流量",
        "距离下次重置剩余",
        "套餐到期"
    ]

    private struct Candidate {
        let source: NodeIdentitySource
        let proxy: [String: YAMLValue]
    }
}

private extension String {
    var subscriptionTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var subscriptionNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
