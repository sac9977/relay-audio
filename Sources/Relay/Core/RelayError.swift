import Foundation

enum RelayError: LocalizedError {
    case coreAudio(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(status, context):
            return "Core Audio error \(status) (\(fourCC(UInt32(bitPattern: status)))) — \(context)"
        case let .message(text):
            return text
        }
    }
}

/// Renders an integer as a printable FourCC ('abcD') when possible — makes
/// Core Audio error codes and property selectors readable in logs.
func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ]
    if bytes.allSatisfy({ (32...126).contains($0) }), let text = String(bytes: bytes, encoding: .ascii) {
        return "'\(text)'"
    }
    return String(value)
}
