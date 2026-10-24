//! Times as the thread view reads them: desktop-qt's day-aware stamps
//! ("9:41 AM", "yesterday at 9:41 AM", "9/20 9:41 AM"), durations ("Worked
//! for 2m 5s") and a row's long time ("9:41 AM, 23rd September 2026").
//!
//! The clock and the time zone are given, so tests read one day the same
//! everywhere.

use std::rc::Rc;

use chrono::{
    DateTime, Datelike, FixedOffset, Local, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc,
};

use crate::json::Json;

/// What "now" is.
pub type Now = Rc<dyn Fn() -> DateTime<Utc>>;

/// The zone local days and times are read in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Zone {
    /// The machine's.
    #[default]
    Local,
    Fixed(FixedOffset),
}

impl Zone {
    pub fn utc() -> Zone {
        Zone::Fixed(FixedOffset::east_opt(0).expect("UTC"))
    }

    pub fn local(self, at: DateTime<Utc>) -> NaiveDateTime {
        match self {
            Zone::Local => at.with_timezone(&Local).naive_local(),
            Zone::Fixed(offset) => at.with_timezone(&offset).naive_local(),
        }
    }

    /// A wall-clock time of this zone, as UTC (the earlier of two, in a
    /// repeated hour).
    pub fn utc_of(self, at: NaiveDateTime) -> Option<DateTime<Utc>> {
        match self {
            Zone::Local => Local
                .from_local_datetime(&at)
                .earliest()
                .map(|t| t.with_timezone(&Utc)),
            Zone::Fixed(offset) => offset
                .from_local_datetime(&at)
                .earliest()
                .map(|t| t.with_timezone(&Utc)),
        }
    }
}

/// The clock and zone the view reads times on.
#[derive(Clone)]
pub struct Clock {
    pub now: Now,
    pub zone: Zone,
}

impl Default for Clock {
    fn default() -> Self {
        Clock {
            now: Rc::new(Utc::now),
            zone: Zone::Local,
        }
    }
}

impl std::fmt::Debug for Clock {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Clock").field("zone", &self.zone).finish()
    }
}

impl Clock {
    /// A clock stopped at `at`, read in UTC: for tests.
    pub fn fixed(at: DateTime<Utc>) -> Clock {
        Clock {
            now: Rc::new(move || at),
            zone: Zone::utc(),
        }
    }

    pub fn now(&self) -> DateTime<Utc> {
        (self.now)()
    }
}

/// An ISO 8601 time as the MC writes them (Qt::ISODateWithMs): with or
/// without milliseconds and an offset; one without an offset is local.
/// None for anything else.
pub fn parse_iso(text: &str, zone: Zone) -> Option<DateTime<Utc>> {
    if text.is_empty() {
        return None;
    }
    if let Ok(at) = DateTime::parse_from_rfc3339(text) {
        return Some(at.with_timezone(&Utc));
    }
    ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%dT%H:%M"]
        .iter()
        .find_map(|format| NaiveDateTime::parse_from_str(text, format).ok())
        .and_then(|at| zone.utc_of(at))
}

/// A JSON string as a time; None for anything else.
pub fn time_of(value: Option<&Json>, zone: Zone) -> Option<DateTime<Utc>> {
    parse_iso(value?.as_str()?, zone)
}

/// The time of day in the device's timestampFormat, as sidebar::timeOfDay
/// reads it.
pub fn time_of_day(local: NaiveDateTime, timestamp_format: &str) -> String {
    let (hour, minute) = (local.hour(), local.minute());
    match timestamp_format {
        "24-hour" => format!("{hour:02}:{minute:02}"),
        "12-hour" => {
            let twelve = match hour % 12 {
                0 => 12,
                h => h,
            };
            let half = if hour < 12 { "AM" } else { "PM" };
            format!("{twelve}:{minute:02} {half}")
        }
        _ => crate::sidebar_model::short_time(hour, minute),
    }
}

/// en-US's numeric date, as Intl's {month: "numeric", day: "numeric"}
/// (and year: "numeric" with `with_year`): "9/20", "9/20/2025".
// TODO(ljos#76): QLocale::dateFormat(ShortFormat), only en-US here.
pub fn numeric_date(date: NaiveDate, with_year: bool) -> String {
    if with_year {
        format!("{}/{}/{}", date.month(), date.day(), date.year())
    } else {
        format!("{}/{}", date.month(), date.day())
    }
}

/// formatDayAwareTimestamp for a time that has happened: "9:41 AM",
/// "yesterday at 9:41 AM", "9/20 9:41 AM".
pub fn day_aware(local: NaiveDateTime, today: NaiveDate, timestamp_format: &str) -> String {
    let time = time_of_day(local, timestamp_format);
    let days = (today - local.date()).num_days();
    if days <= 0 {
        return time;
    }
    if days == 1 {
        return format!("yesterday at {time}");
    }
    format!(
        "{} {time}",
        numeric_date(local.date(), local.date().year() != today.year())
    )
}

/// A time as the rows show theirs, on local calendar days; empty for none.
pub fn stamp(at: Option<DateTime<Utc>>, clock: &Clock, timestamp_format: &str) -> String {
    let Some(at) = at else {
        return String::new();
    };
    let today = clock.zone.local(clock.now()).date();
    day_aware(clock.zone.local(at), today, timestamp_format)
}

