#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

// How subagents read wherever a client lists them (the timeline, the lineage,
// the Agents tab), shared by the desktop and the phone. Upstream:
// packages/shared/src/model.ts (formatModelSlugName) and
// packages/client-runtime/src/state/subagentDisplay.ts.
namespace subagents {

// A model slug the way a person writes it: "gpt-5.4" reads "GPT-5.4",
// "claude-opus-4-6" "Claude Opus 4.6", "openai/gpt-5.4-mini"
// "openai/GPT-5.4-Mini". A slug of no family it knows is left as it is.
QString formatModelSlugName(const QString& slug);

// A subagent's title without its provider's "Subagent: " prefix; a Codex task
// path ("/root/team/review_docs/") reads as its last part ("Review Docs").
QString displayTitle(const QString& title);

// A group's states counted in the order a reader scans them, what still works
// first and then the outcomes: "2 working · 1 done · 1 failed".
QString summarizeStatuses(const QStringList& statuses);

// Whether a lifecycle status is still working (pending, running, waiting).
bool live(const QString& status);

// One span for a group, from its first launch to its last finish: invalid
// `end` while a member works or a finished one has no end time, when the span
// is withheld (or runs to now while it works).
struct Span {
  QDateTime start;
  QDateTime end;
  bool live = false;
};
// `members` are `subagent` entities or turn items (status, startedAt, completedAt).
Span groupSpan(const QList<QJsonObject>& members);

// 12s, 3m 04s, 1h 02m.
QString formatElapsed(qint64 seconds);

}  // namespace subagents
