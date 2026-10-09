// A thread's timeline (TimelineModel.h) fed any sequence of stream frames, as
// a buggy or hostile MC could send them: snapshots, events with HalC2.Patch
// patches, pages, live and resync, in any order and with any fields. The
// model must not crash, and every row it then shows must read.

#include "Fuzz.h"
#include "TimelineModel.h"

#include <QDateTime>
#include <QTimeZone>

#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// The keys and words TimelineModel.cpp looks for (frames, patches, entities).
const std::vector<std::string> kKeys{
    "t", "part", "rows", "done", "offset", "floor", "handle", "events", "s", "u", "a", "d", "id", "type", "runId",
    "ordinal", "status", "streaming", "text", "output", "markdown", "progress", "failure", "message", "subagentId",
    "exitCode", "fileName", "toolName", "role", "inputIntent", "createdBy", "senderThreadId", "attachments", "files",
    "path", "additions", "deletions", "checkpointId", "scopeId", "turn", "startedAt", "completedAt", "updatedAt",
    "createdAt", "requestedAt", "requestId", "requestKind", "question", "questions", "decision", "steps", "title",
    "summary", "model", "childThreadId", "targetThreadId", "threadId", "results", "command", "name", "args", "input",
    "result", "content", "structuredContent", "isError", "is_error", "outputIndicatesFailure", "messageId", "_tag",
    "scheduledTaskId", "taskId", "viewedImagePath", "pattern", "patterns", "marker", "code", "nodeId", "rootNodeId"};
const std::vector<std::string> kTexts{
    "snapshot", "events", "live", "page", "resync", "turn-item", "run", "run-attempt", "runtime-request", "plan",
    "message", "checkpoint", "subagent", "user_message", "assistant_message", "command_execution", "file_change",
    "file_search", "web_search", "todo_list", "dynamic_tool", "reasoning", "proposed_plan", "error", "fork", "handoff",
    "compaction", "thread_created", "notification", "running", "completed", "failed", "interrupted", "cancelled",
    "pending", "idle", "ready", "rolled_back", "superseded", "declined", "user", "agent", "system_notice",
    "queued_turn", "steer", "promoted_queued_to_steer", "approval_request", "user_input_request", "thread-send",
    "thread-read", "thread-create", "file-read", "code-search", "edit", "delegate", "r1", "r2", "i1", "i2", "i3",
    "m1", "c1", "a1", "fold:r1", "work:i2", "log-1", "2026-09-23T10:00:00Z", "2026-09-22T23:59:59.999Z",
    "src/main.cpp", "https://github.com/hal-c2/hal-c2/pull/1"};

// The frames a thread opens with, then a turn streaming and settling.
const char* const kOpen[] = {
    R"({"t":"snapshot","part":0,"done":false,"offset":7,"handle":"log-1","floor":1,"rows":[
        ["run","r1",{"id":"r1","ordinal":1,"status":"completed","startedAt":"2026-09-23T10:00:00Z","completedAt":"2026-09-23T10:02:00Z"}],
        ["subagent","a1",{"id":"a1","model":"gpt-5","title":"Survey"}],
        ["turn-item","i1",{"id":"i1","type":"user_message","runId":"r1","ordinal":1,"status":"completed","streaming":false,"text":"Fix it","inputIntent":"steer","createdBy":"agent","senderThreadId":"t9","attachments":[{"type":"image","id":"img1","name":"a.png"}]}]]})",
    R"({"t":"snapshot","part":1,"done":true,"offset":7,"handle":"log-1","floor":1,"rows":[
        ["turn-item","i2",{"id":"i2","type":"command_execution","runId":"r1","ordinal":2,"status":"failed","streaming":false,"command":"make","output":"boom","exitCode":2}],
        ["turn-item","i3",{"id":"i3","type":"file_change","runId":"r1","ordinal":3,"status":"completed","streaming":false,"files":[{"path":"src/main.cpp","additions":3,"deletions":1}]}],
        ["turn-item","i4",{"id":"i4","type":"subagent","runId":"r1","ordinal":4,"status":"running","streaming":true,"subagentId":"a1","progress":"half"}],
        ["turn-item","i5",{"id":"i5","type":"assistant_message","runId":"r1","ordinal":5,"status":"completed","streaming":false,"text":"Done, see https://github.com/hal-c2/hal-c2/pull/1","messageId":"m1"}],
        ["checkpoint","c1",{"id":"c1","runId":"r1","checkpointId":"c1","scopeId":"s1","turn":1,"files":[{"path":"src/main.cpp","additions":3,"deletions":1}]}]]})",
    R"({"t":"live","offset":7,"handle":"log-1"})",
};
const char* const kTurn[] = {
    R"({"t":"events","offset":12,"events":[
        [8,"run","r2",{"s":{"id":"r2","ordinal":2,"status":"running","startedAt":"2026-09-23T10:05:00Z"}},"2026-09-23T10:05:00Z"],
        [9,"turn-item","i6",{"s":{"id":"i6","type":"reasoning","runId":"r2","ordinal":1,"status":"running","streaming":true,"text":"Hm"}},"2026-09-23T10:05:01Z"],
        [10,"turn-item","i6",{"a":{"text":"m, so"}},"2026-09-23T10:05:02Z"],
        [11,"runtime-request","q1",{"s":{"id":"q1","runId":"r2","requestKind":"approval_request","status":"pending","question":"Run make?"}},"2026-09-23T10:05:03Z"],
        [12,"plan","p1",{"s":{"id":"p1","runId":"r2","steps":[{"title":"one","status":"completed"},{"title":"two","status":"pending"}]}},"2026-09-23T10:05:04Z"]]})",
    R"({"t":"events","offset":15,"events":[
        [13,"turn-item","i6",{"s":{"streaming":false,"status":"completed"},"u":["progress"]},"2026-09-23T10:06:00Z"],
        [14,"runtime-request","q1",{"d":true},"2026-09-23T10:06:01Z"],
        [15,"run","r2",{"s":{"status":"interrupted","completedAt":"2026-09-23T10:06:02Z"}},"2026-09-23T10:06:02Z"]]})",
    R"({"t":"page","done":true,"offset":15,"floor":null,"rows":[
        ["run","r0",{"id":"r0","ordinal":0,"status":"completed"}],
        ["turn-item","i0",{"id":"i0","type":"error","runId":"r0","ordinal":1,"status":"failed","failure":{"message":"no"}}]]})",
    R"({"t":"resync","offset":3})",
};

