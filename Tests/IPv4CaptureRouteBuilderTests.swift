import XCTest

final class IPv4CaptureRouteBuilderTests: XCTestCase {
    func testProvenEmptyStrictAutoRouteFalseCombinationProducesInternetCoverage() {
        let plan = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: [],
            coreExcludedRoutes: [],
            hasIPv4TunnelAddress: true,
            strictRoute: true
        )

        XCTAssertFalse(plan.includedRoutes.isEmpty)
        assertInternetCoverage(plan)
        XCTAssertEqual(Set(plan.includedRoutes.map(routeKey)).count, plan.includedRoutes.count)
    }

    func testNonStrictEmptyIntentProducesDefaultRoute() {
        let plan = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: [],
            coreExcludedRoutes: [],
            hasIPv4TunnelAddress: true,
            strictRoute: false
        )

        XCTAssertEqual(plan.includedRoutes, [route("0.0.0.0", "0.0.0.0")])
        assertInternetCoverage(plan)
    }

    func testExplicitCoreIncludedRoutesRemainAuthoritative() {
        let core = [
            route("10.0.0.0", "255.0.0.0"),
            route("203.0.113.0", "255.255.255.0")
        ]

        let plan = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: core,
            coreExcludedRoutes: [],
            hasIPv4TunnelAddress: true,
            strictRoute: true
        )

        XCTAssertEqual(plan.includedRoutes, core)
        XCTAssertFalse(captures("8.8.8.8", plan: plan))
    }

    func testCoreExclusionsRemainUnchangedAndWinEffectiveCoverage() {
        let excluded = [route("203.0.113.0", "255.255.255.0")]
        let plan = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: [],
            coreExcludedRoutes: excluded,
            hasIPv4TunnelAddress: true,
            strictRoute: true
        )

        XCTAssertEqual(plan.excludedRoutes, excluded)
        XCTAssertFalse(captures("203.0.113.9", plan: plan))
        XCTAssertTrue(captures("8.8.8.8", plan: plan))
    }

    func testMissingIPv4TunnelAddressDoesNotSynthesizeCaptureRoutes() {
        let plan = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: [],
            coreExcludedRoutes: [],
            hasIPv4TunnelAddress: false,
            strictRoute: true
        )

        XCTAssertTrue(plan.includedRoutes.isEmpty)
    }

    func testPhysicalPathWithoutIPv6KeepsIPv6SettingsDisabled() {
        XCTAssertFalse(IPv6RouteInstallationPolicy.shouldInstall(
            coreMode: "automatic",
            hasIPv6TunnelAddress: true,
            physicalPathSupportsIPv6: false
        ))
        XCTAssertTrue(IPv6RouteInstallationPolicy.shouldInstall(
            coreMode: "automatic",
            hasIPv6TunnelAddress: true,
            physicalPathSupportsIPv6: true
        ))
    }

    private func assertInternetCoverage(
        _ plan: IPv4CaptureRoutePlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for address in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "223.255.255.254"] {
            XCTAssertTrue(captures(address, plan: plan), address, file: file, line: line)
        }
    }

    private func captures(_ address: String, plan: IPv4CaptureRoutePlan) -> Bool {
        plan.includedRoutes.contains { contains(address, route: $0) }
            && !plan.excludedRoutes.contains { contains(address, route: $0) }
    }

    private func contains(_ address: String, route: IPv4CaptureRoute) -> Bool {
        guard let addressValue = ipv4(address), let routeValue = ipv4(route.destinationAddress),
              let maskValue = ipv4(route.subnetMask) else { return false }
        return addressValue & maskValue == routeValue & maskValue
    }

    private func ipv4(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func route(_ address: String, _ mask: String) -> IPv4CaptureRoute {
        .init(destinationAddress: address, subnetMask: mask)
    }

    private func routeKey(_ route: IPv4CaptureRoute) -> String {
        "\(route.destinationAddress)/\(route.subnetMask)"
    }
}
