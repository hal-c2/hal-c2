// The timeline of one thread as the MC streams it (TimelineModel), against a
// model of the rows a user should see.
//
// The model keeps the MC's thread (runs and turn items) and its log, and what
// the client holds of it: its offset, its window's floor and whether it is
// caught up. The fake MC in it answers the model's `sub` frames as
// HalC2.Streams.Server does: a snapshot of the window when the copy is new or
// of another log, else the log's events since the offset, then `live`; pages of
// earlier runs; and every change to what the client holds while it follows.
// The client lets go of the runs far above the row the user reads (keepFrom),
// and follows again from the floor that raises.
// Answers can be cut off part-way, events can come twice, and the client can
// restart from its cache.
//
// After each step the rows equal the model's projection, QAbstractItemModelTester
// finds nothing wrong with the row signals, every row whose roles changed was
// redrawn for them, and no row that stayed the same was redrawn.

#include "Prop.h"

#include <QAbstractItemModelTester>
#include <QJsonDocument>
#include <QLoggingCategory>

#include <memory>
#include <optional>

#include "LocalCache.h"
#include "TimelineModel.h"
#include "TimelineSummary.h"

namespace {

const QString kKey = QStringLiteral("env-1:thread-1");
// The turn items a window or page of the fake MC holds at least (it rounds up
// to whole runs), whatever the client asks for: small, so threads page.
constexpr int kWindow = 3;
// The turn items the client keeps above the row read, and frees at least
// before it lets go (TimelineModel::setKeep): one, so threads this small trim.
constexpr int kKeep = 1;
constexpr int kMaxRuns = 5;
constexpr int kMaxItems = 16;

const QSet<QString> kSettled{QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("interrupted")};

QDateTime clock() {
  return QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
}

const QStringList kAgents{QStringLiteral("agent-1"), QStringLiteral("agent-2")};

// One of `values` (RapidCheck's elementOf finds no begin() for a QList).
QString pick(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

// --- What a group of calls did --------------------------------------------------

// A tool call as a work group summarizes it.
struct Call {
  // command_execution, file_change, file_search, web_search, todo_list,
  // dynamic_tool or reasoning
  QString type;
  // completed, failed, declined or running
  QString status;
  std::optional<int> exitCode;
  // A change's file, a search's pattern (and, read, its one result).
  QString file;
  bool read = false;
  // A tool's name: "Read" reads a file.
  QString tool;
};

void showValue(const Call& call, std::ostream& os) {
  os << call.type.toStdString() << "(" << call.status.toStdString();
  if (call.exitCode) os << " exit=" << *call.exitCode;
  if (!call.file.isEmpty()) os << " file=" << call.file.toStdString();
  if (call.read) os << " read";
  if (!call.tool.isEmpty()) os << " tool=" << call.tool.toStdString();
  os << ")";
}

QJsonObject json(const Call& call) {
  QJsonObject item{{QStringLiteral("type"), call.type}, {QStringLiteral("status"), call.status}};
  if (call.exitCode) item.insert(QStringLiteral("exitCode"), *call.exitCode);
  if (call.type == QLatin1String("file_change") && !call.file.isEmpty()) item.insert(QStringLiteral("fileName"), call.file);
  if (call.type == QLatin1String("file_search")) {
    item.insert(QStringLiteral("pattern"), call.file);
    if (call.read) item.insert(QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("fileName"), call.file}}});
  }
  if (call.type == QLatin1String("dynamic_tool")) item.insert(QStringLiteral("toolName"), call.tool);
  return item;
}

rc::Gen<Call> genCall() {
  return rc::gen::exec([] {
    Call call;
    call.type = *rc::gen::weightedElement<QString>({{3, QStringLiteral("command_execution")},
                                                    {3, QStringLiteral("file_change")},
                                                    {2, QStringLiteral("file_search")},
                                                    {1, QStringLiteral("web_search")},
                                                    {1, QStringLiteral("todo_list")},
                                                    {2, QStringLiteral("dynamic_tool")},
                                                    {2, QStringLiteral("reasoning")}});
    call.status = *rc::gen::weightedElement<QString>(
        {{6, QStringLiteral("completed")}, {2, QStringLiteral("failed")}, {1, QStringLiteral("declined")}, {1, QStringLiteral("running")}});
    if (call.type == QLatin1String("command_execution") && *rc::gen::arbitrary<bool>()) call.exitCode = *rc::gen::inRange(0, 2);
    if (call.type == QLatin1String("file_change")) call.file = *rc::gen::elementOf(std::vector<QString>{{}, QStringLiteral("a.cpp"), QStringLiteral("b.h")});
    if (call.type == QLatin1String("file_search")) {
      call.file = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("a.cpp"), QStringLiteral("b.h")});
      call.read = *rc::gen::arbitrary<bool>();
    }
    if (call.type == QLatin1String("dynamic_tool")) call.tool = *rc::gen::elementOf(std::vector<QString>{QStringLiteral("Read"), QStringLiteral("lint")});
    return call;
  });
}

// The kind of work a call was, and how an amount of it reads.
QString actionOf(const Call& call) {
  if (call.type == QLatin1String("command_execution")) return QStringLiteral("command");
  if (call.type == QLatin1String("file_change")) return QStringLiteral("edit");
  if (call.type == QLatin1String("file_search")) return call.read ? QStringLiteral("read") : QStringLiteral("code-search");
  if (call.type == QLatin1String("web_search")) return QStringLiteral("search");
  if (call.type == QLatin1String("todo_list")) return QStringLiteral("update");
  return call.tool == QLatin1String("Read") ? QStringLiteral("read") : QStringLiteral("other");
}

QString labelOf(const QString& action, int count) {
  const auto plural = [&](const QString& verb, const QString& noun) {
    return QStringLiteral("%1 %2 %3%4").arg(verb).arg(count).arg(noun, count == 1 ? QString() : QStringLiteral("s"));
  };
  if (action == QLatin1String("command")) return plural(QStringLiteral("Ran"), QStringLiteral("command"));
  if (action == QLatin1String("edit")) return plural(QStringLiteral("Changed"), QStringLiteral("file"));
  if (action == QLatin1String("read")) return plural(QStringLiteral("Read"), QStringLiteral("file"));
  if (action == QLatin1String("code-search")) return plural(QStringLiteral("Searched code"), QStringLiteral("time"));
  if (action == QLatin1String("search")) return plural(QStringLiteral("Searched the web"), QStringLiteral("time"));
  if (action == QLatin1String("update")) return plural(QStringLiteral("Received"), QStringLiteral("update"));
  return plural(QStringLiteral("Used"), QStringLiteral("tool"));
}

// Calls that change something are named before reads and searches, and those
// before tools and updates.
int rank(const QString& action) {
  if (action == QLatin1String("command") || action == QLatin1String("edit")) return 0;
  return action == QLatin1String("other") || action == QLatin1String("update") ? 2 : 1;
}

// A fold of the calls: each kind of work by first appearance, the two that rank
// first named (an edit by the files it touched), the rest counted; thinking
// alone is "Thought"; failed when any call did.
timeline::GroupSummary expectedSummary(const QList<Call>& all) {
  QList<Call> calls;
  for (const Call& call : all) {
    if (call.type != QLatin1String("reasoning")) calls.append(call);
  }
  if (calls.isEmpty()) {
    if (all.isEmpty()) return {};
    return {all.size() == 1 ? QStringLiteral("Thought") : QStringLiteral("Thought (×%1)").arg(all.size())};
  }
  QStringList order;
  QHash<QString, int> counts;
  QHash<QString, QSet<QString>> files;
  QHash<QString, int> unnamed;
  bool failed = false;
  for (const Call& call : std::as_const(calls)) {
    const QString action = actionOf(call);
    if (!order.contains(action)) order.append(action);
    ++counts[action];
    if (call.file.isEmpty()) {
      ++unnamed[action];
    } else {
      files[action].insert(call.file);
    }
    failed = failed || call.status == QLatin1String("failed") || call.status == QLatin1String("declined") ||
             (call.type == QLatin1String("command_execution") && call.exitCode.value_or(0) != 0);
  }
  QStringList named;
  for (int wanted = 0; wanted <= 2 && named.size() < 2; ++wanted) {
    for (const QString& action : std::as_const(order)) {
      if (rank(action) == wanted && named.size() < 2) named.append(action);
    }
  }
  QStringList labels;
  int counted = 0;
  for (const QString& action : std::as_const(order)) {
    if (!named.contains(action)) continue;
    const int amount = action == QLatin1String("edit") ? int(files.value(action).size()) + unnamed.value(action) : counts.value(action);
    labels.append(labels.isEmpty() ? labelOf(action, amount) : labelOf(action, amount).replace(0, 1, labelOf(action, amount).at(0).toLower()));
    counted += counts.value(action);
  }
  if (const int rest = int(calls.size()) - counted; rest > 0) {
    labels.append(QStringLiteral("performed %1 other action%2").arg(rest).arg(rest == 1 ? QString() : QStringLiteral("s")));
  }
  const QString sentence = labels.size() < 3 ? labels.join(QStringLiteral(" and "))
                                             : labels.mid(0, labels.size() - 1).join(QStringLiteral(", ")) + QStringLiteral(", and ") + labels.last();
  return {sentence, failed};
}

