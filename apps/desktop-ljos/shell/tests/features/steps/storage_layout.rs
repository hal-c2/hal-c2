//! Where the desktop app keeps its files and listens for later launches
//! (src/storage.rs, src/single_instance.rs): the @desktop scenarios of
//! features/mc/platform/storage-layout.feature the shell delivers itself.
//! The user is "/home/me", with the environment each scenario gives them.
//! desktop-qt's StorageLayoutSteps.cpp.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use hal_c2_shell::single_instance;
use hal_c2_shell::storage::{Platform, Profile, StoragePaths, resolve};

use crate::expect;
use crate::harness::{Q, Steps};
use crate::world::World;

const HOME: &str = "/home/me";

#[derive(Default)]
struct Layout {
    env: HashMap<String, String>,
    windows: bool,
    /// One per ambient home the app was started under.
    started: Vec<StoragePaths>,
}

fn layout(world: &mut World) -> &mut Layout {
    world.part::<Layout>()
}

fn expand(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => format!("{HOME}/{rest}"),
        None => path.to_owned(),
    }
}

fn paths_in(
    home_dir: Option<&Path>,
    env: &HashMap<String, String>,
    platform: Platform,
    profile: Profile,
) -> StoragePaths {
    resolve(
        home_dir,
        &|name| env.get(name).cloned(),
        Path::new(HOME),
        platform,
        profile,
    )
}

