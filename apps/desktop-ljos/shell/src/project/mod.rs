//! What the shell knows of a project apart from its threads: how it is told
//! apart ([`identity`]), its checkout's `hal-c2.json` ([`file`]) and the
//! actions the environment resolves for it ([`scripts`]).

pub mod file;
pub mod identity;
pub mod scripts;