// --- The model --------------------------------------------------------------------

struct Run {
  QString id;
  int ordinal = 0;
  // running, completed, failed, interrupted, rolled_back, queued or cancelled
  QString status;
  // A queued run held for the user, numbered above the run that passed it.
  bool held = false;
  // How long before clock() the message asking for it was sent; -1 when the
  // MC says nothing of it.
  int requestedAgo = -1;
  bool operator==(const Run&) const = default;
};

struct Item {
  QString id;
  // user_message, assistant_message, command_execution, reasoning,
  // proposed_plan, subagent, error or notification
  QString type;
  QString run;
  int ordinal = 0;
  // What the row reads: a message's text, a call's output, a plan's
  // markdown, a subagent's progress, an error's message.
  QString text;
  bool streaming = false;
  QString status;
  // A subagent's agent.
  QString agent;
  // The message that started its run: the user's, or one the MC sent the agent
  // for itself, a notification.
  bool opener = false;
  // A user_message a thread stored before the MC recorded those as
  // notifications: "envelope", a delegated task's result as the agent reads
  // it (its text is the task's title), or "wake", the provider waking itself.
  QString legacy;
  // A call that drove an app on the environment's machine, shown with the
  // app's icon once the environment signs its address.
  bool app = false;
  bool operator==(const Item&) const = default;
};

struct Thread {
  QMap<QString, Run> runs;
  QMap<QString, Item> items;
  // Each subagent's model, by agent id.
  QMap<QString, QString> agents;
  bool operator==(const Thread&) const = default;
};

struct Event {
  int seq = 0;
  QString kind;
  QString id;
  QJsonObject patch;
  // The run of a turn item, for whether a window holds it.
  QString run;
};

struct Model {
  // The MC's.
  Thread mc;
  QList<Event> log;
  int seq = 0;
  int ordinal = 0;
  int handle = 1;
  // The client's: what it holds, the offset and handle it holds them as of,
  // and its window's floor.
  Thread held;
  qint64 offset = -1;
  int heldHandle = 0;
  std::optional<int> floor;
  // Following the stream and caught up: changes reach it.
  bool live = false;
  // The last events frame it was sent.
  QJsonObject lastEvents;
  // What the user opened, by run and by work group row.
  QSet<QString> foldsOpen;
  QSet<QString> groupsToggled;
  // Read as the phone reads (TimelineModel::Folds::Phone).
  bool phone = false;
  // The client holds a signed address for the app's icon.
  bool appSigned = false;
};

// The app the calls drove, its icon's attachment id, and where it is served.
const QJsonObject kApp{{QStringLiteral("_tag"), QStringLiteral("display-name")}, {QStringLiteral("displayName"), QStringLiteral("Calculator")}};
const QString kAppIcon = QStringLiteral("native-app-icon:") + QString::fromUtf8(QJsonDocument(kApp).toJson(QJsonDocument::Compact));
const QUrl kAppIconUrl(QStringLiteral("http://mc.test/api/assets/app-icon"));

bool settled(const Run& run) {
  return kSettled.contains(run.status);
}

QString field(const QString& type) {
  if (type == QLatin1String("command_execution")) return QStringLiteral("output");
  if (type == QLatin1String("proposed_plan")) return QStringLiteral("markdown");
  if (type == QLatin1String("subagent")) return QStringLiteral("progress");
  if (type == QLatin1String("notification")) return QStringLiteral("summary");
  return QStringLiteral("text");
}

QJsonObject json(const Run& run) {
  QJsonObject entity{{QStringLiteral("id"), run.id}, {QStringLiteral("ordinal"), run.ordinal}, {QStringLiteral("status"), run.status}};
  if (run.held) entity.insert(QStringLiteral("queueHeld"), true);
  if (run.requestedAgo >= 0) entity.insert(QStringLiteral("requestedAt"), clock().addSecs(-run.requestedAgo).toString(Qt::ISODate));
  if (run.status != QLatin1String("queued") && run.status != QLatin1String("cancelled") && run.status != QLatin1String("starting")) {
    entity.insert(QStringLiteral("startedAt"), clock().toString(Qt::ISODate));
  }
  return entity;
}

QJsonObject json(const Item& item) {
  QJsonObject entity{{QStringLiteral("id"), item.id},
                     {QStringLiteral("type"), item.type},
                     {QStringLiteral("runId"), item.run},
                     {QStringLiteral("ordinal"), item.ordinal},
                     {QStringLiteral("status"), item.status},
                     {QStringLiteral("streaming"), item.streaming}};
  if (item.type == QLatin1String("error")) {
    QJsonObject failure{{QStringLiteral("message"), item.text}};
    // A usage limit has its own text, "limit" here.
    if (item.text == QLatin1String("limit")) failure.insert(QStringLiteral("class"), QStringLiteral("usage_limit"));
    entity.insert(QStringLiteral("failure"), failure);
  } else if (item.legacy == QLatin1String("envelope")) {
    entity.insert(QStringLiteral("createdBy"), QStringLiteral("system"));
    entity.insert(QStringLiteral("creationSource"), QStringLiteral("server"));
    entity.insert(QStringLiteral("text"),
                  QStringLiteral("<delegated_task_result taskId=\"task:1\" title=\"%1\" status=\"failed\" childThreadId=\"thread:2\">\nno\n</delegated_task_result>")
                      .arg(item.text));
  } else if (item.legacy == QLatin1String("wake")) {
    entity.insert(QStringLiteral("createdBy"), QStringLiteral("agent"));
    entity.insert(QStringLiteral("creationSource"), QStringLiteral("provider"));
    entity.insert(QStringLiteral("text"), item.text);
  } else {
    entity.insert(field(item.type), item.text);
  }
  if (!item.agent.isEmpty()) entity.insert(QStringLiteral("subagentId"), item.agent);
  if (item.app) entity.insert(QStringLiteral("toolIcon"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("native-app")}, {QStringLiteral("app"), kApp}});
  return entity;
}

// Whether a window from `floor` holds a turn item of `run`.
bool holds(const Thread& thread, const QString& run, std::optional<int> floor) {
  return !floor || thread.runs.value(run).ordinal >= *floor;
}

// What a client with the window from `floor` holds of `thread`.
Thread window(const Thread& thread, std::optional<int> floor) {
  Thread held{thread.runs, {}, thread.agents};
  for (const Item& item : thread.items) {
    if (holds(thread, item.run, floor)) held.items.insert(item.id, item);
  }
  return held;
}

// HalC2.Streams.View.take_runs: the runs before `before` (none: the newest)
// that hold `count` turn items, and the floor once they are held (none when
// no run is left before them).
std::pair<QSet<QString>, std::optional<int>> takeRuns(const Thread& thread, std::optional<int> before, int count) {
  QHash<QString, int> counts;
  for (const Item& item : thread.items) ++counts[item.run];
  QList<std::pair<int, QString>> runs;
  for (const Run& run : thread.runs) {
    if (run.status == QLatin1String("rolled_back")) continue;
    if (!before || run.ordinal < *before) runs.append({run.ordinal, run.id});
  }
  std::sort(runs.begin(), runs.end(), std::greater<>());
  QSet<QString> taken;
  int held = 0;
  for (qsizetype i = 0; i < runs.size(); ++i) {
    taken.insert(runs.at(i).second);
    held += counts.value(runs.at(i).second);
    if (held >= count) return {taken, i + 1 < runs.size() ? std::optional(runs.at(i).first) : std::nullopt};
  }
  return {taken, std::nullopt};
}

// --- The rows a user should see -----------------------------------------------------

struct Row {
  QString id;
  QString kind;
  QString title;
  QString text;
  bool streaming = false;
  bool meta = false;
  bool expanded = false;
  int hidden = 0;
  // A work group's calls on screen.
  QStringList entries;
  // Each of those calls' own icon, empty for none.
  QStringList icons;
  bool summarized = false;
  // What a summarized group did, and whether a call of it failed.
  QString summary;
  bool summaryFailed = false;
  // What the last call on screen reads, when it is a command: while its turn
  // runs, how it went ("Running command").
  QString command;
  QString agentModel;
  bool operator==(const Row&) const = default;
};

