//! A time zone by its IANA name as chrono reads one, so the models written
//! over `chrono::TimeZone` keep a named zone's daylight saving changes.

use std::fmt;
use std::rc::Rc;

use chrono::{
    FixedOffset, MappedLocalTime, NaiveDate, NaiveDateTime, Offset as ChronoOffset, TimeZone,
};
use ljos::locale::{LocalTime, TimeZone as Named};

/// The zone the platform's database names, as `QTimeZone(id)` is.
#[derive(Clone, Debug)]
pub struct Zone(Rc<Named>);

impl Zone {
    /// The zone named `id` (`America/New_York`), if the database has it.
    #[must_use]
    pub fn named(id: &str) -> Option<Self> {
        Named::named(id).map(|zone| Self(Rc::new(zone)))
    }

    fn at(&self, unix_ms: i64) -> Offset {
        let seconds = self.0.offset_at(unix_ms);
        Offset {
            zone: self.clone(),
            fixed: FixedOffset::east_opt(seconds).unwrap_or(FixedOffset::east_opt(0).unwrap()),
        }
    }
}

/// A zone's offset at one instant, with the zone it is of.
#[derive(Clone, Debug)]
pub struct Offset {
    zone: Zone,
    fixed: FixedOffset,
}

impl ChronoOffset for Offset {
    fn fix(&self) -> FixedOffset {
        self.fixed
    }
}

impl fmt::Display for Offset {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.fixed.fmt(f)
    }
}

impl TimeZone for Zone {
    type Offset = Offset;

    fn from_offset(offset: &Offset) -> Self {
        offset.zone.clone()
    }

    fn offset_from_local_date(&self, local: &NaiveDate) -> MappedLocalTime<Offset> {
        self.offset_from_local_datetime(&local.and_time(chrono::NaiveTime::MIN))
    }

    fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> MappedLocalTime<Offset> {
        match self.0.from_local(local.and_utc().timestamp_millis()) {
            LocalTime::None => MappedLocalTime::None,
            LocalTime::One(at) => MappedLocalTime::Single(self.at(at)),
            LocalTime::Both(first, second) => {
                MappedLocalTime::Ambiguous(self.at(first), self.at(second))
            }
        }
    }

    fn offset_from_utc_date(&self, utc: &NaiveDate) -> Offset {
        self.offset_from_utc_datetime(&utc.and_time(chrono::NaiveTime::MIN))
    }

    fn offset_from_utc_datetime(&self, utc: &NaiveDateTime) -> Offset {
        self.at(utc.and_utc().timestamp_millis())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_named_zone_skips_and_repeats_its_changed_hours() {
        let zone = Zone::named("America/New_York").expect("the platform's zone database");
        let local = |month: u32, day: u32, hour: u32| {
            NaiveDate::from_ymd_opt(2027, month, day)
                .and_then(|date| date.and_hms_opt(hour, 30, 0))
                .unwrap()
        };
        // 14 March 2027, 02:00 -> 03:00.
        assert!(
            zone.from_local_datetime(&local(3, 14, 2))
                .earliest()
                .is_none()
        );
        let after = zone.from_local_datetime(&local(3, 14, 3)).single().unwrap();
        assert_eq!(after.offset().fix().local_minus_utc(), -4 * 3600);
        // 7 November 2027, 02:00 -> 01:00.
        let repeated = zone.from_local_datetime(&local(11, 7, 1));
        assert!(matches!(repeated, MappedLocalTime::Ambiguous(..)));
        let winter = repeated.latest().unwrap();
        assert_eq!(winter.offset().fix().local_minus_utc(), -5 * 3600);
        // Time added in the zone is read in it, not at the offset it left.
        let later = after + chrono::Duration::days(240);
        assert_eq!(later.offset().fix().local_minus_utc(), -5 * 3600);
    }
}
