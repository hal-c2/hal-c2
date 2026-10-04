#include "TimelineModel.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QRegularExpression>

#include <algorithm>
#include <cmath>
#include <optional>
#include <utility>

#include "SidebarModel.h"
#include "TimelineSummary.h"

namespace {

// The entity kinds the timeline reads; the stream's others (nodes, provider
// sessions, ...) are left out. Plans and the user's messages are kept for the
// composer (turnChanged), checkpoints for the diff panel (checkpointsChanged)
// and a reply's revert (checkpointOf), subagents for the Agents tab
// (agentsChanged); they draw no rows.
const QSet<QString> kKinds{QStringLiteral("turn-item"),       QStringLiteral("run"),  QStringLiteral("run-attempt"),
                           QStringLiteral("runtime-request"), QStringLiteral("plan"), QStringLiteral("message"),
                           QStringLiteral("checkpoint"),      QStringLiteral("subagent")};
// Turn items the composer's turn state reads (requests).
const QSet<QString> kTurnItems{QStringLiteral("approval_request"), QStringLiteral("user_input_request")};
// Turn item fields that move, regroup or refold rows. Anything else (text,
// output, status) only redraws the row showing the item.
const QSet<QString> kStructural{QStringLiteral("type"),    QStringLiteral("runId"),       QStringLiteral("ordinal"),
                                QStringLiteral("streaming"), QStringLiteral("inputIntent"), QStringLiteral("nodeId")};
const QSet<QString> kSettled{QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("interrupted"),
                             QStringLiteral("cancelled")};
const QSet<QString> kRunning{QStringLiteral("preparing"), QStringLiteral("starting"), QStringLiteral("running"),
                             QStringLiteral("waiting")};

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QDateTime timeOf(const QJsonValue& value) {
  return QDateTime::fromString(value.toString(), Qt::ISODateWithMs);
}

// When a turn item happened: its start, else its last update (the web's
// projectedItemCreatedAt).
QDateTime itemTime(const QJsonObject& item) {
  const QDateTime started = timeOf(item.value(QLatin1String("startedAt")));
  return started.isValid() ? started : timeOf(item.value(QLatin1String("updatedAt")));
}

// The locale's numeric date, as Intl's {month: "numeric", day: "numeric"}
// (and year: "numeric" with `withYear`): "9/20", "9/20/2025".
QString numericDate(const QDate& date, bool withYear, const QLocale& locale) {
  QString format = locale.dateFormat(QLocale::ShortFormat);
  format.replace(QRegularExpression(QStringLiteral("d+")), QStringLiteral("d"));
  format.replace(QRegularExpression(QStringLiteral("M+")), QStringLiteral("M"));
  if (withYear) {
    format.replace(QRegularExpression(QStringLiteral("y+")), QStringLiteral("yyyy"));
  } else {
    // The year and the separator joining it to the day or month.
    static const QRegularExpression year(QStringLiteral("^y+[^dMy]*|[^dMy]*y+$|y+[^dMy]*"));
    format.remove(year);
  }
  return locale.toString(date, format);
}

// apps/web/src/components/chat/MessagesTimeline.tsx workEntryIconName, for
// the turn items the native timeline shows as calls and rows.
QString iconOf(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("command_execution")) return QStringLiteral("terminal");
  if (type == QLatin1String("file_change")) return QStringLiteral("square-pen");
  if (timeline::isFileRead(item)) return QStringLiteral("eye");
  if (type == QLatin1String("file_search")) return QStringLiteral("search");
  if (type == QLatin1String("web_search")) return QStringLiteral("globe");
  if (type == QLatin1String("dynamic_tool")) return QStringLiteral("wrench");
  if (type == QLatin1String("reasoning")) return QStringLiteral("brain");
  if (type == QLatin1String("approval_request") || type == QLatin1String("user_input_request")) {
    return QStringLiteral("message-circle");
  }
  if (type == QLatin1String("subagent")) return QStringLiteral("bot");
  if (type == QLatin1String("error")) return QStringLiteral("circle-alert");
  if (type == QLatin1String("notification")) {
    return text(item, QLatin1String("outcome")) == QLatin1String("failed") ? QStringLiteral("circle-alert")
                                                                            : QStringLiteral("zap");
  }
  // V2LifecycleRow's dividers and interrupt request.
  if (type == QLatin1String("compaction")) return QStringLiteral("minus");
  if (type == QLatin1String("fork")) return QStringLiteral("git-fork");
  if (type == QLatin1String("handoff")) return QStringLiteral("arrow-right-left");
  if (type == QLatin1String("thread_created")) return QStringLiteral("message-square");
  if (type == QLatin1String("run_interrupt_request")) return QStringLiteral("square");
  if (type == QLatin1String("run_interrupt_result")) return QStringLiteral("x");
  // The info tone (todo lists, notices).
  return QStringLiteral("check");
}

QString ordinalSuffix(int day) {
  const int lastTwo = day % 100;
  if (lastTwo >= 11 && lastTwo <= 13) return QStringLiteral("th");
  switch (day % 10) {
    case 1:
      return QStringLiteral("st");
    case 2:
      return QStringLiteral("nd");
    case 3:
      return QStringLiteral("rd");
    default:
      return QStringLiteral("th");
  }
}

// HalC2.Patch: `s` sets, `u` unsets, `a` appends to strings, `d` deletes
// (alone) or replaces (with `s`/`a`). nullopt when the entity is gone.
std::optional<QJsonObject> patched(const QJsonObject& entity, const QJsonObject& patch) {
  const bool replace = patch.value(QLatin1String("d")).toBool();
  if (replace && !patch.contains(QLatin1String("s")) && !patch.contains(QLatin1String("a"))) return std::nullopt;
  QJsonObject next = replace ? QJsonObject() : entity;
  const QJsonObject set = patch.value(QLatin1String("s")).toObject();
  for (auto it = set.begin(); it != set.end(); ++it) next.insert(it.key(), it.value());
  for (const QJsonValue& field : patch.value(QLatin1String("u")).toArray()) next.remove(field.toString());
  const QJsonObject append = patch.value(QLatin1String("a")).toObject();
  for (auto it = append.begin(); it != append.end(); ++it) {
    next.insert(it.key(), next.value(it.key()).toString() + it.value().toString());
  }
  return next;
}