void showValue(const Row& row, std::ostream& os) {
  os << row.id.toStdString() << "(" << row.kind.toStdString();
  if (!row.title.isEmpty()) os << " title=" << row.title.toStdString();
  if (!row.text.isEmpty()) os << " text=" << row.text.toStdString();
  if (row.streaming) os << " streaming";
  if (row.meta) os << " meta";
  if (row.expanded) os << " expanded";
  if (row.hidden) os << " hidden=" << row.hidden;
  if (!row.entries.isEmpty()) os << " entries=" << row.entries.join(QLatin1Char(',')).toStdString();
  if (std::any_of(row.icons.cbegin(), row.icons.cend(), [](const QString& icon) { return !icon.isEmpty(); })) {
    os << " icons=" << row.icons.join(QLatin1Char(',')).toStdString();
  }
  if (row.summarized) os << " summary=" << row.summary.toStdString() << (row.summaryFailed ? " failed" : "");
  if (!row.command.isEmpty()) os << " command=" << row.command.toStdString();
  if (!row.agentModel.isEmpty()) os << " model=" << row.agentModel.toStdString();
  os << ")";
}

// What the MC sent the agent for itself shows as a marker naming it, not as a
// message of the user's.
QString noticeOf(const Item& item) {
  if (item.legacy == QLatin1String("envelope")) return item.text + QStringLiteral(" failed");
  if (item.legacy == QLatin1String("wake")) return QStringLiteral("Background activity updated");
  if (item.type != QLatin1String("notification")) return {};
  return item.text.isEmpty() ? QStringLiteral("Notification") : item.text;
}

QString kindOf(const Item& item) {
  const QString& type = item.type;
  if (!noticeOf(item).isEmpty()) return QStringLiteral("marker");
  if (type == QLatin1String("user_message") || type == QLatin1String("assistant_message")) return QStringLiteral("message");
  if (type == QLatin1String("proposed_plan")) return QStringLiteral("plan");
  if (type == QLatin1String("subagent") || type == QLatin1String("error")) return type;
  return QStringLiteral("work");
}

// A settled turn folds its calls and commentary behind "Worked" ("You stopped
// this response" for the latest, interrupted), leaving its last reply and any
// call still running in view; while one of its replies streams it stays open.
// Consecutive calls of a turn make one group, which a settled turn with
// several calls summarizes; a group shows its latest call until opened.
// The phone's also keeps a turn's first reply in view, and leaves a failed
// turn open with a row per call; a settled turn leaves out the calls that
// never ended, and a starting or running latest turn ends in "Thinking"
// unless its last call is running or went well, or its reply is streaming.
QList<Row> project(const Model& model) {
  const Thread& thread = model.held;
  QList<Item> shown;
  for (const Item& item : thread.items) {
    const Run& run = thread.runs.value(item.run);
    if (run.status == QLatin1String("rolled_back")) continue;
    if (model.phone && settled(run) && kindOf(item) == QLatin1String("work") && item.status == QLatin1String("running")) continue;
    shown.append(item);
  }
  std::sort(shown.begin(), shown.end(), [](const Item& a, const Item& b) {
    return a.ordinal != b.ordinal ? a.ordinal < b.ordinal : a.id < b.id;
  });
  QString latest;
  for (const Run& run : thread.runs) {
    // Held for the user and never started: still queued, or cancelled while held.
    if (run.held && (run.status == QLatin1String("queued") || run.status == QLatin1String("cancelled"))) continue;
    // Runs are in the order they were made, so `>=` would give equal ordinals
    // to the newest made. The generators only ever make unique ordinals, so
    // no tie arises here; the implementation's tie-break is later-starting
    // (first item in timeline order), covered by the dedicated regression in
    // tst_TimelineRepaintRegression instead.
    if (latest.isEmpty() || run.ordinal >= thread.runs.value(latest).ordinal) latest = run.id;
  }

  QHash<QString, QString> terminal;  // run -> its last reply
  QSet<QString> streaming;           // runs with a reply streaming
  QHash<QString, QString> first;     // run -> its first item after the user's message
  QHash<QString, QString> firstReply;
  for (const Item& item : std::as_const(shown)) {
    if (item.opener) continue;
    if (!first.contains(item.run)) first.insert(item.run, item.id);
    if (item.type == QLatin1String("assistant_message")) {
      if (!firstReply.contains(item.run)) firstReply.insert(item.run, item.id);
      terminal.insert(item.run, item.id);
      if (item.streaming) streaming.insert(item.run);
    }
  }
  struct Fold {
    QString run;
    int hidden = 0;
  };
  QHash<QString, Fold> foldBefore;  // by the item it goes above
  QSet<QString> folded;
  const auto failed = [&](const QString& run) { return model.phone && thread.runs.value(run).status == QLatin1String("failed"); };
  for (const Run& run : thread.runs) {
    if (!settled(run) || streaming.contains(run.id) || !first.contains(run.id) || failed(run.id)) continue;
    QStringList hidden;
    for (const Item& item : std::as_const(shown)) {
      if (item.run != run.id || item.opener || item.id == terminal.value(run.id)) continue;
      if (model.phone && item.id == firstReply.value(run.id)) continue;
      const QString kind = kindOf(item);
      if ((kind == QLatin1String("work") && item.status != QLatin1String("running")) || kind == QLatin1String("message")) {
        hidden.append(item.id);
      }
    }
    if (hidden.isEmpty()) continue;
    foldBefore.insert(first.value(run.id), {run.id, int(hidden.size())});
    if (!model.foldsOpen.contains(run.id)) {
      for (const QString& id : std::as_const(hidden)) folded.insert(id);
    }
  }

  QList<Row> rows;
  for (qsizetype i = 0; i < shown.size();) {
    const Item& item = shown.at(i);
    if (const auto fold = foldBefore.constFind(item.id); fold != foldBefore.cend()) {
      const Run& run = thread.runs.value(fold->run);
      Row row{QStringLiteral("fold:") + run.id, QStringLiteral("fold")};
      row.title = run.status == QLatin1String("interrupted") && run.id == latest ? QStringLiteral("You stopped this response")
                                                                                  : QStringLiteral("Worked");
      row.hidden = fold->hidden;
      row.expanded = model.foldsOpen.contains(run.id);
      rows.append(row);
    }
    if (folded.contains(item.id)) {
      ++i;
      continue;
    }
    const QString kind = kindOf(item);
    if (kind == QLatin1String("work")) {
      Row row{QStringLiteral("work:") + item.id, kind};
      QStringList calls;
      for (; i < shown.size(); ++i) {
        const Item& call = shown.at(i);
        if (!calls.isEmpty() && foldBefore.contains(call.id)) break;
        if (kindOf(call) != QLatin1String("work") || folded.contains(call.id) || call.run != item.run) break;
        calls.append(call.id);
        if (failed(item.run)) {
          ++i;
          break;
        }
      }
      row.summarized = calls.size() > 1 && settled(thread.runs.value(item.run));
      if (row.summarized) {
        QList<Call> work;
        for (const QString& id : std::as_const(calls)) work.append({thread.items.value(id).type, thread.items.value(id).status});
        const timeline::GroupSummary summary = expectedSummary(work);
        row.summary = summary.text;
        row.summaryFailed = summary.failed;
      }
      row.expanded = model.groupsToggled.contains(row.id);
      const int visible = row.summarized ? 0 : 1;
      row.hidden = int(calls.size()) - visible;
      row.entries = row.expanded ? calls : calls.mid(calls.size() - visible);
      for (const QString& id : std::as_const(row.entries)) {
        row.icons.append(thread.items.value(id).app && model.appSigned ? kAppIconUrl.toString() : QString());
      }
      if (const Item last = thread.items.value(row.entries.value(row.entries.size() - 1)); last.type == QLatin1String("command_execution")) {
        // These commands name no program.
        const bool live = !settled(thread.runs.value(item.run)) && !row.expanded;
        const QString& status = last.status;
        const QString verb = status == QLatin1String("failed")      ? QStringLiteral("Failed")
                             : status == QLatin1String("completed") ? QStringLiteral("Ran")
                                                                    : QStringLiteral("Running");
        row.command = (live ? verb : QStringLiteral("Ran")) + QStringLiteral(" command");
      }
      rows.append(row);
      continue;
    }
    Row row{item.id, kind};
    row.text = kind == QLatin1String("marker") ? QString() : item.text;
    if (kind == QLatin1String("marker")) row.title = noticeOf(item);
    row.streaming = item.streaming;
    if (kind == QLatin1String("plan")) row.title = QStringLiteral("Proposed plan");
    if (kind == QLatin1String("subagent")) {
      row.title = QStringLiteral("Subagent");
      row.agentModel = thread.agents.value(item.agent);
    }
    if (kind == QLatin1String("error")) {
      // A usage limit is one line naming the wait, with no body.
      const bool limit = item.text == QLatin1String("limit");
      row.title = limit ? QStringLiteral("Usage limit reached.") : QStringLiteral("Error");
      if (limit) row.text.clear();
    }
    if (terminal.value(item.run) == item.id) row.meta = !streaming.contains(item.run) && settled(thread.runs.value(item.run));
    rows.append(row);
    ++i;
  }
  const QString latestStatus = thread.runs.value(latest).status;
  if (model.phone && (latestStatus == QLatin1String("running") || latestStatus == QLatin1String("starting"))) {
    // The last item on screen, of the last row: a group's latest call.
    Item last;
    for (qsizetype i = shown.size() - 1; i >= 0 && last.id.isEmpty(); --i) {
      if (!folded.contains(shown.at(i).id)) last = shown.at(i);
    }
    const QString kind = kindOf(last);
    const bool told = last.run == latest && ((kind == QLatin1String("work") && (last.status == QLatin1String("running") || last.status == QLatin1String("completed"))) ||
                                             (last.type == QLatin1String("assistant_message") && last.streaming));
    if (!told) {
      Row row{QStringLiteral("thinking:") + latest, QStringLiteral("thinking")};
      row.title = QStringLiteral("Thinking");
      rows.append(row);
    }
  }
  return rows;
}

