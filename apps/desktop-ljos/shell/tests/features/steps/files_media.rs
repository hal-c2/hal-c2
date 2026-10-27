//! Media in the file viewer (desktop-qt's FilesMediaSteps.cpp;
//! features/files/file-viewer-and-editing.feature): an image previewed from
//! the address the thread's environment signed, a preview that fails to load
//! and its retry, and a thread on another machine of the cluster; and a file
//! a reply links to (timeline/markdown.feature). FakeFiles signs and serves
//! the files.

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::workspace_files::media_kind_of;
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use super::fake_files::fake_files;
use super::files_workspace::{
    ensure_viewer_file, environment, file_status, open_path, show_panel, text_prop, workspace_root,
};
use super::stream::{self, FakeStreams};
use crate::brick;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

fn describe_media(world: &World) -> String {
    format!(
        "the viewer has \"{}\" ({} {}, \"{}\") from {}; {}",
        open_path(world),
        text_prop(world, "mediaKind"),
        file_status(world),
        text_prop(world, "fileProblem"),
        text_prop(world, "mediaUrl"),
        image_state(world)
    )
}

/// The panel's Image itself: its status (QQuickImageBase's) and progress,
/// and what it loads.
fn image_state(world: &World) -> String {
    let Some(brick) = world.peek_part::<brick::Shown>().and_then(|shown| shown.0) else {
        return "no panel".into();
    };
    let Ok(Some(image)) = brick.find(world, "fileImage") else {
        return "no image".into();
    };
    let status = match brick.read(world, image, "status") {
        Value::Int(0) => "Null".to_owned(),
        Value::Int(1) => "Ready".to_owned(),
        Value::Int(2) => "Loading".to_owned(),
        Value::Int(3) => "Error".to_owned(),
        other => format!("{other:?}"),
    };
    format!(
        "its image is {status} at {} of {}{}",
        brick.text_of(world, image, "progress"),
        brick.text_of(world, image, "source"),
        if brick.flag(world, image, "visible") {
            ""
        } else {
            ", hidden"
        }
    )
}

/// Whether the panel draws its part named `object_name`.
fn drawn(world: &mut World, object_name: &str) -> Outcome<bool> {
    let brick = brick::shown(world)?;
    Ok(match brick.find(world, object_name)? {
        Some(item) => brick.flag(world, item, "visible"),
        None => false,
    })
}

/// The panel's image, once it has loaded.
fn loaded_image(world: &mut World) -> Outcome<ObjectId> {
    let brick = show_panel(world)?;
    let ready = move |w: &World| -> Option<ObjectId> {
        let image = brick.find(w, "fileImage").ok()??;
        // QQuickImageBase::Ready
        (brick.flag(w, image, "visible") && brick.read(w, image, "status") == Value::Int(1))
            .then_some(image)
    };
    world.wait_for_with(
        |w| ready(w).is_some(),
        |w| format!("the image to load; {}", describe_media(w)),
    )?;
    match ready(world) {
        Some(image) => Ok(image),
        None => fail!("the image went away"),
    }
}

/// Every `assets.createUrl` for a workspace's file.
fn signings(world: &mut World) -> Outcome<Vec<crate::fake_mc::Rpc>> {
    world.sync()?;
    Ok(world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "assets.createUrl"
                && text(&rpc.payload["resource"]["_tag"]).ends_with("-file")
        })
        .cloned()
        .collect())
}

