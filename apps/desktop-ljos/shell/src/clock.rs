//! The wall clock moving other than by time passing: set by hand or by
//! the network, or the machine waking from sleep. What is scheduled for a
//! wall-clock moment ("Next run in 5m") is scheduled on the engine's
//! steady clock, which a jump does not move and sleep may stop, so it
//! listens here and works out its moment again.
//!
//! The system says when it happens; nothing here polls. On Linux a thread
//! blocks on a timerfd armed on the real-time clock with
//! `TFD_TIMER_CANCEL_ON_SET`, which the kernel cancels when the clock is
//! set and on resume. On macOS a thread blocks on the Darwin notification
//! the system posts when the calendar clock is set, which it also posts
//! on wake. Windows' steady clock counts sleep, so a schedule due while
//! the machine slept fires on wake; a hand-set clock there is seen at the
//! next moment something is shown again.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use ljos::prelude::Engine;

type Wake = Arc<dyn Fn() + Send + Sync>;

/// What the watcher thread leaves for the Engine thread.
#[derive(Default)]
struct Changes {
    pending: AtomicBool,
    wake: Mutex<Option<Wake>>,
}

impl Changes {
    fn push(&self) {
        self.pending.store(true, Ordering::Release);
        let wake = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(wake) = wake {
            wake();
        }
    }
}

#[derive(Default)]
struct Clock {
    listeners: RefCell<Vec<Rc<dyn Fn(&Engine)>>>,
    changes: Arc<Changes>,
    watching: Cell<bool>,
}

/// Calls `f` on the Engine thread each time the wall clock jumps or the
/// machine wakes.
pub fn on_change(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Clock>()
        .listeners
        .borrow_mut()
        .push(Rc::new(f));
}

/// Tells every listener the wall clock moved: what the watcher does, and
/// what a test does after setting the engine's wall clock.
pub fn changed(engine: &Engine) {
    let listeners = engine.extension::<Clock>().listeners.borrow().clone();
    for listener in listeners {
        listener(engine);
    }
}

/// Starts watching the system's clock; `wake` brings the Engine thread to
/// [`deliver`]. Once per engine.
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    let clock = engine.extension::<Clock>();
    *clock
        .changes
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(wake));
    let changes = clock.changes.clone();
    if !clock.watching.replace(true) {
        watch(changes);
    }
}

/// Tells the listeners when the watcher saw the clock move. On the Engine
/// thread.
pub fn deliver(engine: &Engine) {
    let clock = engine.extension::<Clock>();
    if clock.changes.pending.swap(false, Ordering::AcqRel) {
        changed(engine);
    }
}

fn spawn(changes: Arc<Changes>, run: impl FnOnce(&Changes) + Send + 'static) {
    let started = std::thread::Builder::new()
        .name("clock-watch".into())
        .spawn(move || run(&changes));
    if let Err(error) = started {
        eprintln!("[clock] cannot watch the system clock: {error}");
    }
}

#[cfg(target_os = "linux")]
fn watch(changes: Arc<Changes>) {
    spawn(changes, |changes| {
        // SAFETY: plain syscalls on a descriptor this thread owns.
        unsafe {
            let fd = libc::timerfd_create(libc::CLOCK_REALTIME, libc::TFD_CLOEXEC);
            if fd < 0 {
                eprintln!("[clock] no timerfd: {}", std::io::Error::last_os_error());
                return;
            }
            // A deadline that never comes: only the cancel wakes the read.
            let never = libc::itimerspec {
                it_interval: libc::timespec {
                    tv_sec: 0,
                    tv_nsec: 0,
                },
                it_value: libc::timespec {
                    tv_sec: libc::time_t::MAX,
                    tv_nsec: 0,
                },
            };
            loop {
                let flags = libc::TFD_TIMER_ABSTIME | libc::TFD_TIMER_CANCEL_ON_SET;
                if libc::timerfd_settime(fd, flags, &never, std::ptr::null_mut()) < 0 {
                    eprintln!(
                        "[clock] cannot arm the timerfd: {}",
                        std::io::Error::last_os_error()
                    );
                    break;
                }
                let mut expirations = 0u64;
                let read = libc::read(
                    fd,
                    (&raw mut expirations).cast(),
                    std::mem::size_of::<u64>(),
                );
                if read >= 0 {
                    continue;
                }
                match std::io::Error::last_os_error().raw_os_error() {
                    Some(libc::ECANCELED) => changes.push(),
                    Some(libc::EINTR) => {}
                    _ => {
                        eprintln!(
                            "[clock] the timerfd failed: {}",
                            std::io::Error::last_os_error()
                        );
                        break;
                    }
                }
            }
            libc::close(fd);
        }
    });
}

#[cfg(target_os = "macos")]
fn watch(changes: Arc<Changes>) {
    use std::ffi::{c_char, c_int};

    // libSystem's notify(3).
    unsafe extern "C" {
        fn notify_register_file_descriptor(
            name: *const c_char,
            notify_fd: *mut c_int,
            flags: c_int,
            out_token: *mut c_int,
        ) -> u32;
    }
    const NOTIFY_STATUS_OK: u32 = 0;

    spawn(changes, |changes| {
        let (mut fd, mut token): (c_int, c_int) = (-1, 0);
        // SAFETY: notify(3) fills `fd` and `token`; the name is a C string.
        let status = unsafe {
            notify_register_file_descriptor(
                c"com.apple.system.clock_set".as_ptr(),
                &mut fd,
                0,
                &mut token,
            )
        };
        if status != NOTIFY_STATUS_OK {
            eprintln!("[clock] cannot watch the system clock: notify status {status}");
            return;
        }
        loop {
            // Each post writes the token that was posted.
            let mut posted: c_int = 0;
            // SAFETY: reading into a local the size of what is written.
            let read =
                unsafe { libc::read(fd, (&raw mut posted).cast(), std::mem::size_of::<c_int>()) };
            if read > 0 {
                changes.push();
            } else if read == 0
                || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR)
            {
                break;
            }
        }
    });
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn watch(_changes: Arc<Changes>) {}