fn display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// SHA-1 of `data` (RFC 3174), for the name desktop-qt's pipe has always had.
fn sha1_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks(64) {
        let mut w = [0u32; 80];
        for (i, word) in block.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, word) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let next = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = next;
        }
        for (slot, add) in h.iter_mut().zip([a, b, c, d, e]) {
            *slot = slot.wrapping_add(add);
        }
    }
    h.iter().map(|word| format!("{word:08x}")).collect()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "a Linux user with no XDG variables and no HAL-C2 home configured",
        |world, _, _| {
            *layout(world) = Layout::default();
            Ok(())
        },
    );
    steps.step("a Windows user", |world, _, _| {
        layout(world).windows = true;
        Ok(())
    });
    steps.step(
        &format!("HAL_C2_HOME is {Q} in the developer's shell"),
        |world, c, _| {
            layout(world).env.insert("HAL_C2_HOME".into(), c[0].clone());
            Ok(())
        },
    );
    steps.step(&format!("XDG_RUNTIME_DIR is {Q}"), |world, c, _| {
        layout(world)
            .env
            .insert("XDG_RUNTIME_DIR".into(), c[0].clone());
        Ok(())
    });
    steps.step("XDG_RUNTIME_DIR is not set", |world, _, _| {
        layout(world).env.remove("XDG_RUNTIME_DIR");
        Ok(())
    });

    // The home directory.
    steps.step(
        &format!(
            "a developer starts the desktop app from a linked git worktree with --home-dir {Q}"
        ),
        |world, c, _| {
            let state = layout(world);
            // With the developer's own HAL_C2_HOME, and with a worktree's own.
            let mut worktree = state.env.clone();
            worktree.insert(
                "HAL_C2_HOME".into(),
                "/code/hal-c2/.claude/worktrees/feature/.hal-c2".into(),
            );
            for env in [state.env.clone(), worktree] {
                state.started.push(paths_in(
                    Some(Path::new(&c[0])),
                    &env,
                    Platform::Unix,
                    Profile::Installed,
                ));
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the desktop app and the server it hosts keep every kind under {Q}"),
        |world, c, _| {
            let started = layout(world).started.clone();
            expect!(started.len() == 2, "the app was not started");
            let under = |kind: &str| PathBuf::from(&c[0]).join(kind);
            for paths in &started {
                // `root` is what the hosted server is given as --base-dir
                // (main.rs).
                expect!(
                    paths.root.as_deref() == Some(Path::new(&c[0]))
                        && paths.config == under("config")
                        && paths.data == under("data")
                        && paths.state == under("state")
                        && paths.cache == under("cache"),
                    "the app keeps {}, {}, {} and {} and hands the server {:?}",
                    display(&paths.config),
                    display(&paths.data),
                    display(&paths.state),
                    display(&paths.cache),
                    paths.root
                );
            }
            Ok(())
        },
    );

    steps.step(
        "a developer starts the desktop app from a linked git worktree with --dev",
        |world, _, _| {
            let state = layout(world);
            state.started = vec![paths_in(
                None,
                &state.env,
                Platform::Unix,
                Profile::Development,
            )];
            Ok(())
        },
    );
    steps.step("the desktop app keeps its files in:", |world, _, table| {
        let paths = layout(world).started.first().cloned().unwrap_or_default();
        for row in table.iter().skip(1) {
            let kind = row.first().cloned().unwrap_or_default();
            let kept = match kind.as_str() {
                "config" => &paths.config,
                "data" => &paths.data,
                "state" => &paths.state,
                "cache" => &paths.cache,
                _ => Path::new(""),
            };
            let wanted = expand(row.get(1).map_or("", String::as_str));
            expect!(display(kept) == wanted, "{kind} is {}", display(kept));
        }
        Ok(())
    });
    steps.step("the server it hosts is given no root", |world, _, _| {
        // `root` is what the hosted server is given as --base-dir (main.rs).
        let root = layout(world)
            .started
            .first()
            .and_then(|paths| paths.root.clone());
        expect!(root.is_none(), "the server is handed {root:?}");
        Ok(())
    });

    // The control socket.
    steps.step("the user starts the desktop app", |world, _, _| {
        let state = layout(world);
        let platform = if state.windows {
            Platform::Windows
        } else {
            Platform::Unix
        };
        state.started = vec![paths_in(None, &state.env, platform, Profile::Installed)];
        Ok(())
    });
    steps.step(&format!("its control socket is in {Q}"), |world, c, _| {
        let home = world.home_dir().to_path_buf();
        let state = layout(world);
        let started = state.started.first().cloned().unwrap_or_default();
        let runtime = state.env.get("XDG_RUNTIME_DIR").cloned();
        let address = single_instance::address(&started.state, runtime.as_deref(), false);
        let parent = Path::new(&address)
            .parent()
            .map(display)
            .unwrap_or_default();
        expect!(parent == expand(&c[0]), "the socket is {address}");
        // And an app that listens there is found by a later launch. The
        // same rule, in a directory this test may write.
        let scratch = home.join("hc-instance");
        let state_dir = scratch.join("state");
        let via_runtime = runtime.is_some();
        let real_runtime = scratch.join("run");
        let listening = single_instance::address(
            &state_dir,
            via_runtime.then(|| display(&real_runtime)).as_deref(),
            false,
        );
        let wanted = if via_runtime {
            real_runtime.join("hal-c2")
        } else {
            state_dir.clone()
        };
        // A socket path is limited to about a hundred bytes; where this
        // run's scratch home is deeper than that the rule falls back to
        // the temporary directory (single_instance::address), and there
        // is no short directory this test may write to.
        if display(&wanted).len() + "/hal-c2-ljos-".len() + 16 >= 100 {
            return Ok(());
        }
        expect!(
            Path::new(&listening).parent() == Some(wanted.as_path()),
            "the socket would be {listening}"
        );
        let reached = (|| -> std::io::Result<()> {
            std::fs::create_dir_all(wanted)?;
            let server = std::os::unix::net::UnixListener::bind(&listening)?;
            std::os::unix::net::UnixStream::connect(&listening)?;
            drop(server);
            Ok(())
        })();
        expect!(
            reached.is_ok(),
            "nothing can listen at {listening}: {reached:?}"
        );
        Ok(())
    });
    steps.step(
        "its control channel is the same named pipe as before",
        |world, _, _| {
            let state = layout(world);
            let started = state.started.first().cloned().unwrap_or_default();
            // The name it has always had: "hal-c2-qt-" and sixteen hex digits
            // of the state directory's SHA-1, whatever the runtime directory.
            let before = format!(
                "hal-c2-qt-{}",
                &sha1_hex(display(&started.state).as_bytes())[..16]
            );
            let plain = single_instance::address(&started.state, None, true);
            let with_runtime =
                single_instance::address(&started.state, Some("/run/user/1000"), true);
            expect!(
                plain == before && with_runtime == before,
                "the pipe is {plain}, it was {before}"
            );
            Ok(())
        },
    );
}
