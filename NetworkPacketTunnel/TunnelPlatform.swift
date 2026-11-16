import Clash
import Darwin
import Foundation
import Network
import NetworkExtension

private enum TunnelPlatformFailure: Error {
    case missingProvider
    case missingOptions
    case cancelled
    case invalidSettings
    case settingsTimedOut
    case defaultPathUnavailable
}
/// The semaphore gives Core's synchronous OpenTun callback a bounded wait for
/// Apple's asynchronous network-settings API.
private final class SettingsReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    let semaphore = DispatchSemaphore(value: 0)

    func complete(_ error: Error?) {
        lock.lock()
        result = error.map(Result.failure) ?? .success(())
        lock.unlock()
        semaphore.signal()
    }

    func value() throws {
        lock.lock()
        let result = result
        lock.unlock()
        try result?.get()
    }
}

/// Apple platform bridge only. Core owns DNS, route selection, public
/// outbounds and network-session reset policy.
final class TunnelPlatform: NSObject, ClashPlatformInterfaceProtocol, @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    private let lock = NSLock()
    private var stopped = false
    private var packetBridge: PacketFlowBridge?
    private var pathMonitor: NWPathMonitor?
    private var pathListener: (any ClashInterfaceUpdateListenerProtocol)?
    private var defaultPath: DefaultPathSnapshot?
    private var monitorEpoch: UInt64 = 0
    private var tunnelAddresses: Set<String> = []

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func openTun(
        _ options: (any ClashTunOptionsProtocol)?,
        ret0_: UnsafeMutablePointer<Int32>?
    ) throws {
        guard let options, let ret0_ else {
            throw TunnelPlatformFailure.missingOptions
        }
        guard let provider else {
            throw TunnelPlatformFailure.missingProvider
        }
        guard !isStopped else {
            throw TunnelPlatformFailure.cancelled
        }
        let settings = try makeSettings(options)
        let reply = SettingsReply()
        provider.setTunnelNetworkSettings(settings) { reply.complete($0) }
        guard reply.semaphore.wait(timeout: .now() + .seconds(10)) == .success else {
            throw TunnelPlatformFailure.settingsTimedOut
        }
        try reply.value()
        guard !isStopped else {
            throw TunnelPlatformFailure.cancelled
        }

        let bridge = PacketFlowBridge(packetFlow: provider.packetFlow) { [weak provider] error in
            provider?.cancelTunnelWithError(error)
        }
        let descriptor = try bridge.start()
        lock.lock()
        if stopped {
            lock.unlock()
            bridge.stop()
            throw TunnelPlatformFailure.cancelled
        }
        packetBridge = bridge
        lock.unlock()
        ret0_.pointee = descriptor
    }

    func stop() {
        lock.lock()
        stopped = true
        let bridge = packetBridge
        let monitor = pathMonitor
        packetBridge = nil
        pathMonitor = nil
        pathListener = nil
        defaultPath = nil
        tunnelAddresses.removeAll()
        monitorEpoch &+= 1
        lock.unlock()
        monitor?.cancel()
        bridge?.stop()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func makeSettings(
        _ options: any ClashTunOptionsProtocol
    ) throws -> NEPacketTunnelNetworkSettings {
        let mtu = Int(options.getMTU())
        let dnsAddress = try options.getDNSServerAddress().value
        guard (1_280...9_000).contains(mtu), !dnsAddress.isEmpty,
              let v4Iterator = options.getInet4Address() else {
            throw TunnelPlatformFailure.invalidSettings
        }

        let ipv4Addresses = collectAddresses(v4Iterator)
        let ipv6Addresses = options.getInet6Address().map(collectAddresses) ?? []
        lock.lock()
        let pathSupportsIPv6 = defaultPath?.supportsIPv6 == true
        lock.unlock()
        let ipv6Mode = options.getIPv6Mode()
        let strictRoute = options.getStrictRoute()
        let useIPv6 = IPv6RouteInstallationPolicy.shouldInstall(
            coreMode: ipv6Mode,
            hasIPv6TunnelAddress: !ipv6Addresses.isEmpty,
            physicalPathSupportsIPv6: pathSupportsIPv6
        )

        guard TunnelRoutingPolicy.accepts(
            dnsAddress: dnsAddress,
            ipv4Addresses: ipv4Addresses.map(\.address),
            ipv4Masks: ipv4Addresses.map(\.mask),
            ipv6Addresses: useIPv6 ? ipv6Addresses.map(\.address) : [],
            ipv6Prefixes: useIPv6 ? ipv6Addresses.map(\.prefix) : []
        ) else { throw TunnelPlatformFailure.invalidSettings }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)
        settings.tunnelOverheadBytes = nil

        let ipv4 = NEIPv4Settings(
            addresses: ipv4Addresses.map(\.address),
            subnetMasks: ipv4Addresses.map(\.mask)
        )
        guard let v4Included = options.getInet4RouteAddress(),
              let v4Excluded = options.getInet4RouteExcludeAddress() else {
            throw TunnelPlatformFailure.invalidSettings
        }
        let coreIncluded4 = collectIPv4Routes(v4Included)
        let coreExcluded4 = collectIPv4Routes(v4Excluded)
        let routePlan4 = IPv4CaptureRouteBuilder.build(
            coreIncludedRoutes: coreIncluded4.map {
                .init(destinationAddress: $0.destinationAddress, subnetMask: $0.destinationSubnetMask)
            },
            coreExcludedRoutes: coreExcluded4.map {
                .init(destinationAddress: $0.destinationAddress, subnetMask: $0.destinationSubnetMask)
            },
            hasIPv4TunnelAddress: !ipv4Addresses.isEmpty,
            strictRoute: strictRoute
        )
        ipv4.includedRoutes = routePlan4.includedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
        }
        ipv4.excludedRoutes = routePlan4.excludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
        }
        settings.ipv4Settings = ipv4

        if useIPv6 {
            guard let v6Included = options.getInet6RouteAddress(),
                  let v6Excluded = options.getInet6RouteExcludeAddress() else {
                throw TunnelPlatformFailure.invalidSettings
            }
            let included6Intent = collectIPv6Routes(v6Included)
            let excluded6Intent = collectIPv6Routes(v6Excluded)
            let ipv6 = NEIPv6Settings(
                addresses: ipv6Addresses.map(\.address),
                networkPrefixLengths: ipv6Addresses.map { NSNumber(value: $0.prefix) }
            )
            var included6 = included6Intent
            // Once the IPv6 stack passes its existing Core/address/physical
            // path gate, it also needs a real NE capture route.
            if included6.isEmpty {
                included6 = [NEIPv6Route(destinationAddress: "::", networkPrefixLength: 0)]
            }
            ipv6.includedRoutes = included6
            ipv6.excludedRoutes = excluded6Intent
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: [dnsAddress])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns

        lock.lock()
        tunnelAddresses = Set(ipv4Addresses.map(\.address))
            .union(useIPv6 ? ipv6Addresses.map(\.address) : [])
        lock.unlock()
        return settings
    }

    private typealias Address = (address: String, mask: String, prefix: Int)

    private func collectAddresses(_ iterator: any ClashRoutePrefixIteratorProtocol) -> [Address] {
        var result: [Address] = []
        while iterator.hasNext() {
            guard let value = iterator.next() else { break }
            result.append((value.address(), value.mask(), Int(value.prefix())))
        }
        return result
    }

    private func collectIPv4Routes(
        _ iterator: any ClashRoutePrefixIteratorProtocol
    ) -> [NEIPv4Route] {
        var routes: [NEIPv4Route] = []
        while iterator.hasNext() {
            guard let value = iterator.next() else { break }
            routes.append(NEIPv4Route(destinationAddress: value.address(), subnetMask: value.mask()))
        }
        return routes
    }

    private func collectIPv6Routes(
        _ iterator: any ClashRoutePrefixIteratorProtocol
    ) -> [NEIPv6Route] {
        var routes: [NEIPv6Route] = []
        while iterator.hasNext() {
            guard let value = iterator.next() else { break }
            routes.append(NEIPv6Route(
                destinationAddress: value.address(),
                networkPrefixLength: NSNumber(value: value.prefix())
            ))
        }
        return routes
    }

    // Required by the SDK protocol but deliberately disabled by
    // usePlatformAutoDetectControl(). Swift owns no outbound egress policy.
    func autoDetectControl(_ fd: Int32) throws { _ = fd }

    func usePlatformAutoDetectControl() -> Bool { false }

    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        lock.lock()
        let path = defaultPath
        let addresses = tunnelAddresses
        lock.unlock()
        let iterator = NetworkInterfaceIterator(
            NetworkInterfaceInventory.current(path: path, tunnelAddresses: addresses)
        )
        return iterator
    }

    func startDefaultInterfaceMonitor(
        _ listener: (any ClashInterfaceUpdateListenerProtocol)?
    ) throws {
        guard let listener else {
            throw TunnelPlatformFailure.defaultPathUnavailable
        }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkClient.MihomoPacketTunnel.default-path")
        let ready = DispatchSemaphore(value: 0)

        lock.lock()
        guard !stopped, pathMonitor == nil else {
            lock.unlock()
            throw TunnelPlatformFailure.cancelled
        }
        pathMonitor = monitor
        pathListener = listener
        monitorEpoch &+= 1
        let epoch = monitorEpoch
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let monitor else { return }
            self?.accept(path, from: monitor, epoch: epoch, ready: ready)
        }
        monitor.start(queue: queue)
        guard ready.wait(timeout: .now() + .seconds(3)) == .success else {
            try closeDefaultInterfaceMonitor(listener)
            throw TunnelPlatformFailure.defaultPathUnavailable
        }
        lock.lock()
        let usable = !stopped && defaultPath != nil && pathMonitor === monitor
        lock.unlock()
        guard usable else {
            try closeDefaultInterfaceMonitor(listener)
            throw TunnelPlatformFailure.defaultPathUnavailable
        }
    }

    func closeDefaultInterfaceMonitor(
        _ listener: (any ClashInterfaceUpdateListenerProtocol)?
    ) throws {
        _ = listener
        lock.lock()
        let monitor = pathMonitor
        pathMonitor = nil
        pathListener = nil
        defaultPath = nil
        monitorEpoch &+= 1
        lock.unlock()
        monitor?.cancel()
    }

    private func accept(
        _ path: NWPath, from monitor: NWPathMonitor,
        epoch: UInt64, ready: DispatchSemaphore
    ) {
        let snapshot = Self.snapshot(from: path)
        lock.lock()
        guard !stopped, monitorEpoch == epoch, pathMonitor === monitor else {
            lock.unlock()
            return
        }
        let wasReady = defaultPath != nil
        defaultPath = snapshot
        let listener = pathListener
        lock.unlock()

        listener?.updateDefaultInterface(
            snapshot?.interface.name ?? "",
            interfaceIndex: snapshot.map { Int32(bitPattern: $0.interface.index) } ?? 0,
            isExpensive: snapshot?.isExpensive ?? false,
            isConstrained: snapshot?.isConstrained ?? false,
            supportsIPv4: snapshot?.supportsIPv4 ?? false,
            supportsIPv6: snapshot?.supportsIPv6 ?? false
        )
        if !wasReady, snapshot != nil { ready.signal() }
    }

    private static func snapshot(from path: NWPath) -> DefaultPathSnapshot? {
        guard path.status == .satisfied else { return nil }
        let physicalTypes: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        let available = path.availableInterfaces.compactMap { interface -> DefaultPathInterface? in
            guard physicalTypes.contains(interface.type), interface.index > 0,
                  interface.index <= Int32.max,
                  if_nametoindex(interface.name) == UInt32(interface.index) else { return nil }
            return DefaultPathInterface(
                name: interface.name,
                index: UInt32(interface.index),
                kind: InterfaceKind(interface.type)
            )
        }
        guard let selected = available.first(where: { value in
            physicalTypes.contains { type in
                InterfaceKind(type) == value.kind && path.usesInterfaceType(type)
            }
        }), path.supportsIPv4 || path.supportsIPv6 else { return nil }
        return DefaultPathSnapshot(
            interface: selected,
            availableInterfaces: available,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
    }

    func underNetworkExtension() -> Bool { true }

    func writeLog(_ message: String?) {
        // Core logs may contain destinations or configuration values.
        _ = message
    }
}
