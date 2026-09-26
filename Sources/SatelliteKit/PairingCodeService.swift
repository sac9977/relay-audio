import Foundation
import Network

/// Pairing-code helpers shared by senders and receivers.
///
/// Two flows use 4-digit codes:
/// 1. Receivers (macOS/iOS Satellite) advertise their code in a Bonjour TXT
///    record (`c=4821`) on `_relay-sat._udp`. In Relay you type the code —
///    not an IP — and the matching receiver is added. The code says WHICH
///    receiver and implies physical consent.
/// 2. While streaming, Relay's bridge advertises `_relay-bridge._udp` with
///    its code and shows it in the UI. A sender (iPhone) browses, picks the
///    Mac, proves the code via a pair-request round trip, and only then may
///    it stream audio.
public enum PairingCode {
    /// Fresh 4-digit code, "0000" excluded so it never reads as blank.
    public static func make() -> String {
        var code: String
        repeat {
            code = String(format: "%04d", Int(arc4random_uniform(10_000)))
        } while code == "0000"
        return code
    }

    /// TXT record advertising a code (`c=4821`).
    public static func txtRecord(_ code: String) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["c"] = code
        return txt
    }

    /// Reads a code out of browse-result metadata (nil if absent).
    public static func code(fromTXT metadata: NWTXTRecord) -> String? {
        guard let raw = metadata["c"], raw.count == 4, raw.allSatisfy(\.isNumber) else { return nil }
        return raw
    }
}
