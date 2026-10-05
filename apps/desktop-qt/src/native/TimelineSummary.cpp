#include "TimelineSummary.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>
#include <optional>

namespace timeline {

namespace {

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// packages/shared/src/halC2McpToolPresentation.ts: the orchestration tools a
// summary describes by what they did. The rest of HAL-C2's tools are counted
// as tools used.
const QHash<QString, QString>& orchestrationActions() {
  static const QHash<QString, QString> actions{
      {QStringLiteral("hal_c2_thread_send"), QStringLiteral("thread-send")},
      {QStringLiteral("create_threads"), QStringLiteral("thread-create")},
      {QStringLiteral("hal_c2_thread_start"), QStringLiteral("thread-create")},
      {QStringLiteral("hal_c2_thread_launch"), QStringLiteral("thread-create")},
      {QStringLiteral("delegate_task"), QStringLiteral("delegate")},
      {QStringLiteral("hal_c2_thread_read"), QStringLiteral("thread-read")},
      {QStringLiteral("hal_c2_thread_wait"), QStringLiteral("thread-wait")},
  };
  return actions;
}

// resolveHalC2McpToolName: agents prefix the HAL-C2 server's tools their own
// way (`mcp__hal-c2__x`, `hal-c2.x`, a bare `x`).
QString orchestrationAction(const QString& toolName) {
  static const QRegularExpression done(QStringLiteral("\\s+(?:complete|completed)\\s*$"),
                                       QRegularExpression::CaseInsensitiveOption);
  QString label = toolName;
  label = label.remove(done).trimmed();
  static const QRegularExpression mcp(QStringLiteral("^mcp__(.+?)__(.+)$"), QRegularExpression::CaseInsensitiveOption);
  static const QSet<QString> servers{QStringLiteral("hal-c2"), QStringLiteral("hal_c2"), QStringLiteral("halc2")};
  if (const auto match = mcp.match(label); match.hasMatch()) {
    return servers.contains(match.captured(1).toLower()) ? orchestrationActions().value(match.captured(2)) : QString();
  }
  static const QRegularExpression scoped(QStringLiteral("^hal[-_]?c2(?:[.:/]|\\s*·\\s*)(.+)$"),
                                         QRegularExpression::CaseInsensitiveOption);
  if (const auto match = scoped.match(label); match.hasMatch()) return orchestrationActions().value(match.captured(1));
  return orchestrationActions().value(label);
}

// An MCP result as the provider adapters keep it: the data it carries and
// whether it reports an error (halC2ToolSummary.ts readResult).
struct Result {
  QJsonObject data;
  bool failed = false;
};

Result readResult(const QJsonValue& value, int depth = 0) {
  if (depth > 4) return {};
  if (value.isString()) {
    QJsonParseError error;
    const QJsonDocument parsed = QJsonDocument::fromJson(value.toString().toUtf8(), &error);
    if (error.error != QJsonParseError::NoError) return {};
    return readResult(parsed.isArray() ? QJsonValue(parsed.array()) : QJsonValue(parsed.object()), depth + 1);
  }
  if (value.isArray()) {
    Result result;
    for (const QJsonValue& block : value.toArray()) {
      const QJsonObject record = block.toObject();
      QJsonValue inner = record.value(QLatin1String("text"));
      if (inner.isUndefined()) inner = record.value(QLatin1String("content")).toObject().value(QLatin1String("text"));
      const Result read = readResult(inner, depth + 1);
      if (result.data.isEmpty()) result.data = read.data;
      result.failed = result.failed || read.failed;
    }
    return result;
  }
  if (!value.isObject()) return {};
  const QJsonObject record = value.toObject();
  static const QRegularExpression errorTag(QStringLiteral("(?:Error|Failure)$"));
  const QJsonValue error = record.value(QLatin1String("error"));
  const bool failed = record.value(QLatin1String("isError")).toBool() || record.value(QLatin1String("is_error")).toBool() ||
                      errorTag.match(text(record, QLatin1String("_tag"))).hasMatch() ||
                      !(error.isUndefined() || error.isNull());
  QJsonValue content = record.value(QLatin1String("structuredContent"));
  if (content.isUndefined()) content = record.value(QLatin1String("content"));
  if (!content.isUndefined()) {
    Result result = readResult(content, depth + 1);
    result.failed = result.failed || failed;
    return result;
  }
  return {record, failed};
}

// Cursor keeps its MCP arguments in an envelope; other adapters keep them as they are.
QJsonObject readInput(const QJsonValue& value) {
  const QJsonObject input = readResult(value).data;
  return input.value(QLatin1String("toolName")).isString() ? input.value(QLatin1String("args")).toObject() : input;
}

std::optional<QString> idOf(const QJsonValue& value) {
  return value.isString() && !value.toString().trimmed().isEmpty() ? std::optional(value.toString()) : std::nullopt;
}

// Distinct ids, plus every call that named none.
int countEntities(const QList<std::optional<QString>>& ids) {
  QSet<QString> known;
  int unknown = 0;
  for (const auto& id : ids) {
    if (id) {
      known.insert(*id);
    } else {
      ++unknown;
    }
  }
  return int(known.size()) + unknown;
}

QString quantity(int count, const QString& noun) {
  return QStringLiteral("%1 %2%3").arg(count).arg(noun, count == 1 ? QString() : QStringLiteral("s"));
}

enum class Outcome { Completed, Failed, Unfinished };

struct Call {
  QJsonObject input;
  QJsonObject output;
  Outcome outcome = Outcome::Unfinished;
};

Call orchestrationCall(const QJsonObject& item) {
  const Result result = readResult(item.value(QLatin1String("output")));
  const QString status = text(item, QLatin1String("status"));
  Outcome outcome = Outcome::Unfinished;
  if (result.failed || status == QLatin1String("failed") || status == QLatin1String("declined")) {
    outcome = Outcome::Failed;
  } else if (status == QLatin1String("completed")) {
    outcome = Outcome::Completed;
  }
  return {readInput(item.value(QLatin1String("input"))), result.data, outcome};
}

// summarizeHalC2ToolCalls: what the calls that went through did; "Tried to"
// when none did.
QString orchestrationLabel(const QString& action, const QList<Call>& calls) {
  QList<Call> completed;
  for (const Call& call : calls) {
    if (call.outcome == Outcome::Completed) completed.append(call);
  }
  const QList<Call>& selected = completed.isEmpty() ? calls : completed;
  const auto phrase = [&](const QString& past, const QString& infinitive, const QString& object) {
    return QStringLiteral("%1 %2").arg(completed.isEmpty() ? QStringLiteral("Tried to ") + infinitive : past, object);
  };
  QList<std::optional<QString>> threads;
  for (const Call& call : selected) {
    std::optional<QString> thread = idOf(call.output.value(QLatin1String("threadId")));
    if (!thread) thread = idOf(call.output.value(QLatin1String("thread")).toObject().value(QLatin1String("threadId")));
    if (!thread) thread = idOf(call.input.value(QLatin1String("threadId")));
    threads.append(thread);
  }
  const bool targetsKnown = std::all_of(threads.cbegin(), threads.cend(), [](const auto& id) { return id.has_value(); });
  const auto distinctThreads = [&] {
    QSet<QString> distinct;
    for (const auto& id : threads) distinct.insert(*id);
    return int(distinct.size());
  };
  const QString times = quantity(int(selected.size()), QStringLiteral("time"));

  if (action == QLatin1String("thread-send")) {
    QList<std::optional<QString>> messageIds;
    for (const Call& call : selected) messageIds.append(idOf(call.output.value(QLatin1String("messageId"))));
    const int messages = countEntities(messageIds);
    if (!targetsKnown) return phrase(QStringLiteral("Sent"), QStringLiteral("send"), quantity(messages, QStringLiteral("message")));
    const int count = distinctThreads();
    const QString object = messages == count && messages > 1
                               ? QStringLiteral("messages to %1").arg(quantity(count, QStringLiteral("thread")))
                               : QStringLiteral("%1 to %2").arg(quantity(messages, QStringLiteral("message")), quantity(count, QStringLiteral("thread")));
    return phrase(QStringLiteral("Sent"), QStringLiteral("send"), object);
  }
  if (action == QLatin1String("thread-create")) {
    QSet<QString> created;
    bool known = !completed.isEmpty();
    for (const Call& call : completed) {
      const QJsonValue listed = call.output.value(QLatin1String("threads"));
      const QJsonArray outputs = listed.isArray() ? listed.toArray() : QJsonArray{call.output};
      for (const QJsonValue& value : outputs) {
        const QJsonObject thread = value.toObject();
        if (text(thread, QLatin1String("status")) == QLatin1String("rolled_back")) continue;
        const auto id = idOf(thread.value(QLatin1String("threadId")));
        if (!id) {
          known = false;
        } else {
          created.insert(*id);
        }
      }
    }
    return known ? QStringLiteral("Created %1").arg(quantity(int(created.size()), QStringLiteral("thread")))
                 : QStringLiteral("Requested thread creation %1").arg(times);
  }
  if (action == QLatin1String("delegate")) {
    QList<std::optional<QString>> tasks;
    for (const Call& call : selected) {
      std::optional<QString> task = idOf(call.output.value(QLatin1String("taskId")));
      if (!task) task = idOf(call.input.value(QLatin1String("taskId")));
      tasks.append(task);
    }
    return phrase(QStringLiteral("Delegated"), QStringLiteral("delegate"), quantity(countEntities(tasks), QStringLiteral("task")));
  }
  // thread-read and thread-wait.
  const QString targets = targetsKnown ? quantity(distinctThreads(), QStringLiteral("thread")) : QStringLiteral("threads %1").arg(times);
  return action == QLatin1String("thread-read") ? phrase(QStringLiteral("Read"), QStringLiteral("read"), targets)
                                                : phrase(QStringLiteral("Waited on"), QStringLiteral("wait on"), targets);
}

// toolGroupAction: what kind of work a call was.
QString actionOf(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("thread_created")) return QStringLiteral("thread-create");
  if (type == QLatin1String("approval_request") && text(item, QLatin1String("requestKind")) == QLatin1String("file-read")) {
    return QStringLiteral("read");
  }
  if (type == QLatin1String("dynamic_tool")) {
    static const QRegularExpression read(QStringLiteral("^read(?:\\s+file)?$"), QRegularExpression::CaseInsensitiveOption);
    const QString title = text(item, QLatin1String("title")).trimmed();
    if (item.contains(QLatin1String("viewedImagePath")) ||
        read.match(title.isEmpty() ? text(item, QLatin1String("toolName")).trimmed() : title).hasMatch()) {
      return QStringLiteral("read");
    }
    return QStringLiteral("other");
  }
  if (isFileRead(item)) return QStringLiteral("read");
  if (type == QLatin1String("file_change")) return QStringLiteral("edit");
  if (type == QLatin1String("command_execution")) return QStringLiteral("command");
  if (type == QLatin1String("file_search")) return QStringLiteral("code-search");
  if (type == QLatin1String("web_search")) return QStringLiteral("search");
  // Notices and plan updates are news, not tools.
  if (type == QLatin1String("system_notice") || type == QLatin1String("todo_list") ||
      type == QLatin1String("run_interrupt_request") || type == QLatin1String("run_interrupt_result")) {
    return QStringLiteral("update");
  }
  return QStringLiteral("other");
}

// toolGroupActionLabel.
QString actionLabel(const QString& action, int count) {
  const bool one = count == 1;
  if (action == QLatin1String("read")) return QStringLiteral("Read %1 %2").arg(count).arg(one ? QStringLiteral("file") : QStringLiteral("files"));
  if (action == QLatin1String("edit")) return QStringLiteral("Changed %1 %2").arg(count).arg(one ? QStringLiteral("file") : QStringLiteral("files"));
  if (action == QLatin1String("command")) return QStringLiteral("Ran %1 %2").arg(count).arg(one ? QStringLiteral("command") : QStringLiteral("commands"));
  if (action == QLatin1String("thread-create")) return QStringLiteral("Created %1 %2").arg(count).arg(one ? QStringLiteral("thread") : QStringLiteral("threads"));
  if (action == QLatin1String("search")) return QStringLiteral("Searched the web %1 %2").arg(count).arg(one ? QStringLiteral("time") : QStringLiteral("times"));
  if (action == QLatin1String("code-search")) return QStringLiteral("Searched code %1 %2").arg(count).arg(one ? QStringLiteral("time") : QStringLiteral("times"));
  if (action == QLatin1String("update")) return QStringLiteral("Received %1 %2").arg(count).arg(one ? QStringLiteral("update") : QStringLiteral("updates"));
  return QStringLiteral("Used %1 %2").arg(count).arg(one ? QStringLiteral("tool") : QStringLiteral("tools"));
}

// summaryActionPriority: what changed something comes before what only looked.
int priority(const QString& action) {
  static const QSet<QString> first{QStringLiteral("command"), QStringLiteral("edit"), QStringLiteral("delegate"),
                                   QStringLiteral("thread-create"), QStringLiteral("thread-send")};
  if (first.contains(action)) return 0;
  return action == QLatin1String("other") || action == QLatin1String("update") ? 2 : 1;
}

}  // namespace

