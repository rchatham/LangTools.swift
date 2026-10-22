import Foundation
import Darwin
import HelperLink

public struct MobileLANInterface: Identifiable, Equatable, Sendable {
    public let name: String
    public let address: String
    public var id: String { "\(name):\(address)" }

    public static func available() -> [Self] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [Self] = []
        var current = first
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            guard MobileHelperPairingPayload.isPrivateIPv4(ip) else { continue }
            result.append(Self(name: String(cString: entry.ifa_name), address: ip))
        }
        return result.sorted { $0.id < $1.id }
    }
}
