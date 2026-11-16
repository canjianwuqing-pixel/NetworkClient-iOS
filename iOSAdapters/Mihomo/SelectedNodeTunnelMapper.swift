import Darwin
import Foundation
import Yams

enum SelectedNodeTunnelError: Error, Equatable {
    case missingNode, unresolvedReference, unsupportedProtocol, unsupportedField, unsupportedValue
    case endpointRequiresIPv4, endpointResolutionFailed, unsupportedMode
}

#if ROUTE_VALIDATION
enum RouteValidationEndpointFailure: Error, Sendable {
    case invalidHostname
    case systemLookup(code: Int32, aaaaRecords: Int)
    case noPublicIPv4(EndpointLookupSummary)
    case timedOut
}

/// Counts only address classes; never retains or prints the node hostname or IP.
struct EndpointLookupSummary: Sendable {
    var aRecords = 0
    var aaaaRecords = 0
    var conversionFailures = 0
    var rejectedPrivate = 0
    var rejectedLoopback = 0
    var rejectedLinkLocal = 0
    var rejectedBenchmark = 0
    var rejectedShared = 0
    var rejectedDocumentation = 0
    var rejectedOther = 0

    mutating func recordRejected(_ value: String) {
        guard let octets = IPv4AddressValidator.octets(value) else {
            conversionFailures += 1
            return
        }
        let a = octets[0], b = octets[1], c = octets[2]
        switch (a, b, c) {
        case (10, _, _), (172, 16...31, _), (192, 168, _): rejectedPrivate += 1
        case (127, _, _): rejectedLoopback += 1
        case (169, 254, _): rejectedLinkLocal += 1
        case (198, 18...19, _): rejectedBenchmark += 1
        case (100, 64...127, _): rejectedShared += 1
        case (192, 0, 2), (198, 51, 100), (203, 0, 113): rejectedDocumentation += 1
        default: rejectedOther += 1
        }
    }

    var safeDescription: String {
        "a=\(aRecords),aaaa=\(aaaaRecords),conversion=\(conversionFailures)," +
        "private=\(rejectedPrivate),loopback=\(rejectedLoopback)," +
        "linkLocal=\(rejectedLinkLocal),benchmark=\(rejectedBenchmark)," +
        "shared=\(rejectedShared),documentation=\(rejectedDocumentation)," +
        "other=\(rejectedOther)"
    }
}

/// Isolated-device evidence only. The two fixed files contain counts and
/// failure categories, never a hostname, IP address, URL, or node secret.
private enum RouteValidationEndpointDiagnostic {
    static func system(_ stage: String, status: Int32 = 0,
                       summary: EndpointLookupSummary) {
        write("system", values: [
            "stage": stage, "lookupCode": status,
            "aRecords": summary.aRecords, "aaaaRecords": summary.aaaaRecords,
            "conversionFailures": summary.conversionFailures,
            "rejectedPrivate": summary.rejectedPrivate,
            "rejectedLoopback": summary.rejectedLoopback,
            "rejectedLinkLocal": summary.rejectedLinkLocal,
            "rejectedBenchmark": summary.rejectedBenchmark,
            "rejectedShared": summary.rejectedShared,
            "rejectedDocumentation": summary.rejectedDocumentation,
            "rejectedOther": summary.rejectedOther
        ])
    }

    static func doh(_ category: String) {
        write("doh", values: ["category": category])
    }