/// A time that may be ahead, as a usage limit's reset reads: "9:41 AM"
/// today, "tomorrow at 9:41 AM", "10/9 9:41 AM"; a past one reads as
/// [`stamp`].
pub fn upcoming_stamp(at: Option<DateTime<Utc>>, clock: &Clock, timestamp_format: &str) -> String {
    let Some(at) = at else {
        return String::new();
    };
    let local = clock.zone.local(at);
    let today = clock.zone.local(clock.now()).date();
    let days = (local.date() - today).num_days();
    if days < 0 {
        return day_aware(local, today, timestamp_format);
    }
    let time = time_of_day(local, timestamp_format);
    match days {
        0 => time,
        1 => format!("tomorrow at {time}"),
        _ => format!(
            "{} {time}",
            numeric_date(local.date(), local.date().year() != today.year())
        ),
    }
}

/// The long form of a time, in English, for a tooltip: "9:41 AM, 23rd
/// September 2026".
pub fn long_time(at: DateTime<Utc>, clock: &Clock, timestamp_format: &str) -> String {
    const MONTHS: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    let local = clock.zone.local(at);
    let day = local.day();
    format!(
        "{}, {day}{} {} {}",
        time_of_day(local, timestamp_format),
        ordinal_suffix(day),
        MONTHS[local.month0() as usize],
        local.year()
    )
}

pub fn ordinal_suffix(day: u32) -> &'static str {
    if (11..=13).contains(&(day % 100)) {
        return "th";
    }
    match day % 10 {
        1 => "st",
        2 => "nd",
        3 => "rd",
        _ => "th",
    }
}

/// apps/tui/src/timeline.ts formatDuration: "850ms", "4.2s", "12s", "2m",
/// "2m 5s".
pub fn format_duration(ms: i64) -> String {
    if ms < 0 {
        return "0ms".into();
    }
    if ms < 1000 {
        return format!("{}ms", ms.max(1));
    }
    if ms < 10_000 {
        let tenths = (ms as f64 / 100.0).round() / 10.0;
        return if tenths >= 10.0 {
            "10s".into()
        } else {
            format!("{tenths:.1}s")
        };
    }
    if ms < 60_000 {
        return format!("{}s", (ms as f64 / 1000.0).round() as i64);
    }
    let minutes = ms / 60_000;
    let seconds = ((ms % 60_000) as f64 / 1000.0).round() as i64;
    match seconds {
        0 => format!("{minutes}m"),
        60 => format!("{}m", minutes + 1),
        _ => format!("{minutes}m {seconds}s"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> DateTime<Utc> {
        parse_iso(text, Zone::utc()).unwrap()
    }

    fn clock() -> Clock {
        Clock::fixed(at("2026-09-23T10:00:00Z"))
    }

    #[test]
    fn reads_the_mc_times() {
        assert_eq!(
            parse_iso("2026-09-23T10:00:00.250Z", Zone::utc()),
            Some(at("2026-09-23T10:00:00Z") + chrono::Duration::milliseconds(250))
        );
        assert_eq!(
            parse_iso("2026-09-23T12:00:00+02:00", Zone::utc()),
            Some(at("2026-09-23T10:00:00Z"))
        );
        assert_eq!(parse_iso("", Zone::utc()), None);
        assert_eq!(parse_iso("soon", Zone::utc()), None);
    }

    // features/timeline: "the message is stamped …".
    #[test]
    fn stamps_a_time_by_the_day_it_was() {
        let c = clock();
        let stamp = |t: &str, format: &str| stamp(Some(at(t)), &c, format);
        assert_eq!(stamp("2026-09-23T09:05:00Z", "locale"), "9:05 AM");
        assert_eq!(stamp("2026-09-23T09:05:00Z", "24-hour"), "09:05");
        assert_eq!(stamp("2026-09-23T13:05:00Z", "12-hour"), "1:05 PM");
        assert_eq!(
            stamp("2026-09-22T09:05:00Z", "locale"),
            "yesterday at 9:05 AM"
        );
        assert_eq!(stamp("2026-09-20T09:05:00Z", "locale"), "9/20 9:05 AM");
        assert_eq!(
            stamp("2025-12-31T00:05:00Z", "locale"),
            "12/31/2025 12:05 AM"
        );
        assert_eq!(super::stamp(None, &c, "locale"), "");
    }

    #[test]
    fn a_time_ahead_reads_from_today() {
        let c = clock();
        let up = |t: &str| upcoming_stamp(Some(at(t)), &c, "locale");
        assert_eq!(up("2026-09-23T11:00:00Z"), "11:00 AM");
        assert_eq!(up("2026-09-24T09:41:00Z"), "tomorrow at 9:41 AM");
        assert_eq!(up("2026-10-09T09:41:00Z"), "10/9 9:41 AM");
        assert_eq!(up("2026-09-22T09:41:00Z"), "yesterday at 9:41 AM");
    }

    #[test]
    fn the_long_time_names_the_day() {
        let c = clock();
        assert_eq!(
            long_time(at("2026-09-23T09:41:00Z"), &c, "locale"),
            "9:41 AM, 23rd September 2026"
        );
        assert_eq!(ordinal_suffix(1), "st");
        assert_eq!(ordinal_suffix(2), "nd");
        assert_eq!(ordinal_suffix(11), "th");
        assert_eq!(ordinal_suffix(12), "th");
        assert_eq!(ordinal_suffix(13), "th");
        assert_eq!(ordinal_suffix(22), "nd");
    }

    #[test]
    fn durations_read_as_the_tui_reads_them() {
        assert_eq!(format_duration(-5), "0ms");
        assert_eq!(format_duration(0), "1ms");
        assert_eq!(format_duration(850), "850ms");
        assert_eq!(format_duration(4_240), "4.2s");
        assert_eq!(format_duration(9_960), "10s");
        assert_eq!(format_duration(12_400), "12s");
        assert_eq!(format_duration(120_000), "2m");
        assert_eq!(format_duration(125_000), "2m 5s");
        assert_eq!(format_duration(179_700), "3m");
    }
}