// apps/tui/src/timeline.ts formatDuration.
QString formatDuration(qint64 ms) {
  if (ms < 0) return QStringLiteral("0ms");
  if (ms < 1000) return QStringLiteral("%1ms").arg(std::max<qint64>(1, ms));
  if (ms < 10000) {
    const double tenths = std::round(ms / 100.0) / 10.0;
    return tenths >= 10 ? QStringLiteral("10s") : QStringLiteral("%1s").arg(tenths, 0, 'f', 1);
  }
  if (ms < 60000) return QStringLiteral("%1s").arg(std::llround(ms / 1000.0));
  const qint64 minutes = ms / 60000;
  const qint64 seconds = std::llround((ms % 60000) / 1000.0);
  if (seconds == 0) return QStringLiteral("%1m").arg(minutes);
  if (seconds == 60) return QStringLiteral("%1m").arg(minutes + 1);
  return QStringLiteral("%1m %2s").arg(minutes).arg(seconds);
}

enum class Kind { Message, Work, Plan, Subagent, Error, Marker, Checkpoint };

Kind classify(const QString& type) {
  if (type == QLatin1String("user_message") || type == QLatin1String("assistant_message")) return Kind::Message;
  if (type == QLatin1String("proposed_plan")) return Kind::Plan;
  if (type == QLatin1String("subagent")) return Kind::Subagent;
  if (type == QLatin1String("error")) return Kind::Error;
  if (type == QLatin1String("checkpoint")) return Kind::Checkpoint;
  if (type == QLatin1String("fork") || type == QLatin1String("handoff") || type == QLatin1String("compaction") ||
      type == QLatin1String("thread_created") || type == QLatin1String("notification")) {
    return Kind::Marker;
  }
  return Kind::Work;
}

QString kindName(Kind kind) {
  switch (kind) {
    case Kind::Message:
      return QStringLiteral("message");
    case Kind::Work:
      return QStringLiteral("work");
    case Kind::Plan:
      return QStringLiteral("plan");
    case Kind::Subagent:
      return QStringLiteral("subagent");
    case Kind::Error:
      return QStringLiteral("error");
    case Kind::Marker:
    case Kind::Checkpoint:
      break;
  }
  return QStringLiteral("marker");
}

// apps/tui/src/worklog.ts: how a tool call ended; empty once it completed.
QString callStatusLabel(const QString& status) {
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  if (status == QLatin1String("completed")) return {};
  return QStringLiteral("Running");
}

// apps/web/src/components/chat/V2LifecycleRow.tsx STATUS_VISUALS.
QString subagentStatusLabel(const QString& status) {
  if (status == QLatin1String("idle")) return QStringLiteral("Idle · resumable");
  if (status == QLatin1String("completed")) return QStringLiteral("Completed");
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  return QStringLiteral("Working");
}

QString intentMarker(const QString& intent) {
  if (intent == QLatin1String("queued_turn")) return QStringLiteral("Queued behind the active turn");
  if (intent == QLatin1String("steer")) return QStringLiteral("Steered the active turn");
  if (intent == QLatin1String("promoted_queued_to_steer")) {
    return QStringLiteral("Originally queued, then promoted to steer the active turn");
  }
  return {};
}

// apps/tui/src/proposedPlan.ts: the first heading, else "Proposed plan".
QString planTitle(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"),
                                          QRegularExpression::MultilineOption);
  const QString title = heading.match(markdown).captured(1).trimmed();
  return title.isEmpty() ? QStringLiteral("Proposed plan") : title;
}

// apps/web/src/proposedPlan.ts stripDisplayedPlanMarkdown: the plan's
// markdown without the heading it opens with (the card's title) or a
// "Summary" heading after it.
QString planBody(const QString& markdown) {
  static const QRegularExpression heading(QStringLiteral("^\\s{0,3}#{1,6}\\s+(.+)$"));
  QString trimmed = markdown;
  while (!trimmed.isEmpty() && trimmed.back().isSpace()) trimmed.chop(1);
  QStringList lines = trimmed.split(QRegularExpression(QStringLiteral("\\r?\\n")));
  const auto dropBlank = [&lines] {
    while (!lines.isEmpty() && lines.constFirst().trimmed().isEmpty()) lines.removeFirst();
  };
  if (!lines.isEmpty() && heading.match(lines.constFirst()).hasMatch()) lines.removeFirst();
  dropBlank();
  if (!lines.isEmpty() &&
      heading.match(lines.constFirst()).captured(1).trimmed().compare(QLatin1String("summary"), Qt::CaseInsensitive) == 0) {
    lines.removeFirst();
    dropBlank();
  }
  return lines.join(QLatin1Char('\n'));
}

QString markerTitle(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("fork")) return QStringLiteral("Conversation fork");
  if (type == QLatin1String("handoff")) return QStringLiteral("Context handoff");
  if (type == QLatin1String("compaction")) return QStringLiteral("Context compacted");
  if (type == QLatin1String("thread_created")) return QStringLiteral("Created thread");
  const QString title = text(item, QLatin1String("title")).trimmed();
  return title.isEmpty() ? QStringLiteral("Notification") : title;
}

QString markerDetail(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("fork")) return QStringLiteral("Continues in %1").arg(text(item, QLatin1String("targetThreadId")));
  if (type == QLatin1String("thread_created")) return text(item, QLatin1String("title"));
  return text(item, QLatin1String("summary"));
}

}  // namespace

TimelineModel::TimelineModel(const QString& threadKey, QObject* parent)
    : QAbstractListModel(parent), m_threadKey(threadKey) {}