fn source_is_media(world: &World, image: ObjectId) -> bool {
    let source = world.engine().read_by_name(image, "source");
    let url = text_prop(world, "mediaUrl");
    matches!(&source, Value::String(s) | Value::Url(s) if s.as_str() == url)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the file is previewed as (an image|a video|audio|a document|a web page)",
        |world, c, _| {
            if c[0] != "an image" {
                fail!("the desktop does not preview {} yet", c[0]);
            }
            let path = open_path(world);
            let image = loaded_image(world)?;
            let downloaded = fake_files(&mut world.mc)
                .downloads()
                .downloaded
                .contains(&path);
            expect!(
                source_is_media(world, image) && downloaded,
                "{}",
                describe_media(world)
            );
            expect!(
                !drawn(world, "fileLines")? && !drawn(world, "fileEdit")?,
                "the file shows as text too"
            );
            // Never read as text.
            for rpc in &world.mc.calls {
                expect!(
                    rpc.method != "projects.readFile" || rpc.payload["relativePath"] != json!(path),
                    "{path} was read as text"
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("loading {Q} fails once"), |world, c, _| {
        ensure_viewer_file(world, &c[0]);
        fake_files(&mut world.mc)
            .downloads()
            .load_fails_once
            .insert(c[0].clone());
        Ok(())
    });
    steps.step(
        "the user is told the (image|video|audio|document) could not be loaded",
        |world, c, _| {
            show_panel(world)?;
            world.wait_for_with(|w| file_status(w) == "error", describe_media)?;
            let told = text_prop(world, "fileProblem")
                == format!("The {} could not be loaded.", c[0])
                && drawn(world, "fileRetry")?;
            expect!(told, "{}", describe_media(world));
            Ok(())
        },
    );
    // A file a reply linked to, opened in the Files tab (timeline/markdown.feature).
    steps.step(&format!("{Q} opens as a large preview"), |world, c, _| {
        if media_kind_of(&c[0]) != "image" {
            fail!("the desktop does not preview {} yet", c[0]);
        }
        world.wait_for_with(
            |w| {
                w.with::<RightPanel, _>(|p, _| p.active_tab() == "files")
                    .unwrap_or(false)
                    && open_path(w) == c[0]
            },
            |w| {
                format!(
                    "the {} tab; {}",
                    w.with::<RightPanel, _>(|p, _| p.active_tab())
                        .unwrap_or_default(),
                    describe_media(w)
                )
            },
        )?;
        let image = loaded_image(world)?;
        let downloaded = fake_files(&mut world.mc)
            .downloads()
            .downloaded
            .contains(&c[0]);
        expect!(
            source_is_media(world, image) && downloaded,
            "{}",
            describe_media(world)
        );
        Ok(())
    });
    steps.step("the image is shown", |world, _, _| {
        let image = loaded_image(world)?;
        expect!(source_is_media(world, image), "{}", describe_media(world));
        Ok(())
    });

    // A thread of the project on another member of the cluster, open.
    steps.step(
        "the thread is on another machine of the cluster",
        |world, _, _| {
            world.mc.join(stream::PEER, stream::PEER_ENVIRONMENT);
            world.mc.send_peer_row_of(
                stream::PEER_ENVIRONMENT,
                stream::PROJECT,
                &json!({"id": stream::PROJECT, "title": stream::PROJECT,
                    "workspaceRoot": format!("/work/{}", stream::PROJECT), "scripts": []}),
                "project",
            );
            world.mc.send_peer_row(
                stream::PEER_ENVIRONMENT,
                stream::PEER_THREAD,
                &json!({"id": stream::PEER_THREAD, "title": "Remote", "projectId": stream::PROJECT,
                    "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
            );
            world.sync()?;
            let fake = world.mc.part::<FakeStreams>();
            fake.thread = stream::PEER_THREAD.into();
            fake.environment = stream::PEER_ENVIRONMENT.into();
            stream::look(
                world,
                &format!("{}:{}", stream::PEER_ENVIRONMENT, stream::PEER_THREAD),
                true,
            )?;
            world.wait_for("the Files tab to follow the thread", |w| {
                environment(w) == stream::PEER_ENVIRONMENT && !workspace_root(w).is_empty()
            })
        },
    );
    steps.step(
        "the image comes from the machine the thread is on",
        |world, _, _| {
            let calls = signings(world)?;
            let Some(last) = calls.last() else {
                fail!("no address was signed");
            };
            let resource = &last.payload["resource"];
            expect!(
                last.environment == stream::PEER_ENVIRONMENT
                    && resource["threadId"] == json!(stream::PEER_THREAD),
                "the address was signed by \"{}\" for {}",
                last.environment,
                show(resource)
            );
            Ok(())
        },
    );
}
