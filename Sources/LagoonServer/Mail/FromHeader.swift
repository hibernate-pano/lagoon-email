import Foundation

/// `From:` header → (address, display name). Shared by both providers so the
/// same wire value lands in the store the same way, whichever backend fetched
/// it. Deliberately forgiving: a malformed header yields the raw text as the
/// address instead of dropping the message.
public enum FromHeader {
    public static func parse(_ raw: String) -> (String, String?) {
        if raw.contains("<") && raw.contains(">") {
            let namePart = raw.split(separator: "<").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let addrPart = raw.split(separator: "<").last.map(String.init)?
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            return (addrPart ?? raw, (namePart?.isEmpty == false) ? namePart : nil)
        }
        return (raw.trimmingCharacters(in: .whitespaces), nil)
    }
}
