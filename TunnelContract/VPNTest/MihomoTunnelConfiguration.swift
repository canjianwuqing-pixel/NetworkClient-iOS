import Darwin
import Foundation

/// Shared by the app-only probe and active tunnel. The replaceable installation
/// resource is packaged in both bundles; an invalid resource disables testing
/// rather than silently using the pinned SDK's unrelated default URL.
enum NodeLatencyTarget {
    private struct Values: Decodable { let latencyTestURL: String }
    static let url: String? = {
        guard let resource = Bundle.main.url(forResource: "NetworkEndpoints", withExtension: "json"),
              let data = try? Data(contentsOf: resource),
              let values = try? JSONDecoder().decode(Values.self, from: data),
              let target = URL(string: values.latencyTestURL),
              target.scheme == "http" || target.scheme == "https",
              target.host != nil, target.user == nil, target.password == nil,
              target.fragment == nil else { return nil }
        return values.latencyTestURL
    }()
}

/// Non-secret description of one outbound in a freshly built configuration.
struct MihomoCandidateDescriptor: Codable, Sendable, Equatable {
    let nodeID: String
    let revision: String
    let coreName: String
}

/// A fresh current configuration handoff between the app and its extension.
/// The identifier addresses this immutable file, never a restored lifecycle.
struct MihomoTunnelConfiguration: Codable, Sendable {
    let generation: UUID
    let nodeID: String
    let serverIPv4: String
    let yaml: String
    let createdAt: Date
    /// Optional SHA-256 scope supplied by the current Mapper, never credentials.
    let accountScope: String?
    /// Optional current selection revision supplied by the Mapper.
    let configurationRevision: String?
    /// Current rewritten outbound key used by startup selection and app-only probes.
    let coreName: String?
    /// Optional current rule/global mode already represented in the YAML.
    let mode: String?
    /// Optional non-secret inventory for the current fixed-candidate feature.
    let candidatePool: [MihomoCandidateDescriptor]?
    let candidatePoolRevision: String?
    /// Immutable App-published GeoData version selected before NE startup.
    let geoDataPublicationIdentifier: String?

    init(generation: UUID, nodeID: String, serverIPv4: String, yaml: String,
         createdAt: Date, accountScope: String? = nil, coreName: String? = nil,
         configurationRevision: String? = nil, mode: String? = nil,
         candidatePool: [MihomoCandidateDescriptor]? = nil,
         candidatePoolRevision: String? = nil,
         geoDataPublicationIdentifier: String? = nil) {
        self.generation = generation
        self.nodeID = nodeID
        self.serverIPv4 = serverIPv4
        self.yaml = yaml
        self.createdAt = createdAt
        self.accountScope = accountScope
        self.coreName = coreName
        self.configurationRevision = configurationRevision
        self.mode = mode
        self.candidatePool = candidatePool
        self.candidatePoolRevision = candidatePoolRevision
        self.geoDataPublicationIdentifier = geoDataPublicationIdentifier
    }

    func withCandidatePool(yaml: String, candidates: [MihomoCandidateDescriptor],
                           revision: String) -> Self {
        Self(generation: generation, nodeID: nodeID, serverIPv4: serverIPv4,
             yaml: yaml, createdAt: createdAt, accountScope: accountScope,
             coreName: coreName, configurationRevision: configurationRevision,
             mode: mode,
             candidatePool: candidates, candidatePoolRevision: revision,
             geoDataPublicationIdentifier: geoDataPublicationIdentifier)
    }

    func withGeoDataPublication(_ publicationIdentifier: String) -> Self {
        Self(generation: generation, nodeID: nodeID, serverIPv4: serverIPv4,
             yaml: yaml, createdAt: createdAt, accountScope: accountScope,
             coreName: coreName, configurationRevision: configurationRevision,
             mode: mode, candidatePool: candidatePool,
             candidatePoolRevision: candidatePoolRevision,
             geoDataPublicationIdentifier: publicationIdentifier)
    }
}