    private static func write(_ kind: String, values: [String: Any]) {
        guard let group = try? MihomoTunnelStore.appGroup(),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              ) else { return }
        let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record = values
        record["recordedAt"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(
            to: directory.appendingPathComponent("route-endpoint-\(kind).json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
#endif

/// Accepts only fields reviewed against the pinned Mihomo 1.19.33 outbound
/// options. A parsed subscription alone does not establish protocol support.
/// Core DNS is separate from the app's URLSession resolver, the pre-tunnel
/// endpoint lookup, and the system DNS configured on the Packet Tunnel.
/// Both servers are explicitly routed through the selected Core outbound;
/// an invalid remote value cannot replace the authenticated DoH fallback.
enum CoreDNSPolicy {
    static func nameservers(
        remoteIPv4: String?, fallbackDoH: URL, remoteValidated: Bool = false
    ) -> [String] {
        let fallback = fallbackDoH.absoluteString + "#VPN"
        guard remoteValidated, let remoteIPv4, IPv4AddressValidator.valid(remoteIPv4) else {
            return [fallback]
        }
        return [remoteIPv4 + "#VPN", fallback]
    }
}

struct SelectedNodeTunnelMapper {
    func makeConfiguration(
        subscription: ParsedSubscription, request: TunnelRequest, dnsEndpoint: URL,
        accountScope: String? = nil, resolvedServerIPv4: String? = nil,
        mihomoDns: String? = nil, remoteMihomoDNSValidated: Bool = false
    ) throws -> MihomoTunnelConfiguration {
        guard dnsEndpoint.scheme == "https", dnsEndpoint.user == nil,
              dnsEndpoint.password == nil, dnsEndpoint.query == nil,
              dnsEndpoint.fragment == nil,
              let dnsHost = dnsEndpoint.host, IPv4AddressValidator.valid(dnsHost),
              !dnsEndpoint.path.isEmpty else { throw SelectedNodeTunnelError.unsupportedValue }
        guard let record = subscription.runtimeProxyRecords[request.nodeID],
              let node = subscription.nodes.first(where: { $0.id == request.nodeID }) else {
            throw SelectedNodeTunnelError.missingNode
        }
        guard record.issue == nil, let runtime = record.runtimeProxy else {
            throw SelectedNodeTunnelError.unresolvedReference
        }
        let type = string(runtime["type"])?.lowercased() ?? ""
        let base: Set<String> = ["name", "type", "server", "port"]
        // These names come from the pinned Core's outbound Option structs.
        // A field absent from the reviewed set is rejected instead of being
        // silently ignored by Core's weakly typed YAML decoder.
        let tls: Set<String> = ["skip-cert-verify", "alpn", "client-fingerprint",
                                "name-cert-verify", "fingerprint", "certificate", "private-key"]
        let transport: Set<String> = ["network", "ws-opts", "grpc-opts", "http-opts", "h2-opts"]
        let allowed: Set<String>
        switch type {
        case "ss":
            allowed = base.union(["udp", "cipher", "password", "plugin", "plugin-opts",
                                  "udp-over-tcp", "udp-over-tcp-version", "client-fingerprint"])
            guard nonempty(runtime["cipher"]), nonempty(runtime["password"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validatePlugin(runtime)
            try validateBooleanOptions(runtime, keys: ["udp-over-tcp"])
            guard runtime["udp-over-tcp-version"] == nil ||
                    nonnegativeInteger(runtime["udp-over-tcp-version"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "vmess":
            allowed = base.union(tls).union(transport)
                .union(["udp", "uuid", "alterId", "cipher", "tls", "servername",
                        "packet-addr", "xudp", "packet-encoding", "global-padding",
                        "authenticated-length"])
            guard let uuid = string(runtime["uuid"]), UUID(uuidString: uuid) != nil else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            guard [nil, "auto", "aes-128-gcm", "chacha20-poly1305", "none"]
                .contains(string(runtime["cipher"])),
                runtime["alterId"] == nil || nonnegativeInteger(runtime["alterId"]),
                runtime["tls"] == nil || runtime["tls"] == .bool(true) || runtime["tls"] == .bool(false) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateTransport(runtime, supported: ["tcp", "ws", "grpc", "http", "h2"])
            try validatePacketEncoding(runtime)
        case "vless":
            allowed = base.union(tls).union(transport)
                .union(["udp", "uuid", "flow", "tls", "servername", "reality-opts", "encryption",
                        "packet-addr", "xudp", "packet-encoding"])
            guard let uuid = string(runtime["uuid"]), UUID(uuidString: uuid) != nil,
                  runtime["tls"] == .bool(true),
                  nonempty(runtime["servername"]),
                  [nil, "none"].contains(string(runtime["encryption"])) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateTransport(runtime, supported: ["tcp", "ws", "grpc", "http", "h2"])
            try validatePacketEncoding(runtime)
            if runtime["reality-opts"] != nil {
                guard [nil, "xtls-rprx-vision"].contains(string(runtime["flow"])),
                      [nil, "tcp"].contains(string(runtime["network"])),
                      nonempty(runtime["client-fingerprint"]) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
                try validateReality(runtime["reality-opts"])
            } else if runtime["flow"] != nil {
                guard string(runtime["flow"]) == "xtls-rprx-vision",
                      [nil, "tcp"].contains(string(runtime["network"])) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
        case "trojan":
            allowed = base.union(tls).union(["network", "ws-opts", "grpc-opts",
                                             "udp", "password", "sni", "ss-opts"])
            guard nonempty(runtime["password"]), nonempty(runtime["sni"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateTransport(runtime, supported: ["tcp", "ws", "grpc"])
            if let ss = runtime["ss-opts"] {
                guard case let .object(options) = ss,
                      Set(options.keys).isSubset(of: ["enabled", "method", "password"]),
                      options["enabled"] == nil || isBool(options["enabled"]),
                      options["enabled"] != .bool(true) ||
                        (nonempty(options["method"]) && nonempty(options["password"])) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
        case "hysteria2":
            allowed = base.union(tls.subtracting(["client-fingerprint"])).union(["udp", "password", "sni", "alpn", "ports",
                "hop-interval", "obfs", "obfs-password", "obfs-min-packet-size",
                "obfs-max-packet-size", "up", "down", "cwnd", "bbr-profile",
                "udp-mtu", "handshake-timeout", "initial-stream-receive-window",
                "max-stream-receive-window", "initial-connection-receive-window",
                "max-connection-receive-window"])
            // The pinned HY2 Core always enables UDP (UDP: true,
            // UDPDisabled: false). Preserve an affirmative compatibility flag;
            // reject false rather than pretend the Core can disable UDP.
            guard runtime["udp"] == nil || runtime["udp"] == .bool(true) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            guard nonempty(runtime["password"]), nonempty(runtime["sni"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            guard ["up", "down"].allSatisfy({ runtime[$0] == nil || nonempty(runtime[$0]) }) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            if let obfs = string(runtime["obfs"]) {
                guard ["salamander", "gecko"].contains(obfs), nonempty(runtime["obfs-password"]) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            } else if runtime["obfs-password"] != nil {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateNumericOptions(runtime, keys: ["obfs-min-packet-size",
                "obfs-max-packet-size", "cwnd", "udp-mtu", "handshake-timeout",
                "initial-stream-receive-window", "max-stream-receive-window",
                "initial-connection-receive-window", "max-connection-receive-window"])
            guard runtime["ports"] == nil || validPortRanges(runtime["ports"]),
                  runtime["hop-interval"] == nil || validHopInterval(runtime["hop-interval"]),
                  runtime["bbr-profile"] == nil || nonempty(runtime["bbr-profile"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "tuic":
            allowed = base.union(tls.subtracting(["client-fingerprint"])).union(["uuid", "password", "token", "sni", "alpn",
                "udp-relay-mode", "congestion-controller", "heartbeat-interval",
                "reduce-rtt", "request-timeout", "disable-sni", "fast-open",
                "max-open-streams", "cwnd", "bbr-profile", "recv-window-conn",
                "recv-window", "disable-mtu-discovery", "max-datagram-frame-size",
                "max-udp-relay-packet-size", "udp-over-stream", "udp-over-stream-version"])
            let token = nonempty(runtime["token"])
            let uuid = string(runtime["uuid"])
            guard nonempty(runtime["sni"]),
                  (token && runtime["uuid"] == nil && runtime["password"] == nil)
                    || (!token && uuid.flatMap(UUID.init(uuidString:)) != nil
                        && nonempty(runtime["password"])),
                  runtime["udp-relay-mode"] == nil ||
                    ["native", "quic"].contains(string(runtime["udp-relay-mode"]) ?? ""),
                  runtime["congestion-controller"] == nil || nonempty(runtime["congestion-controller"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateNumericOptions(runtime, keys: ["heartbeat-interval", "request-timeout",
                "max-open-streams", "cwnd", "recv-window-conn", "recv-window",
                "max-datagram-frame-size", "max-udp-relay-packet-size", "udp-over-stream-version"])
            try validateBooleanOptions(runtime, keys: ["reduce-rtt", "disable-sni",
                "fast-open", "disable-mtu-discovery", "udp-over-stream"])
        case "ssr":
            allowed = base.union(["udp", "password", "cipher", "obfs", "obfs-param",
                                  "protocol", "protocol-param"])
            guard ["password", "cipher", "obfs", "protocol"].allSatisfy({ nonempty(runtime[$0]) }) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "snell":
            allowed = base.union(["udp", "psk", "version", "reuse", "obfs-opts", "mode", "user-key"])
            guard nonempty(runtime["psk"]),
                  runtime["version"] == nil || nonnegativeInteger(runtime["version"]),
                  runtime["reuse"] == nil || isBool(runtime["reuse"]),
                  runtime["obfs-opts"] == nil || isObject(runtime["obfs-opts"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            if case let .object(options)? = runtime["obfs-opts"] {
                guard Set(options.keys).isSubset(of: ["mode", "host"]),
                      options["mode"] == nil || nonempty(options["mode"]),
                      options["host"] == nil || nonempty(options["host"]) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
        case "hysteria":
            allowed = base.union(tls.subtracting(["client-fingerprint"])).union(["ports", "protocol", "obfs-protocol", "up",
                "up-speed", "down", "down-speed", "auth", "auth-str", "obfs", "sni",
                "recv-window-conn", "recv-window", "disable-mtu-discovery",
                "fast-open", "hop-interval"])
            guard nonempty(runtime["sni"]),
                  nonempty(runtime["auth"]) || nonempty(runtime["auth-str"]),
                  nonempty(runtime["up"]) || positiveInteger(runtime["up-speed"]),
                  nonempty(runtime["down"]) || positiveInteger(runtime["down-speed"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateNumericOptions(runtime, keys: ["up-speed", "down-speed",
                "recv-window-conn", "recv-window", "hop-interval"])
            try validateBooleanOptions(runtime, keys: ["disable-mtu-discovery", "fast-open"])
        case "anytls":
            allowed = base.union(tls).union(["udp", "password", "sni", "client-metadata",
                "idle-session-check-interval", "idle-session-timeout", "min-idle-session",
                "disable-reuse"])
            guard nonempty(runtime["password"]), nonempty(runtime["sni"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateNumericOptions(runtime, keys: ["idle-session-check-interval",
                "idle-session-timeout", "min-idle-session"])
            try validateBooleanOptions(runtime, keys: ["disable-reuse"])
        case "socks5", "http":
            let certificateFields: Set<String> = ["skip-cert-verify", "name-cert-verify",
                                                   "fingerprint", "certificate", "private-key"]
            allowed = base.union(certificateFields).union(["username", "password", "tls"])
                .union(type == "socks5" ? ["udp"] : ["sni", "headers"])
            // Credentials must never be sent to a plaintext proxy.
            guard runtime["tls"] == .bool(true),
                  runtime["username"] == nil || nonempty(runtime["username"]),
                  runtime["password"] == nil || nonempty(runtime["password"]),
                  runtime["sni"] == nil || validServerName(runtime["sni"] ?? .null) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            if let headers = runtime["headers"] {
                guard type == "http", case let .object(values) = headers,
                      values.allSatisfy({ !$0.key.isEmpty && nonempty($0.value) }) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
        case "ssh":
            allowed = base.union(["username", "password", "host-key", "host-key-algorithms"])
            guard nonempty(runtime["username"]), stringArray(runtime["host-key"]),
                  nonempty(runtime["password"]),
                  runtime["host-key-algorithms"] == nil || stringArray(runtime["host-key-algorithms"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "shadowquic":
            allowed = base.union(["username", "password", "sni", "alpn", "quic-versions",
                "udp-over-stream", "zero-rtt", "keep-alive-interval", "congestion-controller",
                "up", "down", "cwnd", "bbr-profile", "recv-window-conn", "recv-window",
                "disable-mtu-discovery", "max-datagram-frame-size", "max-open-streams"])
            guard nonempty(runtime["password"]), nonempty(runtime["sni"]),
                  runtime["quic-versions"] == nil || stringArray(runtime["quic-versions"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateBooleanOptions(runtime, keys: ["udp-over-stream", "zero-rtt",
                                                       "disable-mtu-discovery"])
            try validateNumericOptions(runtime, keys: ["keep-alive-interval", "cwnd",
                "recv-window-conn", "recv-window", "max-datagram-frame-size", "max-open-streams"])
        case "gost-relay":
            // The pinned Core constructs this relay with its own scoped
            // dialer. Require authenticated TLS; forwarding and unreviewed
            // client certificate paths remain unsupported.
            allowed = base.union(["tls", "sni", "username", "password", "udp", "mux",
                                  "client-fingerprint", "name-cert-verify"])
            guard runtime["tls"] == .bool(true), nonempty(runtime["sni"]),
                  nonempty(runtime["username"]), nonempty(runtime["password"]),
                  runtime["udp"] == nil || runtime["udp"] == .bool(false),
                  runtime["client-fingerprint"] == nil || nonempty(runtime["client-fingerprint"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateBooleanOptions(runtime, keys: ["udp", "mux"])
        case "trusttunnel":
            // Only the TCP/TLS pool is reviewed. QUIC, ECH, client keys and
            // eager health checks require separate physical-path evidence.
            allowed = base.union(["username", "password", "sni", "alpn", "udp",
                                  "client-fingerprint", "name-cert-verify", "fingerprint"])
            guard nonempty(runtime["username"]), nonempty(runtime["password"]),
                  nonempty(runtime["sni"]),
                  runtime["udp"] == nil || runtime["udp"] == .bool(false),
                  runtime["client-fingerprint"] == nil || nonempty(runtime["client-fingerprint"]),
                  runtime["fingerprint"] == nil || nonempty(runtime["fingerprint"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "mieru":
            // The fixed Core injects its scoped Dialer and PacketDialer into
            // Mieru. Start with a single TCP endpoint; UDP transport and port
            // hopping are intentionally excluded pending device validation.
            allowed = base.union(["transport", "username", "password", "udp"])
            guard string(runtime["transport"]) == "TCP",
                  runtime["udp"] == nil || runtime["udp"] == .bool(false),
                  nonempty(runtime["username"]), nonempty(runtime["password"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        case "sudoku":
            // The basic encrypted TCP tunnel uses the fixed Core dialer.
            // HTTP masking and custom table options need separate review.
            allowed = base.union(["key"])
            guard nonempty(runtime["key"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        default:
            throw SelectedNodeTunnelError.unsupportedProtocol
        }
        guard Set(runtime.keys).isSubset(of: allowed) else { throw SelectedNodeTunnelError.unsupportedField }
        guard runtime["skip-cert-verify"] == nil || runtime["skip-cert-verify"] == .bool(false),
              runtime["alpn"] == nil || stringArray(runtime["alpn"]),
              runtime["udp"] == nil || isBool(runtime["udp"]),
              (runtime["certificate"] == nil) == (runtime["private-key"] == nil),
              !["servername", "sni"].contains(where: {
                  guard let value = runtime[$0] else { return false }
                  return !validServerName(value)
              }),
              runtime["name-cert-verify"] == nil ||
                validServerName(runtime["name-cert-verify"] ?? .null) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        guard let serverIPv4 = IPv4AddressValidator.valid(node.server) ? node.server : resolvedServerIPv4,
              IPv4AddressValidator.valid(serverIPv4) else {
            // Resolve before tunnel startup so the outbound exactly matches
            // the NETunnelProviderProtocol.serverAddress pinned by the app.
            // Network Extension then owns the server-route exception while
            // Swift remains out of Core's public-socket egress policy.
            throw SelectedNodeTunnelError.endpointRequiresIPv4
        }
        guard string(runtime["server"]) == node.server else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        var proxy = runtime.mapValues(\.foundationValue)
        proxy["server"] = serverIPv4
        // Core switches modes in place. Keep the complete rule table loaded
        // even while global mode bypasses it, so a subsequent switch to rule
        // mode can take effect without reloading or restarting the tunnel.
        let rules = [
            "DOMAIN-SUFFIX,local,DIRECT",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
            "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
            "GEOSITE,cn,DIRECT",
            "GEOIP,CN,DIRECT",
            "MATCH,VPN",
        ]
        let yamlRoot: [String: Any] = [
            "mode": request.mode.rawValue, "log-level": "error", "ipv6": true,
            "geodata-mode": false, "geodata-loader": "memconservative",
            "tun": ["enable": true, "stack": "gvisor", "auto-route": true,
                    "auto-detect-interface": false, "strict-route": true, "mtu": 1500,
                    "inet4-address": ["198.18.0.1/30"],
                    "inet6-address": ["fdfe:dcba:9876::1/126"],
                    "dns-hijack": ["any:53"]] as [String: Any],
            "dns": ["enable": true, "ipv6": true, "enhanced-mode": "fake-ip",
                    "fake-ip-range": "198.18.0.1/16",
                    "nameserver": CoreDNSPolicy.nameservers(
                        remoteIPv4: mihomoDns, fallbackDoH: dnsEndpoint,
                        remoteValidated: remoteMihomoDNSValidated
                    )] as [String: Any],
            "proxies": [proxy],
            // The file provider is intentionally absent from every routing
            // group. Its outbounds are available only to named URLTest calls.
            "proxy-providers": ["NetworkClientLatencyCandidates": [
                "type": "file", "path": "latency-candidates.yaml",
            ]],
            "proxy-groups": [["name": "VPN", "type": "select",
                              "proxies": [record.coreName]]],
            "rules": rules,
        ]
        return MihomoTunnelConfiguration(
            generation: UUID(), nodeID: node.id, serverIPv4: serverIPv4,
            yaml: try Yams.dump(object: yamlRoot, sortKeys: true), createdAt: Date(),
            accountScope: accountScope, coreName: record.coreName,
            configurationRevision: request.configurationRevision,
            mode: request.mode.rawValue
        )
    }

    private func string(_ value: YAMLValue?) -> String? {
        if case let .string(text)? = value { return text }
        return nil
    }

    private func nonempty(_ value: YAMLValue?) -> Bool {
        guard let value = string(value) else { return false }
        return !value.isEmpty && value.count <= 1024
    }

    private func nonnegativeInteger(_ value: YAMLValue?) -> Bool {
        if case let .integer(number)? = value { return (0...65535).contains(number) }
        return false
    }

    private func positiveInteger(_ value: YAMLValue?) -> Bool {
        if case let .integer(number)? = value { return number > 0 && number <= Int64(Int32.max) }
        return false
    }

    private func boundedInteger(_ value: YAMLValue?) -> Bool {
        if case let .integer(number)? = value { return number >= 0 && number <= Int64(Int32.max) }
        return false
    }

    private func isBool(_ value: YAMLValue?) -> Bool {
        if case .bool? = value { return true }
        return false
    }

    private func isObject(_ value: YAMLValue?) -> Bool {
        if case .object? = value { return true }
        return false
    }

    private func validateNumericOptions(_ proxy: [String: YAMLValue], keys: [String]) throws {
        guard keys.allSatisfy({ proxy[$0] == nil || boundedInteger(proxy[$0]) }) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
    }

    private func validateBooleanOptions(_ proxy: [String: YAMLValue], keys: [String]) throws {
        guard keys.allSatisfy({ proxy[$0] == nil || isBool(proxy[$0]) }) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
    }

    private func validPortRanges(_ value: YAMLValue?) -> Bool {
        guard let raw = string(value), !raw.isEmpty else { return false }
        var count = 0
        for component in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = component.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let start = Int(bounds[0]), (1...65_535).contains(start),
                  let end = Int(bounds.last ?? ""), (start...65_535).contains(end) else { return false }
            count += end - start + 1
            if count > 128 { return false }
        }
        return count > 0
    }

    private func validHopInterval(_ value: YAMLValue?) -> Bool {
        let raw: String?
        if case let .integer(number)? = value { raw = String(number) }
        else { raw = string(value) }
        guard let raw, !raw.isEmpty else { return false }
        let bounds = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(bounds.count),
              let start = Int(bounds[0]), (0...3_600).contains(start),
              let end = Int(bounds.last ?? ""), (start...3_600).contains(end) else { return false }
        return true
    }

    private func validatePacketEncoding(_ proxy: [String: YAMLValue]) throws {
        try validateBooleanOptions(proxy, keys: ["packet-addr", "xudp",
                                                "global-padding", "authenticated-length"])
        guard proxy["packet-encoding"] == nil ||
                ["packetaddr", "packet", "xudp"].contains(string(proxy["packet-encoding"]) ?? "") else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
    }

    private func validatePlugin(_ proxy: [String: YAMLValue]) throws {
        guard let plugin = proxy["plugin"] else {
            guard proxy["plugin-opts"] == nil else { throw SelectedNodeTunnelError.unsupportedValue }
            return
        }
        guard let name = string(plugin), ["obfs", "v2ray-plugin"].contains(name),
              case let .object(options)? = proxy["plugin-opts"],
              Set(options.keys).isSubset(of: ["mode", "host", "path", "tls", "headers",
                                              "skip-cert-verify", "mux"]),
              nonempty(options["mode"]),
              (name != "obfs" || ["http", "tls"].contains(string(options["mode"]) ?? "")),
              (name != "v2ray-plugin" || string(options["mode"]) == "websocket"),
              options["skip-cert-verify"] == nil || options["skip-cert-verify"] == .bool(false) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        try validateBooleanOptions(options, keys: ["tls", "mux"])
        if let headers = options["headers"] {
            guard case let .object(values) = headers,
                  values.allSatisfy({ !$0.key.isEmpty && nonempty($0.value) }) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        }
        guard options["host"] == nil || nonempty(options["host"]),
              options["path"] == nil || nonempty(options["path"]) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
    }

    private func validServerName(_ value: YAMLValue) -> Bool {
        guard case let .string(name) = value else { return false }
        return !name.isEmpty && name.count <= 253 && !name.contains("/") && !name.contains("#")
    }

    private func stringArray(_ value: YAMLValue?) -> Bool {
        guard case let .array(items)? = value else { return false }
        return !items.isEmpty && items.allSatisfy { item in
            if case let .string(text) = item { return !text.isEmpty && text.count <= 255 }
            return false
        }
    }

    private func validateTransport(_ proxy: [String: YAMLValue], supported: Set<String>) throws {
        let network = string(proxy["network"]) ?? "tcp"
        guard supported.contains(network) else { throw SelectedNodeTunnelError.unsupportedValue }
        // The pinned Core accepts WebSocket with its default options. Options
        // for another transport must still be rejected instead of discarded.
        guard network == "ws" || proxy["ws-opts"] == nil else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        guard network == "grpc" || proxy["grpc-opts"] == nil,
              network == "http" || proxy["http-opts"] == nil,
              network == "h2" || proxy["h2-opts"] == nil else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        if let ws = proxy["ws-opts"] {
            guard network == "ws", case let .object(options) = ws,
                  Set(options.keys).isSubset(of: ["path", "headers", "max-early-data",
                                                 "early-data-header-name", "v2ray-http-upgrade",
                                                 "v2ray-http-upgrade-fast-open"]),
                  options["path"] == nil || nonempty(options["path"]),
                  options["max-early-data"] == nil || nonnegativeInteger(options["max-early-data"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateBooleanOptions(options, keys: ["v2ray-http-upgrade",
                                                        "v2ray-http-upgrade-fast-open"])
            if let headers = options["headers"] {
                guard case let .object(values) = headers,
                      values.allSatisfy({ !$0.key.isEmpty && nonempty($0.value) }) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
            if let header = options["early-data-header-name"], !nonempty(header) {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        }
        if let grpc = proxy["grpc-opts"] {
            guard network == "grpc", case let .object(options) = grpc,
                  Set(options.keys).isSubset(of: ["grpc-service-name", "grpc-user-agent",
                                                 "ping-interval", "max-connections",
                                                 "min-streams", "max-streams"]),
                  options["grpc-service-name"] == nil || nonempty(options["grpc-service-name"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            try validateNumericOptions(options, keys: ["ping-interval", "max-connections",
                                                      "min-streams", "max-streams"])
            guard options["grpc-user-agent"] == nil || nonempty(options["grpc-user-agent"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        }
        if let http = proxy["http-opts"] {
            guard network == "http", case let .object(options) = http,
                  Set(options.keys).isSubset(of: ["method", "path", "headers"]),
                  options["method"] == nil || nonempty(options["method"]),
                  options["path"] == nil || stringArray(options["path"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            if let headers = options["headers"] {
                guard case let .object(values) = headers,
                      values.allSatisfy({ !$0.key.isEmpty && stringArray($0.value) }) else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
            }
        }
        if let h2 = proxy["h2-opts"] {
            guard network == "h2", case let .object(options) = h2,
                  Set(options.keys).isSubset(of: ["host", "path"]),
                  options["host"] == nil || stringArray(options["host"]),
                  options["path"] == nil || nonempty(options["path"]) else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
        }
    }

    private func validateReality(_ value: YAMLValue?) throws {
        guard case let .object(reality)? = value,
              Set(reality.keys).isSubset(of: ["public-key", "short-id",
                                               "support-x25519mlkem768"]),
              let publicKey = string(reality["public-key"]), validRealityPublicKey(publicKey),
              let shortID = string(reality["short-id"]),
              shortID.count <= 16, shortID.count.isMultiple(of: 2),
              shortID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              reality["support-x25519mlkem768"] == nil ||
                isBool(reality["support-x25519mlkem768"]) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
    }

    private func validRealityPublicKey(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: padded)?.count == 32
    }
}

/// Reuses the fully reviewed, pinned outbound from the tunnel mapper while
/// removing TUN and system DNS listeners. URLTest targets its exact Core name.
enum MihomoNodeProbeConfiguration {
    static func yaml(from tunnelYAML: String) throws -> String {
        guard var root = try Yams.load(yaml: tunnelYAML) as? [String: Any],
              let proxies = root["proxies"] as? [[String: Any]], !proxies.isEmpty,
              let groups = root["proxy-groups"] as? [[String: Any]], groups.count == 1,
              groups[0]["name"] as? String == "VPN",
              let selected = groups[0]["proxies"] as? [String], selected.count == 1,
              proxies.contains(where: { $0["name"] as? String == selected[0] }) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        root["tun"] = ["enable": false]
        root["dns"] = ["enable": false]
        root.removeValue(forKey: "proxy-providers")
        root["rules"] = ["MATCH,VPN"]
        root["mode"] = "rule"
        return try Yams.dump(object: root, sortKeys: true)
    }

    /// Combine individually validated, non-TUN probe configurations into one
    /// Core service. The global SDK permits only one app-owned service; every
    /// named outbound remains independent and no VPN selector is changed.
    static func batchYAML(from candidates: [NodeProbeCandidate]) throws -> String {
        guard let first = candidates.first,
              var root = try Yams.load(yaml: first.yaml) as? [String: Any] else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        var proxies: [[String: Any]] = []
        var definitions: [String: String] = [:]
        var selectedNames = Set<String>()
        for candidate in candidates {
            guard let candidateRoot = try Yams.load(yaml: candidate.yaml) as? [String: Any],
                  let candidateProxies = candidateRoot["proxies"] as? [[String: Any]],
                  !candidateProxies.isEmpty,
                  let groups = candidateRoot["proxy-groups"] as? [[String: Any]],
                  groups.count == 1,
                  groups[0]["name"] as? String == "VPN",
                  let selected = groups[0]["proxies"] as? [String],
                  selected == [candidate.coreName],
                  selectedNames.insert(candidate.coreName).inserted,
                  candidateProxies.contains(where: {
                      $0["name"] as? String == candidate.coreName
                  }),
                  let tun = candidateRoot["tun"] as? [String: Any],
                  tun["enable"] as? Bool == false,
                  let dns = candidateRoot["dns"] as? [String: Any],
                  dns["enable"] as? Bool == false else {
                throw SelectedNodeTunnelError.unsupportedValue
            }
            for proxy in candidateProxies {
                guard let name = proxy["name"] as? String, !name.isEmpty else {
                    throw SelectedNodeTunnelError.unsupportedValue
                }
                let definition = try Yams.dump(object: proxy, sortKeys: true)
                if let existing = definitions[name] {
                    guard existing == definition else {
                        throw SelectedNodeTunnelError.unsupportedValue
                    }
                } else {
                    definitions[name] = definition
                    proxies.append(proxy)
                }
            }
        }
        root["proxies"] = proxies
        root["proxy-groups"] = [[
            "name": "VPN", "type": "select",
            "proxies": candidates.map(\.coreName)
        ]]
        return try Yams.dump(object: root, sortKeys: true)
    }
}

/// Resolve the selected hostname while the system tunnel is still down.
/// The resulting IPv4 address is placed both in Mihomo's selected outbound
/// and in the NE /32 exclusion, so Core never re-resolves into its own route.
/// The blocking libc lookup runs off the main actor; its result is delivered
/// once, with a bound even if the OS lookup cannot be cancelled immediately.
struct SelectedNodeEndpointResolver: Sendable {
    static func firstPublicIPv4(in addresses: [String]) -> String? {
        addresses.first(where: IPv4AddressValidator.publicUnicast)
    }

    /// Both lookups are read-only and bounded by their callers. In particular,
    /// an unsafe system answer never becomes the NE exception or Core outbound.
    static func resolvePublicIPv4(
        system: @Sendable () async throws -> String,
        configuredDoH: @Sendable () async throws -> String
    ) async throws -> String {
        do {
            let answer = try await system()
            try Task.checkCancellation()
            if IPv4AddressValidator.publicUnicast(answer) { return answer }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The configured authenticated DoH path is the only fallback.
        }
        try Task.checkCancellation()
        let answer = try await configuredDoH()
        try Task.checkCancellation()
        guard IPv4AddressValidator.publicUnicast(answer) else {
            throw SelectedNodeTunnelError.endpointResolutionFailed
        }
        #if ROUTE_VALIDATION
        SafeLog.info("[VPN] stage=configured-doh-endpoint-accepted")
        RouteValidationEndpointDiagnostic.doh("accepted")
        #endif
        return answer
    }

    /// This authenticated DNS-over-HTTPS request works before tunnel startup
    /// or through an already-connected tunnel during node replacement. Its
    /// configured numeric host cannot recursively depend on the proxy name.
    /// Never fall back to plaintext or an unbound proxy socket on failure.
    func resolveUsingConfiguredDoH(_ hostname: String, endpoint: URL) async throws -> String {
        guard endpoint.scheme == "https", endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil,
              endpoint.fragment == nil, let host = endpoint.host,
              IPv4AddressValidator.valid(host), !endpoint.path.isEmpty else {
            #if ROUTE_VALIDATION
            SafeLog.warning("[VPN] stage=configured-doh-failed category=configuration")
            RouteValidationEndpointDiagnostic.doh("configuration")
            #endif
            throw SelectedNodeTunnelError.endpointResolutionFailed
        }
        let identifier = UInt16.random(in: .min ... .max)
        let query = try DNSIPv4Message.query(hostname, identifier: identifier)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 4
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, http.url == endpoint,
                  http.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased().hasPrefix("application/dns-message") == true else {
                #if ROUTE_VALIDATION
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                SafeLog.warning("[VPN] stage=configured-doh-failed category=http status=\(status)")
                RouteValidationEndpointDiagnostic.doh("http-\(status)")
                #endif
                throw SelectedNodeTunnelError.endpointResolutionFailed
            }
            do {
                return try DNSIPv4Message.answer(data, identifier: identifier, hostname: hostname)
            } catch {
                #if ROUTE_VALIDATION
                SafeLog.warning("[VPN] stage=configured-doh-failed category=dns-answer")
                RouteValidationEndpointDiagnostic.doh("dns-answer")
                #endif
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #if ROUTE_VALIDATION
            if let urlError = error as? URLError {
                let category: String
                switch urlError.code {
                case .timedOut: category = "timeout"
                case .cannotFindHost, .dnsLookupFailed: category = "dns"
                case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                    category = "network"
                case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                    category = "tls"
                default: category = "transport"
                }
                SafeLog.warning("[VPN] stage=configured-doh-failed category=\(category)")
                RouteValidationEndpointDiagnostic.doh(category)
            } else {
                RouteValidationEndpointDiagnostic.doh("transport-or-response")
            }
            #endif
            throw SelectedNodeTunnelError.endpointResolutionFailed
        }
    }

    func resolve(_ hostname: String) async throws -> String {
        guard hostname.count <= 253, !hostname.isEmpty,
              hostname.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0)
                  || (65...90).contains($0) || (97...122).contains($0) }),
              !hostname.hasPrefix("."), !hostname.hasSuffix(".") else {
            #if ROUTE_VALIDATION
            throw RouteValidationEndpointFailure.invalidHostname
            #else
            throw SelectedNodeTunnelError.endpointResolutionFailed
            #endif
        }
        let reply = ResolutionReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    reply.finish(Self.resolveBlocking(hostname))
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(4))
                    #if ROUTE_VALIDATION
                    reply.finish(.failure(RouteValidationEndpointFailure.timedOut))
                    #else
                    reply.finish(.failure(SelectedNodeTunnelError.endpointResolutionFailed))
                    #endif
                }
            }
        } onCancel: {
            reply.finish(.failure(CancellationError()))
        }
    }

    private static func resolveBlocking(_ hostname: String) -> Result<String, Error> {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var first: UnsafeMutablePointer<addrinfo>?
        let status = hostname.withCString { getaddrinfo($0, nil, &hints, &first) }
        guard status == 0, let first else {
            #if ROUTE_VALIDATION
            let aaaaRecords = ipv6RecordCount(hostname)
            SafeLog.warning("[VPN] stage=endpoint-system-lookup code=\(status) aaaa=\(aaaaRecords)")
            var summary = EndpointLookupSummary()
            summary.aaaaRecords = aaaaRecords
            RouteValidationEndpointDiagnostic.system("lookup-failed", status: status,
                                                     summary: summary)
            return .failure(RouteValidationEndpointFailure.systemLookup(
                code: status, aaaaRecords: aaaaRecords
            ))
            #else
            return .failure(SelectedNodeTunnelError.endpointResolutionFailed)
            #endif
        }
        defer { freeaddrinfo(first) }
        #if ROUTE_VALIDATION
        var summary = EndpointLookupSummary()
        #endif
        var addresses: [String] = []
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let item = candidate {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let outcome = getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen,
                                      &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if outcome == 0 {
                let value = String(decoding: buffer.prefix(while: { $0 != 0 })
                    .map { UInt8(bitPattern: $0) }, as: UTF8.self)
                #if ROUTE_VALIDATION
                summary.aRecords += 1
                #endif
                addresses.append(value)
                #if ROUTE_VALIDATION
                if !IPv4AddressValidator.publicUnicast(value) {
                    summary.recordRejected(value)
                }
                #endif
            } else {
                #if ROUTE_VALIDATION
                summary.conversionFailures += 1
                #endif
            }
            candidate = item.pointee.ai_next
        }
        if let selected = firstPublicIPv4(in: addresses) {
            #if ROUTE_VALIDATION
            RouteValidationEndpointDiagnostic.system("public-ipv4", summary: summary)
            #endif
            return .success(selected)
        }
        #if ROUTE_VALIDATION
        // AF_INET is the production lookup. This diagnostic-only second lookup
        // distinguishes an IPv6-only answer without changing the selected route.
        summary.aaaaRecords = ipv6RecordCount(hostname)
        SafeLog.warning("[VPN] stage=endpoint-no-public-ipv4 \(summary.safeDescription)")
        RouteValidationEndpointDiagnostic.system("no-public-ipv4", summary: summary)
        return .failure(RouteValidationEndpointFailure.noPublicIPv4(summary))
        #else
        return .failure(SelectedNodeTunnelError.endpointResolutionFailed)
        #endif
    }

    #if ROUTE_VALIDATION
    private static func ipv6RecordCount(_ hostname: String) -> Int {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var first: UnsafeMutablePointer<addrinfo>?
        guard hostname.withCString({ getaddrinfo($0, nil, &hints, &first) }) == 0 else {
            if let first { freeaddrinfo(first) }
            return 0
        }
        defer { if let first { freeaddrinfo(first) } }
        var count = 0
        var current = first
        while let item = current {
            if item.pointee.ai_family == AF_INET6 { count += 1 }
            current = item.pointee.ai_next
        }
        return count
    }
    #endif
}

private final class ResolutionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func install(_ value: CheckedContinuation<String, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            value.resume(with: result)
        } else {
            continuation = value
            lock.unlock()
        }
    }

    func finish(_ value: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
}

/// Minimal RFC 1035 A response codec for the configured numeric-host DoH
/// endpoint. Only an answer for the requested name (or its CNAME chain) may
/// become a physical proxy endpoint; malformed or private answers fail closed.
enum DNSIPv4Message {
    static func query(_ hostname: String, identifier: UInt16) throws -> Data {
        let name = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) &&
                  label.utf8.allSatisfy { byte in
                      (45...45).contains(byte) || (48...57).contains(byte) ||
                      (65...90).contains(byte) || (97...122).contains(byte)
                  }
              }) else { throw SelectedNodeTunnelError.endpointResolutionFailed }
        var bytes: [UInt8] = [UInt8(identifier >> 8), UInt8(identifier & 0xff),
                              0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in labels {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0, 0, 1, 0, 1]) // root, A, IN
        return Data(bytes)
    }

    static func answer(_ data: Data, identifier: UInt16, hostname: String) throws -> String {
        let bytes = Array(data)
        guard (12...4096).contains(bytes.count) else { throw failure }
        func word(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= bytes.count - 2 else { throw failure }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        let flags = try word(2)
        let questionCount = try word(4)
        let answerCount = try word(6)
        guard try word(0) == identifier, flags & 0x8000 != 0,
              flags & 0x7a0f == 0, questionCount == 1,
              answerCount > 0, answerCount <= 64 else { throw failure }
        var offset = 12
        let question = try readName(bytes, offset: &offset)
        let questionType = try word(offset)
        let questionClass = try word(offset + 2)
        guard question == hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              questionType == 1, questionClass == 1 else { throw failure }
        offset += 4
        var addresses: [String: String] = [:]
        var aliases: [String: String] = [:]
        for _ in 0..<Int(answerCount) {
            let owner = try readName(bytes, offset: &offset)
            let kind = try word(offset)
            let dnsClass = try word(offset + 2)
            guard offset <= bytes.count - 10 else { throw failure }
            let ttl = UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16 |
                      UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
            let length = Int(try word(offset + 8))
            offset += 10
            guard length <= bytes.count - offset else { throw failure }
            if dnsClass == 1 && ttl > 0 {
                if kind == 1 && length == 4 {
                    let address = bytes[offset..<(offset + 4)].map(String.init).joined(separator: ".")
                    if IPv4AddressValidator.publicUnicast(address) { addresses[owner] = address }
                } else if kind == 5 {
                    var cursor = offset
                    let alias = try readName(bytes, offset: &cursor)
                    guard cursor <= offset + length else { throw failure }
                    aliases[owner] = alias
                }
            }
            offset += length
        }
        var owner = question
        var visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(owner).inserted else { throw failure }
            if let address = addresses[owner] { return address }
            guard let next = aliases[owner] else { break }
            owner = next
        }
        throw failure
    }

    private static var failure: SelectedNodeTunnelError { .endpointResolutionFailed }

    private static func readName(_ bytes: [UInt8], offset: inout Int) throws -> String {
        var cursor = offset
        var jumped = false
        var visited = Set<Int>()
        var labels: [String] = []
        for _ in 0..<32 {
            guard cursor < bytes.count, visited.insert(cursor).inserted else { throw failure }
            let length = Int(bytes[cursor])
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { throw failure }
                let pointer = (length & 0x3f) << 8 | Int(bytes[cursor + 1])
                guard pointer < bytes.count else { throw failure }
                if !jumped { offset = cursor + 2; jumped = true }
                cursor = pointer
            } else if length == 0 {
                if !jumped { offset = cursor + 1 }
                return labels.joined(separator: ".")
            } else {
                guard length <= 63, cursor + 1 + length <= bytes.count else { throw failure }
                let slice = bytes[(cursor + 1)..<(cursor + 1 + length)]
                guard slice.allSatisfy({ (45...45).contains($0) || (48...57).contains($0) ||
                                           (65...90).contains($0) || (97...122).contains($0) }),
                      let label = String(bytes: slice, encoding: .ascii) else { throw failure }
                labels.append(label.lowercased())
                cursor += 1 + length
                if !jumped { offset = cursor }
            }
        }
        throw failure
    }
}
