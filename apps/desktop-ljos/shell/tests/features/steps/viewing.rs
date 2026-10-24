//! What the shell says of times (desktop-qt's ViewingSteps.cpp). For now
//! only "the time is", which most domains' scenarios start from.

use crate::harness::{Q, Steps};

pub fn register(steps: &mut Steps) {
    steps.step(&format!("the time is {Q}"), |world, c, _| {
        world.set_time_iso(&c[0])
    });
}
