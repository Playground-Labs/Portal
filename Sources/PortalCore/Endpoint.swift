import Foundation
import Darwin

public struct Endpoint: Equatable, Codable, Sendable {
    public let host: String
    public let port: UInt16
    public var address: String { (host.contains(":") ? "[\(host)]" : host) + (port == 5900 ? "" : ":\(port)") }
    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("vnc://") {
            value = String(value.dropFirst(6))
            if value.hasSuffix("/") { value.removeLast() }
        }
        guard !value.isEmpty, value.utf8.count <= 300,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains(where: { "/@?#\\".contains($0) }) else { throw AddressError.invalid }
        let hostname: String
        var portText = "5900"
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { throw AddressError.invalid }
            hostname = String(value[value.index(after: value.startIndex)..<end])
            let suffix = String(value[value.index(after: end)...])
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw AddressError.invalid }
                portText = String(suffix.dropFirst())
            }
            guard Self.isIPv6(hostname) else { throw AddressError.invalid }
        } else if value.filter({ $0 == ":" }).count > 1 {
            guard Self.isIPv6(value) else { throw AddressError.invalid }
            hostname = value
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            hostname = String(parts[0])
            if parts.count == 2 { portText = String(parts[1]) }
            guard hostname.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9.])?$"#, options: .regularExpression) != nil else { throw AddressError.invalid }
            if hostname.allSatisfy({ $0.isNumber || $0 == "." }) {
                var address = in_addr()
                guard inet_pton(AF_INET, hostname, &address) == 1 else { throw AddressError.invalid }
            }
        }
        guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt16(portText), number > 0 else { throw AddressError.invalid }
        host = hostname.lowercased()
        port = number
    }
    private static func isIPv6(_ host: String) -> Bool {
        let parts = host.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 2, parts[1].range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, String(parts[0]), &address) == 1
    }
}

public enum AddressError: LocalizedError {
    case invalid
    public var errorDescription: String? { "Enter a hostname or IP address, optionally followed by :port. Use brackets around IPv6 addresses with a port." }
}
