//! A file coloured by its language (features/files/file-viewer-and-editing.feature,
//! desktop-qt's FileColourSteps.cpp): what the viewer's lines draw, read
//! off the line items themselves.

use fancy_regex::Regex;
use hal_c2_shell::controllers::theme::{Mode, Themes};
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::{ObjectId, Value};

use super::fake_files::fake_files;
use super::files_workspace::{file_status, files, open_path, show_panel};
use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps};
use crate::world::World;
use crate::{expect, fail};

struct Sample {
    code: &'static str,
    /// A word the language colours, at the start of the first line.
    keyword: &'static str,
}

fn sample(language: &str) -> Option<Sample> {
    match language {
        "TypeScript" => Some(Sample {
            code: "export const total = (items: number[]) => items.length;\nexport const tax = 0.2;\n",
            keyword: "export",
        }),
        "Elixir" => Some(Sample {
            code: "defmodule Shop.Cart do\n  def total(items), do: length(items)\nend\n",
            keyword: "defmodule",
        }),
        "QML" => Some(Sample {
            code: "import QtQuick\n\nItem {\n    id: cart\n}\n",
            keyword: "import",
        }),
        _ => None,
    }
}

#[derive(Default)]
struct ColourSeen {
    keyword_colour: String,
    file_reads: usize,
    long_line: String,
}

fn seen(world: &mut World) -> &mut ColourSeen {
    world.mc.part::<ColourSeen>()
}

/// The item drawing line `number` of the open file, once there.
fn line_item(world: &mut World, number: usize) -> Outcome<(Brick, ObjectId)> {
    let brick = show_panel(world)?;
    let name = format!("fileLineText-{number}");
    world.wait_for_with(
        |w| matches!(brick.find(w, &name), Ok(Some(_))),
        |_| format!("line {number} to be drawn"),
    )?;
    match brick.find(world, &name)? {
        Some(item) => Ok((brick, item)),
        None => fail!("line {number} went away"),
    }
}

/// What a line's markup reads as.
fn plain(styled: &str) -> String {
    let tag = Regex::new("<[^>]+>").expect("a pattern");
    tag.replace_all(styled, "")
        .replace("&nbsp;", " ")
        .replace("&#9;", "\t")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

fn styled_text(world: &World, brick: Brick, item: ObjectId) -> bool {
    brick.read(world, item, "textFormat") == Value::Int(4) // Text.StyledText
}

/// The colour `keyword` is drawn in on `item`'s line, empty when plain.
fn colour_of(world: &World, brick: Brick, item: ObjectId, keyword: &str) -> String {
    if !styled_text(world, brick, item) {
        return String::new();
    }
    let font = Regex::new(&format!(
        "<font color=\"(#[0-9a-f]+)\">(?:<[biu]>)*{}",
        fancy_regex::escape(keyword)
    ))
    .expect("a pattern");
    let text = brick.text_of(world, item, "text");
    font.captures(&text)
        .ok()
        .flatten()
        .and_then(|c| c.get(1).map(|m| m.as_str().to_owned()))
        .unwrap_or_default()
}

fn file_reads(world: &World) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "projects.readFile")
        .count()
}

fn lines_model(world: &World) -> Option<ObjectId> {
    let engine = world.engine();
    files(world)
        .ok()
        .and_then(|f| WorkspaceFiles::lines(engine, f))
}

fn lines_flag(world: &World, name: &str) -> bool {
    let engine = world.engine();
    lines_model(world)
        .is_some_and(|lines| matches!(engine.read_by_name(lines, name), Value::Bool(true)))
}

fn wait_for_read(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| file_status(w) == "ready" && !lines_flag(w, "reading"),
        |w| format!("the file to be read; it is {}", file_status(w)),
    )
}

