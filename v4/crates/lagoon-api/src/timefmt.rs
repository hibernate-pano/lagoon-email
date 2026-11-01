//! v3's stored date format and its wire form.
//!
//! The store keeps timestamps as TEXT in `yyyy-MM-dd HH:mm:ss.SSS` (UTC,
//! en_US_POSIX) - `LagoonKit/StoredDate.swift:25-49`. SQLite sorts that form
//! lexicographically in chronological order, which is why `ORDER BY
//! received_at DESC` is a correct "newest first" without a numeric column.
//!
//! On the wire the same instant is ISO-8601 with second precision:
//! `JSONEncoder.dateEncodingStrategy = .iso8601` writes `2025-01-03T09:00:00Z`
//! and **drops** the milliseconds (probed: `.999` and `.500` both encode as
//! `:00Z`, and `23:59:59.900` as `:59Z` - truncation, not rounding). Reproducing
//! that here is what makes `receivedAt` diff-clean against the v3 sidecar.

/// A UTC instant, kept at the store's millisecond resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Timestamp {
    millis: i64,
}

impl Timestamp {
    pub fn from_millis(millis: i64) -> Self {
        Self { millis }
    }

    pub fn millis(self) -> i64 {
        self.millis
    }
}

/// On the wire an instant is ISO-8601 text, second precision.
impl serde::Serialize for Timestamp {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&to_iso8601(*self))
    }
}

/// The current instant in UTC.
pub fn now() -> Timestamp {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(elapsed) => Timestamp::from_millis(elapsed.as_millis() as i64),
        Err(before) => Timestamp::from_millis(-(before.duration().as_millis() as i64)),
    }
}

/// The current instant rendered the way the wire expects it.
pub fn iso8601_now() -> String {
    to_iso8601(now())
}

/// Parse the store's `yyyy-MM-dd HH:mm:ss.SSS` form.
///
/// Component widths are not enforced beyond "the separators are where they
/// should be": `DateFormatter` with a fixed `dateFormat` accepts a one-digit
/// month, and rejecting that here would turn a readable row into a 500.
pub fn parse_stored(raw: &str) -> Option<Timestamp> {
    let (date, clock) = raw.split_once(' ')?;
    let mut date_parts = date.split('-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    if date_parts.next().is_some() {
        return None;
    }
    let mut clock_parts = clock.split(':');
    let hour: u32 = clock_parts.next()?.parse().ok()?;
    let minute: u32 = clock_parts.next()?.parse().ok()?;
    let seconds_and_millis = clock_parts.next()?;
    if clock_parts.next().is_some() {
        return None;
    }
    let (second_text, millis_text) = seconds_and_millis.split_once('.')?;
    let second: u32 = second_text.parse().ok()?;
    let millis: u32 = millis_text.parse().ok()?;
    if millis_text.len() != 3 {
        return None;
    }
    make_timestamp(year, month, day, hour, minute, second).map(|ts| {
        Timestamp::from_millis(ts.millis() + millis as i64)
    })
}

/// Parse the store's form, falling back to ISO-8601.
///
/// The fallback mirrors `StoredDate.date(from:)`, which tries the stored format
/// first and then `ISO8601DateFormatter`. A `NULL` column and an unparseable
/// value are both `None`; the caller decides which of the two is an error.
pub fn parse(raw: Option<&str>) -> Option<Timestamp> {
    let raw = raw?;
    if raw.is_empty() {
        return None;
    }
    parse_stored(raw).or_else(|| parse_iso8601(raw))
}

/// Minimal RFC-3339 reader: `YYYY-MM-DDTHH:MM:SS[.fff](Z|+HH:MM|-HH:MM)`.
pub fn parse_iso8601(raw: &str) -> Option<Timestamp> {
    let (date, rest) = raw.split_once('T')?;
    let mut date_parts = date.split('-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    if date_parts.next().is_some() {
        return None;
    }

    let (clock, offset_seconds) = if let Some(clock) = rest.strip_suffix('Z') {
        (clock, 0i64)
    } else {
        // The offset sign is the last '+'/'-' in the string, so the date's own
        // hyphens cannot be mistaken for it.
        let split_at = rest.rfind(['+', '-'])?;
        let (clock, offset) = rest.split_at(split_at);
        let sign = if offset.starts_with('-') { -1 } else { 1 };
        let offset = &offset[1..];
        let (hours, minutes) = offset.split_once(':')?;
        let hours: i64 = hours.parse().ok()?;
        let minutes: i64 = minutes.parse().ok()?;
        (clock, sign * (hours * 3600 + minutes * 60))
    };

    let (clock, millis) = match clock.split_once('.') {
        Some((clock, fraction)) => {
            let mut digits = fraction.to_owned();
            while digits.len() < 3 {
                digits.push('0');
            }
            digits.truncate(3);
            (clock, digits.parse::<u32>().ok()?)
        }
        None => (clock, 0u32),
    };

    let mut clock_parts = clock.split(':');
    let hour: u32 = clock_parts.next()?.parse().ok()?;
    let minute: u32 = clock_parts.next()?.parse().ok()?;
    let second: u32 = clock_parts.next()?.parse().ok()?;
    if clock_parts.next().is_some() {
        return None;
    }

    let base = make_timestamp(year, month, day, hour, minute, second)?;
    Some(Timestamp::from_millis(
        base.millis() + millis as i64 - offset_seconds * 1000,
    ))
}