void TimelineModel::setStatus(const QString& status, const QString& problem) {
  if (status == m_status && problem == m_problem) return;
  m_status = status;
  m_problem = problem;
  emit statusChanged();
}

QString TimelineModel::workingLabel() const {
  if (!working()) return {};
  const qint64 seconds = std::max<qint64>(0, m_workingSince.secsTo(m_now()));
  return seconds < 1 ? QStringLiteral("Working") : QStringLiteral("Working for %1").arg(formatDuration(seconds * 1000));
}

void TimelineModel::setTimestampFormat(const QString& format) {
  const QString next = format.isEmpty() ? QStringLiteral("locale") : format;
  if (next == m_timestampFormat) return;
  m_timestampFormat = next;
  redrawTimes();
}

void TimelineModel::setLocale(const QLocale& locale) {
  if (locale == m_locale) return;
  m_locale = locale;
  redrawTimes();
}

void TimelineModel::redrawTimes() {
  if (m_rows.isEmpty()) return;
  emit dataChanged(index(0), index(int(m_rows.size()) - 1), {TimeRole, EntriesRole});
}

QDateTime TimelineModel::rowTime(const Row& row) const {
  if (row.kind == QLatin1String("fold")) return row.at;
  if (row.kind == QLatin1String("work") || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  // A reply is stamped when it finished (the web's updatedAt), so not while it streams.
  if (text(item, QLatin1String("type")) == QLatin1String("assistant_message")) {
    if (item.value(QLatin1String("streaming")).toBool()) return {};
    return timeOf(item.value(QLatin1String("updatedAt")));
  }
  return itemTime(item);
}

// apps/web/src/timestampFormat.ts formatDayAwareTimestamp: local calendar days.
QString TimelineModel::stamp(const QDateTime& at) const {
  if (!at.isValid()) return {};
  const QDateTime local = at.toLocalTime();
  const QDate today = m_now().toLocalTime().date();
  const QString time = sidebar::timeOfDay(local, m_timestampFormat, m_locale);
  const qint64 days = local.date().daysTo(today);
  if (days <= 0) return time;
  if (days == 1) return QStringLiteral("yesterday at ") + time;
  return numericDate(local.date(), local.date().year() != today.year(), m_locale) + QLatin1Char(' ') + time;
}

// apps/web/src/timestampFormat.ts formatChatTimestampTooltip, English as the web's is.
QString TimelineModel::timeTitle(const QString& rowId, const QString& entryId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  QDateTime when;
  if (entryId.isEmpty()) {
    when = rowTime(row);
  } else if (row.items.contains(entryId)) {
    when = itemTime(entity(QStringLiteral("turn-item"), entryId));
  }
  if (!when.isValid()) return {};
  const QDateTime local = when.toLocalTime();
  const int day = local.date().day();
  return QStringLiteral("%1, %2%3 %4 %5")
      .arg(sidebar::timeOfDay(local, m_timestampFormat, m_locale))
      .arg(day)
      .arg(ordinalSuffix(day), QLocale(QLocale::English).monthName(local.date().month()))
      .arg(local.date().year());
}

// --- The fold ------------------------------------------------------------------------

void TimelineModel::snapshot(int part, const QJsonArray& rows, bool done) {
  if (part == 0) m_incoming.clear();
  for (const QJsonValue& value : rows) {
    const QJsonArray row = value.toArray();
    const QString kind = row.at(0).toString();
    if (!kKinds.contains(kind)) continue;
    const QJsonObject entity = row.at(2).toObject();
    if (kind == QLatin1String("message") && text(entity, QLatin1String("role")) != QLatin1String("user")) continue;
    m_incoming[kind].insert(row.at(1).toString(), entity);
  }
  if (!done) return;
  // Everything may have changed: the rows keep their ids and are redrawn.
  m_entities = std::exchange(m_incoming, {});
  sortItems();
  restructure({}, true);
  emit turnChanged();
  emit checkpointsChanged();
  emit agentsChanged();
}

void TimelineModel::events(const QJsonArray& events) {
  QSet<QString> changed;
  bool structural = false;
  m_turnTouched = false;
  m_checkpointsTouched = false;
  m_agentsTouched = false;
  for (const QJsonValue& value : events) {
    const QJsonArray event = value.toArray();
    structural |= apply(event.at(1).toString(), event.at(2).toString(), event.at(3).toObject(), changed);
  }
  if (m_turnTouched) emit turnChanged();
  if (m_checkpointsTouched) emit checkpointsChanged();
  if (m_agentsTouched) {
    emit agentsChanged();
    // A subagent's row shows its entity's model.
    for (int row = 0; row < m_rows.size(); ++row) {
      if (m_rows.at(row).kind == QLatin1String("subagent")) emit dataChanged(index(row), index(row), {ModelRole});
    }
  }
  if (structural) {
    restructure(changed, false);
    return;
  }
  QSet<int> redraw;
  for (const QString& id : std::as_const(changed)) {
    const int row = m_rowOfItem.value(id, -1);
    if (row >= 0) redraw.insert(row);
  }
  for (const int row : std::as_const(redraw)) emit dataChanged(index(row), index(row));
}

bool TimelineModel::apply(const QString& kind, const QString& id, const QJsonObject& patch, QSet<QString>& changed) {
  if (!kKinds.contains(kind)) return false;
  QHash<QString, QJsonObject>& byKind = m_entities[kind];
  const auto current = byKind.constFind(id);
  const bool existed = current != byKind.cend();
  const std::optional<QJsonObject> next = patched(existed ? *current : QJsonObject(), patch);
  if (kind == QLatin1String("checkpoint") || kind == QLatin1String("subagent")) {
    (kind == QLatin1String("subagent") ? m_agentsTouched : m_checkpointsTouched) = true;
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    return false;
  }
  if (kind == QLatin1String("plan") || kind == QLatin1String("message")) {
    // The agent's streamed replies are the turn items'; only the user's
    // messages (a queued run's text) are kept.
    if (kind == QLatin1String("message") && text(next ? *next : QJsonObject(), QLatin1String("role")) != QLatin1String("user")) {
      byKind.remove(id);
      return false;
    }
    m_turnTouched = true;
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    return false;
  }
  if (kind != QLatin1String("turn-item")) {
    m_turnTouched = true;
    // A run rolled back drops its commands from the Agents tab.
    if (kind == QLatin1String("run")) m_agentsTouched = true;
    // Runs, attempts and requests change fold labels, visibility and the
    // working state; they change far less often than items.
    if (next) {
      byKind.insert(id, *next);
    } else {
      byKind.remove(id);
    }
    return true;
  }
  changed.insert(id);
  const QString type = text(next ? *next : existed ? *current : QJsonObject(), QLatin1String("type"));
  if (kTurnItems.contains(type)) m_turnTouched = true;
  const bool replaced = patch.value(QLatin1String("d")).toBool();
  // A command starting, settling or going away; not its streamed output.
  if (type == QLatin1String("command_execution") &&
      (!existed || !next || replaced || patch.contains(QLatin1String("s")) || patch.contains(QLatin1String("u")))) {
    m_agentsTouched = true;
  }
  bool structural = !existed || !next || replaced;
  QStringList fields = patch.value(QLatin1String("s")).toObject().keys();
  for (const QJsonValue& field : patch.value(QLatin1String("u")).toArray()) fields.append(field.toString());
  for (const QString& field : std::as_const(fields)) structural = structural || kStructural.contains(field);
  const bool moves = !existed || !next || replaced || fields.contains(QStringLiteral("ordinal"));
  if (existed && moves) unplace(id);
  if (next) {
    byKind.insert(id, *next);
    if (moves) place(id);
  } else {
    byKind.remove(id);
  }
  return structural;
}

void TimelineModel::place(const QString& itemId) {
  const QHash<QString, QJsonObject>& items = m_entities[QStringLiteral("turn-item")];
  const double ordinal = items.value(itemId).value(QLatin1String("ordinal")).toDouble();
  const auto at = std::lower_bound(m_order.begin(), m_order.end(), itemId, [&](const QString& other, const QString&) {
    const double otherOrdinal = items.value(other).value(QLatin1String("ordinal")).toDouble();
    return otherOrdinal != ordinal ? otherOrdinal < ordinal : other < itemId;
  });
  m_order.insert(at, itemId);
}

void TimelineModel::unplace(const QString& itemId) {
  m_order.removeOne(itemId);
}

// Turn items are shown in ordinal order, as the MC sends them.
void TimelineModel::sortItems() {
  const QHash<QString, QJsonObject> items = m_entities.value(QStringLiteral("turn-item"));
  m_order = items.keys();
  std::sort(m_order.begin(), m_order.end(), [&](const QString& a, const QString& b) {
    const double left = items.value(a).value(QLatin1String("ordinal")).toDouble();
    const double right = items.value(b).value(QLatin1String("ordinal")).toDouble();
    return left != right ? left < right : a < b;
  });
}

// --- The projection ---------------------------------------------------------------

void TimelineModel::restructure(const QSet<QString>& changed, bool all) {
  applyRows(project(), changed, all);
  m_rowOfItem.clear();
  for (int row = 0; row < m_rows.size(); ++row) {
    for (const QString& item : std::as_const(m_rows.at(row).items)) m_rowOfItem.insert(item, row);
    if (!m_rows.at(row).checkpoint.isEmpty()) m_rowOfItem.insert(m_rows.at(row).checkpoint, row);
  }
  updateWorking();
}

QList<TimelineModel::Row> TimelineModel::project() const {
  const QHash<QString, QJsonObject> items = m_entities.value(QStringLiteral("turn-item"));
  const QHash<QString, QJsonObject> runs = m_entities.value(QStringLiteral("run"));

  // packages/shared orchestrationV2Timeline: items of a rolled-back run, queued
  // messages of a cancelled run, and the interrupt result a plain steer leaves
  // behind are hidden.
  QSet<QString> superseded;
  for (const QJsonObject& attempt : m_entities.value(QStringLiteral("run-attempt"))) {
    if (text(attempt, QLatin1String("status")) != QLatin1String("superseded")) continue;
    superseded.insert(text(attempt, QLatin1String("runId")) + QLatin1Char('\n') + text(attempt, QLatin1String("rootNodeId")));
  }
  QSet<QString> interruptRequested;
  for (const QJsonObject& item : items) {
    if (text(item, QLatin1String("type")) == QLatin1String("run_interrupt_request")) {
      interruptRequested.insert(text(item, QLatin1String("runId")));
    }
  }
  const auto visible = [&](const QJsonObject& item) {
    const QString runId = text(item, QLatin1String("runId"));
    const QString type = text(item, QLatin1String("type"));
    const QString status = text(runs.value(runId), QLatin1String("status"));
    if (status == QLatin1String("rolled_back")) return false;
    if (status == QLatin1String("cancelled") && type == QLatin1String("user_message") &&
        text(item, QLatin1String("inputIntent")) == QLatin1String("queued_turn")) {
      return false;
    }
    return !(type == QLatin1String("run_interrupt_result") && !runId.isEmpty() &&
             superseded.contains(runId + QLatin1Char('\n') + text(item, QLatin1String("nodeId"))) &&
             !interruptRequested.contains(runId));
  };

  QString latestRun;
  double latestOrdinal = -1;
  for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
    const double ordinal = it->value(QLatin1String("ordinal")).toDouble();
    if (ordinal > latestOrdinal) {
      latestOrdinal = ordinal;
      latestRun = it.key();
    }
  }

  // Each run's items after the user message that started it.
  struct Turn {
    QStringList items;
    QString terminal;    // its last assistant message
    QString checkpoint;  // its latest checkpoint with files
    bool streaming = false;
    QDateTime boundary;
  };
  QList<QJsonObject> shown;
  QHash<QString, Turn> turns;
  QList<QString> turnOrder;
  QDateTime boundary;
  for (const QString& id : m_order) {
    const QJsonObject item = items.value(id);
    if (!visible(item)) continue;
    shown.append(item);
    const QString type = text(item, QLatin1String("type"));
    if (type == QLatin1String("user_message")) {
      boundary = timeOf(item.value(QLatin1String("startedAt")));
      if (!boundary.isValid()) boundary = timeOf(item.value(QLatin1String("updatedAt")));
      continue;
    }
    const QString runId = text(item, QLatin1String("runId"));
    if (runId.isEmpty()) continue;
    if (!turns.contains(runId)) {
      turns[runId].boundary = std::exchange(boundary, QDateTime());
      turnOrder.append(runId);
    }
    Turn& turn = turns[runId];
    turn.items.append(id);
    if (type == QLatin1String("assistant_message")) {
      turn.terminal = id;
      turn.streaming = turn.streaming || item.value(QLatin1String("streaming")).toBool();
    } else if (type == QLatin1String("checkpoint") && !item.value(QLatin1String("files")).toArray().isEmpty()) {
      turn.checkpoint = id;
    }
  }

  // A settled turn folds its work (tool calls, commentary) behind how long it
  // took, leaving its last reply in view.
  struct Fold {
    QString runId;
    QString label;
    int hidden = 0;
    bool open = false;
    QDateTime at;
  };
  QHash<QString, Fold> foldAt;  // by the turn's first item
  QHash<QString, QString> folded;  // hidden item -> run
  for (const QString& runId : std::as_const(turnOrder)) {
    const Turn& turn = turns[runId];
    const QJsonObject run = runs.value(runId);
    const QString status = text(run, QLatin1String("status"));
    if (!kSettled.contains(status) || turn.streaming) continue;
    QStringList hidden;
    for (const QString& id : turn.items) {
      if (id == turn.terminal) continue;
      const Kind kind = classify(text(items.value(id), QLatin1String("type")));
      // Work a turn left running (a background command) stays in view.
      if (kind == Kind::Work && text(items.value(id), QLatin1String("status")) == QLatin1String("running")) continue;
      if (kind == Kind::Work || kind == Kind::Message) hidden.append(id);
    }
    if (hidden.isEmpty()) continue;
    const bool interrupted = runId == latestRun && status == QLatin1String("interrupted");
    const QDateTime started = timeOf(run.value(QLatin1String("startedAt")));
    const QDateTime completed = timeOf(run.value(QLatin1String("completedAt")));
    std::optional<qint64> elapsed;
    if (started.isValid() && completed.isValid()) {
      elapsed = started.msecsTo(completed);
    } else if (!interrupted) {
      // No run times: from the user's message to the last item's update.
      const QJsonObject first = items.value(turn.items.first());
      QDateTime from = turn.boundary.isValid() ? turn.boundary : timeOf(first.value(QLatin1String("startedAt")));
      QDateTime to;
      for (const QString& id : turn.items) to = std::max(to, timeOf(items.value(id).value(QLatin1String("updatedAt"))));
      if (from.isValid() && to.isValid()) elapsed = std::max<qint64>(0, from.msecsTo(to));
    }
    // A run stopped before it started has no duration.
    QString label;
    if (interrupted) {
      label = elapsed ? QStringLiteral("You stopped after %1").arg(formatDuration(*elapsed))
                      : QStringLiteral("You stopped this response");
    } else {
      label = elapsed ? QStringLiteral("Worked for %1").arg(formatDuration(*elapsed)) : QStringLiteral("Worked");
    }
    const bool open = m_expandedFolds.contains(runId) != m_keptOpen.contains(runId);
    // The web's turn fold reads the user's message's time, else its first item's.
    const QDateTime at = turn.boundary.isValid() ? turn.boundary : itemTime(items.value(turn.items.first()));
    foldAt.insert(turn.items.first(), {runId, label, int(hidden.size()), open, at});
    if (!open) {
      for (const QString& id : std::as_const(hidden)) folded.insert(id, runId);
    }
  }

  QList<Row> rows;
  for (qsizetype i = 0; i < shown.size();) {
    const QJsonObject& item = shown.at(i);
    const QString id = text(item, QLatin1String("id"));
    if (const auto fold = foldAt.constFind(id); fold != foldAt.cend()) {
      rows.append({QStringLiteral("fold:") + fold->runId, QStringLiteral("fold"), {}, {}, fold->label, fold->hidden,
                   fold->open, fold->at});
    }
    const Kind kind = classify(text(item, QLatin1String("type")));
    if (folded.contains(id) || kind == Kind::Checkpoint) {
      ++i;
      continue;
    }
    const QString runId = text(item, QLatin1String("runId"));
    if (kind == Kind::Work) {
      // Consecutive calls of one turn make a group.
      Row row{QStringLiteral("work:") + id, QStringLiteral("work")};
      qsizetype next = i;
      for (; next < shown.size(); ++next) {
        const QJsonObject& call = shown.at(next);
        const QString callId = text(call, QLatin1String("id"));
        if (next > i && foldAt.contains(callId)) break;
        const Kind callKind = classify(text(call, QLatin1String("type")));
        if (callKind == Kind::Checkpoint) continue;
        if (callKind != Kind::Work || folded.contains(callId) || text(call, QLatin1String("runId")) != runId) break;
        row.items.append(callId);
      }
      row.summarized = row.items.size() > 1 && kSettled.contains(text(runs.value(runId), QLatin1String("status")));
      row.startsOpen = m_keptOpen.contains(runId);
      rows.append(row);
      i = next;
      continue;
    }
    Row row{id, kindName(kind), {id}};
    if (kind == Kind::Message && !runId.isEmpty() && turns.value(runId).terminal == id) {
      const Turn& turn = turns[runId];
      row.checkpoint = turn.checkpoint;
      row.meta = !turn.streaming && kSettled.contains(text(runs.value(runId), QLatin1String("status")));
    }
    rows.append(row);
    ++i;
  }
  return rows;
}