// The number a user message's turn goes by while no checkpoint gives it one: its
// place among the runs that started and were not rewound.
int turnOf(const Thread& thread, const QString& id) {
  const int ordinal = thread.runs.value(id).ordinal;
  int turn = 0;
  for (const Run& run : thread.runs) {
    const bool neverStarted = run.status == QLatin1String("queued") || run.status == QLatin1String("cancelled");
    if (run.ordinal <= ordinal && run.status != QLatin1String("rolled_back") && (run.id == id || !neverStarted)) ++turn;
  }
  return turn;
}

// --- The client ------------------------------------------------------------------

int modelTestFailures = 0;
QtMessageHandler previousHandler = nullptr;

void countModelTestFailures(QtMsgType type, const QMessageLogContext& context, const QString& message) {
  if (context.category && qstrcmp(context.category, "qt.modeltest") == 0 && type >= QtWarningMsg) ++modelTestFailures;
  previousHandler(type, context, message);
}

struct Sut {
  QTemporaryDir dir{QDir::tempPath() + QStringLiteral("/timeline-XXXXXX")};
  LocalCache cache;
  std::unique_ptr<TimelineModel> model;
  std::unique_ptr<QAbstractItemModelTester> tester;
  // Every row dataChanged named since the step began: its id and roles.
  QList<std::pair<QString, QList<int>>> redrawn;
  // Each row's roles when the step began, by id.
  QHash<QString, QHash<int, QVariant>> before;
  int earlierWanted = 0;
  int raised = 0;
  bool phone = false;

  Sut() {
    cache.open(dir.path());
    make();
  }

  ~Sut() {
    tester.reset();
    model.reset();
    cache.drain();
  }

  void make() {
    tester.reset();
    model = std::make_unique<TimelineModel>(kKey);
    model->setClock(clock);
    model->setCache(&cache);
    model->setFolds(phone ? TimelineModel::Folds::Phone : TimelineModel::Folds::Desktop);
    tester = std::make_unique<QAbstractItemModelTester>(model.get(), QAbstractItemModelTester::FailureReportingMode::Warning);
    QObject::connect(model.get(), &QAbstractItemModel::dataChanged, model.get(),
                     [this](const QModelIndex& top, const QModelIndex& bottom, const QList<int>& roles) {
                       for (int row = top.row(); row <= bottom.row(); ++row) {
                         redrawn.append({model->data(model->index(row), TimelineModel::IdRole).toString(), roles});
                       }
                     });
    QObject::connect(model.get(), &TimelineModel::earlierWanted, model.get(), [this] { ++earlierWanted; });
    QObject::connect(model.get(), &TimelineModel::windowRaised, model.get(), [this] { ++raised; });
    model->setKeep(kKeep);
  }

  QHash<int, QVariant> roles(int row) const {
    QHash<int, QVariant> values;
    const QHash<int, QByteArray> names = model->roleNames();
    for (auto it = names.cbegin(); it != names.cend(); ++it) values.insert(it.key(), model->data(model->index(row), it.key()));
    return values;
  }

  void begin() {
    redrawn.clear();
    before.clear();
    modelTestFailures = 0;
    for (int row = 0; row < model->rowCount(); ++row) {
      before.insert(model->data(model->index(row), TimelineModel::IdRole).toString(), roles(row));
    }
  }

  void send(const QJsonObject& frame) { model->receive(frame); }

  Row row(int at) const {
    const auto value = [&](int role) { return model->data(model->index(at), role); };
    Row row{value(TimelineModel::IdRole).toString(), value(TimelineModel::KindRole).toString()};
    row.title = value(TimelineModel::TitleRole).toString();
    row.text = value(TimelineModel::TextRole).toString();
    row.streaming = value(TimelineModel::StreamingRole).toBool();
    row.meta = value(TimelineModel::MetaRole).toBool();
    row.expanded = value(TimelineModel::ExpandedRole).toBool();
    row.hidden = value(TimelineModel::HiddenCountRole).toInt();
    for (const QVariant& entry : value(TimelineModel::EntriesRole).toList()) {
      row.entries.append(entry.toMap().value(QStringLiteral("id")).toString());
      row.icons.append(entry.toMap().value(QStringLiteral("iconUrl")).toString());
    }
    if (const QVariantMap last = value(TimelineModel::EntriesRole).toList().value(row.entries.size() - 1).toMap();
        last.value(QStringLiteral("type")) == QLatin1String("command_execution")) {
      row.command = last.value(QStringLiteral("label")).toString();
    }
    row.summary = value(TimelineModel::SummaryRole).toString();
    row.summarized = !row.summary.isEmpty();
    row.summaryFailed = value(TimelineModel::SummaryFailedRole).toBool();
    row.agentModel = value(TimelineModel::ModelRole).toString();
    return row;
  }

  QList<Row> rows() const {
    QList<Row> rows;
    for (int at = 0; at < model->rowCount(); ++at) rows.append(row(at));
    return rows;
  }

  // The rows equal what `expected` says the user should see, and the step
  // redrew exactly the rows that changed, for the roles that did.
  void check(const Model& expected) {
    const QList<Row> want = project(expected);
    RC_ASSERT(rows() == want);
    RC_ASSERT(model->property("count").toInt() == want.size());
    RC_ASSERT(modelTestFailures == 0);
    RC_ASSERT(model->hasEarlier() == expected.floor.has_value());
    RC_ASSERT(!model->loadingEarlier());
    // The timer counts from the earliest run still working: from when it began,
    // or from its message while its session starts.
    QDateTime since;
    for (const Run& run : expected.held.runs) {
      if (run.status != QLatin1String("running") && run.status != QLatin1String("starting")) continue;
      const bool begun = run.status == QLatin1String("running");
      const QDateTime asked = !begun && run.requestedAgo >= 0 ? clock().addSecs(-run.requestedAgo) : clock();
      if (!since.isValid() || asked < since) since = asked;
    }
    RC_ASSERT(model->working() == since.isValid());
    RC_ASSERT(model->workingSince() == since);
    for (const Row& row : want) {
      const Item item = expected.held.items.value(row.id);
      if (item.type != QLatin1String("user_message") || !item.legacy.isEmpty()) continue;
      RC_ASSERT(model->rewindPointOf(row.id).value(QStringLiteral("turn")).toInt() == turnOf(expected.held, item.run));
    }
    for (int row = 0; row < model->rowCount(); ++row) {
      const QString id = model->data(model->index(row), TimelineModel::IdRole).toString();
      const auto was = before.constFind(id);
      if (was == before.cend()) continue;
      const QHash<int, QVariant> now = roles(row);
      QList<int> changed;
      for (auto it = now.cbegin(); it != now.cend(); ++it) {
        if (was->value(it.key()) != it.value()) changed.append(it.key());
      }
      QList<int> covered;
      bool all = false;
      bool named = false;
      for (const auto& [redrawnId, roles] : std::as_const(redrawn)) {
        if (redrawnId != id) continue;
        named = true;
        all = all || roles.isEmpty();
        covered.append(roles);
      }
      if (changed.isEmpty()) {
        if (named) RC_LOG() << "redrawn unchanged: " << id.toStdString() << " roles " << rc::toString(covered) << "\n";
        RC_ASSERT_FALSE(named);  // a repaint for nothing
        continue;
      }
      for (const int role : std::as_const(changed)) RC_ASSERT(all || covered.contains(role));
    }
  }
};

