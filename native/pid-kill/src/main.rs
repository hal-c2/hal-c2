//! `hal-c2-pid-kill [--group] <pid> <start ticks>`: SIGKILL the process `pid` only if it
//! is still the one that started at those ticks, and, with `--group`, the group it leads.
//!
//! The MC's orphan reaper (`HalC2.Subprocess.Orphans`) runs this. The pidfd is opened
//! before the start time is read, so the signal can only reach the process that was
//! read: a pid reused after that leaves the pidfd naming the old process, and a signal
//! through it fails instead of landing on the new one.
//!
//! Exits 0 when the signal was delivered, 3 when the pid no longer holds that process
//! (nothing was signalled), 4 when this kernel has no pidfds (the caller has to fall
//! back), and 1 on any other failure.

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::{c_int, c_long, c_uint, c_void};
    use std::io::{Error, ErrorKind};
    use std::ptr::null;

    // The same on every architecture Linux gave numbers to after 4.20.
    const SYS_PIDFD_SEND_SIGNAL: c_long = 424;
    const SYS_PIDFD_OPEN: c_long = 434;
    const SIGKILL: c_int = 9;
    const PIDFD_SIGNAL_PROCESS_GROUP: c_uint = 1 << 2;
    const EPERM: i32 = 1;
    const ESRCH: i32 = 3;
    const EINVAL: i32 = 22;
    const ENOSYS: i32 = 38;

    unsafe extern "C" {
        fn syscall(number: c_long, ...) -> c_long;
        fn close(fd: c_int) -> c_int;
        fn kill(pid: c_int, signal: c_int) -> c_int;
    }

    #[derive(Debug, PartialEq)]
    pub enum Outcome {
        Delivered,
        NotThatProcess,
        NoPidfds,
        Failed(String),
    }

    struct Pidfd(c_int);

    impl Drop for Pidfd {
        fn drop(&mut self) {
            unsafe { close(self.0) };
        }
    }

    impl Pidfd {
        fn open(pid: c_int) -> Result<Self, Error> {
            match unsafe { syscall(SYS_PIDFD_OPEN, pid, 0 as c_uint) } {
                -1 => Err(Error::last_os_error()),
                fd => Ok(Self(fd as c_int)),
            }
        }

        fn signal(&self, signal: c_int, flags: c_uint) -> Result<(), Error> {
            let info: *const c_void = null();
            match unsafe { syscall(SYS_PIDFD_SEND_SIGNAL, self.0, signal, info, flags) } {
                -1 => Err(Error::last_os_error()),
                _ => Ok(()),
            }
        }

        // SIGKILL for the group whose id is this process's own pid. The flag names the
        // group by the pidfd itself (Linux 6.9). Before that the id is all there is: it
        // is checked to still be this process's right before, which leaves the moment
        // between them on those kernels.
        fn kill_group(&self, pid: c_int) -> Result<(), Error> {
            match self.signal(SIGKILL, PIDFD_SIGNAL_PROCESS_GROUP) {
                Err(e) if e.raw_os_error() == Some(EINVAL) => {
                    self.signal(0, 0)?;
                    match unsafe { kill(-pid, SIGKILL) } {
                        -1 => Err(Error::last_os_error()),
                        _ => Ok(()),
                    }
                }
                other => other,
            }
        }
    }

    // Field 22 of a stat, counted after the command name, which may hold spaces and
    // parentheses.
    pub fn start_ticks(stat: &str) -> Option<&str> {
        stat.rsplit(')').next()?.split_whitespace().nth(19)
    }

    // Lossy: the command name in it is raw bytes, which the kernel may have cut mid-character.
    fn read_stat(pid: c_int) -> Result<String, Error> {
        let stat = std::fs::read(format!("/proc/{pid}/stat"))?;
        Ok(String::from_utf8_lossy(&stat).into_owned())
    }

    pub fn kill_checked(pid: c_int, ticks: &str, group: bool) -> Outcome {
        let fd = match Pidfd::open(pid) {
            Ok(fd) => fd,
            Err(e) => {
                return match e.raw_os_error() {
                    Some(ESRCH) => Outcome::NotThatProcess,
                    // EPERM: a seccomp filter that refuses what it does not know.
                    Some(ENOSYS | EPERM) => Outcome::NoPidfds,
                    _ => Outcome::Failed(format!("pidfd_open: {e}")),
                };
            }
        };

        match read_stat(pid) {
            Ok(stat) if start_ticks(&stat) == Some(ticks) => {}
            Ok(_) => return Outcome::NotThatProcess,
            // ESRCH: reaped after the file was opened.
            Err(e) if e.kind() == ErrorKind::NotFound || e.raw_os_error() == Some(ESRCH) => {
                return Outcome::NotThatProcess;
            }
            Err(e) => return Outcome::Failed(format!("reading its stat: {e}")),
        }

        // No group left to signal is not a failure: its leader is signalled next.
        let group = if group {
            match fd.kill_group(pid) {
                Ok(()) => Some(Ok(())),
                Err(e) if e.raw_os_error() == Some(ESRCH) => None,
                Err(e) => Some(Err(e)),
            }
        } else {
            None
        };

        match (fd.signal(SIGKILL, 0), group) {
            (_, Some(Err(e))) => Outcome::Failed(format!("signalling its group: {e}")),
            (Ok(()), _) => Outcome::Delivered,
            // The group's signal already ended it, and its parent reaped it.
            (Err(e), Some(Ok(()))) if e.raw_os_error() == Some(ESRCH) => Outcome::Delivered,
            (Err(e), _) if e.raw_os_error() == Some(ESRCH) => Outcome::NotThatProcess,
            (Err(e), _) => Outcome::Failed(format!("signalling it: {e}")),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::io::{BufRead, BufReader};
        use std::os::unix::process::{CommandExt, ExitStatusExt};
        use std::process::{Child, Command, Stdio};

        fn ticks(pid: u32) -> String {
            start_ticks(&read_stat(pid as c_int).unwrap())
                .unwrap()
                .to_owned()
        }

        fn sleeper(new_group: bool) -> Child {
            let mut command = Command::new("sleep");
            command.arg("60");
            if new_group {
                command.process_group(0);
            }
            command.spawn().unwrap()
        }

        #[test]
        fn reads_the_start_ticks_past_a_command_name_with_parentheses() {
            let fields = (4..=21)
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
                .join(" ");
            let stat = format!("123 (a) b) c) S {fields} 999 1000");
            assert_eq!(start_ticks(&stat), Some("999"));
            assert_eq!(start_ticks("123 (sh) S 1"), None);
        }

        #[test]
        fn kills_the_process_that_started_at_those_ticks() {
            let mut child = sleeper(false);
            let outcome = kill_checked(child.id() as c_int, &ticks(child.id()), false);
            assert_eq!(outcome, Outcome::Delivered);
            assert_eq!(child.wait().unwrap().signal(), Some(SIGKILL));
        }

        #[test]
        fn kills_a_process_whose_name_is_not_utf8() {
            let mut child = Command::new("sh")
                .args([
                    "-c",
                    r#"printf 'a\346' > /proc/$$/comm; echo named; read l"#,
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            let mut named = String::new();
            BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut named)
                .unwrap();
            assert_eq!(named, "named\n");
            let comm = std::fs::read(format!("/proc/{}/comm", child.id())).unwrap();
            assert!(String::from_utf8(comm).is_err());

            let outcome = kill_checked(child.id() as c_int, &ticks(child.id()), false);
            assert_eq!(outcome, Outcome::Delivered);
            assert_eq!(child.wait().unwrap().signal(), Some(SIGKILL));
        }

        #[test]
        fn spares_a_process_that_started_at_other_ticks() {
            let mut child = sleeper(false);
            let outcome = kill_checked(child.id() as c_int, "0", false);
            assert_eq!(outcome, Outcome::NotThatProcess);
            assert_eq!(child.try_wait().unwrap(), None);
            child.kill().unwrap();
            child.wait().unwrap();
        }

        #[test]
        fn a_group_kill_reaches_the_rest_of_the_group() {
            let mut leader = sleeper(true);
            let mut member = Command::new("sleep");
            member.arg("60").process_group(leader.id() as i32);
            let mut member = member.spawn().unwrap();
            let outcome = kill_checked(leader.id() as c_int, &ticks(leader.id()), true);
            assert_eq!(outcome, Outcome::Delivered);
            assert_eq!(leader.wait().unwrap().signal(), Some(SIGKILL));
            assert_eq!(member.wait().unwrap().signal(), Some(SIGKILL));
        }

        // What closes the race: once the process is gone, its number may be anyone's,
        // and the pidfd still names only the process it was opened on.
        #[test]
        fn a_pidfd_outliving_its_process_signals_nothing() {
            let mut child = sleeper(false);
            let fd = Pidfd::open(child.id() as c_int).unwrap();
            child.kill().unwrap();
            child.wait().unwrap();
            assert_eq!(
                fd.signal(SIGKILL, 0).unwrap_err().raw_os_error(),
                Some(ESRCH)
            );
        }

        #[test]
        fn no_such_process_is_not_that_process() {
            let mut child = sleeper(false);
            let (pid, started) = (child.id(), ticks(child.id()));
            child.kill().unwrap();
            child.wait().unwrap();
            assert_eq!(
                kill_checked(pid as c_int, &started, false),
                Outcome::NotThatProcess
            );
        }
    }
}

#[cfg(target_os = "linux")]
fn main() {
    use linux::{Outcome, kill_checked};

    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let group = args.first().is_some_and(|arg| arg == "--group");
    if group {
        args.remove(0);
    }

    let [pid, ticks] = args.as_slice() else {
        eprintln!("usage: hal-c2-pid-kill [--group] <pid> <start ticks>");
        std::process::exit(1);
    };
    let pid = match pid.parse() {
        Ok(pid) if pid > 1 => pid,
        _ => {
            eprintln!("not a pid to kill: {pid}");
            std::process::exit(1);
        }
    };

    std::process::exit(match kill_checked(pid, ticks, group) {
        Outcome::Delivered => 0,
        Outcome::NotThatProcess => 3,
        Outcome::NoPidfds => 4,
        Outcome::Failed(why) => {
            eprintln!("{why}");
            1
        }
    });
}

#[cfg(not(target_os = "linux"))]
fn main() {
    std::process::exit(4);
}
