//! The system's file dialogs as Qt shows a FileDialog: when one of its
//! `nameFilters` takes every file ("All files (*)"), any file can be
//! chosen.
//!
//! TODO(ljos#NN): Ljós hands the system's dialog only the filters it can
//! name by extension and leaves out one that takes every file, so the rest
//! restrict the choice. The composer's attach dialog asks for
//! `["All files (*)", "Images (*.png ...)"]` and offered images alone: on
//! macOS the open panel greyed out a screen recording (.mov), since rfd
//! makes the extensions of every filter the panel's allowed types, and the
//! portal and Windows offer the Images filter only. Until Ljós keeps that
//! filter, a request with one asks the system for no filter at all.

use std::rc::Rc;

use ljos::prelude::{DialogAnswer, DialogRequest, DialogService, Engine, NameFilter, Platform};

/// Puts [`EveryFile`] in front of the dialogs the host installed. Once,
/// before the root is made.
pub fn install(engine: &Engine) {
    let platform = Platform::of(engine);
    platform.set_dialogs(Rc::new(EveryFile(platform.dialogs())));
}

/// The host's dialogs, asked for no filter when one of a request's takes
/// every file.
struct EveryFile(Rc<dyn DialogService>);

impl DialogService for EveryFile {
    fn can_show(&self, request: &DialogRequest) -> bool {
        self.0.can_show(request)
    }

    fn show(&self, mut request: DialogRequest, answer: DialogAnswer) {
        if request.filters.iter().any(takes_every_file) {
            request.filters.clear();
        }
        self.0.show(request, answer);
    }

    fn close(&self, ticket: u64) {
        self.0.close(ticket);
    }
}

/// `*` or `*.*`, as Qt reads a filter that takes every file.
fn takes_every_file(filter: &NameFilter) -> bool {
    filter.patterns.iter().any(|p| p == "*" || p == "*.*")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_filter_of_every_file_takes_every_file() {
        assert!(takes_every_file(&NameFilter::parse("All files (*)")));
        assert!(takes_every_file(&NameFilter::parse("Anything (*.*)")));
        assert!(!takes_every_file(&NameFilter::parse(
            "Images (*.png *.jpg)"
        )));
        assert!(!takes_every_file(&NameFilter::parse(
            "Theme files (*.json)"
        )));
    }
}