// --- What the MC sends ----------------------------------------------------------

QJsonObject eventsFrame(const QList<Event>& events, qint64 offset) {
  QJsonArray list;
  for (const Event& event : events) {
    list.append(QJsonValue(QJsonArray{event.seq, event.kind, event.id, event.patch, QStringLiteral("2026-09-23T10:00:00Z")}));
  }
  return {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), offset}, {QStringLiteral("events"), list}};
}

QJsonValue nullable(std::optional<int> value) {
  return value ? QJsonValue(*value) : QJsonValue(QJsonValue::Null);
}

QJsonObject agentJson(const QString& id, const QString& model) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("model"), model}};
}

// The entity rows of `thread` a window from `floor` holds, or only the turn
// items of `runs`.
QJsonArray entityRows(const Thread& thread, std::optional<int> floor, const QSet<QString>* runs = nullptr) {
  QJsonArray rows;
  if (!runs) {
    for (const Run& run : thread.runs) rows.append(QJsonValue(QJsonArray{QStringLiteral("run"), run.id, json(run)}));
    for (auto it = thread.agents.cbegin(); it != thread.agents.cend(); ++it) {
      rows.append(QJsonValue(QJsonArray{QStringLiteral("subagent"), it.key(), agentJson(it.key(), *it)}));
    }
  }
  for (const Item& item : thread.items) {
    if (runs ? !runs->contains(item.run) : !holds(thread, item.run, floor)) continue;
    rows.append(QJsonValue(QJsonArray{QStringLiteral("turn-item"), item.id, json(item)}));
  }
  return rows;
}

// Splits `rows` into `parts` frames' worth.
QList<QJsonArray> split(const QJsonArray& rows, int parts) {
  if (parts <= 1 || rows.size() < 2) return {rows};
  const qsizetype half = rows.size() / 2;
  QJsonArray first;
  QJsonArray second;
  for (qsizetype i = 0; i < rows.size(); ++i) (i < half ? first : second).append(rows.at(i));
  return {first, second};
}

// Changes to the MC's thread, sent to the client when it follows and holds
// what they touch.
void commit(Model& model, const QList<Event>& events) {
  model.log.append(events);
  if (!model.live) return;
  QList<Event> sent;
  for (const Event& event : events) {
    if (event.kind != QLatin1String("turn-item") || holds(model.mc, event.run, model.floor)) sent.append(event);
  }
  model.held = window(model.mc, model.floor);
  // A commit that touches nothing the client holds is not sent (HalC2.Streams.Server), so its offset stays.
  if (sent.isEmpty()) return;
  model.offset = model.seq;
  model.lastEvents = eventsFrame(sent, model.seq);
}

void deliver(const Model& model, Sut& sut) {
  if (model.live && model.lastEvents != QJsonObject()) sut.send(model.lastEvents);
}

Event event(Model& model, const QString& kind, const QString& id, const QJsonObject& patch, const QString& run = {}) {
  return {++model.seq, kind, id, patch, run};
}

// --- Commands ---------------------------------------------------------------------

using Command = rc::state::Command<Model, Sut>;

// Commands that change the MC's thread apply to the model, then the frame
// they made (if the client follows) goes to the client.
struct Change : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    next.lastEvents = {};
    apply(next);
    sut.begin();
    deliver(next, sut);
    sut.check(next);
  }
};

// The MC numbers runs in start order: a run that starts takes the ordinal
// after every run that left the queue (a held run cancelled while held left
// it too and keeps its number), and the held runs still waiting move up
// behind it, each renumber a patch on a live run.
int startOrdinal(const Model& model) {
  int left = 0;
  for (const Run& run : model.mc.runs) {
    if (!(run.held && run.status == QLatin1String("queued"))) left = qMax(left, run.ordinal);
  }
  return left + 1;
}

QList<Event> renumberWaiting(Model& model, int after) {
  QList<Event> events;
  QStringList waiting;
  for (const Run& run : model.mc.runs) {
    if (run.held && run.status == QLatin1String("queued")) waiting.append(run.id);
  }
  // Runs are keyed in the order they were made (run-1, run-2, ...).
  for (const QString& id : waiting) {
    const int next = ++after;
    if (model.mc.runs[id].ordinal == next) continue;
    model.mc.runs[id].ordinal = next;
    events.append(event(model, QStringLiteral("run"), id, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("ordinal"), next}}}}));
  }
  model.ordinal = qMax(model.ordinal, after);
  return events;
}

// A new turn: its run and the message that asked for it, in one frame. The
// message is the user's, or the MC's to the agent: a notification, or what a
// thread stored of one before the MC recorded them so.
struct StartRun : Change {
  QString how;
  // The agent's session is still starting: the run is requested, not begun (Begin).
  bool starting = *rc::gen::weightedElement<bool>({{3, false}, {1, true}});
  int requestedAgo = *rc::gen::inRange(-1, 120);
  explicit StartRun(const Model&)
      : how(*rc::gen::weightedElement<QString>(
            {{4, QStringLiteral("user")}, {2, QStringLiteral("notification")}, {1, QStringLiteral("envelope")}, {1, QStringLiteral("wake")}})) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.runs.size() < kMaxRuns); }
  void apply(Model& model) const override {
    // A run that passes a held queue is numbered below it: the held runs are
    // renumbered up behind it in the same commit, as the MC does.
    Run run{QStringLiteral("run-%1").arg(model.mc.runs.size() + 1), startOrdinal(model), starting ? QStringLiteral("starting") : QStringLiteral("running")};
    run.requestedAgo = requestedAgo;
    model.mc.runs.insert(run.id, run);
    QList<Event> events{event(model, QStringLiteral("run"), run.id, {{QStringLiteral("s"), json(run)}})};
    events.append(renumberWaiting(model, run.ordinal));
    Item message{QStringLiteral("ask-") + run.id,
                 how == QLatin1String("notification") ? QStringLiteral("notification") : QStringLiteral("user_message"), run.id,
                 ++model.ordinal, QStringLiteral("ask"), false, QStringLiteral("completed")};
    message.opener = true;
    if (how == QLatin1String("envelope") || how == QLatin1String("wake")) message.legacy = how;
    model.mc.items.insert(message.id, message);
    events.append(event(model, QStringLiteral("turn-item"), message.id, {{QStringLiteral("s"), json(message)}}, run.id));
    commit(model, events);
  }
  void show(std::ostream& os) const override {
    os << "StartRun(" << how.toStdString() << (starting ? ", starting" : "") << ", requested " << requestedAgo << "s ago)";
  }
};

// The agent's session starts and it begins a run that was waiting for it.
struct Begin : Change {
  QString run;
  explicit Begin(const Model& model) {
    QStringList runs;
    for (const Run& found : model.mc.runs) {
      if (found.status == QLatin1String("starting")) runs.append(found.id);
    }
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.runs.value(run).status == QLatin1String("starting")); }
  void apply(Model& model) const override {
    model.mc.runs[run].status = QStringLiteral("running");
    commit(model, {event(model, QStringLiteral("run"), run,
                         {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("running")},
                                                            {QStringLiteral("startedAt"), clock().toString(Qt::ISODate)}}}})});
  }
  void show(std::ostream& os) const override { os << "Begin(" << run.toStdString() << ")"; }
};

// A queued message held for the user (it waited behind a stop) that a newer run
// passed: it waits, numbered above the runs that started, with nothing shown yet.
struct Hold : Change {
  explicit Hold(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.runs.size() < kMaxRuns); }
  void apply(Model& model) const override {
    Run run{QStringLiteral("run-%1").arg(model.mc.runs.size() + 1), ++model.ordinal, QStringLiteral("queued")};
    run.held = true;
    model.mc.runs.insert(run.id, run);
    commit(model, {event(model, QStringLiteral("run"), run.id, {{QStringLiteral("s"), json(run)}})});
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// A message queued behind the active turn: numbered when it was sent, with nothing
// shown yet. The model does not start one; a later StartRun passes it.
struct Enqueue : Change {
  explicit Enqueue(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.runs.size() < kMaxRuns); }
  void apply(Model& model) const override {
    const Run run{QStringLiteral("run-%1").arg(model.mc.runs.size() + 1), ++model.ordinal, QStringLiteral("queued")};
    model.mc.runs.insert(run.id, run);
    commit(model, {event(model, QStringLiteral("run"), run.id, {{QStringLiteral("s"), json(run)}})});
  }
  void show(std::ostream& os) const override { os << "Enqueue"; }
};

