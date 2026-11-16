import XCTest
#if !NETWORKCLIENT_ROUTE_CONTRACT_TESTS
import Clash
import Yams
import UIKit
@testable import NetworkClient

private let subscriptionRecoveryCandidate = "ss://"
    + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
    + "@198.51.100.20:443"
#endif

final class SubscriptionTests: XCTestCase {
    #if !NETWORKCLIENT_ROUTE_CONTRACT_TESTS
    func testCountryFlagsRecognizeCodesNamesAndRegionalEmoji() {
        for (name, code, emoji) in [
            ("TW 01", "TW", "🇹🇼"), ("Taiwan 01", "TW", "🇹🇼"),
            ("台湾 01", "TW", "🇹🇼"), ("台灣 01", "TW", "🇹🇼"),
            ("臺灣 01", "TW", "🇹🇼"), ("🇹🇼 01", "TW", "🇹🇼"),
            ("JP Japan 日本", "JP", "🇯🇵"), ("USA United States 美国", "US", "🇺🇸"),
            ("HK Hong Kong 香港", "HK", "🇭🇰"),
            ("SG Singapore 新加坡", "SG", "🇸🇬"),
            ("KR Korea 韩国", "KR", "🇰🇷"),
            ("VN Vietnam 越南", "VN", "🇻🇳"),
            ("UK United Kingdom 英国", "GB", "🇬🇧")
        ] {
            XCTAssertEqual(CountryFlagResolver.countryCode(from: name), code, name)
            XCTAssertEqual(CountryFlagResolver.flagEmoji(countryCode: nil, nodeName: name), emoji)
        }
        XCTAssertEqual(CountryFlagResolver.flagEmoji(
            countryCode: "CA", nodeName: "unmapped"
        ), "🇨🇦")
        XCTAssertEqual(CountryFlagResolver.flagEmoji(
            countryCode: nil, nodeName: "unmapped"
        ), "🌐")
        XCTAssertNil(CountryFlagResolver.countryCode(from: "RUST INTEGRATION TWIN"))
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            let isFlagCode = code.unicodeScalars.count == 2 &&
                code.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
            if isFlagCode {
                XCTAssertNotEqual(CountryFlagResolver.flagEmoji(
                    countryCode: code, nodeName: "unmapped"
                ), "🌐", code)
            } else {
                XCTAssertEqual(CountryFlagResolver.flagEmoji(
                    countryCode: code, nodeName: "unmapped"
                ), "🌐", code)
            }
        }
    }

    func testTaiwanFlagUsesBundledImageEvenWhenCachedCodeDisagrees() throws {
        for name in ["TW", "tw", "Taiwan", "台湾", "台灣", "臺灣", "🇹🇼"] {
            XCTAssertEqual(CountryFlagResolver.resolvedCode(
                countryCode: "US", nodeName: "\(name) 01"
            ), "TW", name)
            XCTAssertEqual(CountryFlagResolver.visual(
                countryCode: "US", nodeName: "\(name) 01"
            ), .taiwanImage, name)
        }
        XCTAssertNotNil(UIImage(named: "TaiwanFlag"))
        XCTAssertEqual(CountryFlagResolver.visual(
            countryCode: "JP", nodeName: "Japan 01"
        ), .emoji("🇯🇵"))
        XCTAssertEqual(CountryFlagResolver.visual(
            countryCode: nil, nodeName: "unmapped"
        ), .emoji("🌐"))
    }

    func testSystemRegionNamesAndAliasesResolveIndependentlyOfEmojiGeneration() {
        let locales = [Locale(identifier: "en_US"), Locale(identifier: "zh_Hans_CN"),
                       Locale(identifier: "zh_Hant_TW")]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.unicodeScalars.count == 2,
                  code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else { continue }
            XCTAssertNotEqual(CountryFlagResolver.flagEmoji(
                countryCode: code, nodeName: "unmapped"
            ), "🌐", code)
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: code),
                      name.caseInsensitiveCompare(code) != .orderedSame else { continue }
                XCTAssertEqual(CountryFlagResolver.countryCode(from: name), code,
                               "\(locale.identifier): \(name)")
            }
        }
        for (name, code) in [
            ("UK-01", "GB"), ("USA_02", "US"), ("Viet Nam 01", "VN"),
            ("Czech Republic-01", "CZ"), ("香港-01", "HK"),
            ("🇸🇬-Singapore 01", "SG")
        ] {
            XCTAssertEqual(CountryFlagResolver.countryCode(from: name), code, name)
        }
        XCTAssertNil(CountryFlagResolver.countryCode(from: "RUST INTEGRATION TWIN"))
        XCTAssertEqual(CountryFlagResolver.resolvedCode(
            countryCode: "US", nodeName: "🇯🇵 Japan 01"
        ), "JP")
    }
    func testNodeLatencyUsesMacOSTargetAndBatchKeepsNamedOutboundsWithoutTun() throws {
        XCTAssertEqual(NodeLatencyTarget.url, "https://latency.example.invalid/generate_204")
        func candidate(_ name: String) -> NodeProbeCandidate {
            let yaml = """
            mode: rule
            tun: {enable: false}
            dns: {enable: false}
            proxies:
              - {name: \(name), type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: fixture}
            proxy-groups:
              - {name: VPN, type: select, proxies: [\(name)]}
            rules: ["MATCH,VPN"]
            """
            return NodeProbeCandidate(nodeID: name, revision: "revision",
                                      coreName: name, yaml: yaml)
        }
        let first = candidate("node-one")
        let second = candidate("node-two")
        let root = try XCTUnwrap(Yams.load(yaml: MihomoNodeProbeConfiguration.batchYAML(
            from: [first, second]
        )) as? [String: Any])
        let proxies = try XCTUnwrap(root["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.compactMap { $0["name"] as? String },
                       ["node-one", "node-two"])
        XCTAssertEqual((root["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((root["dns"] as? [String: Any])?["enable"] as? Bool, false)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-batch-config-test-\(UUID().uuidString)", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let options = ClashSetupOptions()
        options.basePath = base.path
        options.workingPath = base.path
        options.tempPath = base.path
        options.runtimeProfile = ClashRuntimeProfileIOSApplication
        options.disablePersistentCache = false
        options.persistentCacheDirectory = cache.path
        var sdkError: NSError?
        XCTAssertTrue(ClashSetup(options, &sdkError),
                      "Pinned SDK setup failed: \(String(describing: sdkError))")
        sdkError = nil
        XCTAssertTrue(ClashCheckConfig(try MihomoNodeProbeConfiguration.batchYAML(
            from: [first, second]
        ), &sdkError), "Pinned SDK rejected the synthetic multi-proxy probe catalog: \(String(describing: sdkError))")
        XCTAssertThrowsError(try MihomoNodeProbeConfiguration.batchYAML(
            from: [first, first]
        ))
    }

    func testIsolatedHTTPProbeKeepsReviewedDialerProxyDependencyWithoutTun() throws {
        let tunnelYAML = """
        mode: rule
        tun: {enable: true}
        dns: {enable: true}
        proxies:
          - {name: upstream, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: fixture}
          - {name: selected, type: ss, server: 8.8.8.8, port: 443, cipher: aes-128-gcm, password: fixture, dialer-proxy: upstream}
        proxy-groups:
          - {name: VPN, type: select, proxies: [selected]}
        proxy-providers:
          NetworkClientLatencyCandidates: {type: file, path: latency-candidates.yaml}
        rules: [MATCH,VPN]
        """
        let probeYAML = try MihomoNodeProbeConfiguration.yaml(from: tunnelYAML)
        let root = try XCTUnwrap(Yams.load(yaml: probeYAML) as? [String: Any])
        let proxies = try XCTUnwrap(root["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 2)
        XCTAssertEqual(proxies[1]["dialer-proxy"] as? String, "upstream")
        XCTAssertEqual((root["tun"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((root["dns"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertNil(root["proxy-providers"])
        XCTAssertThrowsError(try MihomoNodeProbeConfiguration.yaml(
            from: tunnelYAML.replacingOccurrences(of: "proxies: [selected]", with: "proxies: [missing]")
        ))
    }

    func testEncryptedDNSReplyAcceptsOnlyMatchingPublicIPv4() throws {
        let identifier: UInt16 = 0x1234
        let question = try DNSIPv4Message.query("edge.example", identifier: identifier)
        let header: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        let answer: [UInt8] = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60,
                               0, 4, 8, 8, 8, 8]
        let response = Data(header) + question.dropFirst(12) + Data(answer)
        XCTAssertEqual(try DNSIPv4Message.answer(
            response, identifier: identifier, hostname: "edge.example"
        ), "8.8.8.8")
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            response, identifier: identifier, hostname: "other.example"
        ))
        var privateAddress = response
        privateAddress.replaceSubrange((privateAddress.count - 4)..<privateAddress.count,
                                       with: [10, 0, 0, 1])
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            privateAddress, identifier: identifier, hostname: "edge.example"
        ))
        var businessError = response
        businessError[3] = 0x83 // NXDOMAIN, even with an otherwise plausible A record
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            businessError, identifier: identifier, hostname: "edge.example"
        ))
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            Data([0x12, 0x34, 0x81]), identifier: identifier, hostname: "edge.example"
        ))
    }

    func testEncryptedDNSRejectsAAAAOnlyAndChoosesPublicAFromMultipleAnswers() throws {
        let identifier: UInt16 = 0x4321
        let query = try DNSIPv4Message.query("node.example", identifier: identifier)
        let question = query.dropFirst(12)
        let header: [UInt8] = [0x43, 0x21, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0]
        let privateA: [UInt8] = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60,
                                 0, 4, 10, 0, 0, 1]
        let publicA: [UInt8] = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60,
                                0, 4, 8, 8, 4, 4]
        XCTAssertEqual(try DNSIPv4Message.answer(
            Data(header) + question + Data(privateA) + Data(publicA),
            identifier: identifier, hostname: "node.example"
        ), "8.8.4.4")
        let aaaa: [UInt8] = [0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16]
            + Array(repeating: 0, count: 15) + [1]
        var aaaaHeader = header
        aaaaHeader[7] = 1
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            Data(aaaaHeader) + question + Data(aaaa),
            identifier: identifier, hostname: "node.example"
        ))
        aaaaHeader[7] = 0
        XCTAssertThrowsError(try DNSIPv4Message.answer(
            Data(aaaaHeader) + question,
            identifier: identifier, hostname: "node.example"
        ))
        for hostname in ["bad..example", "example.com:443", "[2001:db8::1]", "invalid_域名"] {
            XCTAssertThrowsError(try DNSIPv4Message.query(hostname, identifier: identifier))
        }
    }

    func testTunnelStartResolutionUsesOnlyVerifiedPublicIPv4() async throws {
        let direct = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
            system: { "1.1.1.1" }, configuredDoH: { "8.8.8.8" }
        )
        XCTAssertEqual(direct, "1.1.1.1")
        let recovered = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
            system: { "198.18.0.1" }, configuredDoH: { "8.8.8.8" }
        )
        XCTAssertEqual(recovered, "8.8.8.8")
        let failedSystem = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
            system: { throw SelectedNodeTunnelError.endpointResolutionFailed },
            configuredDoH: { "8.8.4.4" }
        )
        XCTAssertEqual(failedSystem, "8.8.4.4")
        do {
            _ = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
                system: { "198.18.0.1" }, configuredDoH: { "10.0.0.1" }
            )
            XCTFail("Non-public fallback answer was accepted")
        } catch let error as SelectedNodeTunnelError {
            XCTAssertEqual(error, .endpointResolutionFailed)
        }
        do {
            _ = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
                system: { throw SelectedNodeTunnelError.endpointResolutionFailed },
                configuredDoH: { throw SelectedNodeTunnelError.endpointResolutionFailed }
            )
            XCTFail("Both failed lookups were accepted")
        } catch let error as SelectedNodeTunnelError {
            XCTAssertEqual(error, .endpointResolutionFailed)
        }
        let cancelled = Task {
            try await SelectedNodeEndpointResolver.resolvePublicIPv4(
                system: { try await Task.sleep(for: .seconds(1)); return "1.1.1.1" },
                configuredDoH: { "8.8.8.8" }
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled resolution was accepted")
        } catch is CancellationError {
            // A cancelled old selection cannot authorize a newer tunnel.
        }
    }
    private let yaml = """
    proxies:
      - name: 香港 01
        type: vless
        server: example.invalid
        port: 443
        uuid: 00000000-0000-4000-8000-000000000001
        tls: true
        reality-opts:
          public-key: fixture-only
          short-id: abcd
      - name: 日本 01
        type: ss
        server: example.invalid
        port: 8443
        cipher: aes-128-gcm
        password: fixture-only
    """
    func testStableIdentityAndNestedRealityPreserved() throws {
        let first = try SubscriptionParser().parse(yaml)
        let second = try SubscriptionParser().parse(yaml)
        XCTAssertEqual(first, second); XCTAssertEqual(first.nodes.count, 2)
        XCTAssertEqual(first.nodes.first?.countryCode, "HK")
        let node = try XCTUnwrap(first.nodes.first)
        let record = try XCTUnwrap(first.runtimeProxyRecords[node.id])
        guard case let .object(options)? = record.originalProxy["reality-opts"] else { return XCTFail("Missing nested fields") }
        XCTAssertEqual(options["short-id"], .string("abcd"))
        XCTAssertEqual(PendingProtocolCapabilities().capability(for: record).readiness, .unverified)
    }
    func testInvalidSubscriptionRejected() {
        XCTAssertThrowsError(try SubscriptionParser().parse("proxies: not-an-array"))
        XCTAssertThrowsError(try SubscriptionParser().parse("proxies: [{name: bad, type: ss, server: invalid, port: 99999}]"))
    }
    func testUnreviewedProtocolRemainsVisibleButUnavailable() throws {
        let parsed = try SubscriptionParser().parse("""
        proxies:
          - name: Synthetic future protocol
            type: future-protocol
            server: 198.51.100.20
            port: 443
        """)
        let node = try XCTUnwrap(parsed.nodes.first)
        XCTAssertFalse(node.available)
        let record = try XCTUnwrap(parsed.runtimeProxyRecords[node.id])
        XCTAssertEqual(PendingProtocolCapabilities().capability(for: record).readiness, .unsupported)
    }
    func testDuplicateNamesRemainDistinct() throws {
        let value = yaml.replacingOccurrences(of: "日本 01", with: "香港 01")
        let result = try SubscriptionParser().parse(value)
        XCTAssertEqual(Set(result.nodes.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.nodes.map(\.coreName)).count, 2)
    }
    func testSameNameDifferentEndpointsKeepIndependentStableIdentities() throws {
        let sources = [
            NodeIdentitySource(originalName: "Shared", type: "ss", server: "198.51.100.1", port: 443),
            NodeIdentitySource(originalName: "Shared", type: "ss", server: "198.51.100.2", port: 443),
            NodeIdentitySource(originalName: "Shared", type: "trojan", server: "198.51.100.1", port: 443),
            NodeIdentitySource(originalName: "Shared", type: "ss", server: "198.51.100.1", port: 8443)
        ]
        let first = try NodeIdentityFactory.makeNodes(from: sources)
        let reordered = try NodeIdentityFactory.makeNodes(from: Array(sources.reversed()))
        XCTAssertEqual(Set(first.map(\.id)).count, sources.count)
        XCTAssertEqual(Set(first.map(\.coreName)).count, sources.count)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.map { ("\($0.protocolType)/\($0.server)/\($0.port)", $0.id) }),
            Dictionary(uniqueKeysWithValues: reordered.map { ("\($0.protocolType)/\($0.server)/\($0.port)", $0.id) })
        )
        XCTAssertTrue(first.allSatisfy { $0.displayName == "Shared" })
        XCTAssertTrue(first.allSatisfy { !$0.id.contains("198.51.100") })
    }
    func testSelectedRevisionChangesOnlyWhenSelectedProxyChanges() throws {
        let original = try SubscriptionParser().parse(yaml)
        let selected = try XCTUnwrap(original.nodes.first?.id)
        let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(
            in: original, nodeID: selected
        ))
        let otherChanged = try SubscriptionParser().parse(
            yaml.replacingOccurrences(of: "password: fixture-only", with: "password: changed-only-other")
        )
        XCTAssertEqual(try SelectedNodeConfigurationIdentity.revision(
            in: otherChanged, nodeID: selected
        ), revision)
        let selectedChanged = try SubscriptionParser().parse(
            yaml.replacingOccurrences(of: "public-key: fixture-only", with: "public-key: changed-selected")
        )
        XCTAssertNotEqual(try SelectedNodeConfigurationIdentity.revision(
            in: selectedChanged, nodeID: selected
        ), revision)
        XCTAssertNil(try SelectedNodeConfigurationIdentity.revision(in: .empty, nodeID: selected))
    }
    func testTunnelMapperRejectsIncompleteVLESSRealityConfiguration() throws {
        let parsed = try SubscriptionParser().parse(yaml)
        let node = try XCTUnwrap(parsed.nodes.first)
        XCTAssertThrowsError(try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )) { error in XCTAssertEqual(error as? SelectedNodeTunnelError, .unsupportedValue) }
    }

    func testReviewedVLESSRealityVisionPreservesSecurityFieldsAndPinnedRoute() throws {
        let key = String(repeating: "A", count: 43) // synthetic 32-byte X25519 public key
        let parsed = try SubscriptionParser().parse("""
        proxies:
          - name: Synthetic Reality
            type: vless
            server: fixture.example
            port: 443
            uuid: 00000000-0000-4000-8000-000000000001
            flow: xtls-rprx-vision
            tls: true
            servername: camouflage.example
            client-fingerprint: chrome
            skip-cert-verify: false
            reality-opts:
              public-key: \(key)
              short-id: abcd
            udp: true
        """)
        let node = try XCTUnwrap(parsed.nodes.first)
        let request = TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture")
        let mapper = SelectedNodeTunnelMapper()
        XCTAssertThrowsError(try mapper.makeConfiguration(
            subscription: parsed, request: request,
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )) { error in XCTAssertEqual(error as? SelectedNodeTunnelError, .endpointRequiresIPv4) }
        let result = try mapper.makeConfiguration(
            subscription: parsed, request: request,
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!,
            accountScope: String(repeating: "a", count: 64),
            resolvedServerIPv4: "198.51.100.21"
        )
        XCTAssertEqual(result.serverIPv4, "198.51.100.21")
        XCTAssertEqual(result.accountScope, String(repeating: "a", count: 64))
        XCTAssertEqual(result.configurationRevision, request.configurationRevision)
        XCTAssertTrue(result.yaml.contains("xtls-rprx-vision"))
        XCTAssertTrue(result.yaml.contains("camouflage.example"))
        XCTAssertTrue(result.yaml.contains("198.51.100.21"))
        XCTAssertTrue(result.yaml.contains("dns-query#VPN"))
        XCTAssertFalse(result.yaml.contains("server: fixture.example"))
        XCTAssertEqual(try SubscriptionParser().parse(result.yaml).nodes.count, 1)
    }

    func testVLESSRealityRejectsCertificateBypassAndUnknownNestedField() throws {
        let base = """
        proxies:
          - name: Synthetic Reality
            type: vless
            server: 198.51.100.21
            port: 443
            uuid: 00000000-0000-4000-8000-000000000001
            flow: xtls-rprx-vision
            tls: true
            servername: camouflage.example
            client-fingerprint: chrome
            skip-cert-verify: true
            reality-opts:
              public-key: \(String(repeating: "A", count: 43))
              short-id: abcd
        """
        func map(_ raw: String) throws -> MihomoTunnelConfiguration {
            let parsed = try SubscriptionParser().parse(raw)
            let id = try XCTUnwrap(parsed.nodes.first?.id)
            return try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: id, mode: .global, configurationRevision: "fixture"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
        }
        XCTAssertThrowsError(try map(base)) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, .unsupportedValue)
        }
        let unknown = base.replacingOccurrences(of: "skip-cert-verify: true", with: "skip-cert-verify: false")
            + "\n      unexpected: secret\n"
        XCTAssertThrowsError(try map(unknown)) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, .unsupportedValue)
        }
    }

    func testResolvedEndpointRejectsPrivateAndReservedAddresses() {
        XCTAssertTrue(IPv4AddressValidator.publicUnicast("1.1.1.1"))
        for value in ["0.0.0.0", "10.0.0.1", "127.0.0.1", "169.254.1.1",
                      "172.20.1.1", "192.168.2.1", "100.64.0.1",
                      "192.0.2.1", "198.18.0.1", "198.51.100.1",
                      "203.0.113.1", "224.0.0.1", "240.0.0.1",
                      "999.1.1.1", "1.1.1", "١.1.1.1", "01.1.1.1"] {
            XCTAssertFalse(IPv4AddressValidator.publicUnicast(value), value)
        }
        XCTAssertEqual(SelectedNodeEndpointResolver.firstPublicIPv4(
            in: ["198.18.0.2", "10.0.0.1", "1.1.1.1", "8.8.8.8"]
        ), "1.1.1.1")
        XCTAssertNil(SelectedNodeEndpointResolver.firstPublicIPv4(in: []))
        XCTAssertNil(SelectedNodeEndpointResolver.firstPublicIPv4(
            in: ["198.18.0.2", "10.0.0.1"]
        ))
        XCTAssertTrue(IPv4AddressValidator.looksLikeLiteral("10.0.0.1"))
        XCTAssertTrue(IPv4AddressValidator.looksLikeLiteral("010.0.0.1"))
        XCTAssertFalse(IPv4AddressValidator.looksLikeLiteral("edge.example"))
        XCTAssertFalse(IPv4AddressValidator.valid("010.0.0.1"))
        XCTAssertFalse(IPv4AddressValidator.valid("999.0.0.1"))
    }

    func testTunnelRoutingRequiresIPv4AndAcceptsCapabilityDrivenIPv6() {
        func accepts(_ dns: String = "198.18.0.2", _ ipv6: [String] = ["fdfe:dcba:9876::1"],
                     _ prefixes: [Int] = [126]) -> Bool {
            TunnelRoutingPolicy.accepts(
                dnsAddress: dns,
                ipv4Addresses: ["198.18.0.1"], ipv4Masks: ["255.255.255.252"],
                ipv6Addresses: ipv6, ipv6Prefixes: prefixes
            )
        }
        XCTAssertTrue(accepts())
        XCTAssertTrue(accepts("198.51.100.21"))
        XCTAssertFalse(accepts("invalid.example"))
        XCTAssertTrue(accepts("198.18.0.2", [], []))
        XCTAssertFalse(accepts("198.18.0.2", ["::"], [0]))
        XCTAssertFalse(accepts("198.18.0.2", ["fdfe:dcba:9876::1"], [129]))
        XCTAssertFalse(TunnelRoutingPolicy.accepts(
            dnsAddress: "203.0.113.9", ipv4Addresses: [], ipv4Masks: [],
            ipv6Addresses: [], ipv6Prefixes: []
        ))
    }

    func testTunnelConfigurationKeepsAccountBindingAndDecodesOldDisconnectedFixture() throws {
        let value = MihomoTunnelConfiguration(
            generation: UUID(), nodeID: "synthetic-id", serverIPv4: "198.51.100.21",
            yaml: "proxies: []", createdAt: Date(timeIntervalSince1970: 1),
            accountScope: String(repeating: "a", count: 64), coreName: "synthetic-core",
            configurationRevision: String(repeating: "b", count: 64)
        )
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MihomoTunnelConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.accountScope, value.accountScope)
        XCTAssertEqual(decoded.coreName, value.coreName)
        XCTAssertEqual(decoded.configurationRevision, value.configurationRevision)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "accountScope")
        legacy.removeValue(forKey: "coreName")
        legacy.removeValue(forKey: "configurationRevision")
        let old = try JSONDecoder().decode(MihomoTunnelConfiguration.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.accountScope)
        XCTAssertNil(old.coreName)
        XCTAssertNil(old.configurationRevision)
    }

    func testSelectedShadowsocksNodeBuildsProtectedTunnelConfiguration() throws {
        let parsed = try SubscriptionParser().parse("""
        proxies:
          - name: Synthetic SS
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: synthetic-only
        """)
        let node = try XCTUnwrap(parsed.nodes.first)
        let result = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )
        XCTAssertEqual(result.nodeID, node.id)
        XCTAssertEqual(result.serverIPv4, "198.51.100.20")
        XCTAssertTrue(result.yaml.contains("strict-route"))
        XCTAssertTrue(result.yaml.contains("MATCH,"))
        XCTAssertFalse(result.yaml.contains("mixed-port"))
        XCTAssertEqual(try SubscriptionParser().parse(result.yaml).nodes.count, 1)
    }

    func testTunnelMapperRejectsHostnameUntilSafeRouteResolutionExists() throws {
        let parsed = try SubscriptionParser().parse(yaml)
        let node = try XCTUnwrap(parsed.nodes.last)
        XCTAssertThrowsError(try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )) { error in XCTAssertEqual(error as? SelectedNodeTunnelError, .endpointRequiresIPv4) }
    }

    func testTunnelMapperBuildsMacCompatibleRuleModeAndRejectsUnknownField() throws {
        let base = """
        proxies:
          - name: Synthetic SS
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: synthetic-only
        """
        let parsed = try SubscriptionParser().parse(base)
        let id = try XCTUnwrap(parsed.nodes.first?.id)
        let ruleConfiguration = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: id, mode: .rule, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )
        XCTAssertTrue(ruleConfiguration.yaml.contains("mode: rule"))
        XCTAssertEqual(ruleConfiguration.mode, "rule")
        XCTAssertTrue(ruleConfiguration.yaml.contains("DOMAIN-SUFFIX,local,DIRECT"))
        XCTAssertTrue(ruleConfiguration.yaml.contains("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"))
        XCTAssertTrue(ruleConfiguration.yaml.contains("GEOSITE,cn,DIRECT"))
        XCTAssertTrue(ruleConfiguration.yaml.contains("GEOIP,CN,DIRECT"))
        XCTAssertTrue(ruleConfiguration.yaml.contains("MATCH,"))
        let globalConfiguration = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: id, mode: .global, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )
        XCTAssertEqual(globalConfiguration.mode, "global")
        XCTAssertTrue(globalConfiguration.yaml.contains("mode: global"))
        XCTAssertTrue(globalConfiguration.yaml.contains("GEOSITE,cn,DIRECT"))
        XCTAssertTrue(globalConfiguration.yaml.contains("GEOIP,CN,DIRECT"))
        let modified = try SubscriptionParser().parse(base + "\n    plugin: unsupported\n")
        let modifiedID = try XCTUnwrap(modified.nodes.first?.id)
        XCTAssertThrowsError(try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: modified,
            request: TunnelRequest(nodeID: modifiedID, mode: .global, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )) { error in XCTAssertEqual(error as? SelectedNodeTunnelError, .unsupportedValue) }
    }

    func testSelectedVMessTCPWebSocketAndGRPCFieldsRemainInTunnelYAML() throws {
        let transports: [(String, [String])] = [
            ("tcp", []),
            ("ws", ["    ws-opts:", "      path: /synthetic", "      headers:", "        Host: example.invalid"]),
            ("grpc", ["    grpc-opts:", "      grpc-service-name: synthetic"]),
        ]
        for (network, options) in transports {
            let yaml = ([
                "proxies:", "  - name: Synthetic VMess", "    type: vmess",
                "    server: 198.51.100.30", "    port: 443",
                "    uuid: 11111111-1111-4111-8111-111111111111",
                "    alterId: 0", "    cipher: auto", "    network: \(network)",
            ] + options).joined(separator: "\n")
            let parsed = try SubscriptionParser().parse(yaml)
            let id = try XCTUnwrap(parsed.nodes.first?.id)
            let result = try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: id, mode: .global, configurationRevision: "fixture"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
            XCTAssertTrue(result.yaml.contains("198.51.100.30"))
            XCTAssertTrue(result.yaml.contains(network))
            XCTAssertEqual(try SubscriptionParser().parse(result.yaml).nodes.count, 1)
            if network == "ws" { XCTAssertTrue(result.yaml.contains("/synthetic")) }
            if network == "grpc" { XCTAssertTrue(result.yaml.contains("synthetic")) }
        }
    }

    private func hy2UDPFixture(_ extra: String = "", hostname: Bool = false) -> String {
        """
        proxies:
          - name: Synthetic HY2 UDP
            type: hysteria2
            server: \(hostname ? "edge.fixture.invalid" : "198.51.100.20")
            port: 443
            password: synthetic-hy2-password
            sni: tls.fixture.invalid
            skip-cert-verify: false
            \(extra)
        """
    }

    private func mapHY2UDPFixture(_ raw: String) throws -> MihomoTunnelConfiguration {
        let parsed = try SubscriptionParser().parse(raw)
        let node = try XCTUnwrap(parsed.nodes.first)
        let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(in: parsed, nodeID: node.id))
        return try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: node.id, mode: .rule, configurationRevision: revision),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!,
            resolvedServerIPv4: "198.51.100.20"
        )
    }

    private func hy2Proxy(in yaml: String) throws -> [String: Any] {
        let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        return try XCTUnwrap((root["proxies"] as? [[String: Any]])?.first)
    }

    private func assertHY2UDPRejected(_ extra: String, error expected: SelectedNodeTunnelError = .unsupportedValue,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try mapHY2UDPFixture(hy2UDPFixture(extra)), file: file, line: line) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, expected, file: file, line: line)
        }
    }

    func testHY2UDPMissingRemainsAccepted() throws {
        let configuration = try mapHY2UDPFixture(hy2UDPFixture())
        XCTAssertNil(try hy2Proxy(in: configuration.yaml)["udp"])
    }

    func testHY2UDPTruePreservesParserRecordRevisionAndProbeSemantics() throws {
        let raw = hy2UDPFixture("udp: true")
        let parsed = try SubscriptionParser().parse(raw)
        let node = try XCTUnwrap(parsed.nodes.first)
        let record = try XCTUnwrap(parsed.runtimeProxyRecords[node.id])
        XCTAssertEqual(record.originalProxy["udp"], .bool(true))
        XCTAssertEqual(record.runtimeProxy?["udp"], .bool(true))
        let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(in: parsed, nodeID: node.id))
        let configuration = try mapHY2UDPFixture(raw)
        XCTAssertEqual(configuration.configurationRevision, revision)
        XCTAssertEqual(try OriginalProxyCanonicalization.digest(record.originalProxy), revision)
        XCTAssertEqual(configuration.coreName, record.coreName)
        XCTAssertEqual(try hy2Proxy(in: configuration.yaml)["udp"] as? Bool, true)
        let decoded = try JSONDecoder().decode(MihomoTunnelConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.yaml, configuration.yaml)
        let probe = try MihomoNodeProbeConfiguration.yaml(from: decoded.yaml)
        XCTAssertEqual(try hy2Proxy(in: probe)["udp"] as? Bool, true)
        XCTAssertEqual(try hy2Proxy(in: probe)["name"] as? String, record.coreName)
        XCTAssertEqual(record.originalProxy["udp"], .bool(true))
        XCTAssertEqual(record.runtimeProxy?["udp"], .bool(true))
    }

    func testHY2UDPFalseRejectedBecausePinnedCoreCannotDisableUDP() {
        assertHY2UDPRejected("udp: false")
    }
    func testHY2UDPStringRejected() { assertHY2UDPRejected("udp: 'true'") }
    func testHY2UDPIntegerRejected() { assertHY2UDPRejected("udp: 1") }
    func testHY2UDPArrayRejected() { assertHY2UDPRejected("udp: [true]") }
    func testHY2UDPObjectRejected() { assertHY2UDPRejected("udp: {enabled: true}") }
    func testHY2UDPNullRejected() { assertHY2UDPRejected("udp: null") }

    func testHY2UDPUnknownFieldStillRejected() {
        assertHY2UDPRejected("udp: true\n    unknown-hy2-option: true", error: .unsupportedField)
    }
    func testHY2UDPDoesNotAllowSkippingCertificateVerification() throws {
        let raw = hy2UDPFixture("udp: true").replacingOccurrences(of: "skip-cert-verify: false", with: "skip-cert-verify: true")
        XCTAssertThrowsError(try mapHY2UDPFixture(raw)) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, .unsupportedValue)
        }
    }
    func testHY2UDPStillRequiresPassword() throws {
        let raw = hy2UDPFixture("udp: true").replacingOccurrences(of: "password: synthetic-hy2-password", with: "password: ''")
        XCTAssertThrowsError(try mapHY2UDPFixture(raw)) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, .unsupportedValue)
        }
    }
    func testHY2UDPStillRequiresSNI() throws {
        let raw = hy2UDPFixture("udp: true").replacingOccurrences(of: "sni: tls.fixture.invalid", with: "sni: ''")
        XCTAssertThrowsError(try mapHY2UDPFixture(raw)) {
            XCTAssertEqual($0 as? SelectedNodeTunnelError, .unsupportedValue)
        }
    }
    func testHY2UDPPreservesValidObfsCombination() throws {
        let configuration = try mapHY2UDPFixture(hy2UDPFixture("udp: true\n    obfs: salamander\n    obfs-password: synthetic-obfs"))
        let proxy = try hy2Proxy(in: configuration.yaml)
        XCTAssertEqual(proxy["udp"] as? Bool, true)
        XCTAssertEqual(proxy["obfs"] as? String, "salamander")
        XCTAssertEqual(proxy["obfs-password"] as? String, "synthetic-obfs")
    }
    func testHY2UDPPreservesValidPortsCombination() throws {
        let configuration = try mapHY2UDPFixture(hy2UDPFixture("udp: true\n    ports: '443-445'\n    hop-interval: '10'"))
        let proxy = try hy2Proxy(in: configuration.yaml)
        XCTAssertEqual(proxy["udp"] as? Bool, true)
        XCTAssertEqual(proxy["ports"] as? String, "443-445")
        XCTAssertEqual(proxy["hop-interval"] as? String, "10")
    }
    func testHY2UDPCurrentRealFieldSetSyntheticEquivalentAccepted() throws {
        let configuration = try mapHY2UDPFixture(hy2UDPFixture("udp: true", hostname: true))
        let proxy = try hy2Proxy(in: configuration.yaml)
        XCTAssertEqual(Set(proxy.keys), Set(["name", "type", "server", "port", "password", "sni", "skip-cert-verify", "udp"]))
        XCTAssertEqual(proxy["udp"] as? Bool, true)
        XCTAssertEqual(proxy["skip-cert-verify"] as? Bool, false)
    }
    func testHY2UDPPreservesOtherSafetyRejections() {
        for extra in ["obfs: salamander", "ports: invalid", "hop-interval: invalid",
                      "max-stream-receive-window: invalid"] {
            assertHY2UDPRejected("udp: true\n    " + extra)
        }
    }

    func testHY2UDPPinnedSDKAlwaysReportsUDPEnabled() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hy2-sdk-udp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let options = ClashSetupOptions()
        options.basePath = base.path; options.workingPath = base.path; options.tempPath = base.path
        options.runtimeProfile = ClashRuntimeProfileIOSApplication
        options.disablePersistentCache = false
        options.persistentCacheDirectory = base.appendingPathComponent("cache").path
        try FileManager.default.createDirectory(atPath: options.persistentCacheDirectory, withIntermediateDirectories: true)
        var sdkError: NSError?
        XCTAssertTrue(ClashSetup(options, &sdkError))
        for extra in ["", "udp: true", "udp: false"] {
            // Direct SDK fixture only: false must never pass through the production mapper.
            let raw = hy2UDPFixture(extra)
            sdkError = nil
            XCTAssertTrue(ClashCheckConfig(raw, &sdkError), "Pinned HY2 config parse failed")
            sdkError = nil
            let catalog = try XCTUnwrap(ClashProxyCatalogForIOS(raw, "", "", &sdkError)?.value)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
            let proxies = try XCTUnwrap(root["proxies"] as? [String: Any])
            let proxy = try XCTUnwrap(proxies["Synthetic HY2 UDP"] as? [String: Any])
            XCTAssertEqual(proxy["udp"] as? Bool, true, "Pinned HY2 has no UDP-off configuration switch")
        }
    }

    func testReviewedAdditionalProtocolConfigurationsPreserveRequiredFields() throws {
        let fixtures: [(type: String, fields: String, expected: String)] = [
            ("ss", "cipher: chacha20-ietf-poly1305\n    password: synthetic-secret", "chacha20-ietf-poly1305"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    tls: true\n    servername: synthetic.example\n    network: ws\n    ws-opts:\n      path: /synthetic", "/synthetic"),
            ("trojan", "password: synthetic-secret\n    sni: synthetic.example\n    network: grpc\n    grpc-opts:\n      grpc-service-name: synthetic", "grpc-service-name"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    obfs: salamander\n    obfs-password: synthetic-obfs\n    alpn: [h3]", "salamander"),
            ("tuic", "uuid: 00000000-0000-4000-8000-000000000001\n    password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]\n    udp-relay-mode: native", "udp-relay-mode"),
            ("gost-relay", "tls: true\n    sni: synthetic.example\n    username: synthetic-user\n    password: synthetic-secret", "gost-relay"),
            ("trusttunnel", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example", "trusttunnel"),
            ("mieru", "transport: TCP\n    username: synthetic-user\n    password: synthetic-secret", "transport: TCP"),
            ("sudoku", "key: synthetic-secret", "sudoku"),
        ]
        for fixture in fixtures {
            let raw = """
            proxies:
              - name: Synthetic node
                type: \(fixture.type)
                server: 198.51.100.20
                port: 443
                \(fixture.fields)
            """
            let parsed = try SubscriptionParser().parse(raw)
            let node = try XCTUnwrap(parsed.nodes.first)
            let config = try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
            XCTAssertTrue(config.yaml.contains(fixture.expected), fixture.type)
            XCTAssertEqual(try SubscriptionParser().parse(config.yaml).nodes.count, 1, fixture.type)
            let record = try XCTUnwrap(parsed.runtimeProxyRecords[node.id])
            XCTAssertEqual(PendingProtocolCapabilities().capability(for: record).readiness, .unverified)
        }
    }

    func testAdditionalProtocolsFailClosedOnUnsafeOrUnknownOptions() throws {
        let fixtures = [
            ("trojan", "password: synthetic-secret\n    sni: synthetic.example\n    skip-cert-verify: true"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    obfs: salamander"),
            ("tuic", "token: synthetic-secret\n    sni: synthetic.example\n    unknown-option: true"),
            ("tuic", "token: synthetic-secret\n    uuid: 00000000-0000-4000-8000-000000000001\n    password: synthetic-other\n    sni: synthetic.example"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    max-stream-receive-window: invalid"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    network: h2\n    h2-opts:\n      host: invalid-scalar"),
            ("ss", "cipher: aes-256-gcm\n    password: synthetic-secret\n    plugin: v2ray-plugin\n    plugin-opts:\n      mode: http"),
            ("socks5", "username: synthetic-user\n    password: synthetic-secret\n    tls: false"),
            ("ssh", "username: synthetic-user\n    password: synthetic-secret\n    private-key: /tmp/unsafe"),
            ("shadowquic", "password: synthetic-secret\n    sni: synthetic.example\n    max-open-streams: invalid"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    tls: true\n    servername: synthetic.example\n    reality-opts:\n      short-id: abcd"),
            ("vmess", "uuid: invalid-uuid\n    cipher: auto"),
            ("ss", "cipher: aes-256-gcm"),
            ("ssr", "cipher: aes-256-cfb\n    obfs: plain\n    protocol: origin"),
            ("snell", "version: 3"),
            ("hysteria", "up: 10 Mbps\n    down: 10 Mbps\n    sni: synthetic.example"),
            ("anytls", "sni: synthetic.example"),
            ("http", "username: synthetic-user\n    password: synthetic-secret\n    tls: false"),
            ("ssh", "username: synthetic-user\n    password: synthetic-secret"),
            ("shadowquic", "sni: synthetic.example"),
            ("gost-relay", "tls: false\n    sni: synthetic.example\n    username: synthetic-user\n    password: synthetic-secret"),
            ("gost-relay", "tls: true\n    sni: synthetic.example\n    username: synthetic-user\n    password: synthetic-secret\n    forward: true"),
            ("gost-relay", "tls: true\n    sni: synthetic.example\n    username: synthetic-user\n    password: synthetic-secret\n    udp: true"),
            ("trusttunnel", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example\n    quic: true"),
            ("trusttunnel", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example\n    skip-cert-verify: true"),
            ("trusttunnel", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example\n    udp: true"),
            ("mieru", "transport: UDP\n    username: synthetic-user\n    password: synthetic-secret"),
            ("mieru", "transport: TCP\n    username: synthetic-user\n    password: synthetic-secret\n    port-range: 443-445"),
            ("mieru", "transport: TCP\n    username: synthetic-user\n    password: synthetic-secret\n    udp: true"),
            ("sudoku", "key: synthetic-secret\n    http-mask: true"),
            ("sudoku", "aead-method: aes-256-gcm"),
        ]
        for (type, fields) in fixtures {
            let parsed = try SubscriptionParser().parse("""
            proxies:
              - name: Synthetic node
                type: \(type)
                server: 198.51.100.20
                port: 443
                \(fields)
            """)
            let node = try XCTUnwrap(parsed.nodes.first)
            XCTAssertThrowsError(try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            ), type)
        }
    }

    func testPinnedProtocolOptionsSurviveSubscriptionToRuntimeWithoutMutatingOriginal() throws {
        let fixtures: [(type: String, fields: String, retained: String)] = [
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    tls: true\n    servername: synthetic.example\n    flow: xtls-rprx-vision\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: \(String(repeating: "A", count: 43))\n      short-id: abcd\n      support-x25519mlkem768: true", "support-x25519mlkem768"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: h2\n    h2-opts:\n      host: [synthetic.example]\n      path: /tunnel", "h2-opts"),
            ("ss", "cipher: aes-256-gcm\n    password: synthetic-secret\n    plugin: obfs\n    plugin-opts:\n      mode: http\n      host: synthetic.example", "plugin-opts"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    ports: 443-445\n    hop-interval: '10'\n    alpn: [h3]", "hop-interval"),
            ("tuic", "uuid: 00000000-0000-4000-8000-000000000001\n    password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]\n    reduce-rtt: true\n    request-timeout: 1000", "reduce-rtt"),
        ]
        for fixture in fixtures {
            let parsed = try SubscriptionParser().parse("""
            proxies:
              - name: Synthetic node
                type: \(fixture.type)
                server: 198.51.100.20
                port: 443
                \(fixture.fields)
            """)
            let node = try XCTUnwrap(parsed.nodes.first)
            let original = try XCTUnwrap(parsed.runtimeProxyRecords[node.id]?.originalProxy)
            let config = try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: node.id, mode: .global,
                                       configurationRevision: "synthetic"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
            XCTAssertTrue(config.yaml.contains(fixture.retained), fixture.type)
            XCTAssertEqual(parsed.runtimeProxyRecords[node.id]?.originalProxy, original)
            XCTAssertEqual(config.coreName, node.coreName)
        }
    }

    func testRealityMLKEMTriStateMatchesConnectAndLatencyRuntime() throws {
        let publicKey = String(repeating: "A", count: 43)
        for fixture in [
            (name: "absent", line: "", expected: Optional<Bool>.none),
            (name: "false", line: "      support-x25519mlkem768: false\n", expected: false),
            (name: "true", line: "      support-x25519mlkem768: true\n", expected: true),
        ] {
            let subscription = try SubscriptionParser().parse("""
            proxies:
              - name: Reality \(fixture.name)
                type: vless
                server: 198.51.100.20
                port: 443
                uuid: 00000000-0000-4000-8000-000000000001
                flow: xtls-rprx-vision
                tls: true
                servername: synthetic.example
                client-fingerprint: chrome
                reality-opts:
                  public-key: \(publicKey)
                  short-id: abcd
            \(fixture.line)
            """)
            let node = try XCTUnwrap(subscription.nodes.first)
            let record = try XCTUnwrap(subscription.runtimeProxyRecords[node.id])
            guard case let .object(inputReality)? = record.originalProxy["reality-opts"] else {
                return XCTFail("Missing input Reality options for \(fixture.name)")
            }
            XCTAssertEqual(inputReality["support-x25519mlkem768"]?.foundationValue as? Bool,
                           fixture.expected, fixture.name)

            let connect = try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: subscription,
                request: TunnelRequest(nodeID: node.id, mode: .global,
                                       configurationRevision: "mlkem-\(fixture.name)"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
            let connectRoot = try XCTUnwrap(Yams.load(yaml: connect.yaml) as? [String: Any])
            let connectProxy = try XCTUnwrap((connectRoot["proxies"] as? [[String: Any]])?.first)
            let connectReality = try XCTUnwrap(connectProxy["reality-opts"] as? [String: Any])
            XCTAssertEqual(connectReality["support-x25519mlkem768"] as? Bool,
                           fixture.expected, "connect \(fixture.name)")

            let latencyYAML = try MihomoNodeProbeConfiguration.yaml(from: connect.yaml)
            let latencyRoot = try XCTUnwrap(Yams.load(yaml: latencyYAML) as? [String: Any])
            let latencyProxy = try XCTUnwrap((latencyRoot["proxies"] as? [[String: Any]])?.first)
            let latencyReality = try XCTUnwrap(latencyProxy["reality-opts"] as? [String: Any])
            XCTAssertEqual(latencyReality["support-x25519mlkem768"] as? Bool,
                           fixture.expected, "latency \(fixture.name)")
            XCTAssertEqual(latencyReality["public-key"] as? String, publicKey)
            XCTAssertEqual(latencyReality["short-id"] as? String, "abcd")
            for key in ["name", "type", "server", "port", "uuid", "flow", "tls",
                        "servername", "client-fingerprint"] {
                XCTAssertEqual(String(describing: connectProxy[key]),
                               String(describing: latencyProxy[key]), "\(fixture.name): \(key)")
            }
        }

        let plain = try SubscriptionParser().parse("""
        proxies:
          - name: Plain VLESS TLS
            type: vless
            server: 198.51.100.20
            port: 443
            uuid: 00000000-0000-4000-8000-000000000002
            tls: true
            servername: synthetic.example
        """)
        let plainNode = try XCTUnwrap(plain.nodes.first)
        let plainConnect = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: plain,
            request: TunnelRequest(nodeID: plainNode.id, mode: .global,
                                   configurationRevision: "non-reality"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )
        let plainLatency = try MihomoNodeProbeConfiguration.yaml(from: plainConnect.yaml)
        XCTAssertFalse(plainConnect.yaml.contains("support-x25519mlkem768"))
        XCTAssertFalse(plainLatency.contains("support-x25519mlkem768"))
    }

    func testInvalidOrAmbiguousProxyReferenceDoesNotEraseIndependentNode() throws {
        let parsed = try SubscriptionParser().parse("""
        proxies:
          - name: Duplicate
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: synthetic-one
          - name: Duplicate
            type: ss
            server: 198.51.100.21
            port: 443
            cipher: aes-128-gcm
            password: synthetic-two
          - name: Dependent
            type: ss
            server: 198.51.100.22
            port: 443
            cipher: aes-128-gcm
            password: synthetic-three
            dialer-proxy: Duplicate
        """)
        XCTAssertEqual(parsed.nodes.count, 3)
        XCTAssertEqual(Set(parsed.nodes.map(\.coreName)).count, 3)
        let dependent = try XCTUnwrap(parsed.nodes.first(where: { $0.originalName == "Dependent" }))
        XCTAssertEqual(parsed.runtimeProxyRecords[dependent.id]?.issue,
                       .ambiguousReference(field: "dialer-proxy"))
        let independent = try XCTUnwrap(parsed.nodes.first(where: { $0.originalName == "Duplicate" }))
        XCTAssertNoThrow(try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: independent.id, mode: .global,
                                   configurationRevision: "synthetic"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        ))
        XCTAssertThrowsError(try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: dependent.id, mode: .global,
                                   configurationRevision: "synthetic"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        ))
    }

    func testPinnedMihomoSDKParsesReviewedProtocolConfigurations() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let options = ClashSetupOptions()
        options.basePath = base.path
        options.workingPath = base.path
        options.tempPath = base.path
        options.runtimeProfile = ClashRuntimeProfileIOSApplication
        options.disablePersistentCache = false
        options.persistentCacheDirectory = base.appendingPathComponent("cache").path
        try FileManager.default.createDirectory(
            atPath: options.persistentCacheDirectory, withIntermediateDirectories: true
        )
        var error: NSError?
        XCTAssertTrue(ClashSetup(options, &error), "Pinned SDK setup failed")
        try Data("proxies:\n  - {name: __networkclient_latency_empty__, type: reject}\n".utf8)
            .write(to: base.appendingPathComponent("latency-candidates.yaml"))

        // Both modes now carry the same CN rules so hot switching needs no
        // Core reload. The app now owns the reviewed source resources and
        // publishes them before the extension starts.
        let appResources = try XCTUnwrap(Bundle.main.resourceURL)
        for filename in ["geoip.metadb", "geosite.dat"] {
            let source = appResources.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            try FileManager.default.copyItem(at: source, to: base.appendingPathComponent(filename))
        }
        let compiledCN = appResources.appendingPathComponent("cn.mrs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiledCN.path))
        XCTAssertEqual(
            try GeoDataPreparer.streamingDigest(at: compiledCN),
            "ffb5b4311029519a52066711a75a38a5f27d9aa6357778342429babe21cff92c"
        )

        let fixtures: [(String, String)] = [
            ("ss", "cipher: aes-256-gcm\n    password: synthetic-secret"),
            ("ss", "cipher: chacha20-ietf-poly1305\n    password: synthetic-secret"),
            ("ss", "cipher: aes-256-gcm\n    password: synthetic-secret\n    plugin: obfs\n    plugin-opts:\n      mode: http\n      host: synthetic.example"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: ws\n    ws-opts:\n      path: /synthetic"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: ws"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: grpc\n    grpc-opts:\n      grpc-service-name: synthetic"),
            ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: h2\n    h2-opts:\n      host: [synthetic.example]\n      path: /tunnel"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    tls: true\n    servername: synthetic.example"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    flow: xtls-rprx-vision\n    tls: true\n    servername: synthetic.example\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: \(String(repeating: "A", count: 43))\n      short-id: abcd"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    flow: xtls-rprx-vision\n    tls: true\n    servername: synthetic.example\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: \(String(repeating: "A", count: 43))\n      short-id: abcd\n      support-x25519mlkem768: false"),
            ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    flow: xtls-rprx-vision\n    tls: true\n    servername: synthetic.example\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: \(String(repeating: "A", count: 43))\n      short-id: abcd\n      support-x25519mlkem768: true"),
            ("trojan", "password: synthetic-secret\n    sni: synthetic.example"),
            ("trojan", "password: synthetic-secret\n    sni: synthetic.example\n    network: grpc\n    grpc-opts:\n      grpc-service-name: synthetic"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    obfs: salamander\n    obfs-password: synthetic-obfs"),
            ("hysteria2", "password: synthetic-secret\n    sni: synthetic.example\n    ports: 443-445\n    hop-interval: '10'\n    alpn: [h3]"),
            ("tuic", "uuid: 00000000-0000-4000-8000-000000000001\n    password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]"),
            ("tuic", "token: synthetic-secret\n    sni: synthetic.example\n    udp-relay-mode: quic"),
            ("tuic", "uuid: 00000000-0000-4000-8000-000000000001\n    password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]\n    reduce-rtt: true\n    request-timeout: 1000"),
            ("ssr", "cipher: aes-256-cfb\n    password: synthetic-secret\n    obfs: plain\n    protocol: origin"),
            ("snell", "psk: synthetic-secret\n    version: 3"),
            ("hysteria", "auth-str: synthetic-secret\n    up: 10 Mbps\n    down: 10 Mbps\n    sni: synthetic.example"),
            ("anytls", "password: synthetic-secret\n    sni: synthetic.example"),
            ("socks5", "username: synthetic-user\n    password: synthetic-secret\n    tls: true"),
            ("http", "username: synthetic-user\n    password: synthetic-secret\n    tls: true\n    sni: synthetic.example"),
            ("shadowquic", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example\n    alpn: [h3]"),
            ("ssh", "username: synthetic-user\n    password: synthetic-secret\n    host-key: [ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1mDdEOFg8VVlo+L26U3VcutGwDWVKMx0GSTSVcnXMm]"),
            ("gost-relay", "tls: true\n    sni: synthetic.example\n    username: synthetic-user\n    password: synthetic-secret"),
            ("trusttunnel", "username: synthetic-user\n    password: synthetic-secret\n    sni: synthetic.example"),
            ("mieru", "transport: TCP\n    username: synthetic-user\n    password: synthetic-secret"),
            ("sudoku", "key: synthetic-secret"),
        ]
        for (type, fields) in fixtures {
            let parsed = try SubscriptionParser().parse("""
            proxies:
              - name: Synthetic node
                type: \(type)
                server: 198.51.100.20
                port: 443
                \(fields)
            """)
            let node = try XCTUnwrap(parsed.nodes.first)
            let config = try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: parsed,
                request: TunnelRequest(nodeID: node.id, mode: .global, configurationRevision: "fixture"),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            )
            error = nil
            XCTAssertTrue(ClashCheckConfig(config.yaml, &error), "Pinned SDK rejected \(type)")
            error = nil
            let catalog = ClashProxyCatalogForIOS(config.yaml, "", "", &error)
            let catalogJSON = try XCTUnwrap(catalog?.value,
                "Pinned SDK could not load proxy catalog for \(type)")
            let catalogRoot = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(catalogJSON.utf8)) as? [String: Any])
            let proxies = try XCTUnwrap(catalogRoot["proxies"] as? [String: Any])
            XCTAssertNotNil(proxies[node.coreName], "Selected outbound missing for \(type)")
            let selector = try XCTUnwrap(proxies["VPN"] as? [String: Any])
            XCTAssertTrue((selector["all"] as? [String])?.contains(node.coreName) == true,
                          "VPN selector does not contain \(type)")
        }
        let parsed = try SubscriptionParser().parse("""
        proxies:
          - name: Synthetic rule node
            type: ss
            server: 198.51.100.20
            port: 443
            cipher: aes-128-gcm
            password: synthetic-only
        """)
        let selected = try XCTUnwrap(parsed.nodes.first)
        let rule = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: selected.id, mode: .rule, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
        )
        error = nil
        XCTAssertTrue(ClashCheckConfig(rule.yaml, &error), "Pinned SDK rejected rule mode")
        let remoteDNS = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: selected.id, mode: .rule, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!,
            mihomoDns: "203.0.113.53", remoteMihomoDNSValidated: true
        )
        error = nil
        XCTAssertTrue(ClashCheckConfig(remoteDNS.yaml, &error),
                      "Pinned SDK rejected Core DNS routed through VPN")
        let remoteRoot = try XCTUnwrap(Yams.load(yaml: remoteDNS.yaml) as? [String: Any])
        let dns = try XCTUnwrap(remoteRoot["dns"] as? [String: Any])
        XCTAssertEqual(dns["nameserver"] as? [String], [
            "203.0.113.53#VPN", "https://192.0.2.53/dns-query#VPN"
        ])
        let unvalidated = try SelectedNodeTunnelMapper().makeConfiguration(
            subscription: parsed,
            request: TunnelRequest(nodeID: selected.id, mode: .rule, configurationRevision: "fixture"),
            dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!,
            mihomoDns: "203.0.113.53"
        )
        let unvalidatedRoot = try XCTUnwrap(Yams.load(yaml: unvalidated.yaml) as? [String: Any])
        let unvalidatedDNS = try XCTUnwrap(unvalidatedRoot["dns"] as? [String: Any])
        XCTAssertEqual(unvalidatedDNS["nameserver"] as? [String], [
            "https://192.0.2.53/dns-query#VPN"
        ])
        let pair = try SubscriptionParser().parse("""
        proxies:
          - {name: Synthetic A, type: ss, server: 198.51.100.20, port: 443,
             cipher: aes-128-gcm, password: synthetic-a}
          - {name: Synthetic B, type: ss, server: 198.51.100.21, port: 443,
             cipher: aes-128-gcm, password: synthetic-b}
        """)
        let active = try XCTUnwrap(pair.nodes.first)
        let mapped: [(ProxyNode, String, MihomoTunnelConfiguration)] = try pair.nodes.map { node in
            let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(
                in: pair, nodeID: node.id
            ))
            return (node, revision, try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: pair,
                request: TunnelRequest(nodeID: node.id, mode: .rule,
                                       configurationRevision: revision),
                dnsEndpoint: URL(string: "https://192.0.2.53/dns-query")!
            ))
        }
        let probeCandidates = try mapped.map { item in
            NodeProbeCandidate(nodeID: item.0.id, revision: item.1,
                               coreName: try XCTUnwrap(item.2.coreName),
                               yaml: try MihomoNodeProbeConfiguration.yaml(from: item.2.yaml))
        }
        let pool = try MihomoStableCandidatePoolBuilder.build(
            selected: mapped[0].2, candidates: probeCandidates
        )
        let poolRoot = try XCTUnwrap(Yams.load(yaml: pool.yaml) as? [String: Any])
        XCTAssertEqual((poolRoot["proxies"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(poolRoot["proxy-providers"])
        let poolGroup = try XCTUnwrap((poolRoot["proxy-groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(poolGroup["proxies"] as? [String], probeCandidates.map(\.coreName))
        XCTAssertEqual(pool.candidates.count, 2)
        error = nil
        XCTAssertTrue(ClashCheckConfig(pool.yaml, &error),
                      "Pinned SDK rejected fixed non-routing candidates")
        error = nil
        let fixedCatalog = try XCTUnwrap(ClashProxyCatalogForIOS(
            pool.yaml, "", "", &error
        )?.value)
        let fixedRoot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(fixedCatalog.utf8)
        ) as? [String: Any])
        let fixedProxies = try XCTUnwrap(fixedRoot["proxies"] as? [String: Any])
        for candidate in probeCandidates {
            XCTAssertNotNil(fixedProxies[candidate.coreName])
        }
        let fixedSelector = try XCTUnwrap(fixedProxies["VPN"] as? [String: Any])
        XCTAssertEqual(fixedSelector["all"] as? [String], probeCandidates.map(\.coreName))
        XCTAssertEqual(fixedSelector["now"] as? String, active.coreName)
        XCTAssertThrowsError(try MihomoStableCandidatePoolBuilder.build(
            selected: mapped[0].2, candidates: [probeCandidates[0], probeCandidates[0]]
        ))
        XCTAssertThrowsError(try MihomoStableCandidatePoolBuilder.build(
            selected: mapped[0].2,
            candidates: Array(repeating: probeCandidates[0], count: 129)
        ))
        XCTAssertGreaterThan(ClashGeoSiteDomainCount("cn"), 0)

        let geoIP = base.appendingPathComponent("geoip.metadb").path
        let geoSite = base.appendingPathComponent("geosite.dat").path
        error = nil
        XCTAssertTrue(ClashValidateGeodataForIOS("geoip", "mmdb", geoIP, &error), "Pinned GeoIP database is invalid")
        error = nil
        XCTAssertTrue(ClashValidateGeodataCodesForIOS("geosite", "dat", geoSite, "cn", &error), "Pinned GeoSite has no usable CN category")
        let signedGeoSite = appResources.appendingPathComponent("geosite.dat")
        let approvedDigest = try GeoDataPreparer.streamingDigest(at: signedGeoSite)
        XCTAssertEqual(approvedDigest.count, 64)
        XCTAssertEqual(try GeoDataPreparer.streamingDigest(at: URL(fileURLWithPath: geoSite)), approvedDigest)

        func matchedPolicy(_ query: String) throws -> String {
            error = nil
            let result = try XCTUnwrap(ClashMatchRuleForIOS(rule.yaml, "", query, &error), "Pinned SDK could not evaluate rule fixture")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.value.utf8)) as? [String: Any])
            XCTAssertEqual(object["matched"] as? Bool, true)
            XCTAssertNotEqual(object["undecided"] as? Bool, true)
            return try XCTUnwrap(object["policy"] as? String)
        }
        XCTAssertEqual(try matchedPolicy(#"{"ip":"10.1.2.3"}"#), "DIRECT")
        XCTAssertEqual(try matchedPolicy(#"{"ip":"fc00::1"}"#), "DIRECT")
        XCTAssertEqual(try matchedPolicy(#"{"host":"www.baidu.com"}"#), "DIRECT")
        XCTAssertEqual(try matchedPolicy(#"{"ip":"223.5.5.5"}"#), "DIRECT")
        XCTAssertEqual(try matchedPolicy(#"{"host":"www.wikipedia.org","ip":"198.51.100.8"}"#), "VPN")

        let damaged = base.appendingPathComponent("damaged-geosite.dat")
        try Data(repeating: 0x7f, count: 1_024).write(to: damaged)
        error = nil
        XCTAssertFalse(ClashValidateGeodataCodesForIOS(
            "geosite", "dat", damaged.path, "cn", &error
        ), "Damaged GeoSite must fail before a live RULE switch")
        XCTAssertNotEqual(try GeoDataPreparer.streamingDigest(at: damaged), approvedDigest)
        error = nil
        XCTAssertFalse(ClashValidateGeodataForIOS(
            "geoip", "mmdb", base.appendingPathComponent("missing-geoip.metadb").path, &error
        ), "Missing GeoIP must fail before Core startup")
    }

    func testInjectedSubscriptionTransportPreservesParsing() async throws {
        let fixture = yaml
        let transport = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .subscription)
            return (Data(fixture.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/yaml"]
            )!)
        }
        let downloaded = try await SubscriptionFetcher(transport: transport).fetchSubscription(
            from: "https://example.invalid/sub?token=fixture-only", userAgent: "Offline-Test"
        )
        XCTAssertEqual(try SubscriptionParser().parse(downloaded).nodes.count, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.timeout, 60)
    }

    func testInjectedSubscriptionTransportKeepsLimitedRetry() async throws {
        let counter = AttemptCounter()
        let clock = BudgetTestClock(autoBackoff: true)
        let fixture = yaml
        let transport = RecordingNetworkTransport { request, _ in
            await counter.increment()
            if await counter.value == 1 { throw URLError(.timedOut) }
            return (Data(fixture.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!)
        }
        _ = try await SubscriptionFetcher(
            transport: transport, recoveryRouter: APIRecoveryRouter(clock: clock.clock)
        ).fetchSubscription(
            from: "https://example.invalid/sub", userAgent: "Offline-Test"
        )
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testSubscriptionUsesPhysicalNetworkAfterPrimaryTransportFailure() async throws {
        let fixture = yaml
        let primary = RecordingNetworkTransport { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let physical = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .subscription)
            return (Data(fixture.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/yaml"]
            )!)
        }

        let result = try await SubscriptionFetcher(
            transport: primary, physicalNetworkTransport: physical,
            isSystemVPNActive: { true }
        ).fetchSubscription(
            from: "https://example.invalid/sub", userAgent: "Offline-Test"
        )

        XCTAssertEqual(result, fixture)
        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        XCTAssertEqual(primaryCalls.count, 2)
        XCTAssertEqual(physicalCalls.count, 1)
    }

    func testSubscriptionPrimarySuccessDoesNotUsePhysicalNetwork() async throws {
        let fixture = yaml
        let primary = RecordingNetworkTransport { request, _ in
            (Data(fixture.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!)
        }
        let physical = RecordingNetworkTransport { _, _ in
            XCTFail("Physical fallback must not run after primary success")
            throw URLError(.unknown)
        }

        _ = try await SubscriptionFetcher(
            transport: primary, physicalNetworkTransport: physical,
            isSystemVPNActive: { true }
        ).fetchSubscription(
            from: "https://example.invalid/sub", userAgent: "Offline-Test"
        )

        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        XCTAssertEqual(primaryCalls.count, 1)
        XCTAssertEqual(physicalCalls.count, 0)
    }

    func testSubscriptionPhysicalNetworkHTTPFailureRemainsFailure() async {
        let primary = RecordingNetworkTransport { _, _ in
            throw URLError(.networkConnectionLost)
        }
        let physical = RecordingNetworkTransport { request, _ in
            (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: nil
            )!)
        }

        do {
            _ = try await SubscriptionFetcher(
                transport: primary, physicalNetworkTransport: physical,
                isSystemVPNActive: { true }
            ).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test"
            )
            XCTFail("Expected the physical response failure")
        } catch let error as SubscriptionFetchError {
            XCTAssertEqual(error, .invalidHTTPResponse(statusCode: 503))
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        XCTAssertEqual(primaryCalls.count, 2)
        XCTAssertEqual(physicalCalls.count, 1)
    }

    func testSubscriptionCancellationNeverUsesPhysicalNetwork() async {
        let primary = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        let physical = RecordingNetworkTransport { _, _ in
            XCTFail("Cancellation must not enter physical fallback")
            throw URLError(.unknown)
        }

        do {
            _ = try await SubscriptionFetcher(
                transport: primary, physicalNetworkTransport: physical,
                isSystemVPNActive: { true }
            ).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test"
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError")
        }
        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        XCTAssertEqual(primaryCalls.count, 1)
        XCTAssertEqual(physicalCalls.count, 0)
    }

    func testSubscriptionActiveVPNNeverStartsBuiltInRecoveryAfterBothPathsFail() async {
        let clock = BudgetTestClock(autoBackoff: true)
        let runtime = SubscriptionRecoveryRuntimeSpy(payload: Data("proxies: []".utf8))
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime, clock: clock.clock
        )
        let primary = RecordingNetworkTransport { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let physical = RecordingNetworkTransport { _, _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await SubscriptionFetcher(
                transport: primary, physicalNetworkTransport: physical,
                isSystemVPNActive: { true }, recoveryRouter: router
            ).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test",
                builtInProxy: [subscriptionRecoveryCandidate]
            )
            XCTFail("Expected both active-VPN paths to fail")
        } catch let error as SubscriptionFetchError {
            XCTAssertEqual(error, .downloadFailed)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }

        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        let recoveryCounts = await runtime.counts
        XCTAssertEqual(primaryCalls.count, 2)
        XCTAssertEqual(physicalCalls.count, 1)
        XCTAssertEqual(recoveryCounts.starts, 0)
        XCTAssertEqual(recoveryCounts.stops, 0)
    }

    func testSubscriptionDisconnectedPreservesDirectRetryAndBuiltInRecovery() async throws {
        let clock = BudgetTestClock(autoBackoff: true)
        let payload = Data("proxies: []".utf8)
        let runtime = SubscriptionRecoveryRuntimeSpy(payload: payload)
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false,
            clock: clock.clock
        )
        let primary = RecordingNetworkTransport { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let physical = RecordingNetworkTransport { _, _ in
            XCTFail("A disconnected VPN must retain the existing recovery path")
            throw URLError(.unknown)
        }

        let result = try await SubscriptionFetcher(
            transport: primary, physicalNetworkTransport: physical,
            isSystemVPNActive: { false }, recoveryRouter: router
        ).fetchSubscription(
            from: "https://example.invalid/sub", userAgent: "Offline-Test",
            builtInProxy: [subscriptionRecoveryCandidate]
        )

        XCTAssertEqual(result, String(decoding: payload, as: UTF8.self))
        let primaryCalls = await primary.calls
        let physicalCalls = await physical.calls
        let recoveryCounts = await runtime.counts
        XCTAssertEqual(primaryCalls.count, 2)
        XCTAssertEqual(physicalCalls.count, 0)
        XCTAssertEqual(recoveryCounts.starts, 1)
        XCTAssertEqual(recoveryCounts.stops, 1)
    }

    func testStep261SecureConnectionFailureRetriesOnceThenSucceeds() async throws {
        let counter = AttemptCounter()
        let clock = BudgetTestClock(autoBackoff: true)
        let fixture = yaml
        let transport = RecordingNetworkTransport { request, _ in
            await counter.increment()
            if await counter.value == 1 { throw URLError(.secureConnectionFailed) }
            return (Data(fixture.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!)
        }

        let result = try await SubscriptionFetcher(
            transport: transport, recoveryRouter: APIRecoveryRouter(clock: clock.clock)
        ).fetchSubscription(from: "https://example.invalid/sub", userAgent: "Offline-Test")

        XCTAssertEqual(result, fixture)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testStep261SecureConnectionFailureStopsAtExistingRetryLimit() async {
        let clock = BudgetTestClock(autoBackoff: true)
        let transport = RecordingNetworkTransport { _, _ in
            throw URLError(.secureConnectionFailed)
        }
        do {
            _ = try await SubscriptionFetcher(
                transport: transport, recoveryRouter: APIRecoveryRouter(clock: clock.clock)
            ).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test"
            )
            XCTFail("Expected the bounded retry to fail")
        } catch let error as SubscriptionFetchError {
            XCTAssertEqual(error, .downloadFailed)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testStep261UntrustedCertificateIsNotRetried() async {
        await assertStep261CertificateFailureIsNotRetried(.serverCertificateUntrusted)
    }

    func testStep261BadDateCertificateIsNotRetried() async {
        await assertStep261CertificateFailureIsNotRetried(.serverCertificateHasBadDate)
    }

    private func assertStep261CertificateFailureIsNotRetried(
        _ code: URLError.Code,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let clock = BudgetTestClock(autoBackoff: true)
        let transport = RecordingNetworkTransport { _, _ in throw URLError(code) }
        do {
            _ = try await SubscriptionFetcher(
                transport: transport, recoveryRouter: APIRecoveryRouter(clock: clock.clock)
            ).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test"
            )
            XCTFail("Certificate trust errors must fail without retry", file: file, line: line)
        } catch let error as SubscriptionFetchError {
            XCTAssertEqual(error, .downloadFailed, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))", file: file, line: line)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1, file: file, line: line)
    }

    func testInjectedSubscriptionCancellationIsNotRetried() async {
        let transport = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        do {
            _ = try await SubscriptionFetcher(transport: transport).fetchSubscription(
                from: "https://example.invalid/sub", userAgent: "Offline-Test"
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }
    #endif

    #if ROUTE_VALIDATION
    func testEndpointLookupSummaryCountsRejectedAddressClassesWithoutAddresses() {
        var summary = EndpointLookupSummary()
        for value in ["10.0.0.1", "127.0.0.1", "169.254.1.1", "198.18.0.2",
                      "100.64.0.1", "198.51.100.1", "0.0.0.0"] {
            summary.recordRejected(value)
        }
        XCTAssertEqual(summary.rejectedPrivate, 1)
        XCTAssertEqual(summary.rejectedLoopback, 1)
        XCTAssertEqual(summary.rejectedLinkLocal, 1)
        XCTAssertEqual(summary.rejectedBenchmark, 1)
        XCTAssertEqual(summary.rejectedShared, 1)
        XCTAssertEqual(summary.rejectedDocumentation, 1)
        XCTAssertEqual(summary.rejectedOther, 1)
        XCTAssertFalse(summary.safeDescription.contains("198.51.100.1"))
    }
    #endif
}

#if !NETWORKCLIENT_ROUTE_CONTRACT_TESTS
enum Stage2BFixture {
    static let uuid = "00000000-0000-4000-8000-000000000001"
    static func base(_ name: String = "Collision Fixture") -> [String: YAMLValue] {
        ["name": .string(name), "type": .string("vless"), "server": .string("198.51.100.10"),
         "port": .integer(443), "uuid": .string(uuid), "tls": .bool(true),
         "servername": .string("edge.fixture.invalid"), "network": .string("tcp"),
         "client-fingerprint": .string("chrome"),
         "reality-opts": .object(["public-key": .string(Data(repeating: 0, count: 32).base64EncodedString()),
                                   "short-id": .string("abcd")])]
    }
    static func changed(_ proxy: [String: YAMLValue], _ key: String, _ value: YAMLValue?) -> [String: YAMLValue] {
        var copy = proxy
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            var options: [String: YAMLValue] = [:]
            if case let .object(old)? = copy[parts[0]] { options = old }
            options[parts[1]] = value
            copy[parts[0]] = .object(options)
        } else { copy[key] = value }
        return copy
    }
    static func variants(_ field: String) -> [[String: YAMLValue]] {
        var a = base(), b = a
        switch field {
        case "flow": b["flow"] = .string("xtls-rprx-vision")
        case "key": b = changed(b, "reality-opts.public-key", .string(Data(repeating: 1, count: 32).base64EncodedString()))
        case "short": b = changed(b, "reality-opts.short-id", .string("cdef"))
        case "mlkem": b = changed(b, "reality-opts.support-x25519mlkem768", .bool(true))
        case "ws", "grpc":
            a.removeValue(forKey: "reality-opts")
            a["network"] = .string(field)
            a[field + "-opts"] = .object([field == "ws" ? "path" : "grpc-service-name": .string("a")])
            b = changed(a, field + "-opts." + (field == "ws" ? "path" : "grpc-service-name"), .string("b"))
        case "ss", "hy2", "tuic":
            a = ["name": .string("Collision Fixture"), "type": .string(field == "hy2" ? "hysteria2" : field),
                 "server": .string("198.51.100.10"), "port": .integer(443)]
            if field == "ss" {
                a.merge(["cipher": .string("aes-128-gcm"), "password": .string("synthetic-ss"),
                         "plugin": .string("v2ray-plugin"), "plugin-opts": .object(["mode": .string("websocket"), "path": .string("/a")])]) { _, n in n }
                b = changed(a, "plugin-opts.path", .string("/b"))
            } else if field == "hy2" {
                a.merge(["password": .string("synthetic-hy2"), "sni": .string("edge.fixture.invalid"),
                         "obfs": .string("salamander"), "obfs-password": .string("synthetic-a")]) { _, n in n }
                b = changed(a, "obfs-password", .string("synthetic-b"))
            } else {
                a.merge(["sni": .string("edge.fixture.invalid"), "token": .string("synthetic-token-a")]) { _, n in n }
                b = changed(a, "token", .string("synthetic-token-b"))
            }
        default: preconditionFailure("Unknown synthetic case")
        }
        return [a, b]
    }
    static func yaml(_ proxies: [[String: YAMLValue]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject:
            ["proxies": proxies.map { YAMLValue.object($0).foundationValue }], options: [.sortedKeys]), as: UTF8.self)
    }
    static func parse(_ proxies: [[String: YAMLValue]]) throws -> ParsedSubscription {
        try SubscriptionParser().parse(yaml(proxies))
    }
    static func digest(_ proxy: [String: YAMLValue]) throws -> String {
        try OriginalProxyCanonicalization.digest(proxy)
    }
    static func id(_ proxy: [String: YAMLValue], in subscription: ParsedSubscription) throws -> String {
        try XCTUnwrap(subscription.runtimeProxyRecords.values.first { $0.originalProxy == proxy }?.nodeID)
    }
    // The old projection deliberately has no full-proxy collision key.
    static func legacy(_ proxies: [[String: YAMLValue]]) throws -> ParsedSubscription {
        func text(_ p: [String: YAMLValue], _ key: String) -> String {
            if case let .string(value)? = p[key] { return value }; return ""
        }
        let sources = proxies.map { p in
            NodeIdentitySource(originalName: text(p, "name"), type: text(p, "type"),
                server: text(p, "server"), port: 443, uuid: text(p, "uuid"), password: text(p, "password"),
                cipher: text(p, "cipher"), sni: text(p, "sni"), serverName: text(p, "servername"),
                network: text(p, "network"), security: text(p, "security"))
        }
        let nodes = try NodeIdentityFactory.makeNodes(from: sources)
        var records: [String: RuntimeProxyRecord] = [:]
        for (node, proxy) in zip(nodes, proxies) {
            var runtime = proxy; runtime["name"] = .string(node.coreName)
            records[node.id] = RuntimeProxyRecord(nodeID: node.id, originalName: node.originalName,
                coreName: node.coreName, originalProxy: proxy, runtimeProxy: runtime, issue: nil)
        }
        return ParsedSubscription(nodes: nodes, runtimeProxyRecords: records)
    }
}

final class Stage2BIdentityTests: XCTestCase {
    func testUniqueNameIDsRemainByteCompatibleAcrossConfigurationChanges() throws {
        let base = Stage2BFixture.base()
        let variants = [
            base,
            Stage2BFixture.changed(base, "server", .string("198.51.100.11")),
            Stage2BFixture.changed(base, "uuid", .string("00000000-0000-4000-8000-000000000002")),
            Stage2BFixture.variants("flow")[1], Stage2BFixture.variants("key")[1],
            Stage2BFixture.variants("short")[1], Stage2BFixture.variants("ws")[0]
        ]
        let oldRevision = try Stage2BFixture.digest(base)
        for (index, proxy) in variants.enumerated() {
            let parsed = try Stage2BFixture.parse([proxy])
            XCTAssertEqual(parsed.nodes[0].id, "c7139046847ac7e08eaee28c")
            XCTAssertEqual(try SelectedNodeConfigurationIdentity.revision(in: parsed, nodeID: parsed.nodes[0].id),
                           try Stage2BFixture.digest(proxy))
            if index > 0 { XCTAssertNotEqual(try Stage2BFixture.digest(proxy), oldRevision) }
        }
    }
    func testOrdinaryEndpointDuplicateIDsAndCoreNamesRemainLegacyCompatible() throws {
        let a = Stage2BFixture.base(), b = Stage2BFixture.changed(a, "server", .string("198.51.100.11"))
        for proxies in [[a,b], [b,a]] {
            let sub = try Stage2BFixture.parse(proxies)
            let aid = try Stage2BFixture.id(a, in: sub), bid = try Stage2BFixture.id(b, in: sub)
            XCTAssertEqual(aid, "e22d58d192dee4532051f956")
            XCTAssertEqual(bid, "807147ca65656610ce373482")
            XCTAssertEqual(sub.runtimeProxyRecords[aid]?.coreName, "ky-e22d58d192dee453")
            XCTAssertEqual(sub.runtimeProxyRecords[bid]?.coreName, "ky-807147ca65656610")
        }
    }
    func testOrdinaryUUIDDuplicateIDsRemainLegacyCompatible() throws {
        let a = Stage2BFixture.base(), b = Stage2BFixture.changed(a, "uuid", .string("00000000-0000-4000-8000-000000000002"))
        for proxies in [[a,b], [b,a]] {
            let sub = try Stage2BFixture.parse(proxies)
            XCTAssertEqual(try Stage2BFixture.id(a, in: sub), "e22d58d192dee4532051f956")
            XCTAssertEqual(try Stage2BFixture.id(b, in: sub), "8b83ad545d5c812cddde2a40")
        }
    }
    private func assertStable(_ field: String) throws {
        let proxies = Stage2BFixture.variants(field)
        let old = try Stage2BFixture.parse(proxies), new = try Stage2BFixture.parse(proxies.reversed())
        XCTAssertEqual(old.nodes[0].fingerprint, old.nodes[1].fingerprint)
        XCTAssertEqual(Set(old.nodes.map(\.id)).count, 2)
        XCTAssertEqual(Set(old.nodes.map(\.coreName)).count, 2)
        for proxy in proxies {
            let before = try Stage2BFixture.id(proxy, in: old), after = try Stage2BFixture.id(proxy, in: new)
            XCTAssertEqual(before, after, field)
            XCTAssertEqual(old.runtimeProxyRecords[before]?.coreName, new.runtimeProxyRecords[after]?.coreName)
        }
    }
    func testFlowOnlyCollisionReorder() throws { try assertStable("flow") }
    func testRealityPublicKeyOnlyCollisionReorder() throws { try assertStable("key") }
    func testShortIDOnlyCollisionReorder() throws { try assertStable("short") }
    func testWebSocketPathOnlyCollisionReorder() throws { try assertStable("ws") }
    func testGRPCServiceOnlyCollisionReorder() throws { try assertStable("grpc") }
    func testShadowsocksPluginPathOnlyCollisionReorder() throws { try assertStable("ss") }
    func testHysteria2ObfsPasswordOnlyCollisionReorder() throws { try assertStable("hy2") }
    func testTUICTokenOnlyCollisionReorder() throws { try assertStable("tuic") }
    func testMLKEMParticipatesWithoutRuntimeRewrite() throws {
        try assertStable("mlkem")
        let proxies = Stage2BFixture.variants("mlkem"), sub = try Stage2BFixture.parse(proxies)
        XCTAssertNotEqual(try Stage2BFixture.digest(proxies[0]), try Stage2BFixture.digest(proxies[1]))
        let id = try Stage2BFixture.id(proxies[1], in: sub)
        guard case let .object(options)? = sub.runtimeProxyRecords[id]?.runtimeProxy?["reality-opts"] else {
            return XCTFail("Missing unchanged runtime Reality")
        }
        XCTAssertEqual(options["support-x25519mlkem768"], .bool(true))
    }
    func testTripleCollisionRotationKeepsEachEntityAndCoreName() throws {
        let pair = Stage2BFixture.variants("flow"), c = Stage2BFixture.variants("short")[1]
        let old = try Stage2BFixture.parse(pair + [c]), new = try Stage2BFixture.parse([c] + pair)
        for proxy in pair + [c] {
            let a = try Stage2BFixture.id(proxy, in: old), b = try Stage2BFixture.id(proxy, in: new)
            XCTAssertEqual(a,b)
            XCTAssertEqual(old.runtimeProxyRecords[a]?.coreName, new.runtimeProxyRecords[b]?.coreName)
        }
    }
    func testCompletelyIdenticalOccurrencesRemainUniqueWithoutEntityClaims() throws {
        let a = Stage2BFixture.base()
        for count in [2,3,2] {
            let sub = try Stage2BFixture.parse(Array(repeating: a, count: count))
            XCTAssertEqual(Set(sub.nodes.map(\.id)).count, count)
            XCTAssertEqual(Set(sub.nodes.map(\.coreName)).count, count)
            XCTAssertEqual(Set(try sub.runtimeProxyRecords.values.map { try Stage2BFixture.digest($0.originalProxy) }).count, 1)
        }
    }
    func testCanonicalizationPreservesRevisionSemanticsAndArrayOrder() throws {
        let a = "proxies:\n - {name: Canonical, type: ss, server: fixture.invalid, port: 443, password: synthetic, cipher: aes-128-gcm}\n"
        let b = "proxies:\n - cipher: aes-128-gcm\n   password: synthetic\n   port: 443\n   server: fixture.invalid\n   type: ss\n   name: Canonical\n"
        let x = try SubscriptionParser().parse(a), y = try SubscriptionParser().parse(b)
        XCTAssertEqual(x, y)
        let p = Stage2BFixture.changed(Stage2BFixture.base(), "alpn", .array([.string("h2"),.string("http/1.1")]))
        let q = Stage2BFixture.changed(p, "alpn", .array([.string("http/1.1"),.string("h2")]))
        XCTAssertNotEqual(try Stage2BFixture.digest(p), try Stage2BFixture.digest(q))
        let raw = try JSONSerialization.data(withJSONObject: YAMLValue.object(p).foundationValue, options: [.sortedKeys])
        XCTAssertEqual(try Stage2BFixture.digest(p), NodeHash.sha256Hex(String(decoding: raw, as: UTF8.self)))
    }

    func testFixedCandidatePoolKeepsOneHundredMappedNodesDeterministically() throws {
        let rows = (0..<100).map { index in
            "  - {name: Synthetic \(index), type: ss, server: 198.51.100.\(index + 1), port: 443, cipher: aes-128-gcm, password: synthetic-\(index)}"
        }
        let subscription = try SubscriptionParser().parse(
            "proxies:\n" + rows.joined(separator: "\n") + "\n"
        )
        XCTAssertEqual(subscription.nodes.count, 100)
        let dns = try XCTUnwrap(URL(string: "https://192.0.2.53/dns-query"))
        let mapped: [MihomoTunnelConfiguration] = try subscription.nodes.map { node in
            let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(
                in: subscription, nodeID: node.id
            ))
            return try SelectedNodeTunnelMapper().makeConfiguration(
                subscription: subscription,
                request: .init(nodeID: node.id, mode: .rule,
                               configurationRevision: revision),
                dnsEndpoint: dns
            )
        }
        let candidates: [NodeProbeCandidate] = try mapped.map { value in
            NodeProbeCandidate(
                nodeID: value.nodeID,
                revision: try XCTUnwrap(value.configurationRevision),
                coreName: try XCTUnwrap(value.coreName),
                yaml: try MihomoNodeProbeConfiguration.yaml(from: value.yaml)
            )
        }
        let first = try MihomoStableCandidatePoolBuilder.build(
            selected: mapped[0], candidates: candidates
        )
        let second = try MihomoStableCandidatePoolBuilder.build(
            selected: mapped[0], candidates: candidates
        )
        XCTAssertEqual(first.candidates.count, 100)
        XCTAssertEqual(Set(first.candidates.map(\.coreName)).count, 100)
        XCTAssertEqual(first.candidates.first?.nodeID, mapped[0].nodeID)
        XCTAssertEqual(first.yaml, second.yaml)
        XCTAssertEqual(first.revision, second.revision)
        let root = try XCTUnwrap(Yams.load(yaml: first.yaml) as? [String: Any])
        let group = try XCTUnwrap((root["proxy-groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["proxies"] as? [String], candidates.map(\.coreName))
    }
}

private actor SubscriptionRecoveryRuntimeSpy: BuiltInProxyRecoveryRuntimeProtocol {
    private var starts = 0
    private var stops = 0
    private let transport: any NetworkTransport

    var counts: (starts: Int, stops: Int) { (starts, stops) }

    init(payload: Data) {
        transport = RecordingNetworkTransport { request, _ in
            (payload, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/yaml"]
            )!)
        }
    }

    func start(
        endpoint: BuiltInProxyEndpoint
    ) -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        return .init(protocolName: endpoint.protocolName, mixedPort: 1)
    }

    func makeRecoveryTransport() -> any NetworkTransport { transport }

    func stopRecovery() { stops += 1 }
}
#endif