// Brings the rows in line with `rows` by id: removes, inserts and moves them,
// and redraws the ones whose shape or items changed.
void TimelineModel::applyRows(const QList<Row>& rows, const QSet<QString>& changed, bool all) {
  const qsizetype before = m_rows.size();
  QSet<QString> wanted;
  for (const Row& row : rows) wanted.insert(row.id);
  for (qsizetype last = m_rows.size() - 1; last >= 0; --last) {
    if (wanted.contains(m_rows.at(last).id)) continue;
    qsizetype first = last;
    while (first > 0 && !wanted.contains(m_rows.at(first - 1).id)) --first;
    beginRemoveRows(QModelIndex(), int(first), int(last));
    m_rows.remove(first, last - first + 1);
    endRemoveRows();
    last = first;
  }
  QSet<QString> present;
  for (const Row& row : std::as_const(m_rows)) present.insert(row.id);
  const auto dirty = [&](const Row& row) {
    if (all) return true;
    for (const QString& item : row.items) {
      if (changed.contains(item)) return true;
    }
    return !row.checkpoint.isEmpty() && changed.contains(row.checkpoint);
  };
  for (qsizetype i = 0; i < rows.size();) {
    const Row& want = rows.at(i);
    if (!present.contains(want.id)) {
      qsizetype last = i;
      while (last + 1 < rows.size() && !present.contains(rows.at(last + 1).id)) ++last;
      beginInsertRows(QModelIndex(), int(i), int(last));
      for (qsizetype k = i; k <= last; ++k) m_rows.insert(k, rows.at(k));
      endInsertRows();
      i = last + 1;
      continue;
    }
    if (m_rows.at(i).id != want.id) {
      qsizetype from = i + 1;
      while (m_rows.at(from).id != want.id) ++from;
      beginMoveRows(QModelIndex(), int(from), int(from), QModelIndex(), int(i));
      m_rows.move(from, i);
      endMoveRows();
    }
    if (m_rows.at(i) != want || dirty(want)) {
      m_rows[i] = want;
      emit dataChanged(index(int(i)), index(int(i)));
    }
    ++i;
  }
  if (m_rows.size() != before) emit countChanged();
}