enum MihomoTunnelStoreError: String, Error, Equatable {
    case missingGroup = "configuration-missing-container"
    case missingConfiguration = "configuration-missing-file"
    case staleGeneration = "configuration-generation-mismatch"
    case invalidConfiguration = "configuration-invalid-fields"
    case untrustedDirectory = "configuration-untrusted-directory"
    case invalidFileType = "configuration-invalid-file-type"
    case invalidOwner = "configuration-invalid-owner"
    case invalidPermissions = "configuration-invalid-permissions"
    case emptyFile = "configuration-empty-file"
    case fileTooLarge = "configuration-file-too-large"
    case fileReadFailed = "configuration-read-failed"
    case fileChanged = "configuration-file-changed"
    case decodeFailed = "configuration-decode-failed"
    case invalidScope = "configuration-invalid-scope"
    case invalidRevision = "configuration-invalid-revision"
    case invalidCandidates = "configuration-invalid-candidates"
    case invalidIPv4 = "configuration-invalid-ipv4"
    case emptyYAML = "configuration-empty-yaml"
    case oversizedYAML = "configuration-oversized-yaml"
}

enum MihomoTunnelStore {
    // Bound the current runtime and its optional fixed outbound inventory,
    // including JSON's worst-case six-byte escape expansion.
    static let maximumFileBytes = 4 * 1_024 * 1_024
    static let maximumYAMLBytes = 524_288
    private static let maximumJSONDepth = 8
    private static let maximumJSONStructure = 4_096

    /// Synchronous filesystem-boundary seams for deterministic fault tests.
    /// Production always uses the real UID and Darwin.read; no mutable global hook.
    struct ReadIO {
        var expectedOwner: uid_t = getuid()
        var afterFileStat: () -> Void = {}
        var read: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
    }

