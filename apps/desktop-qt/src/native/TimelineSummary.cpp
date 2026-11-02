#include "TimelineSummary.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>
#include <array>
#include <optional>

namespace timeline {

namespace {

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

// One of HAL-C2's own MCP tools (halC2McpToolPresentation): what a summary
// counts it as and what its row calls it.
struct HalC2Tool {
  QString action;
  QString displayName;
};

const QHash<QString, HalC2Tool>& halC2Tools() {
  // [action, detail] read "Delegate a child task"; a tool's summary action groups it.
  static const QHash<QString, HalC2Tool> tools = [] {
    const QList<std::array<const char*, 4>> inventory{
        {"link_pull_request", "link-pr", "Link", "a pull request"},
        {"unlink_pull_request", "unlink-pr", "Unlink", "a pull request"},
        {"list_thread_pull_requests", "list-prs", "Check", "linked pull requests"},
        {"orchestrator_capabilities", "capabilities", "Get", "orchestration capabilities"},
        {"delegate_task", "delegate", "Delegate", "a child task"},
        {"task_status", "task-status", "Get", "delegated task status"},
        {"task_cancel", "task-cancel", "Cancel", "delegated task"},
        {"schedule_task", "schedule-create", "Schedule", "a recurring task"},
        {"list_scheduled_tasks", "schedule-list", "List", "scheduled tasks"},
        {"update_scheduled_task", "schedule-update", "Update", "a scheduled task"},
        {"delete_scheduled_task", "schedule-delete", "Delete", "a scheduled task"},
        {"create_threads", "thread-create", "Create", "HAL-C2 threads"},
        {"hal_c2_thread_start", "thread-create", "Start", "a HAL-C2 thread"},
        {"hal_c2_thread_list", "thread-list", "List", "HAL-C2 threads"},
        {"hal_c2_thread_read", "thread-read", "Read", "a HAL-C2 thread"},
        {"hal_c2_thread_send", "thread-send", "Send", "to a HAL-C2 thread"},
        {"hal_c2_thread_wait", "thread-wait", "Wait", "for a HAL-C2 thread"},
        {"hal_c2_thread_interrupt", "thread-interrupt", "Interrupt", "a HAL-C2 thread"},
        {"hal_c2_worktree_handoff", "worktree-handoff", "Hand off", "thread to a git worktree"},
        {"hal_c2_worktree_status", "worktree-status", "Get", "thread worktree status"},
        {"preview_status", "browser", "Get", "preview browser status"},
        {"preview_open", "browser", "Open", "a page in the preview browser"},
        {"preview_navigate", "browser", "Navigate", "the preview browser"},
        {"preview_snapshot", "browser", "Snapshot", "the preview page"},
        {"preview_click", "browser", "Click", "in the preview browser"},
        {"preview_press", "browser", "Press", "a key in the preview browser"},
        {"preview_type", "browser", "Type", "in the preview browser"},
        {"preview_scroll", "browser", "Scroll", "the preview browser"},
        {"preview_resize", "browser", "Resize", "the preview browser"},
        {"preview_evaluate", "browser", "Evaluate", "script in the preview browser"},
        {"preview_wait_for", "browser", "Wait", "for the preview page"},
        {"preview_set_appearance", "browser", "Set", "preview browser appearance"},
        {"preview_recording_start", "browser", "Start", "recording the preview browser"},
        {"preview_recording_stop", "browser", "Stop", "recording the preview browser"},
        {"device_list", "device", "List", "simulators and emulators"},
        {"device_open", "device", "Open", "a device in the Device panel"},
        {"device_screenshot", "device", "Take a screenshot of", "the device"},
        {"device_close", "device", "Close", "a device"},
        {"run_scheduled_task_now", "schedule-run", "Run", "a scheduled task"},
        {"hal_c2_queue_list", "queue-list", "List", "queued messages"},
        {"hal_c2_queue_read", "queue-read", "Read", "a queued message"},
        {"hal_c2_queue_edit", "queue-edit", "Edit", "a queued message"},
        {"hal_c2_queue_cancel", "queue-cancel", "Cancel", "a queued run"},
        {"hal_c2_queue_reorder", "queue-reorder", "Reorder", "a queued run"},
        {"hal_c2_queue_promote_to_steer", "queue-steer", "Steer with", "a queued message"},
        {"hal_c2_pending_request_list", "question-list", "List", "pending questions"},
        {"hal_c2_pending_request_read", "question-read", "Read", "pending questions"},
        {"hal_c2_pending_request_respond", "question-respond", "Answer", "pending questions"},
        {"hal_c2_thread_configuration", "thread-configuration", "Read", "thread configuration"},
        {"hal_c2_thread_configure", "thread-configure", "Set", "thread model"},
        {"hal_c2_thread_fork", "thread-fork", "Fork", "this thread"},
        {"hal_c2_thread_merge_back", "thread-merge", "Merge", "thread context"},
        {"hal_c2_thread_search", "thread-search", "Search", "thread content"},
        {"hal_c2_thread_transfers", "thread-transfers", "Read", "thread transfers"},
        {"hal_c2_thread_organize", "thread-organize", "Organize", "a thread"},
        {"hal_c2_thread_update", "thread-update", "Update", "HAL-C2 thread metadata"},
        {"hal_c2_worktree_list", "worktree-list", "List", "workspace branches"},
        {"hal_c2_preview_list", "browser", "List", "preview tabs"},
        {"hal_c2_preview_close", "browser", "Close", "a preview tab"},
        {"hal_c2_environment_read", "environment-read", "Read", "environment preferences"},
        {"hal_c2_environment_preferences_update", "environment-update", "Update", "environment preferences"},
        {"hal_c2_thread_launch", "thread-create", "Launch", "a project thread"},
        {"hal_c2_project_list", "project-list", "List", "projects"},
        {"hal_c2_project_read", "project-read", "Read", "a project"},
        {"hal_c2_project_create", "project-create", "Register", "a project"},
        {"hal_c2_project_update", "project-update", "Update", "a project"},
        {"hal_c2_project_delete", "project-delete", "Delete", "a project"},
        {"hal_c2_project_clone", "project-clone", "Clone", "a repository"},
        {"hal_c2_attachment_prepare_upload", "attachment-prepare", "Prepare", "an attachment upload"},
        {"hal_c2_attachment_discard", "attachment-discard", "Discard", "a pending attachment"},
        {"hal_c2_thread_send_attachments", "attachment-send", "Send", "attachments"},
    };
    QHash<QString, HalC2Tool> byName;
    for (const auto& [name, action, verb, detail] : inventory) {
      byName.insert(QString::fromLatin1(name), {QString::fromLatin1(action), QStringLiteral("%1 %2").arg(QLatin1String(verb), QLatin1String(detail))});
    }
    return byName;
  }();
  return tools;
}

// resolveHalC2McpToolName: agents prefix the HAL-C2 server's tools their own
// way (`mcp__hal-c2__x`, `hal-c2.x`, `hal-c2 · x`, a bare `x`). Only a name in
// the inventory counts, and another server's same-named tool is not HAL-C2's.
std::optional<HalC2Tool> halC2Tool(const QString& toolName) {
  static const QRegularExpression done(QStringLiteral("\\s+(?:complete|completed)\\s*$"),
                                       QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression mcp(QStringLiteral("^mcp__(.+?)__(.+)$"), QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression scoped(QStringLiteral("^hal[-_]?c2(?:[.:/]|\\s*·\\s*)(.+)$"),
                                         QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression prefixed(QStringLiteral("^(?:mcp[-_]{1,2})?hal[-_ ]?c2(?:__|[-_.:/ ])(.+)$"),
                                           QRegularExpression::CaseInsensitiveOption);
  static const QSet<QString> servers{QStringLiteral("hal-c2"), QStringLiteral("hal_c2"), QStringLiteral("halc2")};
  const QString label = QString(toolName).remove(done).trimmed();
  QString name = label;
  if (const auto match = mcp.match(label); match.hasMatch()) {
    if (!servers.contains(match.captured(1).toLower())) return std::nullopt;
    name = match.captured(2);
  } else if (const auto match = scoped.match(label); match.hasMatch()) {
    name = match.captured(1);
  } else if (!halC2Tools().contains(label)) {
    // Bare names start with `hal_c2_` themselves: an exact match wins over the prefix.
    name = prefixed.match(label).captured(1);
  }
  const auto tool = halC2Tools().constFind(name);
  if (tool == halC2Tools().cend()) return std::nullopt;
  return *tool;
}

QString orchestrationAction(const QString& toolName) {
  const auto tool = halC2Tool(toolName);
  return tool ? tool->action : QString();
}

// An MCP result as the provider adapters keep it: the data it carries and
// whether it reports an error.
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
  // The ids the calls name under `key`, from their result or else their arguments.
  const auto ids = [&](QLatin1StringView key) {
    QList<std::optional<QString>> found;
    for (const Call& call : selected) {
      std::optional<QString> id = idOf(call.output.value(key));
      if (!id) id = idOf(call.input.value(key));
      found.append(id);
    }
    return found;
  };
  const auto entities = [&](QLatin1StringView key, const QString& noun) {
    return quantity(countEntities(ids(key)), noun);
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
  const int count = int(selected.size());
  const QString times = quantity(count, QStringLiteral("time"));

  if (action == QLatin1String("thread-send")) {
    QList<std::optional<QString>> messageIds;
    for (const Call& call : selected) messageIds.append(idOf(call.output.value(QLatin1String("messageId"))));
    const int messages = countEntities(messageIds);
    if (!targetsKnown) return phrase(QStringLiteral("Sent"), QStringLiteral("send"), quantity(messages, QStringLiteral("message")));
    const int targets = distinctThreads();
    const QString object = messages == targets && messages > 1
                               ? QStringLiteral("messages to %1").arg(quantity(targets, QStringLiteral("thread")))
                               : QStringLiteral("%1 to %2").arg(quantity(messages, QStringLiteral("message")), quantity(targets, QStringLiteral("thread")));
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
  if (action == QLatin1String("thread-read") || action == QLatin1String("thread-wait")) {
    const QString targets = targetsKnown ? quantity(distinctThreads(), QStringLiteral("thread")) : QStringLiteral("threads %1").arg(times);
    return action == QLatin1String("thread-read") ? phrase(QStringLiteral("Read"), QStringLiteral("read"), targets)
                                                  : phrase(QStringLiteral("Waited on"), QStringLiteral("wait on"), targets);
  }
  if (action == QLatin1String("project-read") || action == QLatin1String("project-create") ||
      action == QLatin1String("project-update") || action == QLatin1String("project-delete")) {
    QList<std::optional<QString>> projects;
    for (const Call& call : selected) {
      std::optional<QString> project = idOf(call.output.value(QLatin1String("id")));
      if (!project) project = idOf(call.output.value(QLatin1String("projectId")));
      if (!project) project = idOf(call.input.value(QLatin1String("projectId")));
      projects.append(project);
    }
    const QString object = quantity(countEntities(projects), QStringLiteral("project"));
    if (action == QLatin1String("project-read")) return phrase(QStringLiteral("Read"), QStringLiteral("read"), object);
    if (action == QLatin1String("project-create")) return phrase(QStringLiteral("Registered"), QStringLiteral("register"), object);
    if (action == QLatin1String("project-update")) return phrase(QStringLiteral("Updated"), QStringLiteral("update"), object);
    return phrase(QStringLiteral("Deleted"), QStringLiteral("delete"), object);
  }
  if (action == QLatin1String("attachment-send")) {
    // A message can carry several attachments; retries count by the message.
    QHash<QString, Call> messages;
    for (int index = 0; index < count; ++index) {
      const Call& call = selected.at(index);
      messages.insert(idOf(call.output.value(QLatin1String("messageId"))).value_or(QStringLiteral("call-%1").arg(index)), call);
    }
    int attachments = 0;
    bool countsKnown = true;
    for (const Call& call : std::as_const(messages)) {
      const QJsonArray listed = call.input.value(QLatin1String("attachments")).toArray();
      attachments += int(listed.size());
      countsKnown = countsKnown && !listed.isEmpty();
    }
    const QString targets = targetsKnown ? QStringLiteral(" to %1").arg(quantity(distinctThreads(), QStringLiteral("thread"))) : QString();
    return phrase(QStringLiteral("Sent"), QStringLiteral("send"),
                  countsKnown ? quantity(attachments, QStringLiteral("attachment")) + targets
                              : QStringLiteral("attachments%1 %2").arg(targets, times));
  }
  if (action == QLatin1String("project-clone")) {
    const int repositories = countEntities(ids(QLatin1String("cwd")));
    return phrase(QStringLiteral("Cloned"), QStringLiteral("clone"),
                  QStringLiteral("%1 %2").arg(repositories).arg(repositories == 1 ? QStringLiteral("repository") : QStringLiteral("repositories")));
  }
  if (action == QLatin1String("list-prs")) {
    return phrase(QStringLiteral("Checked"), QStringLiteral("check"),
                  count == 1 ? QStringLiteral("linked pull requests") : QStringLiteral("linked pull requests %1").arg(times));
  }

  // The rest name what they acted on by id, by count, or by how often.
  struct ById {
    const char* key;
    const char* past;
    const char* infinitive;
    const char* noun;
  };
  static const QHash<QString, ById> byId{
      {QStringLiteral("delegate"), {"taskId", "Delegated", "delegate", "task"}},
      {QStringLiteral("task-cancel"), {"taskId", "Requested cancellation of", "cancel", "task"}},
      {QStringLiteral("schedule-create"), {"scheduledTaskId", "Scheduled", "schedule", "task"}},
      {QStringLiteral("schedule-update"), {"scheduledTaskId", "Updated", "update", "scheduled task"}},
      // A delete can report deleted:false; it was still asked for.
      {QStringLiteral("schedule-delete"), {"scheduledTaskId", "Requested deletion of", "delete", "scheduled task"}},
      {QStringLiteral("queue-read"), {"queuedRunId", "Read", "read", "queued message"}},
      {QStringLiteral("queue-edit"), {"queuedRunId", "Edited", "edit", "queued message"}},
      {QStringLiteral("queue-cancel"), {"queuedRunId", "Requested cancellation of", "cancel", "queued run"}},
      {QStringLiteral("queue-reorder"), {"queuedRunId", "Reordered", "reorder", "queued run"}},
      {QStringLiteral("queue-steer"), {"queuedRunId", "Requested steering with", "steer with", "queued message"}},
      {QStringLiteral("question-read"), {"requestId", "Read", "read", "pending question request"}},
      {QStringLiteral("question-respond"), {"requestId", "Answered", "answer", "pending question request"}},
      {QStringLiteral("worktree-handoff"), {"worktreePath", "Handed off to", "hand off to", "worktree"}},
      {QStringLiteral("attachment-prepare"), {"attachmentId", "Prepared", "prepare", "attachment upload"}},
      {QStringLiteral("attachment-discard"), {"attachmentId", "Discarded", "discard", "pending attachment"}},
  };
  if (const auto found = byId.constFind(action); found != byId.cend()) {
    return phrase(QLatin1String(found->past), QLatin1String(found->infinitive),
                  entities(QLatin1StringView(found->key), QLatin1String(found->noun)));
  }
  if (action == QLatin1String("thread-interrupt") || action == QLatin1String("thread-update")) {
    const QString object = quantity(countEntities(threads), QStringLiteral("thread"));
    return action == QLatin1String("thread-interrupt") ? phrase(QStringLiteral("Requested interrupts for"), QStringLiteral("interrupt"), object)
                                                       : phrase(QStringLiteral("Updated"), QStringLiteral("update"), object);
  }
  struct Counted {
    const char* past;
    const char* infinitive;
    const char* noun;
  };
  static const QHash<QString, Counted> counted{
      {QStringLiteral("schedule-run"), {"Requested", "request", "scheduled task run"}},
      {QStringLiteral("thread-fork"), {"Requested", "request", "thread fork"}},
      {QStringLiteral("thread-merge"), {"Requested", "request", "context merge"}},
      {QStringLiteral("link-pr"), {"Linked", "link", "pull request"}},
      {QStringLiteral("unlink-pr"), {"Unlinked", "unlink", "pull request"}},
  };
  if (const auto found = counted.constFind(action); found != counted.cend()) {
    return phrase(QLatin1String(found->past), QLatin1String(found->infinitive), quantity(count, QLatin1String(found->noun)));
  }
  static const QHash<QString, Counted> repeated{
      {QStringLiteral("thread-list"), {"Listed", "list", "threads"}},
      {QStringLiteral("task-status"), {"Checked", "check", "task status"}},
      {QStringLiteral("schedule-list"), {"Listed", "list", "scheduled tasks"}},
      {QStringLiteral("thread-configuration"), {"Checked", "check", "thread configuration"}},
      {QStringLiteral("thread-configure"), {"Set", "set", "thread model"}},
      {QStringLiteral("thread-search"), {"Searched", "search", "threads"}},
      {QStringLiteral("thread-transfers"), {"Checked", "check", "thread transfers"}},
      {QStringLiteral("thread-organize"), {"Organized", "organize", "threads"}},
      {QStringLiteral("queue-list"), {"Listed", "list", "queued messages"}},
      {QStringLiteral("question-list"), {"Listed", "list", "pending questions"}},
      {QStringLiteral("worktree-list"), {"Listed", "list", "workspace branches"}},
      {QStringLiteral("worktree-status"), {"Checked", "check", "worktree status"}},
      {QStringLiteral("project-list"), {"Listed", "list", "projects"}},
      {QStringLiteral("environment-read"), {"Checked", "check", "environment preferences"}},
      {QStringLiteral("environment-update"), {"Updated", "update", "environment preferences"}},
      {QStringLiteral("browser"), {"Used", "use", "browser"}},
      {QStringLiteral("device"), {"Used", "use", "device controls"}},
      {QStringLiteral("capabilities"), {"Checked", "check", "orchestration capabilities"}},
  };
  const Counted done = repeated.value(action, {"Used", "use", "HAL-C2 tools"});
  return phrase(QLatin1String(done.past), QLatin1String(done.infinitive), QStringLiteral("%1 %2").arg(QLatin1String(done.noun), times));
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
  static const QSet<QString> first{
      QStringLiteral("command"),          QStringLiteral("edit"),               QStringLiteral("delegate"),
      QStringLiteral("task-cancel"),      QStringLiteral("thread-create"),      QStringLiteral("thread-send"),
      QStringLiteral("thread-interrupt"), QStringLiteral("schedule-create"),    QStringLiteral("schedule-update"),
      QStringLiteral("schedule-delete"),  QStringLiteral("schedule-run"),       QStringLiteral("thread-configure"),
      QStringLiteral("thread-fork"),      QStringLiteral("thread-merge"),       QStringLiteral("thread-organize"),
      QStringLiteral("thread-update"),    QStringLiteral("queue-edit"),         QStringLiteral("queue-cancel"),
      QStringLiteral("queue-reorder"),    QStringLiteral("queue-steer"),        QStringLiteral("question-respond"),
      QStringLiteral("worktree-handoff"), QStringLiteral("project-create"),     QStringLiteral("project-update"),
      QStringLiteral("project-delete"),   QStringLiteral("project-clone"),      QStringLiteral("environment-update"),
      QStringLiteral("attachment-prepare"), QStringLiteral("attachment-discard"), QStringLiteral("attachment-send")};
  if (first.contains(action)) return 0;
  return action == QLatin1String("other") || action == QLatin1String("update") ? 2 : 1;
}

// "Chrome", "Chrome and Slack", "Chrome, Slack, and Linear".
QString listed(const QStringList& names) {
  if (names.size() < 3) return names.join(QStringLiteral(" and "));
  return names.mid(0, names.size() - 1).join(QStringLiteral(", ")) + QStringLiteral(", and ") + names.last();
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
  // Calls through a browser, the computer or an integration the MC named
  // (`toolSource`) are summed up by what they went through.
  QStringList sourceKeys;
  QStringList sourceNames;
  bool integrations = true;
  int sourced = 0;
  for (const QJsonObject& item : std::as_const(items)) {
    const QString orchestration = text(item, QLatin1String("type")) == QLatin1String("dynamic_tool")
                                      ? orchestrationAction(text(item, QLatin1String("toolName")))
                                      : QString();
    const QJsonObject source = item.value(QLatin1String("toolSource")).toObject();
    if (orchestration.isEmpty() && !source.isEmpty()) {
      ++sourced;
      const QString sourceKey = text(source, QLatin1String("key"));
      if (!sourceKeys.contains(sourceKey)) {
        sourceKeys.append(sourceKey);
        sourceNames.append(text(source, QLatin1String("name")));
        integrations = integrations && text(source, QLatin1String("kind")) == QLatin1String("integration");
      }
      continue;
    }
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
  int counted = sourced;
  if (!sourceNames.isEmpty()) {
    labels.append(QStringLiteral("Used ") + listed(sourceNames) +
                  (integrations ? sourceNames.size() == 1 ? QStringLiteral(" integration") : QStringLiteral(" integrations")
                                : QString()));
  }
  for (const Named& summary : std::as_const(selected)) {
    labels.append(summary.label);
    counted += summary.count;
  }
  if (const int remaining = int(items.size()) - counted; remaining > 0) {
    labels.append(QStringLiteral("Performed %1 other %2").arg(remaining).arg(remaining == 1 ? QStringLiteral("action") : QStringLiteral("actions")));
  }
  for (qsizetype i = 1; i < labels.size(); ++i) labels[i][0] = labels[i].at(0).toLower();
  return {listed(labels), std::any_of(named.cbegin(), named.cend(), [](const Named& summary) { return summary.failed; })};
}

QString plainDetail(const QString& markdown) {
  static const QRegularExpression link(QStringLiteral(R"(\[([^\]]+)\]\([^)]*\))"));
  static const QRegularExpression bullet(QStringLiteral(R"(^[ \t]*[-*][ \t]+)"), QRegularExpression::MultilineOption);
  static const QRegularExpression space(QStringLiteral(R"(\s+)"));
  QString plain = markdown;
  plain.replace(link, QStringLiteral("\\1"));
  plain.remove(QLatin1Char('`'));
  plain.remove(bullet);
  plain.replace(space, QStringLiteral(" "));
  return plain.trimmed();
}

bool subagentSettled(const QString& status) {
  return status != QLatin1String("pending") && status != QLatin1String("running") && status != QLatin1String("waiting");
}

QString subagentDetail(bool settled, const QString& progress, const QString& result) {
  static const QRegularExpression placeholder(QStringLiteral(R"(^Child task ended with status\b)"),
                                              QRegularExpression::CaseInsensitiveOption);
  const QString first = settled ? result.trimmed() : progress.trimmed();
  const QString second = settled ? progress.trimmed() : result.trimmed();
  const QString raw = first.isEmpty() ? second : first;
  return raw.isEmpty() || placeholder.match(raw).hasMatch() ? QString() : plainDetail(raw);
}

QString halC2ToolDisplayName(const QString& toolName) {
  const std::optional<HalC2Tool> tool = halC2Tool(toolName);
  return tool ? tool->displayName : QString();
}

QString commandDisplayText(const QString& command) {
  // sh, bash, zsh, dash or ksh, flags such as -lc, then the script alone.
  static const QRegularExpression wrapper(
      QStringLiteral(R"re(^(?:\S*/)?(?:ba|z|da|k)?sh(?:\.exe)?(?:\s+-[A-Za-z]+)*?\s+-[A-Za-z]*c\s+)re"
                     R"re((?:'((?:[^']|'\\'')*)'|"((?:[^"\\]|\\.)*)"|([^\s'"]+))$)re"),
      QRegularExpression::DotMatchesEverythingOption);
  static const QRegularExpression escaped(QStringLiteral(R"(\\(.))"));
  static const QRegularExpression space(QStringLiteral(R"(\s+)"));
  const QString trimmed = command.trimmed();
  QString shown = trimmed;
  if (const auto match = wrapper.match(trimmed); match.hasMatch()) {
    if (match.capturedStart(1) >= 0) {
      shown = match.captured(1).replace(QStringLiteral("'\\''"), QStringLiteral("'"));
    } else if (match.capturedStart(2) >= 0) {
      shown = match.captured(2).replace(escaped, QStringLiteral("\\1"));
    } else {
      shown = match.captured(3);
    }
  }
  shown = shown.trimmed();
  if (shown.isEmpty()) shown = trimmed;
  return shown.section(QLatin1Char('\n'), 0, 0).replace(space, QStringLiteral(" ")).trimmed();
}

static Notice noticeFrom(const QJsonObject& notification) {
  return Notice{text(notification, QLatin1String("summary")).trimmed(), text(notification, QLatin1String("outcome")),
                text(notification, QLatin1String("workerThreadId")), text(notification, QLatin1String("workerTitle")).trimmed(),
                text(notification, QLatin1String("detail"))};
}

std::optional<Notice> noticeOf(const QJsonObject& item) {
  const QString type = text(item, QLatin1String("type"));
  if (type == QLatin1String("notification")) return noticeFrom(item);
  const QJsonObject notification = item.value(QLatin1String("notification")).toObject();
  if (type.isEmpty() && !notification.isEmpty()) return noticeFrom(notification);
  if (!type.isEmpty() && type != QLatin1String("user_message")) return std::nullopt;
  const QString createdBy = text(item, QLatin1String("createdBy"));
  if (createdBy == QLatin1String("agent")) {
    // A message another agent sent names its thread, or came in over MCP.
    if (text(item, QLatin1String("creationSource")) != QLatin1String("provider") ||
        !text(item, QLatin1String("senderThreadId")).isEmpty()) {
      return std::nullopt;
    }
    return Notice{QStringLiteral("Background activity updated"), QStringLiteral("updated")};
  }
  if (createdBy != QLatin1String("system")) return std::nullopt;
  // <delegated_task_result taskId="…" title="…" status="…" childThreadId="…">
  static const QRegularExpression envelope(
      QStringLiteral("\\A<delegated_task_result taskId=\"[^\"]*\" title=\"([^\n]*)\" status=\"(\\w+)\" childThreadId=\"[^\"\n]*\">"));
  const QRegularExpressionMatch match = envelope.match(text(item, QLatin1String("text")));
  if (!match.hasMatch()) return std::nullopt;
  const QString status = match.captured(2);
  const QString title = match.captured(1).trimmed();
  const QString outcome = status == QLatin1String("completed") || status == QLatin1String("failed") ? status : QStringLiteral("cancelled");
  const QString ended = outcome == QLatin1String("completed") ? QStringLiteral("finished")
                        : outcome == QLatin1String("failed")  ? QStringLiteral("failed")
                                                               : QStringLiteral("stopped");
  return Notice{QStringLiteral("%1 %2").arg(title.isEmpty() ? QStringLiteral("Delegated task") : title, ended), outcome};
}

}  // namespace timeline
