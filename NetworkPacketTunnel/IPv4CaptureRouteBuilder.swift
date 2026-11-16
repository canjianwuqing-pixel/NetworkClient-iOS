import Foundation

struct IPv4CaptureRoute: Equatable, Sendable {
    let destinationAddress: String
    let subnetMask: String
}

struct IPv4CaptureRoutePlan: Equatable, Sendable {
    let includedRoutes: [IPv4CaptureRoute]
    let excludedRoutes: [IPv4CaptureRoute]
}

/// Converts Core route intent into the routes that Apple NetworkExtension uses
/// to decide which system packets enter this Packet Tunnel. Core's auto-route
/// flag is deliberately absent: an empty Core route list cannot mean an empty
/// NE capture policy for a full Internet Packet Tunnel.
enum IPv4CaptureRouteBuilder {
    static func build(
        coreIncludedRoutes: [IPv4CaptureRoute],
        coreExcludedRoutes: [IPv4CaptureRoute],
        hasIPv4TunnelAddress: Bool,
        strictRoute: Bool
    ) -> IPv4CaptureRoutePlan {
        guard hasIPv4TunnelAddress else {
            return .init(includedRoutes: [], excludedRoutes: coreExcludedRoutes)
        }
        guard coreIncludedRoutes.isEmpty else {
            return .init(
                includedRoutes: coreIncludedRoutes,
                excludedRoutes: coreExcludedRoutes
            )
        }
        return .init(
            includedRoutes: strictRoute ? strictInternetCoverage() : [defaultRoute],
            excludedRoutes: coreExcludedRoutes
        )
    }

    private static let defaultRoute = IPv4CaptureRoute(
        destinationAddress: "0.0.0.0",
        subnetMask: "0.0.0.0"
    )

    /// Independently decomposes the ordinary IPv4 Internet range
    /// 1.0.0.0...255.255.255.255 into aligned CIDR blocks. This avoids an
    /// empty strict-route plan while keeping explicit NE exclusions effective.
    private static func strictInternetCoverage() -> [IPv4CaptureRoute] {
        var routes: [IPv4CaptureRoute] = []
        var firstOctet = 1
        while firstOctet < 256 {
            let blockSize = firstOctet & -firstOctet
            let prefixLength = 8 - blockSize.trailingZeroBitCount
            routes.append(.init(
                destinationAddress: "\(firstOctet).0.0.0",
                subnetMask: subnetMask(prefixLength: prefixLength)
            ))
            firstOctet += blockSize
        }
        return routes
    }

    private static func subnetMask(prefixLength: Int) -> String {
        let value = prefixLength == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefixLength)
        return [24, 16, 8, 0]
            .map { String((value >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }
}

enum IPv6RouteInstallationPolicy {
    static func shouldInstall(
        coreMode: String,
        hasIPv6TunnelAddress: Bool,
        physicalPathSupportsIPv6: Bool
    ) -> Bool {
        coreMode != "disabled" && hasIPv6TunnelAddress && physicalPathSupportsIPv6
    }
}