    private static func kind(at url: URL) throws -> stat? {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw MihomoTunnelStoreError.invalidConfiguration
    }
    private static func checkedDirectory(_ url: URL) throws -> URL {
        guard let metadata = try kind(at: url), metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else { throw MihomoTunnelStoreError.untrustedDirectory }
        return url
    }
    private static func containerURL(in bundle: Bundle) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: try appGroup(in: bundle)
        ) else { throw MihomoTunnelStoreError.missingGroup }
        return container
    }
    private static func checkedContainer(in bundle: Bundle) throws -> URL {
        try checkedDirectory(containerURL(in: bundle))
    }
    private static func validateFile(_ metadata: stat, owner: uid_t) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw MihomoTunnelStoreError.invalidFileType }
        guard metadata.st_uid == owner else { throw MihomoTunnelStoreError.invalidOwner }
        guard metadata.st_mode & 0o077 == 0, metadata.st_mode & 0o400 != 0 else {
            throw MihomoTunnelStoreError.invalidPermissions
        }
    }
    private static func checkedFile(_ url: URL) throws -> Bool {
        guard let metadata = try kind(at: url) else { return false }
        try validateFile(metadata, owner: getuid())
        return true
    }
    private static func validDigest(_ value: String?) -> Bool {
        guard let value else { return true } // Optional fields remain optional in the current wire schema.
        return value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
    private static func validate(_ value: MihomoTunnelConfiguration) throws {
        guard !value.nodeID.isEmpty, value.nodeID.utf8.count <= 256,
              value.coreName.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              value.mode.map({ $0 == "rule" || $0 == "global" }) ?? true else {
            throw MihomoTunnelStoreError.invalidConfiguration
        }
        guard validDigest(value.accountScope) else { throw MihomoTunnelStoreError.invalidScope }
        guard validDigest(value.configurationRevision) else { throw MihomoTunnelStoreError.invalidRevision }
        guard value.geoDataPublicationIdentifier.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw MihomoTunnelStoreError.invalidConfiguration
        }
        guard value.serverIPv4.utf8.count <= 15, IPv4AddressValidator.valid(value.serverIPv4) else {
            throw MihomoTunnelStoreError.invalidIPv4
        }
        guard !value.yaml.isEmpty else { throw MihomoTunnelStoreError.emptyYAML }
        guard value.yaml.utf8.count <= maximumYAMLBytes else { throw MihomoTunnelStoreError.oversizedYAML }
        guard let candidates = value.candidatePool else {
            guard value.candidatePoolRevision == nil else { throw MihomoTunnelStoreError.invalidCandidates }
            return
        }
        guard let revision = value.candidatePoolRevision, validDigest(revision),
              !candidates.isEmpty, candidates.count <= 128,
              let coreName = value.coreName, let selectedRevision = value.configurationRevision,
              candidates.allSatisfy({ !$0.nodeID.isEmpty && $0.nodeID.utf8.count <= 256
                  && !$0.coreName.isEmpty && $0.coreName.utf8.count <= 256 && validDigest($0.revision) }),
              Set(candidates.map(\.nodeID)).count == candidates.count,
              Set(candidates.map(\.coreName)).count == candidates.count,
              candidates.contains(where: { $0.nodeID == value.nodeID && $0.coreName == coreName
                  && $0.revision == selectedRevision }) else { throw MihomoTunnelStoreError.invalidCandidates }
    }
    static func appGroup(in bundle: Bundle = .main) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: "TunnelAppGroup") as? String,
              value.hasPrefix("group."), !value.contains("$(") else { throw MihomoTunnelStoreError.missingGroup }
        return value
    }
    static func location(for generation: UUID, in bundle: Bundle = .main) throws -> URL {
        try checkedContainer(in: bundle).appendingPathComponent(filename(generation))
    }
    private static func filename(_ generation: UUID) -> String { "tunnel-\(generation.uuidString).json" }

    static func save(_ value: MihomoTunnelConfiguration, in bundle: Bundle = .main) throws {
        try save(value, directory: checkedContainer(in: bundle))
    }
    static func save(_ value: MihomoTunnelConfiguration, directory: URL) throws {
        try validate(value)
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumFileBytes else { throw MihomoTunnelStoreError.fileTooLarge }
        let location = try checkedDirectory(directory).appendingPathComponent(filename(value.generation))
        // Preserve the established protected staging + exclusive atomic hard-link publication.
        guard try kind(at: location) == nil else { throw MihomoTunnelStoreError.invalidConfiguration }
        let staging = directory.appendingPathComponent("tunnel-staging-\(UUID().uuidString).tmp")
        guard try kind(at: staging) == nil else { throw MihomoTunnelStoreError.invalidConfiguration }
        defer { try? FileManager.default.removeItem(at: staging) }
        try encoded.write(to: staging, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        guard try checkedFile(staging), link(staging.path, location.path) == 0,
              try checkedFile(location) else { throw MihomoTunnelStoreError.invalidConfiguration }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = location; try file.setResourceValues(values)
    }
    static func load(expectedGeneration: UUID, in bundle: Bundle = .main) throws -> MihomoTunnelConfiguration {
        try load(expectedGeneration: expectedGeneration, resolve: { try containerURL(in: bundle) })
    }
    static func load(expectedGeneration: UUID, directory: URL,
                     io: ReadIO = .init()) throws -> MihomoTunnelConfiguration {
        try load(expectedGeneration: expectedGeneration, resolve: { directory }, io: io)
    }
    private static func load(expectedGeneration: UUID, resolve: () throws -> URL,
                             io: ReadIO = .init()) throws -> MihomoTunnelConfiguration {
        do {
            let directory = try resolve()
            let directoryFD = try openDirectory(directory)
            defer { Darwin.close(directoryFD) }
            let fd = try openFile(expectedGeneration, directoryFD: directoryFD)
            defer { Darwin.close(fd) }
            var initial = stat()
            guard Darwin.fstat(fd, &initial) == 0 else { throw MihomoTunnelStoreError.fileReadFailed }
            try validateFile(initial, owner: io.expectedOwner)
            guard initial.st_size > 0 else { throw MihomoTunnelStoreError.emptyFile }
            guard initial.st_size <= maximumFileBytes else { throw MihomoTunnelStoreError.fileTooLarge }
            io.afterFileStat()
            let data = try readFile(fd, metadata: initial, io: io)
            try validateJSONBudget(data)
            let value: MihomoTunnelConfiguration
            do { value = try JSONDecoder().decode(MihomoTunnelConfiguration.self, from: data) }
            catch { throw MihomoTunnelStoreError.decodeFailed }
            guard value.generation == expectedGeneration else { throw MihomoTunnelStoreError.staleGeneration }
            try validate(value)
            return value
        } catch let error as MihomoTunnelStoreError {
            throw error
        } catch {
            throw MihomoTunnelStoreError.fileReadFailed
        }
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw MihomoTunnelStoreError.untrustedDirectory }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else { Darwin.close(fd); throw MihomoTunnelStoreError.untrustedDirectory }
        return fd
    }
    private static func openFile(_ generation: UUID, directoryFD: Int32) throws -> Int32 {
        // NONBLOCK prevents an unexpected FIFO from hanging before fstat rejects it.
        let fd = Darwin.openat(directoryFD, filename(generation), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { throw MihomoTunnelStoreError.missingConfiguration }
            if errno == ELOOP { throw MihomoTunnelStoreError.invalidFileType }
            if errno == EACCES || errno == EPERM { throw MihomoTunnelStoreError.invalidPermissions }
            throw MihomoTunnelStoreError.fileReadFailed
        }
        return fd
    }
    private static func readFile(_ fd: Int32, metadata: stat, io: ReadIO) throws -> Data {
        let size = Int(metadata.st_size)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw MihomoTunnelStoreError.fileReadFailed }
            var offset = 0
            while offset < size {
                let count = io.read(fd, base.advanced(by: offset), size - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= size - offset else { throw MihomoTunnelStoreError.fileReadFailed }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var count: Int
        repeat { count = withUnsafeMutablePointer(to: &extra) { io.read(fd, UnsafeMutableRawPointer($0), 1) } }
        while count < 0 && errno == EINTR
        guard count == 0 else { throw MihomoTunnelStoreError.fileChanged }
        var final = stat()
        guard Darwin.fstat(fd, &final) == 0 else { throw MihomoTunnelStoreError.fileReadFailed }
        try validateFile(final, owner: io.expectedOwner)
        guard final.st_dev == metadata.st_dev, final.st_ino == metadata.st_ino, final.st_size == metadata.st_size,
              final.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec else { throw MihomoTunnelStoreError.fileChanged }
        return data
    }
    /// Bound structural expansion before Foundation builds its JSON representation.
    /// The actual schema has depth 3 and at most 64 flat inventory objects.
    private static func validateJSONBudget(_ data: Data) throws {
        var quoted = false, escaped = false, depth = 0, structure = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; continue }
            if byte == 123 || byte == 91 { depth += 1; structure += 1 }
            if byte == 125 || byte == 93 { depth -= 1 }
            if byte == 44 || byte == 58 { structure += 1 }
            guard depth >= 0, depth <= maximumJSONDepth, structure <= maximumJSONStructure else {
                throw MihomoTunnelStoreError.decodeFailed
            }
        }
    }
    static func remove(expectedGeneration: UUID, in bundle: Bundle = .main) throws {
        try remove(expectedGeneration: expectedGeneration, directory: containerURL(in: bundle))
    }
    static func remove(expectedGeneration: UUID, directory: URL) throws {
        let directoryFD = try openDirectory(directory)
        defer { Darwin.close(directoryFD) }
        let fd: Int32
        do { fd = try openFile(expectedGeneration, directoryFD: directoryFD) }
        catch MihomoTunnelStoreError.missingConfiguration { return }
        defer { Darwin.close(fd) }
        var opened = stat(), named = stat()
        guard Darwin.fstat(fd, &opened) == 0 else { throw MihomoTunnelStoreError.fileReadFailed }
        try validateFile(opened, owner: getuid())
        guard fstatat(directoryFD, filename(expectedGeneration), &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw MihomoTunnelStoreError.fileChanged }
        // Remove only this exact immutable configuration pathname, even if its
        // JSON is damaged. A different current file has a distinct pathname;
        // symlinks and unsafe files still fail.
        guard unlinkat(directoryFD, filename(expectedGeneration), 0) == 0 else { throw MihomoTunnelStoreError.fileReadFailed }
    }
}