// The thread works while a run is under way, since the earliest one started.
void TimelineModel::updateWorking() {
  QDateTime since;
  for (const QJsonObject& run : m_entities.value(QStringLiteral("run"))) {
    if (!kRunning.contains(text(run, QLatin1String("status")))) continue;
    QDateTime started = timeOf(run.value(QLatin1String("startedAt")));
    if (!started.isValid()) started = timeOf(run.value(QLatin1String("requestedAt")));
    if (!started.isValid()) started = m_now();
    if (!since.isValid() || started < since) since = started;
  }
  if (since == m_workingSince) return;
  m_workingSince = since;
  emit workingChanged();
}

void TimelineModel::keepOpen(const QString& runId) {
  if (runId.isEmpty() || m_keptOpen.contains(runId)) return;
  m_keptOpen.insert(runId);
  restructure({}, false);
}

void TimelineModel::toggle(const QString& rowId) {
  if (rowId.startsWith(QLatin1String("fold:"))) {
    const QString runId = rowId.mid(5);
    if (!m_expandedFolds.remove(runId)) m_expandedFolds.insert(runId);
    restructure({}, false);
    return;
  }
  const int row = indexOf(rowId);
  if (row < 0 || m_rows.at(row).kind != QLatin1String("work")) return;
  if (!m_expandedGroups.remove(rowId)) m_expandedGroups.insert(rowId);
  emit dataChanged(index(row), index(row), {EntriesRole, HiddenCountRole, ExpandedRole});
}

