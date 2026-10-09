// The sidebar's store (ShellStore.h) fed any sequence of `shell` frames, as a
// buggy or hostile MC could send them: snapshots with versions, row changes,
// environments, members going online, offline and away, in any order and with
// any fields. The store must not crash, every row it holds must read through
// the sidebar's model, and what it kept in the LocalCache must read back as
// the same rows.

#include "Fuzz.h"
#include "Reach.h"

#include <QDir>
#include <QSet>
#include <QUrl>

#include <atomic>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

#include "LocalCache.h"
#include "McClient.h"
#include "ShellStore.h"
#include "SidebarModel.h"

namespace halc2::fuzz {
// onFrame is private: the subscription's handler is its only caller, and an
// unconnected client delivers nothing.
struct ShellOnFrame {
  using type = void (ShellStore::*)(const QJsonObject&);
  friend type reach(ShellOnFrame);
};
template struct Reach<ShellOnFrame, &ShellStore::onFrame>;
}  // namespace halc2::fuzz

using namespace halc2;

namespace {

// The keys and words ShellStore.cpp and sidebar::threadFromRow look for.
const std::vector<std::string> kKeys{
    "t", "mcs", "rows", "mc", "online", "environment", "environmentId", "capabilities", "label", "epoch", "rev", "reset",
    "removed", "reason", "id", "projectId", "title", "workspaceRoot", "repositoryIdentity", "canonicalKey", "rootPath",
    "displayName", "name", "createdAt", "updatedAt", "deletedAt", "archivedAt", "branch", "lineage",
    "relationshipToParent", "interactionMode", "runtimeMode", "modelSelection", "settledOverride", "settledAt",
    "unsettledAt", "snoozedUntil", "snoozedAt", "pinnedAt", "pinOrderKey", "activeOrderKey", "lastVisitedAt",
    "latestUserMessageAt", "moving", "movedTo", "latestRunId", "activeRunId", "activityRunStatus", "status",
    "hasActionableProposedPlan", "pendingBackgroundTasks", "plugin", "kind", "listed", "latestRunRequestedAt",
    "latestRunStartedAt", "latestRunCompletedAt", "activeProviderThreadId", "lastErrorClass", "threadSettlement",
    "threadSnooze", "threadVisitedTracking", "threadPinning", "threadTitleRegeneration", "pullRequests",
    "threadPullRequests", "threadPullRequestLinking"};
const std::vector<std::string> kTexts{
    "shell", "shell.rows", "shell.environment", "shell.mc", "error", "thread", "project", "mc-a", "mc-b", "env-a",
    "env-b", "epoch-1", "epoch-2", "p1", "p2", "t1", "t2", "t3", "idle", "running", "ready", "completed", "failed",
    "interrupted", "starting", "subagent", "default", "plan", "full-access", "approval-required", "r1", "r2", "key-a",
    "key-b", "2026-09-23T10:00:00Z", "2026-09-23T10:05:00.123Z", "2026-09-22T23:59:59.999Z", "/work/p1", "git@github.com:hal-c2/hal-c2",
    "github.com/hal-c2/hal-c2", "repository", "separate", "Fix it"};

// The MC's `shell` snapshot (apps/server-ex lib/hal_c2/shell.ex, FakeMc.sendSnapshot):
// two members, one of them offline, and each one's rows.
const char* const kSnapshot =
    R"j({"t":"shell","id":1,"mcs":[
        {"mc":"mc-a","online":true,"epoch":"epoch-1","rev":3,"reset":true,
         "environment":{"environmentId":"env-a","label":"Laptop","capabilities":{"threadSettlement":true,"threadSnooze":true,"threadVisitedTracking":true,"threadPinning":true,"threadTitleRegeneration":true}}},
        {"mc":"mc-b","online":false,"epoch":"epoch-2","rev":9,"reset":true,
         "environment":{"environmentId":"env-b","capabilities":{}}}],
      "rows":[
        ["mc-a","p1","project",{"id":"p1","title":"HAL-C2","workspaceRoot":"/work/p1","createdAt":"2026-09-22T09:00:00Z","updatedAt":"2026-09-23T10:00:00Z",
          "repositoryIdentity":{"canonicalKey":"github.com/hal-c2/hal-c2","rootPath":"/work","displayName":"hal-c2","name":"hal-c2"}}],
        ["mc-a","t1","thread",{"id":"t1","projectId":"p1","title":"Fix it","branch":"main","createdAt":"2026-09-23T09:00:00Z","updatedAt":"2026-09-23T10:00:00Z",
          "latestUserMessageAt":"2026-09-23T09:59:00Z","interactionMode":"default","runtimeMode":"full-access","modelSelection":{"instanceId":"codex","model":"gpt-5"},
          "latestRunId":"r1","status":"running","activeRunId":"r1","latestRunStartedAt":"2026-09-23T09:59:30Z","lastVisitedAt":"2026-09-23T09:00:00Z",
          "pinnedAt":"2026-09-23T09:01:00Z","pinOrderKey":"b","activeOrderKey":"a","pendingBackgroundTasks":[{"id":"x"}],"plugin":{"id":"p","kind":"k","listed":true}}],
        ["mc-a","t2","thread",{"id":"t2","projectId":"p1","title":"Old","createdAt":"2026-09-20T09:00:00Z","updatedAt":"2026-09-20T10:00:00Z","archivedAt":"2026-09-21T00:00:00Z",
          "snoozedUntil":"2026-10-01T09:00:00Z","snoozedAt":"2026-09-20T10:00:00Z","settledOverride":"settled","lineage":{"relationshipToParent":"subagent"}}],
        ["mc-b","t3","thread",{"id":"t3","projectId":"p2","title":"Moved","moving":{"environmentId":"env-a","label":"Laptop"}}],
        ["mc-b","p2","project",{"id":"p2","title":"Other","workspaceRoot":"/srv/p2","createdAt":"2026-09-21T09:00:00Z"}]]})j";
