import Foundation

public enum DisplaySizing: String, Codable, CaseIterable, Sendable { case automatic, fit, actual }
public enum ImageQuality: String, Codable, CaseIterable, Sendable { case automatic, high, balanced, low }
public enum ClipboardMode: String, Codable, CaseIterable, Sendable { case bidirectional, receive, off }

public struct SSHConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var host = ""
    public var port = 22
    public var username = ""
    public var keyPath = ""
    public init() {}
}

public struct Computer: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var address: String
    public var username = ""
    public var ssh = SSHConfiguration()
    public var sizing = DisplaySizing.automatic
    public var quality = ImageQuality.automatic
    public var clipboard = ClipboardMode.bidirectional
    public var viewOnly = false
    public var audioEnabled = true
    public var volume: Float = 0.7
    public var lastUsed: Date?
    public var acceptedInsecureAddress: String?
    public init(name: String, address: String) { self.name = name; self.address = address }
    public var destinationIdentity: String {
        let endpoint = (try? Endpoint(address).address) ?? address.lowercased()
        return ssh.enabled ? "\(ssh.username)@\(ssh.host.lowercased()):\(ssh.port)->\(endpoint)" : endpoint
    }
    public var credentialAccount: String { "vnc:\(destinationIdentity):\(username)" }
}

public final class ComputerStore {
    public private(set) var computers: [Computer] = []
    public let url: URL
    private struct Document: Codable { var version = 1; var computers: [Computer] }
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, Set(document.computers.map(\.id)).count == document.computers.count else { throw CocoaError(.fileReadCorruptFile) }
            for computer in document.computers { try computer.validate() }
            computers = document.computers
        }
    }
    public func save(_ computer: Computer) throws {
        try computer.validate()
        var next = computers
        if let index = next.firstIndex(where: { $0.id == computer.id }) { next[index] = computer }
        else { next.append(computer) }
        try write(next)
    }
    public func remove(_ id: UUID) throws { try write(computers.filter { $0.id != id }) }
    private func write(_ next: [Computer]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Document(computers: next))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        computers = next
    }
}

public extension Computer {
    func validate() throws {
        _ = try Endpoint(address)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              username.count <= 256, volume.isFinite, (0...1).contains(volume) else { throw AddressError.invalid }
        if ssh.enabled {
            _ = try Endpoint(ssh.host.contains(":") ? "[\(ssh.host)]:\(ssh.port)" : "\(ssh.host):\(ssh.port)")
            guard (1...65535).contains(ssh.port), ssh.username.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.@-]*$"#, options: .regularExpression) != nil,
                  !ssh.keyPath.contains("\n"), !ssh.keyPath.contains("\0") else { throw AddressError.invalid }
        }
    }
}