enum IPv4AddressValidator {
    static func looksLikeLiteral(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
    }

    static func octets(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  (part.count == 1 || part.first != "0"),
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let octet = UInt8(part) else { return nil }
            result.append(octet)
        }
        return result
    }

    static func valid(_ value: String) -> Bool {
        octets(value) != nil
    }

    /// Hostname resolution must not turn a subscription endpoint into an
    /// on-device, private-network or reserved route exclusion.
    static func publicUnicast(_ value: String) -> Bool {
        guard let octets = octets(value) else { return false }
        let a = octets[0], b = octets[1]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 0 || b == 168) { return false }
        if a == 198 && (b == 18 || b == 19 || b == 51) { return false }
        if a == 203 && b == 0 && octets[2] == 113 { return false }
        return !(a == 192 && b == 0 && octets[2] == 2)
    }
}

/// Validate the concrete addresses Core gives Network Extension. IPv4 is
/// required by the current product configuration; IPv6 is capability-driven
/// and is valid when either complete or absent.
enum TunnelRoutingPolicy {
    static func accepts(
        dnsAddress: String,
        ipv4Addresses: [String], ipv4Masks: [String],
        ipv6Addresses: [String], ipv6Prefixes: [Int]
    ) -> Bool {
        guard (validIPv4(dnsAddress) || validIPv6(dnsAddress)),
              !ipv4Addresses.isEmpty, ipv4Addresses.count == ipv4Masks.count,
              ipv4Addresses.allSatisfy(validIPv4),
              ipv4Masks.allSatisfy(validIPv4) else { return false }
        if ipv6Addresses.isEmpty && ipv6Prefixes.isEmpty { return true }
        return ipv6Addresses.count == ipv6Prefixes.count
            && ipv6Addresses.allSatisfy(validIPv6)
            && ipv6Prefixes.allSatisfy { (1...128).contains($0) }
    }

