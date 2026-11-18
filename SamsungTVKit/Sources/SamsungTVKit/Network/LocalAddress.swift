import Foundation

/// Guards every outbound connection: only private (RFC1918) or link-local IPv4 literals.
public enum LocalAddress {
    public static func isAllowed(_ host: String, allowLoopback: Bool = false) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (part == "0" || part.first != "0"),  // leading zeros are octal to inet_aton
                  let value = Int(part), value <= 255 else { return false }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (127, _): return allowLoopback
        default: return false
        }
    }
}