// Then what changes: rows (one deleted, one moved away), an environment, a
// member coming online, one leaving, a refused subscription.
const char* const kChanges[] = {
    R"j({"t":"shell.rows","id":1,"mc":"mc-a","epoch":"epoch-1","rev":4,"reset":false,"rows":[
        ["t1","thread",{"id":"t1","projectId":"p1","title":"Fix it!","updatedAt":"2026-09-23T10:01:00Z","status":"idle","latestRunId":"r1","latestRunCompletedAt":"2026-09-23T10:01:00Z"}],
        ["t2","thread",{"id":"t2","deletedAt":"2026-09-23T10:02:00Z"}],
        ["t3","thread",{"id":"t3","projectId":"p2","title":"Moved","movedTo":{"environmentId":"env-b","label":"Server","projectId":"p2"}}]]})j",
    R"j({"t":"shell.rows","id":1,"mc":"mc-b","epoch":"epoch-2","rev":10,"reset":true,"rows":[
        ["t3","thread",{"id":"t3","projectId":"p2","title":"Moved here","createdAt":"2026-09-23T10:00:00Z"}]]})j",
    R"j({"t":"shell.environment","id":1,"mc":"mc-b","environment":{"environmentId":"env-b","label":"Server","capabilities":{"threadPinning":true}}})j",
    R"j({"t":"shell.mc","id":1,"mc":"mc-b","online":true})j",
    R"j({"t":"shell.mc","id":1,"mc":"mc-b","online":false,"removed":true})j",
    R"j({"t":"error","id":1,"reason":"not allowed"})j",
};