// The user cancels a message queued behind the active turn: it keeps its number
// and never started.
struct CancelQueued : Change {
  QString run;
  explicit CancelQueued(const Model& model) {
    QStringList runs;
    for (const Run& queued : model.mc.runs) {
      if (!queued.held && queued.status == QLatin1String("queued")) runs.append(queued.id);
    }
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
  }
  void checkPreconditions(const Model& model) const override {
    const Run found = model.mc.runs.value(run);
    RC_PRE(!found.held && found.status == QLatin1String("queued"));
  }
  void apply(Model& model) const override {
    model.mc.runs[run].status = QStringLiteral("cancelled");
    commit(model, {event(model, QStringLiteral("run"), run, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("cancelled")}}}})});
  }
  void show(std::ostream& os) const override { os << "CancelQueued(" << run.toStdString() << ")"; }
};

// The user cancels a held message instead of resuming the queue: the run keeps
// its hold and its number, and never started.
struct CancelHeld : Change {
  QString run;
  explicit CancelHeld(const Model& model) {
    QStringList runs;
    for (const Run& held : model.mc.runs) {
      if (held.held && held.status == QLatin1String("queued")) runs.append(held.id);
    }
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
  }
  void checkPreconditions(const Model& model) const override {
    const Run found = model.mc.runs.value(run);
    RC_PRE(found.held && found.status == QLatin1String("queued"));
  }
  void apply(Model& model) const override {
    model.mc.runs[run].status = QStringLiteral("cancelled");
    commit(model, {event(model, QStringLiteral("run"), run, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("cancelled")}}}})});
  }
  void show(std::ostream& os) const override { os << "CancelHeld(" << run.toStdString() << ")"; }
};

// The user resumes the queue and a held run starts: it takes the ordinal after
// every run that left the queue (a renumber patch on a live run), its hold
// clears, the runs still waiting move up behind it, and its message appears.
struct ResumeHeld : Change {
  QString run;
  explicit ResumeHeld(const Model& model) {
    QStringList runs;
    for (const Run& held : model.mc.runs) {
      if (held.held && held.status == QLatin1String("queued")) runs.append(held.id);
    }
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.mc.items.size() < kMaxItems);
    const Run found = model.mc.runs.value(run);
    RC_PRE(found.held && found.status == QLatin1String("queued"));
  }
  void apply(Model& model) const override {
    Run& started = model.mc.runs[run];
    started.ordinal = startOrdinal(model);
    started.status = QStringLiteral("running");
    started.held = false;
    QList<Event> events{event(model, QStringLiteral("run"), run,
                               {{QStringLiteral("s"),
                                 QJsonObject{{QStringLiteral("ordinal"), started.ordinal},
                                             {QStringLiteral("status"), QStringLiteral("running")},
                                             {QStringLiteral("queueHeld"), false},
                                             {QStringLiteral("startedAt"), clock().toString(Qt::ISODate)}}}})};
    events.append(renumberWaiting(model, started.ordinal));
    Item message{QStringLiteral("ask-") + run, QStringLiteral("user_message"), run, ++model.ordinal, QStringLiteral("ask"), false,
                 QStringLiteral("completed")};
    message.opener = true;
    model.mc.items.insert(message.id, message);
    events.append(event(model, QStringLiteral("turn-item"), message.id, {{QStringLiteral("s"), json(message)}}, run));
    commit(model, events);
  }
  void show(std::ostream& os) const override { os << "ResumeHeld(" << run.toStdString() << ")"; }
};

QStringList running(const Model& model) {
  QStringList runs;
  for (const Run& run : model.mc.runs) {
    if (run.status == QLatin1String("running")) runs.append(run.id);
  }
  return runs;
}

// The agent starts a reply, a call, a plan, a subagent or an error in a running turn.
struct AddItem : Change {
  QString run;
  QString type;
  QString agent;
  // An error that is the provider's usage limit.
  bool limit = false;
  // A command that drove an app.
  bool app = false;
  explicit AddItem(const Model& model) {
    const QStringList runs = running(model);
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
    type = *rc::gen::weightedElement<QString>({{4, QStringLiteral("assistant_message")},
                                               {4, QStringLiteral("command_execution")},
                                               {2, QStringLiteral("reasoning")},
                                               {1, QStringLiteral("proposed_plan")},
                                               {1, QStringLiteral("subagent")},
                                               {1, QStringLiteral("error")},
                                               {1, QStringLiteral("notification")}});
    if (type == QLatin1String("subagent")) agent = pick(kAgents);
    if (type == QLatin1String("error")) limit = *rc::gen::arbitrary<bool>();
    if (type == QLatin1String("command_execution")) app = *rc::gen::arbitrary<bool>();
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.mc.items.size() < kMaxItems);
    RC_PRE(model.mc.runs.value(run).status == QLatin1String("running"));
  }
  void apply(Model& model) const override {
    Item item{QStringLiteral("%1-%2").arg(type.left(4)).arg(model.ordinal + 1), type, run, ++model.ordinal};
    item.text = type == QLatin1String("command_execution") ? QString() : limit ? QStringLiteral("limit") : QStringLiteral("t");
    item.streaming = type == QLatin1String("assistant_message");
    item.status = type == QLatin1String("command_execution") ? QStringLiteral("running") : QStringLiteral("completed");
    item.agent = agent;
    item.app = app;
    model.mc.items.insert(item.id, item);
    commit(model, {event(model, QStringLiteral("turn-item"), item.id, {{QStringLiteral("s"), json(item)}}, run)});
  }
  void show(std::ostream& os) const override {
    os << "AddItem(" << type.toStdString() << (app ? " of the app" : "") << " in " << run.toStdString() << ")";
  }
};

QStringList itemsWhere(const Model& model, const std::function<bool(const Item&)>& keep) {
  QStringList ids;
  for (const Item& item : model.mc.items) {
    if (model.mc.runs.value(item.run).status == QLatin1String("running") && keep(item)) ids.append(item.id);
  }
  return ids;
}

bool streams(const Item& item) {
  if (item.type == QLatin1String("assistant_message")) return item.streaming;
  if (item.type == QLatin1String("command_execution")) return item.status == QLatin1String("running");
  return item.type == QLatin1String("reasoning") || item.type == QLatin1String("proposed_plan") || item.type == QLatin1String("subagent");
}

// Streamed text (or output) appended to an item of a running turn.
struct Delta : Change {
  QString item;
  QString chunk;
  explicit Delta(const Model& model) {
    const QStringList ids = itemsWhere(model, streams);
    RC_PRE(!ids.isEmpty());
    item = pick(ids);
    chunk = pick(QStringList{QStringLiteral("a"), QStringLiteral("bc"), QStringLiteral("d")});
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.mc.items.contains(item) && model.mc.runs.value(model.mc.items.value(item).run).status == QLatin1String("running"));
    RC_PRE(streams(model.mc.items.value(item)));
  }
  void apply(Model& model) const override {
    Item& target = model.mc.items[item];
    target.text += chunk;
    commit(model, {event(model, QStringLiteral("turn-item"), item, {{QStringLiteral("a"), QJsonObject{{field(target.type), chunk}}}}, target.run)});
  }
  void show(std::ostream& os) const override { os << "Delta(" << item.toStdString() << " += " << chunk.toStdString() << ")"; }
};

// A subagent's model is learned or changes (or is set again to the same).
struct AgentModel : Change {
  QString agent;
  QString name;
  explicit AgentModel(const Model&) {
    agent = pick(kAgents);
    name = pick(QStringList{QStringLiteral("opus"), QStringLiteral("sonnet")});
  }
  void apply(Model& model) const override {
    model.mc.agents.insert(agent, name);
    commit(model, {event(model, QStringLiteral("subagent"), agent, {{QStringLiteral("s"), agentJson(agent, name)}})});
  }
  void show(std::ostream& os) const override { os << "AgentModel(" << agent.toStdString() << " = " << name.toStdString() << ")"; }
};