fn describe_line(world: &World, brick: Brick, item: ObjectId) -> String {
    format!(
        "the line reads \"{}\" as {}",
        brick
            .text_of(world, item, "text")
            .chars()
            .take(300)
            .collect::<String>(),
        if styled_text(world, brick, item) {
            "styled text"
        } else {
            "plain text"
        }
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("{Q} in {Q} holds (TypeScript|Elixir|QML) code"),
        |world, c, _| {
            let Some(sample) = sample(&c[2]) else {
                fail!("no sample for {}", c[2])
            };
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), sample.code.to_owned());
            Ok(())
        },
    );
    steps.step(&format!("{Q} in {Q} holds plain text"), |world, c, _| {
        fake_files(&mut world.mc).files.insert(
            c[0].clone(),
            "export const total = 1;\nbuy milk & eggs <today>\n".to_owned(),
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} in {Q} holds more than 512K characters of code"),
        |world, c, _| {
            let line = sample("TypeScript").expect("a sample").code;
            let repeats = 512 * 1024 / line.len() + 1;
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), line.repeat(repeats));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} in {Q} has a line of TypeScript (\\d+) characters long"),
        |world, c, _| {
            let length = c[2].parse::<usize>().unwrap_or(0);
            let piece = "const a = 1; ";
            let mut line = format!("export {}", piece.repeat(length / piece.len() + 1));
            line.truncate(length);
            seen(world).long_line.clone_from(&line);
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), format!("{line}\nexport const b = 2;\n"));
            Ok(())
        },
    );

    steps.step(
        &format!("the lines of {Q} are coloured as (TypeScript|Elixir|QML)"),
        |world, c, _| {
            wait_for_read(world)?;
            expect!(
                open_path(world) == c[0] && lines_flag(world, "coloured"),
                "\"{}\" is open, coloured: {}",
                open_path(world),
                lines_flag(world, "coloured")
            );
            let Some(sample) = sample(&c[1]) else {
                fail!("no sample for {}", c[1])
            };
            let lines: Vec<&str> = sample.code.split('\n').collect();
            for number in 1..lines.len() {
                let (brick, item) = line_item(world, number)?;
                let text = brick.text_of(world, item, "text");
                expect!(
                    plain(&text) == lines[number - 1],
                    "{}",
                    describe_line(world, brick, item)
                );
            }
            let (brick, first) = line_item(world, 1)?;
            let colour = colour_of(world, brick, first, sample.keyword);
            expect!(
                !colour.is_empty(),
                "\"{}\" is not coloured: {}",
                sample.keyword,
                describe_line(world, brick, first)
            );
            seen(world).keyword_colour = colour;
            Ok(())
        },
    );
    steps.step(
        &format!("the lines of {Q} are shown plain"),
        |world, c, _| {
            wait_for_read(world)?;
            expect!(
                open_path(world) == c[0] && !lines_flag(world, "coloured"),
                "\"{}\" is open, coloured: {}",
                open_path(world),
                lines_flag(world, "coloured")
            );
            let first = fake_files(&mut world.mc)
                .files
                .get(&c[0])
                .map_or_else(String::new, |text| {
                    text.split('\n').next().unwrap_or_default().to_owned()
                });
            let (brick, item) = line_item(world, 1)?;
            expect!(
                !styled_text(world, brick, item) && brick.text_of(world, item, "text") == first,
                "{}",
                describe_line(world, brick, item)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the long line is shown up to its (\\d+)(?:st|nd|rd|th) character and then {Q}"),
        |world, c, _| {
            wait_for_read(world)?;
            expect!(lines_flag(world, "coloured"), "the file is not coloured");
            let (brick, item) = line_item(world, 1)?;
            let length = c[0].parse::<usize>().unwrap_or(0);
            let wanted: String = seen(world)
                .long_line
                .chars()
                .take(length)
                .collect::<String>()
                + &c[1];
            let text = brick.text_of(world, item, "text");
            expect!(
                styled_text(world, brick, item) && plain(&text) == wanted,
                "{}",
                describe_line(world, brick, item)
            );
            Ok(())
        },
    );
    steps.step("no colour reaches past the cut", |world, _, _| {
        let (brick, item) = line_item(world, 1)?;
        let text = brick.text_of(world, item, "text");
        // The cut's mark comes after every coloured run has closed.
        let mark = text.rfind('…');
        let ends: Vec<char> = text.chars().collect();
        expect!(
            mark.is_some_and(|mark| {
                mark > 0
                    && text.rfind("</font>").is_some_and(|at| at < mark)
                    && text.rfind("<font").is_some_and(|at| at < mark)
                    && text[mark..].chars().count() == 1
            }),
            "the line ends \"{}\"",
            ends.iter()
                .rev()
                .take(120)
                .collect::<String>()
                .chars()
                .rev()
                .collect::<String>()
        );
        Ok(())
    });

    steps.step(
        "the app turns dark while the file is open",
        |world, _, _| {
            seen(world).file_reads = file_reads(world);
            let Some(mode) = Mode::parse("dark") else {
                fail!("dark is not an appearance")
            };
            let set = world.with::<Themes, _>(|t, e| t.set_mode(e, mode))?;
            expect!(set, "the appearance could not be set");
            world.pump()?;
            world.wait_for_with(
                |w| {
                    w.with::<Themes, _>(|t, _| t.appearance() == "dark")
                        .unwrap_or(false)
                },
                |_| "the app to be drawn dark".to_owned(),
            )
        },
    );
    steps.step(
        &format!("the lines of {Q} are coloured for the dark theme"),
        |world, c, _| {
            expect!(open_path(world) == c[0], "\"{}\" is open", open_path(world));
            let keyword = sample("TypeScript").expect("a sample").keyword;
            let before = seen(world).keyword_colour.clone();
            world.wait_for_with(
                |w| {
                    let Ok(brick) = show_panel_now(w) else {
                        return false;
                    };
                    let Ok(Some(item)) = brick.find(w, "fileLineText-1") else {
                        return false;
                    };
                    let colour = colour_of(w, brick, item, keyword);
                    !colour.is_empty() && colour != before
                },
                |w| {
                    let colour = show_panel_now(w)
                        .ok()
                        .and_then(|brick| {
                            brick
                                .find(w, "fileLineText-1")
                                .ok()
                                .flatten()
                                .map(|item| colour_of(w, brick, item, keyword))
                        })
                        .unwrap_or_default();
                    format!("\"{keyword}\" in another colour than {before}; it is {colour}")
                },
            )
        },
    );
    steps.step("the file was not read again", |world, _, _| {
        expect!(
            !lines_flag(world, "reading"),
            "the code is being read again"
        );
        let before = seen(world).file_reads;
        expect!(
            file_reads(world) == before,
            "the MC was asked for the file {} more times",
            file_reads(world) - before
        );
        Ok(())
    });
}

fn show_panel_now(world: &World) -> Outcome<Brick> {
    match world
        .peek_part::<crate::brick::Shown>()
        .and_then(|shown| shown.0)
    {
        Some(brick) => Ok(brick),
        None => fail!("no panel is shown"),
    }
}
