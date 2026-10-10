#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

#include <optional>

// What a group of tool calls did, in a sentence: "Ran 2 commands and sent
// messages to 3 threads". At most two kinds of work are
// named, changes before reads; the rest is counted ("performed 2 other
// actions"). Failed calls are not counted as work done.
namespace timeline {

struct GroupSummary {
  QString text;
  // Whether a call the summary names failed.
  bool failed = false;
};

// `items` are the group's turn items, oldest first.
GroupSummary summarize(const QList<QJsonObject>& items);

// Whether a call failed: its status, a command's exit code, or an MCP result
// that carries an error.
bool callFailed(const QJsonObject& item);

// A file the agent read: an ACP `read` call, which the MC projects as a file
// search with the file as its one result.
bool isFileRead(const QJsonObject& item);

// One line of a markdown result: list bullets, code ticks and link targets
// dropped.
QString plainDetail(const QString& markdown);

// Whether a subagent has stopped working: anything but pending, running or
// waiting (an idle one has said its piece and waits to be resumed).
bool subagentSettled(const QString& status);

// What a subagent's row says it did: a settled one its result, else its last
// progress; a live one the reverse. The server's "Child task ended with
// status ..." placeholder is dropped, the status already says it. Empty when
// there is nothing to say.
QString subagentDetail(bool settled, const QString& progress, const QString& result);

// A command as its row labels it (client-runtime commandDisplayText): the
// script of a lone `sh -c '<script>'` wrapper, its first line, whitespace
// collapsed.
QString commandDisplayText(const QString& command);

// What the MC sent the agent for itself: that a delegated task ended, or that
// the provider woke up for its background work. The MC records it as a
// `notification` item (`summary`, `outcome`). Threads written before it did hold
// the message as the user's instead, a delegated task's result as the envelope
// the agent reads, and are read here as what they stand for. `item` is a turn
// item, or a queued run's message (which has no `type`).
struct Notice {
  QString summary;
  QString outcome;
};
std::optional<Notice> noticeOf(const QJsonObject& item);

}  // namespace timeline
