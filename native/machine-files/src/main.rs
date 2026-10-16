//! `hal-c2-machine-files <mountpoint> [--ttl-ms <ms>]`: shows the other machines of
//! the cluster at `<mountpoint>` through FUSE, one folder each.
//!
//! The MC that starts it (`HalC2.MachineFiles`) is its 9P2000.L server over stdin
//! and stdout; it only translates. It sends Tversion, mounts, then sends Tattach,
//! which tells the MC the folder is ready. When its input ends (the MC stopped) it
//! unmounts and exits 0; when the mount goes away under it, it exits 1. It logs to
//! stderr only, since stdout is the protocol.

// Elsewhere only the codec's tests use the codec.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod client;
#[cfg(target_os = "linux")]
mod fs;
mod p9;

use std::process::ExitCode;

fn main() -> ExitCode {
    #[cfg(target_os = "linux")]
    {
        linux::run()
    }
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("machine-files: showing another machine's files needs FUSE on Linux for now");
        ExitCode::from(2)
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use crate::client::Client;
    use crate::fs::{MachineFiles, Ready};
    use crate::p9::T;
    use fuser::{Config, MountOption, Session, SessionACL};
    use std::io;
    use std::path::PathBuf;
    use std::process::ExitCode;
    use std::sync::Arc;
    use std::sync::mpsc::channel;
    use std::thread;
    use std::time::Duration;

    const MSIZE: u32 = 1024 * 1024 + 4096;

    enum Event {
        InputClosed,
        Unmounted,
    }

    struct Args {
        mountpoint: PathBuf,
        ttl: Duration,
    }

    fn args() -> Result<Args, String> {
        let mut mountpoint = None;
        let mut ttl = Duration::from_secs(1);
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--ttl-ms" => {
                    let ms = args
                        .next()
                        .and_then(|v| v.parse().ok())
                        .ok_or("--ttl-ms needs a number")?;
                    ttl = Duration::from_millis(ms);
                }
                _ if mountpoint.is_none() => mountpoint = Some(PathBuf::from(arg)),
                _ => return Err(format!("unexpected argument {arg}")),
            }
        }
        let mountpoint =
            mountpoint.ok_or("usage: hal-c2-machine-files <mountpoint> [--ttl-ms <ms>]")?;
        Ok(Args { mountpoint, ttl })
    }

    pub fn run() -> ExitCode {
        let args = match args() {
            Ok(args) => args,
            Err(message) => {
                eprintln!("machine-files: {message}");
                return ExitCode::from(2);
            }
        };

        let client = Arc::new(Client::new(Box::new(io::stdout())));
        let (events, event) = channel();
        {
            let client = client.clone();
            let events = events.clone();
            thread::spawn(move || {
                if let Err(e) = client.read_replies(io::stdin().lock()) {
                    eprintln!("machine-files: reading from the MC: {e}");
                }
                let _ = events.send(Event::InputClosed);
            });
        }

        if let Err(errno) = client.version(MSIZE) {
            eprintln!("machine-files: the MC did not agree on 9P2000.L (errno {errno})");
            return ExitCode::FAILURE;
        }

        let ready = Arc::new(Ready::default());
        let fs = MachineFiles::new(client.clone(), ready.clone(), args.ttl);
        let mut config = Config::default();
        config.mount_options = vec![
            MountOption::FSName("hal-c2".into()),
            MountOption::Subtype("machines".into()),
            MountOption::NoSuid,
            MountOption::NoDev,
        ];
        // No allow_other: only the user the MC runs as gets in.
        config.acl = SessionACL::Owner;
        config.n_threads = Some(8);
        config.clone_fd = true;

        let mut session = match Session::new(fs, &args.mountpoint, &config) {
            Ok(session) => session,
            Err(e) => {
                eprintln!("machine-files: mounting {}: {e}", args.mountpoint.display());
                return ExitCode::FAILURE;
            }
        };
        let mut unmounter = session.unmount_callable();
        thread::spawn(move || {
            if let Err(e) = session.run() {
                eprintln!("machine-files: {e}");
            }
            let _ = events.send(Event::Unmounted);
        });

        // SAFETY: getuid cannot fail and touches no memory.
        let uid = unsafe { libc::getuid() };
        if let Err(errno) = client.call(&T::Attach {
            fid: 0,
            n_uname: uid,
        }) {
            eprintln!("machine-files: the MC refused the attach (errno {errno})");
            let _ = unmounter.unmount();
            return ExitCode::FAILURE;
        }
        ready.set();

        match event.recv() {
            Ok(Event::InputClosed) | Err(_) => {
                if let Err(e) = unmounter.unmount() {
                    eprintln!("machine-files: unmounting: {e}");
                    return ExitCode::FAILURE;
                }
                ExitCode::SUCCESS
            }
            Ok(Event::Unmounted) => {
                eprintln!("machine-files: the folder was unmounted");
                ExitCode::FAILURE
            }
        }
    }
}