bool isFileRead(const QJsonObject& item) {
  if (text(item, QLatin1String("type")) != QLatin1String("file_search")) return false;
  const QJsonArray results = item.value(QLatin1String("results")).toArray();
  return results.size() == 1 && !text(item, QLatin1String("pattern")).isEmpty() &&
         text(results.first().toObject(), QLatin1String("fileName")) == text(item, QLatin1String("pattern"));
}

bool callFailed(const QJsonObject& item) {
  const QString status = text(item, QLatin1String("status"));
  if (status == QLatin1String("failed") || status == QLatin1String("declined")) return true;
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("command_execution")) {
    const QJsonValue exitCode = item.value(QLatin1String("exitCode"));
    return item.value(QLatin1String("outputIndicatesFailure")).toBool() || (exitCode.isDouble() && exitCode.toInt() != 0);
  }
  return type == QLatin1String("dynamic_tool") && !orchestrationAction(text(item, QLatin1String("toolName"))).isEmpty() &&
         readResult(item.value(QLatin1String("output"))).failed;
}

GroupSummary summarize(const QList<QJsonObject>& all) {
  QList<QJsonObject> items;
  for (const QJsonObject& item : all) {
    if (text(item, QLatin1String("type")) != QLatin1String("reasoning")) items.append(item);
  }
  if (items.isEmpty()) {
    if (all.isEmpty()) return {};
    return {all.size() == 1 ? QStringLiteral("Thought") : QStringLiteral("Thought (×%1)").arg(all.size())};
  }

  struct Group {
    QString key;
    QString action;
    bool orchestration = false;
    QList<QJsonObject> items;
  };
  QList<Group> groups;
  for (const QJsonObject& item : std::as_const(items)) {
    const QString orchestration = text(item, QLatin1String("type")) == QLatin1String("dynamic_tool")
                                      ? orchestrationAction(text(item, QLatin1String("toolName")))
                                      : QString();
    const QString key = orchestration.isEmpty() ? actionOf(item) : orchestration;
    auto group = std::find_if(groups.begin(), groups.end(), [&](const Group& candidate) { return candidate.key == key; });
    if (group == groups.end()) {
      groups.append({key, key, !orchestration.isEmpty(), {}});
      group = groups.end() - 1;
    }
    group->items.append(item);
  }

  struct Named {
    int index = 0;
    int count = 0;
    int priority = 0;
    QString label;
    bool failed = false;
  };
  QList<Named> named;
  for (int index = 0; index < groups.size(); ++index) {
    const Group& group = groups.at(index);
    Named summary{index, int(group.items.size()), priority(group.key)};
    if (group.orchestration) {
      QList<Call> calls;
      for (const QJsonObject& item : group.items) calls.append(orchestrationCall(item));
      summary.label = orchestrationLabel(group.action, calls);
      summary.failed = std::any_of(calls.cbegin(), calls.cend(), [](const Call& call) { return call.outcome == Outcome::Failed; });
    } else {
      int count = int(group.items.size());
      if (group.action == QLatin1String("edit")) {
        // Edits count the files they touched.
        QSet<QString> files;
        int unnamed = 0;
        for (const QJsonObject& item : group.items) {
          const QString file = text(item, QLatin1String("fileName"));
          if (file.isEmpty()) {
            ++unnamed;
          } else {
            files.insert(file);
          }
        }
        count = int(files.size()) + unnamed;
      }
      summary.label = actionLabel(group.action, count);
      summary.failed = std::any_of(group.items.cbegin(), group.items.cend(), callFailed);
    }
    named.append(summary);
  }

  QList<Named> selected = named;
  std::stable_sort(selected.begin(), selected.end(), [](const Named& a, const Named& b) { return a.priority < b.priority; });
  selected = selected.mid(0, 2);
  std::sort(selected.begin(), selected.end(), [](const Named& a, const Named& b) { return a.index < b.index; });

  QStringList labels;
  int counted = 0;
  for (const Named& summary : std::as_const(selected)) {
    labels.append(summary.label);
    counted += summary.count;
  }
  if (const int remaining = int(items.size()) - counted; remaining > 0) {
    labels.append(QStringLiteral("Performed %1 other %2").arg(remaining).arg(remaining == 1 ? QStringLiteral("action") : QStringLiteral("actions")));
  }
  for (qsizetype i = 1; i < labels.size(); ++i) labels[i][0] = labels[i].at(0).toLower();
  QString sentence;
  if (labels.size() < 3) {
    sentence = labels.join(QStringLiteral(" and "));
  } else {
    sentence = labels.mid(0, labels.size() - 1).join(QStringLiteral(", ")) + QStringLiteral(", and ") + labels.last();
  }
  return {sentence, std::any_of(named.cbegin(), named.cend(), [](const Named& summary) { return summary.failed; })};
}

}  // namespace timeline
