//! Small, dependency-free civil-time helpers.
//!
//! v3 used `DateFormatter` / `Calendar` for the RFC 5322 `Date` header and
//! hand-parsed IMAP's `INTERNALDATE`; both were already avoiding locale data.
//! The Rust port goes one step further and uses integer arithmetic only, so the
//! format is exact and the tests do not depend on the host time zone. All
//! functions are UTC unless a numeric offset is supplied.

const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// Days since 1970-01-01 for a proleptic-Gregorian date.
///
/// Howard Hinnant's `days_from_civil`; exact for the whole `i32` year range.
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = ((month + 9) % 12) as i64; // Mar = 0
    let doy = (153 * mp + 2) / 5 + day as i64 - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Inverse of [`days_from_civil`].
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Seconds since the epoch for a UTC civil date-time.
pub fn unix_from_utc(year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
    days_from_civil(year, month, day) * 86_400
        + hour as i64 * 3_600
        + minute as i64 * 60
        + second as i64
}

/// Current wall-clock time in seconds since the epoch. The only clock read in
/// this crate; callers that need determinism pass an explicit timestamp to the
/// `*_at` builders.
pub fn now_unix() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(_) => 0,
    }
}

/// RFC 5322 §3.3 date-time in UTC: `Sun, 11 Sep 2026 09:36:08 +0000`.
pub fn format_rfc5322_date(unix: i64) -> String {
    let days = unix.div_euclid(86_400);
    let seconds_of_day = unix.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let weekday = WEEKDAYS[(days + 4).rem_euclid(7) as usize]; // 1970-01-01 = Thursday
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!(
        "{weekday}, {day:02} {month} {year:04} {hour:02}:{minute:02}:{second:02} +0000",
        month = MONTHS[(month - 1) as usize],
    )
}

/// RFC 3501 `INTERNALDATE`: `11-Sep-2026 10:00:00 +0800` → epoch seconds.
///
/// Hand-parsed like v3 (`IMAPClient.parseInternalDate`): three space-separated
/// fields, a three-part date, a three-part time and a five-character offset.
/// Anything else is `None` — a bad date must not fail a whole sync round.
pub fn parse_imap_internal_date(text: &str) -> Option<i64> {
    let parts: Vec<&str> = text.split_whitespace().collect();
    if parts.len() != 3 {
        return None;
    }
    let date: Vec<&str> = parts[0].split('-').collect();
    let time: Vec<&str> = parts[1].split(':').collect();
    if date.len() != 3 || time.len() != 3 {
        return None;
    }
    let day: u32 = date[0].parse().ok()?;
    let month = month_number(date[1])?;
    let year: i64 = date[2].parse().ok()?;
    let hour: u32 = time[0].parse().ok()?;
    let minute: u32 = time[1].parse().ok()?;
    let second: u32 = time[2].parse().ok()?;
    let offset = utc_offset_seconds(parts[2])?;
    Some(unix_from_utc(year, month, day, hour, minute, second) - offset)
}

fn month_number(text: &str) -> Option<u32> {
    MONTHS
        .iter()
        .position(|month| month.eq_ignore_ascii_case(text))
        .map(|index| index as u32 + 1)
}

fn utc_offset_seconds(text: &str) -> Option<i64> {
    // Byte-level validation, not string slicing: this value is server-controlled
    // and a multi-byte character straddling the "digits" range would panic a
    // UTF-8 slice (the Rust equivalent of indexing into a Swift Character
    // string by scalar offset).
    let bytes = text.as_bytes();
    if bytes.len() != 5 || !bytes[1..].iter().all(u8::is_ascii_digit) {
        return None;
    }
    let sign = match bytes[0] {
        b'+' => 1i64,
        b'-' => -1i64,
        _ => return None,
    };
    let tens = |byte: u8| i64::from(byte - b'0');
    let hours = tens(bytes[1]) * 10 + tens(bytes[2]);
    let minutes = tens(bytes[3]) * 10 + tens(bytes[4]);
    Some(sign * (hours * 3_600 + minutes * 60))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_round_trip() {
        for days in [-20_000i64, -1, 0, 1, 20_000, 25_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days, "{days} -> {y}-{m}-{d}");
        }
    }

    #[test]
    fn formats_a_known_utc_timestamp() {
        // 2026-09-11T09:36:08Z is a Friday.
        assert_eq!(
            format_rfc5322_date(1_789_119_368),
            "Fri, 11 Sep 2026 09:36:08 +0000"
        );
        assert_eq!(format_rfc5322_date(0), "Thu, 01 Jan 1970 00:00:00 +0000");
    }

    #[test]
    fn parses_imap_internal_date_with_offset() {
        // 2026-09-11 10:00:00 +0800 == 02:00:00 UTC.
        assert_eq!(
            parse_imap_internal_date("11-Sep-2026 10:00:00 +0800"),
            Some(1_789_092_000)
        );
        assert_eq!(
            parse_imap_internal_date("11-Sep-2026 10:00:00 -0500"),
            Some(1_789_138_800)
        );
        assert_eq!(parse_imap_internal_date("garbage"), None);
        assert_eq!(parse_imap_internal_date("11-Foo-2026 10:00:00 +0800"), None);
        // Server-controlled and not allowed to panic: the byte length is 5 but
        // the middle character is multi-byte.
        assert_eq!(
            parse_imap_internal_date("11-Sep-2026 10:00:00 +0\u{E9}0"),
            None
        );
    }
}