// Two turn items without `id` fields, which once named two rows alike
// (tests/native/tst_TimelineModelRegression.cpp).
const char* const kNoIds[] = {
    R"({"t":"snapshot","part":0,"done":true,"offset":1,"handle":"log-1","floor":null,"rows":[["run","r1",{"id":"r1","ordinal":1,"status":"running"}],["turn-item","i1",{"type":"user_message","runId":"r1","ordinal":1,"text":"one"}]]})",
    R"({"t":"events","offset":2,"events":[[2,"turn-item","i2",{"s":{"type":"user_message","runId":"r1","ordinal":2,"text":"two"}},"2026-09-23T10:00:00Z"]]})",
};

void FramesFold(const std::vector<fuzz::JsonSteps>& frames, bool earlier) {
  TimelineModel model(QStringLiteral("env-1:thread-1"));
  const QDateTime now(QDate(2026, 9, 23), QTime(10, 10), QTimeZone::UTC);
  model.setClock([now] { return now; });
  model.setThreadTitles([](const QString& id) { return id == QLatin1String("t9") ? QStringLiteral("Other") : QString(); });
  model.subscribing();
  for (const fuzz::JsonSteps& steps : frames) {
    const QJsonObject frame = fuzz::object(steps);
    fuzz::print(frame);
    model.receive(frame);
    if (earlier) model.loadEarlier();
  }
  fuzz::settle();

  model.subscribing();
  model.workingLabel();
  for (const char* kind : {"run", "turn-item", "runtime-request", "plan", "checkpoint", "subagent"}) {
    model.entities(QLatin1String(kind));
  }
  const QHash<int, QByteArray> roles = model.roleNames();
  QStringList ids;
  for (int row = 0; row < model.rowCount(); ++row) {
    const QModelIndex index = model.index(row);
    for (auto it = roles.cbegin(); it != roles.cend(); ++it) model.data(index, it.key());
    ids.append(model.data(index, TimelineModel::IdRole).toString());
  }
  // Row ids are unique: each finds its own row.
  for (const QString& id : std::as_const(ids)) ASSERT_EQ(model.indexOf(id), ids.indexOf(id)) << id.toStdString();
  // Toggling moves rows and may drop the ids after it; those must be no-ops.
  for (const QString& id : std::as_const(ids)) {
    model.timeTitle(id);
    model.checkpointOf(id);
    model.finishedRunOf(id);
    model.rewindPointOf(id);
    model.toggle(id);
  }
  // Toggling opened rows' calls and folds; they must read too.
  for (int row = 0; row < model.rowCount(); ++row) {
    for (auto it = roles.cbegin(); it != roles.cend(); ++it) model.data(model.index(row), it.key());
  }
  fuzz::settle();
}
FUZZ_TEST(TimelineModel, FramesFold)
    .WithDomains(fuzztest::VectorOf(fuzz::Json(kKeys, kTexts)).WithMaxSize(12), fuzztest::Arbitrary<bool>())
    .WithSeeds([] {
      std::vector<std::string_view> open(std::begin(kOpen), std::end(kOpen));
      std::vector<std::string_view> all = open;
      all.insert(all.end(), std::begin(kTurn), std::end(kTurn));
      std::vector<fuzz::JsonSteps> opened;
      for (std::string_view frame : open) opened.push_back(fuzz::steps(frame));
      std::vector<fuzz::JsonSteps> whole;
      for (std::string_view frame : all) whole.push_back(fuzz::steps(frame));
      std::vector<fuzz::JsonSteps> noIds;
      for (std::string_view frame : kNoIds) noIds.push_back(fuzz::steps(frame));
      return std::vector<std::tuple<std::vector<fuzz::JsonSteps>, bool>>{
          {opened, false}, {whole, false}, {whole, true}, {noIds, false}};
    });

}  // namespace