int TimelineModel::indexOf(const QString& rowId) const {
  for (int row = 0; row < m_rows.size(); ++row) {
    if (m_rows.at(row).id == rowId) return row;
  }
  return -1;
}

bool TimelineModel::copy(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0 || m_rows.at(at).kind != QLatin1String("message")) return false;
  QGuiApplication::clipboard()->setText(data(index(at), TextRole).toString());
  return true;
}

QVariantMap TimelineModel::checkpointOf(const QString& rowId) const {
  const int at = indexOf(rowId);
  if (at < 0) return {};
  const Row& row = m_rows.at(at);
  if (row.kind != QLatin1String("message") || row.items.isEmpty()) return {};
  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.constFirst());
  if (text(item, QLatin1String("type")) != QLatin1String("assistant_message")) return {};
  const QString runId = text(item, QLatin1String("runId"));
  const QJsonObject run = entity(QStringLiteral("run"), runId);
  if (!kSettled.contains(text(run, QLatin1String("status")))) return {};
  const auto checkpoints = m_entities.value(QStringLiteral("checkpoint"));
  for (auto it = checkpoints.cbegin(); it != checkpoints.cend(); ++it) {
    if (text(*it, QLatin1String("runId")) != runId || text(*it, QLatin1String("status")) != QLatin1String("ready")) continue;
    // The MC's turn number (the diff panel's), else the turn's number among
    // the runs still shown.
    int turn = it->value(QLatin1String("appRunOrdinal")).toInt();
    if (turn <= 0) {
      const int ordinal = run.value(QLatin1String("ordinal")).toInt();
      for (const QJsonObject& other : m_entities.value(QStringLiteral("run"))) {
        if (other.value(QLatin1String("ordinal")).toInt() <= ordinal && text(other, QLatin1String("status")) != QLatin1String("rolled_back")) ++turn;
      }
    }
    return {{QStringLiteral("checkpointId"), it.key()},
            {QStringLiteral("scopeId"), text(*it, QLatin1String("scopeId"))},
            {QStringLiteral("turn"), turn}};
  }
  return {};
}

