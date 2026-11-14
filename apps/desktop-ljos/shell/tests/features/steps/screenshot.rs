//! A scripted screenshot of a start that fails (features/desktop/
//! shell-host.feature): the capture and the exit code are main.rs's, so this
//! runs the built `hal-c2-ljos` itself (no window: `--screenshot` draws
//! offscreen) with a home of its own and a pairing link nothing listens
//! behind. desktop-qt's ScreenshotSteps.cpp.

use std::collections::HashSet;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use crate::harness::Steps;
use crate::{expect, fail};

#[derive(Default)]
struct FailedStart {
    origin: String,
    log: String,
    exit_code: Option<i32>,
    exited: bool,
    shot: PathBuf,
}

const LIMIT: Duration = Duration::from_secs(60);

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user starts the desktop app asking for a screenshot, with a pairing link for an MC that is not running",
        |world, _, _| {
            let home = world.home_dir().join("screenshot-home");
            if std::fs::create_dir_all(&home).is_err() {
                fail!("cannot make {}", home.display());
            }
            // A port nothing listens on: taken, then let go.
            let probe = match std::net::TcpListener::bind("127.0.0.1:0") {
                Ok(probe) => probe,
                Err(e) => fail!("{e}"),
            };
            let port = probe.local_addr().map(|a| a.port()).unwrap_or(0);
            drop(probe);
            let origin = format!("http://127.0.0.1:{port}");
            let shot = home.join("shot.png");
            let child = Command::new(env!("CARGO_BIN_EXE_hal-c2-ljos"))
                .arg("--home-dir")
                .arg(&home)
                .arg("--config-dir")
                .arg(home.join("shell"))
                .arg("--pair")
                .arg(format!("{origin}/pair#token=spent"))
                .arg("--screenshot")
                .arg(&shot)
                // Every file it keeps goes under the scratch home, never the user's.
                .env("HAL_C2_HOME", &home)
                .env_remove("HAL_C2_MC_ORIGIN")
                .env_remove("HAL_C2_MC_TOKEN")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn();
            let child = match child {
                Ok(child) => child,
                Err(e) => fail!("the desktop app did not start: {e}"),
            };
            let pid = child.id();
            let (done, answer) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = done.send(child.wait_with_output());
            });
            let start = world.part::<FailedStart>();
            start.origin = origin;
            start.shot = shot;
            match answer.recv_timeout(LIMIT) {
                Ok(Ok(output)) => {
                    start.log = format!(
                        "{}{}",
                        String::from_utf8_lossy(&output.stdout),
                        String::from_utf8_lossy(&output.stderr)
                    );
                    start.exited = true;
                    start.exit_code = output.status.code();
                    expect!(
                        start.exit_code.is_some(),
                        "the desktop app crashed; it said:\n{}",
                        start.log
                    );
                    Ok(())
                }
                Ok(Err(e)) => fail!("the desktop app was not waited for: {e}"),
                Err(_) => {
                    // The one process this step started, by the id it was given.
                    let _ = Command::new("kill").args(["-9", &pid.to_string()]).status();
                    fail!("the desktop app did not quit")
                }
            }
        },
    );
    steps.step(
        "the screenshot shows the desktop app saying it cannot reach the MC",
        |world, _, _| {
            let start = world.part::<FailedStart>();
            // What the window was told, then the capture of it.
            let told = start
                .log
                .find(&format!("no MC answered at {}", start.origin));
            let captured = start.log.find(&format!("wrote {}", start.shot.display()));
            expect!(
                told.is_some() && captured > told,
                "the desktop app said:\n{}",
                start.log
            );
            let shot = image::open(&start.shot).map(|i| i.to_rgba8());
            let Ok(shot) = shot else {
                fail!("no screenshot at {}", start.shot.display());
            };
            expect!(
                shot.width() > 200 && shot.height() > 200,
                "no screenshot at {}",
                start.shot.display()
            );
            // The error is drawn over the window: more than its background.
            let mut colours = HashSet::new();
            'rows: for y in (0..shot.height()).step_by(2) {
                for x in (0..shot.width()).step_by(2) {
                    colours.insert(shot.get_pixel(x, y).0);
                    if colours.len() >= 3 {
                        break 'rows;
                    }
                }
            }
            expect!(colours.len() >= 3, "the screenshot is one flat colour");
            Ok(())
        },
    );
    steps.step(
        "the desktop app quits with a failure code",
        |world, _, _| {
            let start = world.part::<FailedStart>();
            expect!(
                start.exited && start.exit_code == Some(2),
                "the desktop app quit with {:?}",
                start.exit_code
            );
            Ok(())
        },
    );
}