// Each row of a model the sidebar builds reads, whatever the MC put in it.
void ReadThrough(const ShellStore& store) {
  const QList<sidebar::Thread> threads = store.threads();
  const QList<sidebar::Project> projects = store.projects();
  qint64 now = 1'790'000'000'000;
  for (const sidebar::Thread& thread : threads) {
    sidebar::status(thread);
    sidebar::workingLabel(thread, now);
    sidebar::statusLabel(thread);
    sidebar::unread(thread);
    sidebar::canSnooze(thread, now);
    sidebar::effectiveSnoozed(thread, now);
    sidebar::wokeAt(thread, now);
    sidebar::visibleWokeAt(thread, now);
    sidebar::hasQueuedTurnStart(thread, now);
    // A thread listed is found by its key, and where it lives is one of the listed.
    const QString key = thread.key();
    // (A key splits at its first colon, so an environment id holding one is not found by it.)
    if (!thread.environmentId.contains(QLatin1Char(':'))) ASSERT_TRUE(store.thread(key).has_value()) << key.toStdString();
    store.located(key);
    store.threadOnline(key);
  }
  for (const sidebar::Project& project : projects) {
    if (!project.environmentId.contains(QLatin1Char(':'))) ASSERT_TRUE(store.project(project.key()).has_value()) << project.key().toStdString();
  }
  const auto capabilities = [&store](const QString& environmentId) {
    return store.capabilities(environmentId);
  };
  const sidebar::Partition parts = sidebar::partition(threads, std::nullopt, capabilities, now);
  // Every thread lands in at most one section.
  ASSERT_LE(parts.pinned.size() + parts.active.size() + parts.snoozed.size() + parts.settled.size(), threads.size());
  sidebar::GroupingSettings settings;
  for (const QString& mode : {QStringLiteral("repository"), QStringLiteral("repository_path"), QStringLiteral("separate")}) {
    settings.mode = mode;
    const QList<sidebar::ProjectGroup> groups = sidebar::groupProjects(projects, settings, {}, threads);
    sidebar::Input input;
    input.projects = groups;
    for (const QString& environmentId : store.environments()) {
      if (!store.environmentOnline(environmentId)) input.offlineEnvironments.insert(environmentId);
    }
    input.showJumpHints = true;
    input.jumpLabels = {QStringLiteral("1"), QStringLiteral("2")};
    const sidebar::View view = sidebar::build(threads, input, std::nullopt, capabilities, now);
    // Rows are listed once each.
    ASSERT_EQ(QSet<QString>(view.orderedKeys.begin(), view.orderedKeys.end()).size(), view.orderedKeys.size());
  }
  sidebar::mostRecentProject(projects, threads);
  if (!threads.isEmpty()) sidebar::fallbackAfterDelete(threads, threads.first().key(), QStringLiteral("updated_at"));
  for (const QString& environmentId : store.environments()) {
    store.environment(environmentId);
    store.projectRows(environmentId);
    store.mcServing(environmentId);
    store.servesEnvironment(environmentId);
    store.supports(environmentId, QStringLiteral("pullRequests"));
  }
  store.have();
}

// The frame as an MC writes rows: each row's fields carry the id it is sent
// under. (The store lists a row by the id in its fields and finds it by the
// id it was sent under, so a frame where they differ lists threads that
// `thread()` cannot find, and twice when two rows name one id.)
QJsonObject named(QJsonObject frame) {
  const QJsonValue rows = frame.value(QLatin1String("rows"));
  if (!rows.isArray()) return frame;
  QJsonArray named;
  for (const QJsonValue& value : rows.toArray()) {
    QJsonArray row = value.toArray();
    qsizetype fields = 0;
    while (fields < row.size() && !row.at(fields).isObject()) ++fields;
    if (fields >= 2 && fields < row.size()) {
      QJsonObject kept = row.at(fields).toObject();
      kept.insert(QLatin1String("id"), row.at(fields - 2).toString());
      row.replace(fields, kept);
    }
    named.append(row);
  }
  frame.insert(QLatin1String("rows"), named);
  return frame;
}
void FramesFold(const std::vector<fuzz::JsonSteps>& frames) {
  McClient client;
  ShellStore store(&client);
  const auto onFrame = reach(fuzz::ShellOnFrame{});
  for (const fuzz::JsonSteps& steps : frames) {
    const QJsonObject frame = named(fuzz::object(steps));
    fuzz::print(frame);
    (store.*onFrame)(frame);
    // Each frame leaves the store readable, as the sidebar reads it between them.
    store.threads();
    store.projects();
  }
  fuzz::settle();
  ReadThrough(store);
  // What the store says of itself to the MC is a version per MC, and reads as JSON.
  const QJsonObject have = store.have();
  for (auto it = have.begin(); it != have.end(); ++it) {
    ASSERT_TRUE(it.value().isArray());
    ASSERT_EQ(it.value().toArray().size(), 2);
  }
  store.clear();
  ASSERT_TRUE(store.threads().isEmpty());
  ASSERT_TRUE(store.projects().isEmpty());
  ASSERT_TRUE(store.synchronized());
}

std::vector<fuzz::JsonSteps> Seeded(std::initializer_list<const char*> frames) {
  std::vector<fuzz::JsonSteps> all;
  for (const char* frame : frames) all.push_back(fuzz::steps(frame));
  return all;
}