    private static func parsedIPv4(_ text: String) -> in_addr? {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) == 1 } ? address : nil
    }

    private static func validIPv4(_ text: String) -> Bool {
        parsedIPv4(text) != nil
    }

    private static func validIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
            && text != "::" && text != "::1"
    }
}

/// A failed SDK URL test has only a -1 return value. Its delay snapshot has
/// a classified failure but also contains raw URLs and error messages.
/// Only this fixed vocabulary may enter the app-only probe result.
enum MihomoProbeFailureKind: String, Sendable {
    case timeout, canceled, status, dial, read, write, unknown

    static func from(delaySnapshot: String, proxyName: String) -> Self {
        guard let data = delaySnapshot.data(using: .utf8), data.count <= 32_768,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = root["proxies"] as? [String: Any],
              let proxy = proxies[proxyName] as? [String: Any] else { return .unknown }
        // Non-2xx responses can be recorded only under the URL-specific entry.
        let extra = proxy["extra"] as? [String: [String: Any]]
        let urlFailure = extra?.count == 1 ? extra?.values.first?["failure"] as? [String: Any] : nil
        let failure = urlFailure
            ?? proxy["failure"] as? [String: Any]
        guard let raw = failure?["kind"] as? String else { return .unknown }
        return Self(rawValue: raw) ?? .unknown
    }
}
