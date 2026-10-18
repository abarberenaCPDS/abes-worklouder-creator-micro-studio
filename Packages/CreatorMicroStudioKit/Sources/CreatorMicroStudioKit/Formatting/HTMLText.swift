import Foundation

/// Plain text made safe to drop into the floating panels' HTML.
public enum HTMLText {

    /// Escapes the characters HTML gives meaning to, and drops carriage
    /// returns so CRLF text does not render a stray glyph.
    public static func escape(_ text: String) -> String {
        // Scalars, not Characters: "\r\n" is one Character in Swift, so a
        // Character switch would never see the carriage return on its own.
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "\r": break
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