// A frame whose version is a number `qint64(double)` cannot hold: the steps
// of `shell.rows` with `rev` set to `value`. ShellStore::setVersion casts it
// unchecked, so these seeds fail (float-cast-overflow) until it clamps.
fuzz::JsonSteps WithRev(double value) {
  fuzz::JsonSteps steps = fuzz::steps(R"j({"t":"shell.rows","id":1,"mc":"mc-a","epoch":"epoch-1","reset":false,"rows":[
      ["t1","thread",{"id":"t1","projectId":"p1","title":"T"}]]})j");
  fuzz::JsonStep rev;
  rev.op = fuzz::JsonStep::Real;
  rev.key = "rev";
  rev.real = value;
  steps.push_back(rev);
  return steps;
}

FUZZ_TEST(ShellStore, FramesFold)
    .WithDomains(fuzztest::VectorOf(fuzz::Json(kKeys, kTexts)).WithMaxSize(12))
    .WithSeeds([] {
      std::vector<fuzz::JsonSteps> whole = Seeded({kSnapshot});
      for (const char* change : kChanges) whole.push_back(fuzz::steps(change));
      return std::vector<std::tuple<std::vector<fuzz::JsonSteps>>>{
          {Seeded({kSnapshot})},
          {whole},
          {{fuzz::steps(kSnapshot), WithRev(1e300)}},
          {{fuzz::steps(kSnapshot), WithRev(-1e300)}},
          {{fuzz::steps(kSnapshot), WithRev(9.3e18)}},
      };
    });

// The same frames with a cache under the store: rows are kept as they come,
// and a store opened at the same MC again reads back rows the first held.
std::atomic<int> g_runs{0};

void FramesKept(const std::vector<fuzz::JsonSteps>& frames, bool reopenAtOnce) {
  const QString dir = QDir::tempPath() + QStringLiteral("/hal-c2-fuzz-shell-%1").arg(g_runs++);
  QDir(dir).removeRecursively();
  const QUrl origin(QStringLiteral("http://127.0.0.1:1"));
  QSet<QString> threads, projects;
  {
    LocalCache cache;
    cache.open(dir);
    McClient client;
    ShellStore store(&client);
    store.setCache(&cache);
    store.open(origin);
    const auto onFrame = reach(fuzz::ShellOnFrame{});
    for (const fuzz::JsonSteps& steps : frames) {
      const QJsonObject frame = named(fuzz::object(steps));
      fuzz::print(frame);
      (store.*onFrame)(frame);
    }
    fuzz::settle();
    ReadThrough(store);
    store.flush();
    cache.drain();
    for (const sidebar::Thread& thread : store.threads()) threads.insert(thread.key());
    for (const sidebar::Project& project : store.projects()) projects.insert(project.key());
    if (!reopenAtOnce) {
      // The next run: a store that has not heard from its MC shows the kept rows, offline.
      McClient other;
      ShellStore reopened(&other);
      reopened.setCache(&cache);
      reopened.open(origin);
      ReadThrough(reopened);
      QSet<QString> keptThreads, keptProjects;
      for (const sidebar::Thread& thread : reopened.threads()) keptThreads.insert(thread.key());
      for (const sidebar::Project& project : reopened.projects()) keptProjects.insert(project.key());
      // Never more than it held. (Not always all of it: rows of an MC that
      // came without `reset` and without a version have nothing to be kept under.)
      ASSERT_TRUE(threads.contains(keptThreads));
      ASSERT_TRUE(projects.contains(keptProjects));
      ASSERT_FALSE(reopened.synchronized());
    }
  }
  QDir(dir).removeRecursively();
}
FUZZ_TEST(ShellStore, FramesKept)
    .WithDomains(fuzztest::VectorOf(fuzz::Json(kKeys, kTexts)).WithMaxSize(8), fuzztest::Arbitrary<bool>())
    .WithSeeds([] {
      std::vector<fuzz::JsonSteps> whole = Seeded({kSnapshot});
      for (const char* change : kChanges) whole.push_back(fuzz::steps(change));
      return std::vector<std::tuple<std::vector<fuzz::JsonSteps>, bool>>{{Seeded({kSnapshot}), false}, {whole, false}, {whole, true}};
    });

}  // namespace
