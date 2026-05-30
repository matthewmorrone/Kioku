import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Returns IPv4 addresses suitable for showing the user "where to point the Pi".
// Filters out loopback and link-local addresses so the displayed value is the
// LAN IP a Raspberry Pi on the same Wi-Fi network can actually reach.
enum BridgeAddressFinder {
    // Returns IPv4 addresses for known Wi-Fi/wired interfaces, or an empty array
    // when no usable interface is up. Order is implementation-defined, but the
    // primary Wi-Fi interface (en0) typically appears first on iPhones.
    static func currentLANAddresses() -> [String] {
        var results: [String] = []

        var interfacesPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacesPointer) == 0, let head = interfacesPointer else {
            return []
        }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = interface.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            // en* covers Wi-Fi (en0) and wired ethernet on Macs; pdp_ip* is cellular which
            // is intentionally skipped — we don't want to advertise a cellular address.
            guard interfaceName.hasPrefix("en") || interfaceName.hasPrefix("bridge") else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let host = String(cString: hostBuffer)
            // Drop link-local 169.254.x.x — those won't be reachable from the Pi.
            if host.hasPrefix("169.254.") { continue }
            results.append(host)
        }

        return results
    }
}