// A reply finishes streaming, or a call ends (completed or failed).
struct Finish : Change {
  QString item;
  QString status;
  explicit Finish(const Model& model) {
    const QStringList ids = itemsWhere(model, [](const Item& item) {
      return item.streaming || item.status == QLatin1String("running");
    });
    RC_PRE(!ids.isEmpty());
    item = pick(ids);
    status = pick(QStringList{QStringLiteral("completed"), QStringLiteral("failed")});
  }
  void checkPreconditions(const Model& model) const override {
    const Item found = model.mc.items.value(item);
    RC_PRE(found.streaming || found.status == QLatin1String("running"));
  }
  void apply(Model& model) const override {
    Item& target = model.mc.items[item];
    QJsonObject set;
    if (target.streaming) {
      target.streaming = false;
      set.insert(QStringLiteral("streaming"), false);
    } else {
      target.status = status;
      set.insert(QStringLiteral("status"), status);
    }
    commit(model, {event(model, QStringLiteral("turn-item"), item, {{QStringLiteral("s"), set}}, target.run)});
  }
  void show(std::ostream& os) const override { os << "Finish(" << item.toStdString() << ", " << status.toStdString() << ")"; }
};

// The MC takes back an item of a running turn.
struct DeleteItem : Change {
  QString item;
  explicit DeleteItem(const Model& model) {
    const QStringList ids = itemsWhere(model, [](const Item& item) { return !item.opener; });
    RC_PRE(!ids.isEmpty());
    item = pick(ids);
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.mc.items.contains(item) && model.mc.runs.value(model.mc.items.value(item).run).status == QLatin1String("running"));
  }
  void apply(Model& model) const override {
    const QString run = model.mc.items.take(item).run;
    commit(model, {event(model, QStringLiteral("turn-item"), item, {{QStringLiteral("d"), true}}, run)});
  }
  void show(std::ostream& os) const override { os << "DeleteItem(" << item.toStdString() << ")"; }
};

// A turn settles, in one frame with its replies finishing (before or after
// the run's status), or with them left streaming.
struct Settle : Change {
  QString run;
  QString status;
  bool finish = true;
  bool finishFirst = true;
  explicit Settle(const Model& model) {
    const QStringList runs = running(model);
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
    status = pick(QStringList{QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("interrupted")});
    finish = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
    finishFirst = *rc::gen::arbitrary<bool>();
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.runs.value(run).status == QLatin1String("running")); }
  void apply(Model& model) const override {
    QList<Event> events;
    const auto finishReplies = [&] {
      if (!finish) return;
      for (Item& item : model.mc.items) {
        if (item.run != run || !item.streaming) continue;
        item.streaming = false;
        events.append(event(model, QStringLiteral("turn-item"), item.id, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("streaming"), false}}}}, run));
      }
    };
    if (finishFirst) finishReplies();
    model.mc.runs[run].status = status;
    events.append(event(model, QStringLiteral("run"), run, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), status}}}}));
    if (!finishFirst) finishReplies();
    commit(model, events);
  }
  void show(std::ostream& os) const override {
    os << "Settle(" << run.toStdString() << ", " << status.toStdString() << (finish ? finishFirst ? ", replies first" : ", replies after" : ", replies left") << ")";
  }
};

// A settled turn rolled back (the user rewound past it): its rows go.
struct RollBack : Change {
  QString run;
  explicit RollBack(const Model& model) {
    QStringList runs;
    for (const Run& run : model.mc.runs) {
      if (settled(run)) runs.append(run.id);
    }
    RC_PRE(!runs.isEmpty());
    run = pick(runs);
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(settled(model.mc.runs.value(run))); }
  void apply(Model& model) const override {
    model.mc.runs[run].status = QStringLiteral("rolled_back");
    commit(model, {event(model, QStringLiteral("run"), run, {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("rolled_back")}}}})});
  }
  void show(std::ostream& os) const override { os << "RollBack(" << run.toStdString() << ")"; }
};

// The client (re)subscribes: its `sub` frame says where its copy stands, and
// the MC answers with a snapshot or the events since, in `parts` frames, then
// `live`. `cut`: the connection drops after the first part.
struct Subscribe : Command {
  int parts = 1;
  bool cut = false;
  explicit Subscribe(const Model&) {
    parts = *rc::gen::inRange(1, 3);
    cut = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.live); }

  bool fresh(const Model& model) const { return model.offset < 0 || model.heldHandle != model.handle; }

  void apply(Model& model) const override {
    if (cut) return;
    if (fresh(model) && model.offset < 0) model.floor = takeRuns(model.mc, std::nullopt, kWindow).second;
    model.live = true;
    model.offset = model.seq;
    model.heldHandle = model.handle;
    model.held = window(model.mc, model.floor);
    model.lastEvents = {};
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    const QJsonObject sub = sut.model->subscribing();
    // Where the copy stands, or the window to open with.
    const QJsonObject window = sub.value(QLatin1String("window")).toObject();
    if (model.offset < 0) {
      RC_ASSERT(sub.value(QLatin1String("offset")).isNull());
      RC_ASSERT(window.value(QLatin1String("items")).toInt() == TimelineModel::windowItems);
    } else {
      RC_ASSERT(qint64(sub.value(QLatin1String("offset")).toDouble()) == model.offset);
      RC_ASSERT(sub.value(QLatin1String("handle")).toString() == QStringLiteral("log-%1").arg(model.heldHandle));
      RC_ASSERT(window.value(QLatin1String("floor")) == nullable(model.floor));
    }
    const QString handle = QStringLiteral("log-%1").arg(model.handle);
    QList<QJsonObject> frames;
    if (fresh(model)) {
      // A new copy opens with the newest runs; one of another log keeps its window.
      const std::optional<int> floor = model.offset < 0 ? takeRuns(model.mc, std::nullopt, kWindow).second : model.floor;
      const QList<QJsonArray> chunks = split(entityRows(model.mc, floor), parts);
      for (qsizetype i = 0; i < chunks.size(); ++i) {
        frames.append({{QStringLiteral("t"), QStringLiteral("snapshot")},
                       {QStringLiteral("part"), int(i)},
                       {QStringLiteral("rows"), chunks.at(i)},
                       {QStringLiteral("done"), i + 1 == chunks.size()},
                       {QStringLiteral("offset"), model.seq},
                       {QStringLiteral("handle"), handle},
                       {QStringLiteral("floor"), nullable(floor)}});
      }
    } else {
      QList<Event> missed;
      for (const Event& event : model.log) {
        if (event.seq <= model.offset) continue;
        if (event.kind == QLatin1String("turn-item") && !holds(model.mc, event.run, model.floor)) continue;
        missed.append(event);
      }
      // Parts before the last carry the offset the client is at; the last the one they bring it to.
      if (parts > 1 && missed.size() > 1) {
        const qsizetype half = missed.size() / 2;
        frames.append(eventsFrame(missed.mid(0, half), model.offset));
        frames.append(eventsFrame(missed.mid(half), model.seq));
      } else if (!missed.isEmpty()) {
        frames.append(eventsFrame(missed, model.seq));
      }
    }
    frames.append({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), model.seq}, {QStringLiteral("handle"), handle}});
    if (cut) {
      // Only a first part that is not the whole answer arrives.
      if (frames.size() > 2) sut.send(frames.first());
    } else {
      for (const QJsonObject& frame : std::as_const(frames)) sut.send(frame);
      RC_ASSERT(sut.model->status() == QStringLiteral("live"));
      RC_ASSERT(sut.model->cursor().offset == next.offset);
    }
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Subscribe(" << parts << " parts" << (cut ? ", cut off" : "") << ")"; }
};

// The connection drops; changes go on without the client.
struct Drop : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.live); }
  void apply(Model& model) const override {
    model.live = false;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    sut.begin();
    Model next = model;
    apply(next);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

// The MC restarts on a new log: offsets into the old one mean nothing.
struct NewLog : Drop {
  void checkPreconditions(const Model&) const override {}
  void apply(Model& model) const override {
    Drop::apply(model);
    ++model.handle;
  }
  void show(std::ostream& os) const override { os << "NewLog"; }
};

// The last events frame arrives again.
struct Duplicate : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.live && model.lastEvents != QJsonObject()); }
  void run(const Model& model, Sut& sut) const override {
    sut.begin();
    sut.send(model.lastEvents);
    sut.check(model);
  }
  void show(std::ostream& os) const override { os << "Duplicate"; }
};

