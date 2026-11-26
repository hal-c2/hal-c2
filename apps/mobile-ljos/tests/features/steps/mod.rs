//! The domains' steps, each a file that registers its own, as
//! mobile-qt's tests/features lays them out.

mod pairing;

use crate::harness::Steps;

pub fn register(steps: &mut Steps) {
    pairing::register(steps);
}
