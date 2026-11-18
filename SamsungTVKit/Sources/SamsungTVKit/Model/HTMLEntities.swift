import Foundation

/// Minimal HTML entity decoder for TV-supplied strings (e.g. `65&quot; TV`).
public enum HTMLEntities {
    private static let named: [String: Character] = [
        "quot": "\"", "amp": "&", "lt": "<", "gt": ">", "apos": "'",
    ]

    /// Decodes named (`&quot; &amp; &lt; &gt; &apos;`) and numeric (`&#39;`, `&#x27;`) entities in a single pass.
    /// Unknown or malformed entities are left untouched.
    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var index = s.startIndex
        while index < s.endIndex {
            let ch = s[index]
            if ch == "&",
               let semi = s[index...].prefix(12).firstIndex(of: ";"),
               let decoded = entity(String(s[s.index(after: index)..<semi])) {
                out.append(decoded)
                index = s.index(after: semi)
            } else {
                out.append(ch)
                index = s.index(after: index)
            }
        }
        return out
    }

    private static func entity(_ body: String) -> Character? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if let first = digits.first, first == "x" || first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            return value.flatMap(Unicode.Scalar.init).map(Character.init)
        }
        return named[body]
    }
}