// The user scrolls to the top: the runs before the window come as a page,
// in `parts` frames, the second after a change the stream sent between them.
// `cut`: the connection drops after the first part.
struct LoadEarlier : Command {
  int parts = 1;
  bool cut = false;
  explicit LoadEarlier(const Model&) {
    parts = *rc::gen::inRange(1, 3);
    cut = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.live && model.floor.has_value()); }
  void apply(Model& model) const override {
    if (cut) {
      model.live = false;
      model.lastEvents = {};
      return;
    }
    model.floor = takeRuns(model.mc, model.floor, kWindow).second;
    model.held = window(model.mc, model.floor);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.earlierWanted = 0;
    sut.model->loadEarlier();
    RC_ASSERT(sut.earlierWanted == 1);
    RC_ASSERT(sut.model->loadingEarlier());
    // Asked again while it comes, it is not asked for twice.
    sut.model->loadEarlier();
    RC_ASSERT(sut.earlierWanted == 1);
    const auto [runs, floor] = takeRuns(model.mc, model.floor, kWindow);
    const QList<QJsonArray> chunks = split(entityRows(model.mc, std::nullopt, &runs), parts);
    for (qsizetype i = 0; i < chunks.size(); ++i) {
      // Cut off, only a first part that is not the whole page arrives.
      if (cut && i + 1 == chunks.size()) break;
      sut.send({{QStringLiteral("t"), QStringLiteral("page")},
                {QStringLiteral("rows"), chunks.at(i)},
                {QStringLiteral("done"), i + 1 == chunks.size()},
                {QStringLiteral("offset"), model.seq},
                {QStringLiteral("floor"), nullable(floor)}});
    }
    if (cut) {
      // ThreadStore says it is no longer live; a page cut off is dropped with the subscription.
      sut.model->setStatus(QStringLiteral("unreachable"));
      sut.model->setStatus(QStringLiteral("loading"));
    }
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "LoadEarlier(" << parts << " parts" << (cut ? ", cut off" : "") << ")"; }
};

// The user reads from row `at` on: the turns far above it are let go of and
// the subscription is made again from the raised floor (ThreadStore), which
// Subscribe answers; scrolling back up fetches them again (LoadEarlier).
struct KeepFrom : Command {
  int at = 0;
  explicit KeepFrom(const Model& model) {
    const int rows = std::max<int>(1, project(model).size());
    // Mostly the last, as the view following the end and a thread left read.
    at = *rc::gen::weightedOneOf<int>({{1, rc::gen::inRange<int>(0, rows)}, {2, rc::gen::just(rows - 1)}});
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.live && at < project(model).size()); }

  // The floor the window rises to, when that frees at least kKeep turn
  // items: kKeep of them stay above the run read (the oldest queued one,
  // if older), the oldest of the rows from `at` on.
  std::optional<int> raised(const Model& model) const {
    const QList<Row> rows = project(model);
    std::optional<int> reading;
    for (qsizetype i = at; i < rows.size(); ++i) {
      const Row& row = rows.at(i);
      QString run;
      if (row.id.startsWith(QLatin1String("fold:"))) {
        run = row.id.mid(5);
      } else if (model.held.items.contains(row.id)) {
        run = model.held.items.value(row.id).run;
      } else if (!row.entries.isEmpty()) {
        run = model.held.items.value(row.entries.first()).run;
      }
      if (!run.isEmpty()) reading = std::min(reading.value_or(INT_MAX), model.held.runs.value(run).ordinal);
    }
    if (!reading) return std::nullopt;
    for (const Run& run : model.held.runs) {
      if (run.status == QLatin1String("queued")) reading = std::min(*reading, run.ordinal);
    }
    const std::optional<int> floor = takeRuns(model.held, reading, kKeep).second;
    if (!floor) return std::nullopt;
    int dropped = 0;
    for (const Item& item : model.held.items) {
      const Run& run = model.held.runs.value(item.run);
      if (run.status != QLatin1String("rolled_back") && run.ordinal < *floor) ++dropped;
    }
    if (dropped < kKeep) return std::nullopt;
    return floor;
  }

  void apply(Model& model) const override {
    const std::optional<int> floor = raised(model);
    if (!floor) return;
    model.floor = floor;
    model.held = window(model.mc, floor);
    model.live = false;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.raised = 0;
    sut.model->keepFrom(at);
    RC_ASSERT(sut.raised == (next.live ? 0 : 1));
    RC_TAG(next.live ? "kept every turn" : "let turns go");
    // Nothing it let go of is kept out of sight.
    if (next.floor) {
      for (const QJsonObject& item : sut.model->entities(QStringLiteral("turn-item"))) {
        RC_ASSERT(next.mc.runs.value(item.value(QLatin1String("runId")).toString()).ordinal >= *next.floor);
      }
    }
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "KeepFrom(" << at << ")"; }
};

// The user opens or closes a fold or a work group.
struct Toggle : Command {
  QString row;
  explicit Toggle(const Model& model) {
    QStringList ids;
    for (const Row& row : project(model)) {
      if (row.kind == QLatin1String("fold") || row.kind == QLatin1String("work")) ids.append(row.id);
    }
    RC_PRE(!ids.isEmpty());
    row = pick(ids);
  }
  void checkPreconditions(const Model& model) const override {
    const QList<Row> rows = project(model);
    RC_PRE(std::any_of(rows.cbegin(), rows.cend(), [&](const Row& shown) { return shown.id == row; }));
  }
  void apply(Model& model) const override {
    QSet<QString>& open = row.startsWith(QLatin1String("fold:")) ? model.foldsOpen : model.groupsToggled;
    const QString key = row.startsWith(QLatin1String("fold:")) ? row.mid(5) : row;
    if (!open.remove(key)) open.insert(key);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.model->toggle(row);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Toggle(" << row.toStdString() << ")"; }
};

// The environment signs the app's icon's address (again, or for the first
// time), or an image in the workspace no call here looked at: the calls of the
// app on screen show the icon, and nothing else redraws.
struct SignIcon : Command {
  bool image = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (!image) model.appSigned = true;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    if (image) {
      sut.model->setAttachmentUrl(QStringLiteral("workspace-file:shot.png"), QUrl(QStringLiteral("http://mc.test/api/assets/shot")), clock().addSecs(3600));
    } else {
      sut.model->setAttachmentUrl(kAppIcon, kAppIconUrl, clock().addSecs(3600));
    }
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << (image ? "SignImage" : "SignIcon"); }
};

// The window crosses the phone layout's width, and the timeline reads as the
// phone or the desktop does.
struct Layout : Command {
  void apply(Model& model) const override { model.phone = !model.phone; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.phone = next.phone;
    sut.model->setFolds(next.phone ? TimelineModel::Folds::Phone : TimelineModel::Folds::Desktop);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Layout"; }
};

// The app restarts (or the thread was evicted and opened again): the thread
// parks into the cache, and a new model restores it from there.
struct Restart : Command {
  void apply(Model& model) const override {
    model.live = false;
    model.lastEvents = {};
    model.foldsOpen.clear();
    model.groupsToggled.clear();
    model.appSigned = false;
    if (model.offset < 0) model.held = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.model->park();
    sut.make();
    cache::Thread kept;
    sut.cache.loadThread(kKey, &sut.cache, [&kept](const cache::Thread& thread) { kept = thread; });
    sut.cache.drain();
    sut.begin();
    sut.model->restore(kept);
    RC_ASSERT(sut.model->cursor().offset == next.offset);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class TimelineModelProp : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { previousHandler = qInstallMessageHandler(countModelTestFailures); }
  void cleanupTestCase() { qInstallMessageHandler(previousHandler); }

  void stream() {
    QVERIFY(rc::check("the rows are the MC's thread as the client holds it, redrawn only where they changed", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<StartRun, Begin, Hold, Enqueue, CancelHeld, CancelQueued, ResumeHeld, AddItem, AddItem, Delta, Delta, Delta, Finish, Finish, DeleteItem,
                                                         Settle, Settle, RollBack, Subscribe, Subscribe, Drop, NewLog, Duplicate,
                                                         LoadEarlier, LoadEarlier, KeepFrom, KeepFrom, Toggle, Layout, Restart, AgentModel, SignIcon>());
    }));
  }

  void summary() {
    QVERIFY(rc::check("a group's summary is a fold of its calls", [] {
      const auto calls = *rc::gen::container<std::vector<Call>>(*rc::gen::inRange(0, 9), genCall());
      QList<QJsonObject> items;
      for (const Call& call : calls) items.append(json(call));
      const timeline::GroupSummary want = expectedSummary(QList<Call>(calls.cbegin(), calls.cend()));
      const timeline::GroupSummary got = timeline::summarize(items);
      RC_ASSERT(got.text == want.text);
      RC_ASSERT(got.failed == want.failed);
    }));
  }
};

HAL_C2_PROP_MAIN(TimelineModelProp)
#include "tst_TimelineModelProp.moc"