// --- Rows --------------------------------------------------------------------------

int TimelineModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QHash<int, QByteArray> TimelineModel::roleNames() const {
  return {
      {IdRole, "rowId"},         {KindRole, "kind"},         {AuthorRole, "author"},
      {TextRole, "text"},        {StreamingRole, "streaming"}, {TitleRole, "title"},
      {StatusRole, "status"},    {StatusLabelRole, "statusLabel"}, {MarkerRole, "marker"},
      {EntriesRole, "entries"},  {HiddenCountRole, "hiddenCount"}, {ExpandedRole, "expanded"},
      {FilesRole, "files"},      {TimeRole, "time"},         {IconRole, "icon"},
      {IntentRole, "intent"},    {AttributionRole, "attribution"}, {MetaRole, "meta"},
      {SummaryRole, "summary"},  {SummaryFailedRole, "summaryFailed"}, {ThreadRole, "thread"},
      {ModelRole, "agentModel"},
  };
}

// One tool call of a work group (apps/tui/src/orchestrationV2Adapter.ts itemSummary).
QVariantMap TimelineModel::entry(const QJsonObject& item) const {
  const QString type = text(item, QLatin1String("type"));
  const QString status = text(item, QLatin1String("status"));
  const QString title = text(item, QLatin1String("title")).trimmed();
  QVariantMap entry{
      {QStringLiteral("id"), text(item, QLatin1String("id"))},
      {QStringLiteral("type"), type},
      {QStringLiteral("status"), status},
      {QStringLiteral("statusLabel"), callStatusLabel(status)},
      {QStringLiteral("icon"), iconOf(item)},
      {QStringLiteral("time"), stamp(itemTime(item))},
  };
  QString label;
  QString detail;
  if (type == QLatin1String("reasoning")) {
    const bool thinking = item.value(QLatin1String("streaming")).toBool() || status == QLatin1String("running");
    label = thinking ? QStringLiteral("Thinking") : QStringLiteral("Thought");
    detail = text(item, QLatin1String("text"));
  } else if (type == QLatin1String("command_execution")) {
    label = QStringLiteral("Ran command");
    detail = text(item, QLatin1String("output"));
    entry.insert(QStringLiteral("command"), text(item, QLatin1String("input")));
    const QJsonValue exitCode = item.value(QLatin1String("exitCode"));
    if (exitCode.isDouble()) entry.insert(QStringLiteral("exitCode"), exitCode.toInt());
  } else if (type == QLatin1String("file_change")) {
    label = QStringLiteral("Changed %1").arg(text(item, QLatin1String("fileName")));
    entry.insert(QStringLiteral("path"), text(item, QLatin1String("fileName")));
    detail = QStringLiteral("+%1 -%2").arg(item.value(QLatin1String("additions")).toInt()).arg(item.value(QLatin1String("deletions")).toInt());
  } else if (type == QLatin1String("file_search")) {
    // What it looked for; a read's file (an ACP agent's `read`).
    label = timeline::isFileRead(item) ? QStringLiteral("Read file") : QStringLiteral("Searched files");
    detail = text(item, QLatin1String("pattern"));
  } else if (type == QLatin1String("web_search")) {
    label = QStringLiteral("Searched the web");
    QStringList patterns;
    for (const QJsonValue& pattern : item.value(QLatin1String("patterns")).toArray()) patterns.append(pattern.toString());
    detail = patterns.join(QLatin1Char('\n'));
  } else if (type == QLatin1String("dynamic_tool")) {
    label = item.value(QLatin1String("toolName")).toString(QStringLiteral("Used tool"));
    // Its input; a result's body is not shown (docs/user/activity-log.md).
    if (const QJsonValue input = item.value(QLatin1String("input")); input.isObject() && !input.toObject().isEmpty()) {
      detail = QString::fromUtf8(QJsonDocument(input.toObject()).toJson(QJsonDocument::Indented)).trimmed();
    } else if (input.isString()) {
      detail = input.toString();
    }
  } else if (type == QLatin1String("approval_request") || type == QLatin1String("user_input_request")) {
    // Answered in the composer (ComposerController); the row records the ask.
    const bool approval = type == QLatin1String("approval_request");
    label = approval ? QStringLiteral("Approval requested") : QStringLiteral("Input requested");
    if (approval) {
      detail = text(item, QLatin1String("prompt"));
    } else {
      QStringList questions;
      for (const QJsonValue& question : item.value(QLatin1String("questions")).toArray()) {
        questions.append(text(question.toObject(), QLatin1String("question")));
      }
      detail = questions.join(QLatin1Char('\n'));
    }
    const QJsonObject request = entity(QStringLiteral("runtime-request"), text(item, QLatin1String("requestId")));
    if (text(request, QLatin1String("decision")) == QLatin1String("decline")) {
      entry.insert(QStringLiteral("statusLabel"), QStringLiteral("Declined"));
    } else if (text(request, QLatin1String("status")) == QLatin1String("pending")) {
      entry.insert(QStringLiteral("statusLabel"), approval ? QStringLiteral("Waiting for approval") : QStringLiteral("Waiting for an answer"));
    }
  } else if (type == QLatin1String("todo_list")) {
    label = QStringLiteral("Updated plan");
    QStringList steps;
    for (const QJsonValue& step : item.value(QLatin1String("steps")).toArray()) {
      steps.append(QStringLiteral("%1: %2").arg(text(step.toObject(), QLatin1String("status")), text(step.toObject(), QLatin1String("text"))));
    }
    detail = steps.join(QLatin1Char('\n'));
  } else if (type == QLatin1String("run_interrupt_request")) {
    label = QStringLiteral("Interrupt requested");
    detail = text(item, QLatin1String("message"));
  } else if (type == QLatin1String("run_interrupt_result")) {
    label = QStringLiteral("Run interrupted");
    detail = text(item, QLatin1String("message"));
  } else if (type == QLatin1String("system_notice")) {
    label = text(item, QLatin1String("message"));
  } else {
    label = type;
  }
  if (!title.isEmpty() && type != QLatin1String("reasoning")) label = title;
  entry.insert(QStringLiteral("label"), label);
  entry.insert(QStringLiteral("detail"), detail);
  return entry;
}

