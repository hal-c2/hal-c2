#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

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

}  // namespace timeline
