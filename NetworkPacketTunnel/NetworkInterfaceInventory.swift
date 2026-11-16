import Clash
import Darwin
import Foundation
import Network

struct DefaultPathInterface: Equatable, Sendable {
    let name: String
    let index: UInt32
    let kind: InterfaceKind
}

struct DefaultPathSnapshot: Equatable, Sendable {
    let interface: DefaultPathInterface
    let availableInterfaces: [DefaultPathInterface]
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
}

enum InterfaceKind: Int32, Equatable, Sendable {
    case other = 0
    case wifi = 1
    case cellular = 2
    case wired = 3
    case loopback = 4
    case tunnel = 5

    init(_ type: NWInterface.InterfaceType) {
        switch type {
        case .wifi: self = .wifi
        case .cellular: self = .cellular
        case .wiredEthernet: self = .wired
        case .loopback: self = .loopback
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}

/// A point-in-time inventory only. Core remains the sole owner of route and
/// outbound-interface policy.
enum NetworkInterfaceInventory {
    struct RawRecord: Equatable, Sendable {
        let name: String
        let index: UInt32
        let mtu: Int32
        let addresses: [String]
        let systemFlags: UInt32
    }

    struct Record: Equatable, Sendable {
        let name: String
        let index: UInt32
        let mtu: Int32
        let addresses: [String]
        let flags: Int32
        let kind: InterfaceKind
        let metered: Bool
    }

    private enum CoreFlag {
        static let up: Int32 = 1
        static let broadcast: Int32 = 2
        static let loopback: Int32 = 4
        static let pointToPoint: Int32 = 8
        static let multicast: Int32 = 16
        static let running: Int32 = 32
        static let available: Int32 = 256
        static let isDefault: Int32 = 512
        static let ownTunnel: Int32 = 1_024
    }

    static func current(path: DefaultPathSnapshot?, tunnelAddresses: Set<String>) -> [Record] {
        records(from: enumerate(), path: path, tunnelAddresses: tunnelAddresses)
    }

    static func records(
        from raw: [RawRecord], path: DefaultPathSnapshot?, tunnelAddresses: Set<String>
    ) -> [Record] {
        let available = Dictionary(
            uniqueKeysWithValues: (path?.availableInterfaces ?? []).map { ($0.index, $0) }
        )
        let defaultIndex = path?.interface.index
        return raw.map { value in
            let onPath = available[value.index]
            let ownsTunnelAddress = value.addresses.contains(where: tunnelAddresses.contains)
            let kind = ownsTunnelAddress ? .tunnel : onPath?.kind ?? inferredKind(for: value)
            var flags: Int32 = 0
            if value.systemFlags & UInt32(IFF_UP) != 0 { flags |= CoreFlag.up }
            if value.systemFlags & UInt32(IFF_BROADCAST) != 0 { flags |= CoreFlag.broadcast }
            if value.systemFlags & UInt32(IFF_LOOPBACK) != 0 { flags |= CoreFlag.loopback }
            if value.systemFlags & UInt32(IFF_POINTOPOINT) != 0 { flags |= CoreFlag.pointToPoint }
            if value.systemFlags & UInt32(IFF_MULTICAST) != 0 { flags |= CoreFlag.multicast }
            if value.systemFlags & UInt32(IFF_RUNNING) != 0 { flags |= CoreFlag.running }
            if onPath != nil { flags |= CoreFlag.available }
            if value.index == defaultIndex { flags |= CoreFlag.isDefault }
            if ownsTunnelAddress { flags |= CoreFlag.ownTunnel }
            return Record(
                name: value.name,
                index: value.index,
                mtu: value.mtu,
                addresses: value.addresses,
                flags: flags,
                kind: kind,
                metered: kind == .cellular || (onPath != nil && path?.isExpensive == true)
            )
        }
    }

    static func enumerate() -> [RawRecord] {
        var start: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&start) == 0, let start else { return [] }
        defer { freeifaddrs(start) }

        var order: [String] = []
        var records: [String: RawRecord] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = cursor {
            let value = entry.pointee
            let name = String(cString: value.ifa_name)
            let index = if_nametoindex(name)
            let address = numericAddress(value.ifa_addr)
            let mtu = value.ifa_data.map {
                Int32(clamping: $0.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
            } ?? 0
            if let existing = records[name] {
                var addresses = existing.addresses
                if let address, !addresses.contains(address) { addresses.append(address) }
                records[name] = RawRecord(
                    name: name,
                    index: existing.index == 0 ? index : existing.index,
                    mtu: existing.mtu == 0 ? mtu : existing.mtu,
                    addresses: addresses,
                    systemFlags: existing.systemFlags | value.ifa_flags
                )
            } else {
                order.append(name)
                records[name] = RawRecord(
                    name: name,
                    index: index,
                    mtu: mtu,
                    addresses: address.map { [$0] } ?? [],
                    systemFlags: value.ifa_flags
                )
            }
            cursor = value.ifa_next
        }
        return order.compactMap { records[$0] }.filter { $0.index > 0 }
    }

    private static func numericAddress(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address,
              address.pointee.sa_family == UInt8(AF_INET)
                || address.pointee.sa_family == UInt8(AF_INET6) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
            nil, 0, NI_NUMERICHOST
        ) == 0 else { return nil }
        let terminator = host.firstIndex(of: 0) ?? host.endIndex
        let bytes = host[..<terminator].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
            .split(separator: "%", maxSplits: 1).first.map(String.init)
    }

    private static func inferredKind(for record: RawRecord) -> InterfaceKind {
        if record.systemFlags & UInt32(IFF_LOOPBACK) != 0 || record.name.hasPrefix("lo") {
            return .loopback
        }
        if record.name.hasPrefix("pdp_ip") { return .cellular }
        if record.name.hasPrefix("utun") || record.name.hasPrefix("ipsec") { return .tunnel }
        return .other
    }
}

final class NetworkInterfaceIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    private var remaining: ArraySlice<NetworkInterfaceInventory.Record>
    private let count: Int32

    init(_ records: [NetworkInterfaceInventory.Record]) {
        remaining = records[...]
        count = Int32(clamping: records.count)
    }

    func hasNext() -> Bool { !remaining.isEmpty }
    func len() -> Int32 { count }

    func next() -> ClashNetworkInterface? {
        guard let record = remaining.popFirst() else { return nil }
        let value = ClashNetworkInterface()
        value.name = record.name
        value.index = Int32(bitPattern: record.index)
        value.mtu = record.mtu
        value.addresses = StringIterator(record.addresses)
        value.flags = record.flags
        value.type = record.kind.rawValue
        value.metered = record.metered
        return value
    }
}

private final class StringIterator: NSObject, ClashStringIteratorProtocol {
    private var remaining: ArraySlice<String>
    private let count: Int32

    init(_ values: [String]) {
        remaining = values[...]
        count = Int32(clamping: values.count)
    }

    func hasNext() -> Bool { !remaining.isEmpty }
    func len() -> Int32 { count }
    func next() -> String { remaining.popFirst() ?? "" }
}
