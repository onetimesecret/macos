/// The character references the rendered page preview decodes in raw HTML (plan R3): five
/// names, `nbsp` and terminated numeric references. It is not the HTML5 named-reference table.
enum HTMLEntities {
    static func decode(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, end - index <= 32,
                  scalars[end] != ";", scalars[end] != "&" {
                end += 1
            }
            if end < scalars.count, end - index <= 32, scalars[end] == ";",
               let decoded = reference(String(String.UnicodeScalarView(scalars[(index + 1)..<end]))) {
                output.append(decoded)
                index = end + 1
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    private static func reference(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let hexadecimal = name.hasPrefix("#x") || name.hasPrefix("#X")
        let digits = name.dropFirst(hexadecimal ? 2 : 1)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (hexadecimal && ((65...70).contains(byte) || (97...102).contains(byte)))
        }) else { return nil }
        guard let value = UInt32(digits, radix: hexadecimal ? 16 : 10),
              value != 0, let scalar = Unicode.Scalar(value)
        else { return "\u{FFFD}" }
        return scalar
    }
}
