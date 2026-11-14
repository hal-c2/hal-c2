//! The machine's time zone named as the usage page's hours name it
//! (UsageController.cpp's hourName). This file has one test, so the zone it
//! sets is the only one the process reads.

use chrono::{DateTime, FixedOffset, Utc};
use hal_c2_shell::controllers::usage::Zone;

fn at(text: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&Utc)
}

#[test]
fn the_machines_zone_says_its_abbreviation() {
    // SAFETY: the one test of this process sets it before anything reads
    // the environment or the local zone.
    unsafe { std::env::set_var("TZ", "America/Los_Angeles") };
    let zone = Zone::system();
    assert_eq!(zone.abbreviation(at("2026-01-01T22:05:00Z")), "PST");
    assert_eq!(zone.abbreviation(at("2026-07-01T21:05:00Z")), "PDT");
    // A zone the machine is not in says its offset.
    let pacific = Zone::changing("America/Los_Angeles", |_| {
        FixedOffset::west_opt(8 * 3600).unwrap()
    });
    assert_eq!(pacific.abbreviation(at("2026-01-01T22:05:00Z")), "-08:00");
}
