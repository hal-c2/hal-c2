// What a group of tool calls did (TimelineSummary.cpp summarize) over any turn
// items the MC sends. A call's output and input are read by readResult, which
// parses JSON that is nested in strings, nested up to a depth cap; those helpers
// sit in TimelineSummary.cpp's anonymous namespace, so they are reached through
// summarize and callFailed. Besides not crashing: a group of work has a
// sentence, and a reasoning item, which is not work, changes nothing.

#include "Fuzz.h"
#include "TimelineSummary.h"

#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// The keys TimelineSummary.cpp reads from an item, a call's input and output.
const std::vector<std::string> kKeys{
    "type", "toolName", "title", "status", "output", "input", "result", "content", "structuredContent", "text",
    "isError", "is_error", "error", "_tag", "exitCode", "outputIndicatesFailure", "results", "pattern", "fileName",
    "requestKind", "viewedImagePath", "threadId", "thread", "threads", "messageId", "taskId", "args", "fileName",
    "runId", "id", "files", "path"};

// The item types, tool names and JSON the summary reads: strings that hold JSON
// are what readResult parses.
const std::vector<std::string> kTexts{
    "dynamic_tool", "command_execution", "file_search", "file_change", "reasoning", "web_search", "todo_list",
    "approval_request", "system_notice", "thread_created", "failed", "declined", "completed", "running",
    "mcp__hal-c2__hal_c2_thread_send", "mcp__hal-c2__hal_c2_thread_read", "hal-c2.thread_wait", "hal_c2 · thread_send complete",
    "create_threads", "delegate_task", "hal_c2_thread_launch", "hal-c2:thread_read", "read", "read file", "file-read",
    "src/a.rs", "t1", "t2", "m1", "task-1", "boom", "not json", "",
    R"({"isError":true})", R"({"threadId":"t1"})", R"({"thread":{"threadId":"t2"}})",
    R"([{"type":"text","text":"{\"threadId\":\"t2\",\"messageId\":\"m1\"}"}])",
    R"({"threads":[{"threadId":"t3"},{"status":"rolled_back"}]})",
    R"({"structuredContent":{"taskId":"k1"}})",
    R"({"content":[{"content":{"text":"{\"is_error\":true}"}}]})",
    R"([[[[[[{"isError":true}]]]]]])",
    R"({"toolName":"hal_c2_thread_read","args":{"threadId":"t1"}})",
    R"({"_tag":"ToolError","message":"no"})"};

void SummaryHoldsUp(const std::vector<fuzz::JsonSteps>& items) {
  QList<QJsonObject> turnItems;
  for (const fuzz::JsonSteps& steps : items) {
    const QJsonObject item = fuzz::object(steps);
    fuzz::print(item);
    turnItems.append(item);
    (void)timeline::callFailed(item);
    (void)timeline::isFileRead(item);
  }
  const timeline::GroupSummary summary = timeline::summarize(turnItems);

  bool work = false;
  for (const QJsonObject& item : std::as_const(turnItems)) {
    if (item.value(QLatin1String("type")).toString() != QLatin1String("reasoning")) work = true;
  }
  if (work) {
    EXPECT_FALSE(summary.text.isEmpty());
    // A reasoning item is not work: it changes neither the sentence nor the failure.
    QJsonObject reasoning{{QStringLiteral("type"), QStringLiteral("reasoning")}, {QStringLiteral("text"), QStringLiteral("hm")}};
    QList<QJsonObject> withReasoning{reasoning};
    withReasoning.append(turnItems);
    const timeline::GroupSummary again = timeline::summarize(withReasoning);
    EXPECT_EQ(again.text, summary.text);
    EXPECT_EQ(again.failed, summary.failed);
  }
}
FUZZ_TEST(TimelineSummary, SummaryHoldsUp)
    .WithDomains(fuzztest::VectorOf(fuzz::Json(kKeys, kTexts)).WithMaxSize(6))
    .WithSeeds([] {
      return std::vector<std::tuple<std::vector<fuzz::JsonSteps>>>{
          // An MCP call whose output is a JSON string holding MCP content with a JSON string inside it.
          {fuzz::messages({
              R"j({"type":"dynamic_tool","toolName":"mcp__hal-c2__hal_c2_thread_send","status":"completed",
                   "input":"{\"threadId\":\"t2\",\"message\":\"hi\"}",
                   "output":"[{\"type\":\"text\",\"text\":\"{\\\"threadId\\\":\\\"t2\\\",\\\"messageId\\\":\\\"m1\\\"}\"}]"})j",
              R"j({"type":"reasoning","text":"thinking"})j",
          })},
          // A failed create, its error inside a string inside a string.
          {fuzz::messages({
              R"j({"type":"dynamic_tool","toolName":"create_threads","status":"failed",
                   "output":"{\"content\":[{\"text\":\"{\\\"isError\\\":true}\"}]}"})j",
              R"j({"type":"file_search","pattern":"src/a.rs","results":[{"fileName":"src/a.rs"}]})j",
          })},
          // A command, a file change and an unclosed run of Cursor's envelope.
          {fuzz::messages({
              R"j({"type":"command_execution","command":"make","status":"completed","exitCode":2})j",
              R"j({"type":"file_change","files":[{"path":"a"},{"path":"b"}]})j",
              R"j({"type":"dynamic_tool","toolName":"hal-c2.thread_read","input":"{\"toolName\":\"hal_c2_thread_read\",\"args\":{\"threadId\":\"t1\"}}"})j",
          })},
          // Too deep to read: nested in strings past the cap, still no crash.
          {fuzz::messages({
              R"j({"type":"dynamic_tool","toolName":"delegate_task","output":"[[[[[[{\"taskId\":\"k\"}]]]]]]"})j",
          })},
      };
    });

}  // namespace