QVariant TimelineModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  if (role == IdRole) return row.id;
  if (role == KindRole) return row.kind;
  if (row.kind == QLatin1String("fold")) {
    if (role == TitleRole) return row.label;
    if (role == HiddenCountRole) return row.hidden;
    if (role == ExpandedRole) return row.expanded;
    if (role == TimeRole) return stamp(row.at);
    return {};
  }
  if (row.kind == QLatin1String("work")) {
    const bool expanded = m_expandedGroups.contains(row.id) != row.startsOpen;
    // A summarized group collapses into its summary alone.
    const int shown = row.summarized ? 0 : visibleWorkEntries;
    if (role == ExpandedRole) return expanded;
    if (role == HiddenCountRole) return std::max<int>(0, int(row.items.size()) - shown);
    if (role == EntriesRole) {
      QVariantList entries;
      const qsizetype first = expanded ? 0 : std::max<qsizetype>(0, row.items.size() - shown);
      for (qsizetype i = first; i < row.items.size(); ++i) entries.append(entry(entity(QStringLiteral("turn-item"), row.items.at(i))));
      return entries;
    }
    if (role == SummaryRole || role == SummaryFailedRole) {
      if (!row.summarized) return role == SummaryRole ? QVariant(QString()) : QVariant(false);
      QList<QJsonObject> calls;
      for (const QString& id : row.items) calls.append(entity(QStringLiteral("turn-item"), id));
      const timeline::GroupSummary summary = timeline::summarize(calls);
      return role == SummaryRole ? QVariant(summary.text) : QVariant(summary.failed);
    }
    return {};
  }

  const QJsonObject item = entity(QStringLiteral("turn-item"), row.items.value(0));
  const QString type = text(item, QLatin1String("type"));
  const QString status = text(item, QLatin1String("status"));
  switch (role) {
    case AuthorRole:
      return type == QLatin1String("user_message") ? QStringLiteral("user") : QStringLiteral("assistant");
    case StreamingRole:
      return item.value(QLatin1String("streaming")).toBool();
    case StatusRole:
      return status;
    case MarkerRole:
      return intentMarker(text(item, QLatin1String("inputIntent")));
    case IntentRole:
      return text(item, QLatin1String("inputIntent"));
    case AttributionRole:
      // apps/web/src/components/chat/MessagesTimeline.tsx UserMessageTimelineRow.
      if (type != QLatin1String("user_message")) return QString();
      if (!text(item, QLatin1String("scheduledTaskId")).isEmpty()) return QStringLiteral("Sent by automation");
      if (text(item, QLatin1String("createdBy")) == QLatin1String("agent")) {
        const QString sender = text(item, QLatin1String("senderThreadId"));
        const QString title = sender.isEmpty() || !m_threadTitle ? QString() : m_threadTitle(sender);
        return title.isEmpty() ? QStringLiteral("Sent by another agent") : QStringLiteral("From %1").arg(title);
      }
      return QString();
    case ThreadRole:
      if (row.kind == QLatin1String("subagent")) return text(item, QLatin1String("childThreadId"));
      if (type == QLatin1String("user_message") && text(item, QLatin1String("createdBy")) == QLatin1String("agent")) {
        return text(item, QLatin1String("senderThreadId"));
      }
      return QString();
    case ModelRole:
      if (row.kind != QLatin1String("subagent")) return QString();
      return text(entity(QStringLiteral("subagent"), text(item, QLatin1String("subagentId"))), QLatin1String("model"));
    case MetaRole:
      return row.meta;
    case IconRole:
      return row.kind == QLatin1String("message") || row.kind == QLatin1String("plan") ? QString() : iconOf(item);
    case TimeRole:
      return stamp(rowTime(row));
    case StatusLabelRole:
      return row.kind == QLatin1String("subagent") ? subagentStatusLabel(status) : QString();
    case TitleRole:
      if (row.kind == QLatin1String("plan")) return planTitle(text(item, QLatin1String("markdown")));
      if (row.kind == QLatin1String("marker")) return markerTitle(item);
      if (row.kind == QLatin1String("error")) return QStringLiteral("Error");
      if (row.kind == QLatin1String("subagent")) {
        const QString title = text(item, QLatin1String("title")).trimmed();
        return title.isEmpty() ? QStringLiteral("Subagent") : title;
      }
      return {};
    case TextRole:
      if (row.kind == QLatin1String("plan")) return planBody(text(item, QLatin1String("markdown")));
      if (row.kind == QLatin1String("marker")) return markerDetail(item);
      if (row.kind == QLatin1String("error")) {
        return text(item.value(QLatin1String("failure")).toObject(), QLatin1String("message"));
      }
      if (row.kind == QLatin1String("subagent")) {
        for (const auto field : {QLatin1String("progress"), QLatin1String("result"), QLatin1String("prompt")}) {
          if (!text(item, field).isEmpty()) return text(item, field);
        }
        return QString();
      }
      return text(item, QLatin1String("text"));
    case FilesRole: {
      QVariantList files;
      const QJsonObject checkpoint = entity(QStringLiteral("turn-item"), row.checkpoint);
      for (const QJsonValue& value : checkpoint.value(QLatin1String("files")).toArray()) {
        const QJsonObject file = value.toObject();
        files.append(QVariantMap{
            {QStringLiteral("path"), text(file, QLatin1String("path"))},
            {QStringLiteral("additions"), file.value(QLatin1String("additions")).toInt()},
            {QStringLiteral("deletions"), file.value(QLatin1String("deletions")).toInt()},
        });
      }
      return files;
    }
    default:
      return {};
  }
}