/// Render an instant in the form the store keeps (`yyyy-MM-dd HH:mm:ss.SSS`).
///
/// Needed to bind a `?since=` value against a TEXT `received_at` column: SQLite
/// compares those lexicographically, so the bound value must be in the same
/// shape the column holds.
pub fn to_stored(ts: Timestamp) -> String {
    let seconds = ts.millis().div_euclid(1000);
    let millis = ts.millis().rem_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3600;
    let minute = (seconds_of_day % 3600) / 60;
    let second = seconds_of_day % 60;
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        year, month, day, hour, minute, second, millis
    )
}

/// Render an instant the way `JSONEncoder.dateEncodingStrategy = .iso8601` does:
/// UTC, second precision, milliseconds **truncated** (floor, so pre-epoch
/// instants round the same way the probe showed).
pub fn to_iso8601(ts: Timestamp) -> String {
    let seconds = ts.millis().div_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3600;
    let minute = (seconds_of_day % 3600) / 60;
    let second = seconds_of_day % 60;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, minute, second
    )
}

fn make_timestamp(year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Option<Timestamp> {
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + (hour as i64) * 3600 + (minute as i64) * 60 + second as i64;
    Some(Timestamp::from_millis(seconds * 1000))
}

fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if is_leap_year(year) {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`). Kept in-house so the crate needs no date dependency.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_index = (month as i64 + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Inverse of [`days_from_civil`].
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_form_round_trips_through_the_wire_form() {
        // Expectations taken from a Swift probe of StoredDate + JSONEncoder
        // (.iso8601): see the R1 report's "oracle" section.
        let cases = [
            ("2025-01-03 09:00:00.000", "2025-01-03T09:00:00Z"),
            ("2025-01-03 09:00:00.999", "2025-01-03T09:00:00Z"),
            ("2025-01-03 09:00:00.500", "2025-01-03T09:00:00Z"),
            ("1969-12-31 23:59:59.900", "1969-12-31T23:59:59Z"),
        ];
        for (stored, wire) in cases {
            let parsed = parse_stored(stored).expect(stored);
            assert_eq!(to_iso8601(parsed), wire, "stored {stored}");
        }
    }

    #[test]
    fn millis_are_kept_for_ordering_but_truncated_for_the_wire() {
        let earlier = parse_stored("2025-01-03 09:00:00.000").unwrap();
        let later = parse_stored("2025-01-03 09:00:00.999").unwrap();
        assert!(earlier < later);
        assert_eq!(to_iso8601(earlier), to_iso8601(later));
    }

    #[test]
    fn rejects_values_dateformatter_would_reject() {
        for bad in ["", "2025-01-03", "2025-01-03 09:00:00", "2025-13-03 09:00:00.000", "2025-02-30 09:00:00.000", "2025-01-03 24:00:00.000", "not a date at all"] {
            assert!(parse_stored(bad).is_none(), "accepted {bad:?}");
        }
    }

    #[test]
    fn iso8601_fallback_matches_iso8601dateformatter() {
        let parsed = parse(None).map(|_| ());
        assert!(parsed.is_none(), "NULL column must parse to None");
        let parsed = parse(Some("2025-01-03T09:00:00Z")).expect("internet date-time");
        assert_eq!(to_iso8601(parsed), "2025-01-03T09:00:00Z");
        let offset = parse(Some("2025-01-03T17:00:00+08:00")).unwrap();
        assert_eq!(to_iso8601(offset), "2025-01-03T09:00:00Z");
        let fractional = parse(Some("2025-01-03T09:00:00.999Z")).unwrap();
        assert_eq!(to_iso8601(fractional), "2025-01-03T09:00:00Z");
    }

    #[test]
    fn leap_day_is_accepted_and_abutting_days_are_rejected() {
        assert!(parse_stored("2024-02-29 00:00:00.000").is_some());
        assert!(parse_stored("2025-02-29 00:00:00.000").is_none());
    }
}
