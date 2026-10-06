#pragma once

class QCommandLineParser;
class ShellBridge;
class ShellRuntime;

// Scripted runs: `--action name[=json]` and `--key <chord>` steps replayed in
// command-line order, 1.5 s apart, and `--screenshot <png>`, which grabs the
// window after them and quits with 0, or 2 when the grab fails. PR evidence
// and smoke runs without a person at the window.
namespace ScriptedRun {

void addOptions(QCommandLineParser& parser);
// Whether the command line asks for any of it.
bool requested(const QCommandLineParser& parser);
bool screenshotRequested(const QCommandLineParser& parser);
// Replays the steps from now on; call once the window shows what they act on.
void play(const QCommandLineParser& parser, ShellRuntime* runtime, ShellBridge* bridge);
// A start that failed: grabs the error the window shows and quits with 2.
void captureFailure(const QCommandLineParser& parser, ShellRuntime* runtime);

}  // namespace ScriptedRun
