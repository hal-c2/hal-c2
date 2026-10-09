// The sidebar's order keys (SidebarModel.cpp, the pinned and active sections):
// the key between two neighbours, the spread of keys a section starts with, the
// writes a drag makes, and the thread and project rows the MC sends. Keys are
// base-26 strings that sort as text. Besides not crashing, a key between two
// valid neighbours sorts strictly between them, a spread reads strictly in
// order, and a drag writes keys that keep its section in order, whatever keys
// the threads held, without taking a key a hidden thread holds.

#include "Fuzz.h"
#include "SidebarModel.h"

#include <QSet>

#include <algorithm>
#include <cstdint>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// The keys the MC stores (client-runtime's state/threadSort.ts): one to three
// lowercase letters, never ending in "a".
const std::vector<std::string> kOrderWords{"a", "b", "m", "n", "y", "z", "za", "zb", "zz", "zy", "mz", "nb", "ny", "zyz", "nn"};

// Whether a key is one the MC's order keys can be: at most the longest key's
// letters, and a last letter that leaves room before it.
bool validKey(const QString& key) {
  if (key.isEmpty() || key.size() > sidebar::kMaxOrderKeyLength) return false;
  for (const QChar c : key) {
    if (c < QLatin1Char('a') || c > QLatin1Char('z')) return false;
  }
  return key.back() != QLatin1Char('a');
}

void OrderKeyBetweenIsBetween(const std::string& before, const std::string& after, bool hasBefore, bool hasAfter) {
  const sidebar::Nullable lower = hasBefore ? sidebar::Nullable(fuzz::utf8(before)) : std::nullopt;
  const sidebar::Nullable upper = hasAfter ? sidebar::Nullable(fuzz::utf8(after)) : std::nullopt;
  const sidebar::Nullable key = sidebar::orderKeyBetween(lower, upper);
  // An empty bound is the section's edge.
  const bool lowerOk = !lower || lower->isEmpty() || validKey(*lower);
  const bool upperOk = !upper || upper->isEmpty() || validKey(*upper);
  const bool ordered = !lower || !upper || lower->isEmpty() || upper->isEmpty() || *lower < *upper;
  if (!lowerOk || !upperOk || !ordered) {
    EXPECT_FALSE(key.has_value()) << "a key between corrupt or unordered bounds";
    return;
  }
  // A key is at most a letter longer than its lower bound, so only a longest one leaves no room.
  if (!key) {
    EXPECT_TRUE(lower && lower->size() == sidebar::kMaxOrderKeyLength)
        << "no key between " << (lower ? lower->toStdString() : "") << " and " << (upper ? upper->toStdString() : "");
    return;
  }
  fuzz::print(QJsonArray{lower.value_or(QString()), upper.value_or(QString()), *key});
  EXPECT_TRUE(validKey(*key)) << "key " << key->toStdString();
  if (lower && !lower->isEmpty()) EXPECT_LT(*lower, *key) << "not after its lower bound";
  if (upper && !upper->isEmpty()) EXPECT_LT(*key, *upper) << "not before its upper bound";
}
FUZZ_TEST(Sidebar, OrderKeyBetweenIsBetween)
    .WithDomains(fuzz::Text(kOrderWords), fuzz::Text(kOrderWords), fuzztest::Arbitrary<bool>(), fuzztest::Arbitrary<bool>())
    .WithSeeds([] {
      // The keys a long section grows: the common prefix and the open edges, the longest keys, and
      // 10k- and 100k-letter ones no client writes (the midpoint once walked them a letter per frame).
      const std::string longZ(10000, 'z');
      const std::string longest(std::size_t(sidebar::kMaxOrderKeyLength), 'z');
      return std::vector<std::tuple<std::string, std::string, bool, bool>>{
          {"a", "b", true, true},
          {"y", "z", true, true},
          {"ya", "yb", true, true},
          {"zz", "", true, false},
          {"", "b", false, true},
          {"", "", false, false},
          {"b", "a", true, true},
          {"ya", "yb", true, false},
          {longZ, "", true, false},
          {longZ, "", false, false},
          {longZ, longZ + "z", true, true},
          {"", std::string(10000, 'a') + "b", false, true},
          {std::string(100000, 'z'), "", true, false},
          {longest, "", true, false},
          {"", longest, false, true},
          {longest.substr(1) + "y", longest, true, true},
      };
    });

void SpreadKeysIncrease(int count) {
  const QStringList keys = sidebar::spreadOrderKeys(count);
  ASSERT_EQ(keys.size(), count);
  fuzz::print(QJsonArray::fromStringList(keys));
  for (qsizetype index = 0; index < keys.size(); ++index) {
    EXPECT_TRUE(validKey(keys.at(index))) << keys.at(index).toStdString();
    if (index > 0) EXPECT_LT(keys.at(index - 1), keys.at(index)) << "spread keys out of order at " << index;
  }
}
FUZZ_TEST(Sidebar, SpreadKeysIncrease)
    .WithDomains(fuzztest::InRange(0, 2000))
    .WithSeeds({{0}, {1}, {2}, {25}, {26}, {675}, {676}, {677}, {2000}});

// One thread of a section as the drag sees it: whether it is shown, whether it
// has an order key and which, and where the section's order puts it.
struct PlanRow {
  bool shown = false;
  bool keyed = false;
  std::string orderKey;
  int rank = 0;
};

void PlanReorderHoldsUp(const std::vector<PlanRow>& rows, int moved) {
  std::vector<std::size_t> shown;
  for (std::size_t i = 0; i < rows.size(); ++i) {
    if (rows[i].shown) shown.push_back(i);
  }
  std::stable_sort(shown.begin(), shown.end(), [&rows](std::size_t left, std::size_t right) { return rows[left].rank < rows[right].rank; });
  if (shown.empty()) return;

  const auto keyOf = [](std::size_t i) { return QStringLiteral("t%1").arg(i); };
  QHash<QString, sidebar::Nullable> orderKeys;
  for (std::size_t i = 0; i < rows.size(); ++i) {
    orderKeys.insert(keyOf(i), rows[i].keyed ? sidebar::Nullable(fuzz::utf8(rows[i].orderKey)) : std::nullopt);
  }
  QStringList ordered;
  for (std::size_t i : shown) ordered.append(keyOf(i));
  const QString movedKey = ordered.at(qsizetype(static_cast<unsigned int>(moved) % unsigned(ordered.size())));
  fuzz::print(QJsonObject{{QStringLiteral("moved"), movedKey}, {QStringLiteral("ordered"), QJsonArray::fromStringList(ordered)}});

  const QList<sidebar::OrderAssignment> plan = sidebar::planReorder(ordered, orderKeys, movedKey);
  QHash<QString, sidebar::Nullable> after = orderKeys;
  QSet<QString> assigned;
  for (const sidebar::OrderAssignment& assignment : plan) {
    EXPECT_TRUE(ordered.contains(assignment.key)) << "wrote a key of a thread not in the section: " << assignment.key.toStdString();
    EXPECT_FALSE(assigned.contains(assignment.key)) << "two writes for " << assignment.key.toStdString();
    assigned.insert(assignment.key);
    EXPECT_TRUE(validKey(assignment.orderKey)) << assignment.orderKey.toStdString();
    after.insert(assignment.key, assignment.orderKey);
  }
  // A written key is not one a thread outside the section holds.
  for (const sidebar::OrderAssignment& assignment : plan) {
    for (std::size_t i = 0; i < rows.size(); ++i) {
      if (rows[i].shown || !rows[i].keyed) continue;
      EXPECT_NE(fuzz::utf8(rows[i].orderKey), assignment.orderKey) << "took the key of hidden " << keyOf(i).toStdString();
    }
  }
  // The moved thread and its neighbours hold keys after the drag, and the moved
  // one's sorts as text between theirs, whatever they held before it.
  const qsizetype at = ordered.indexOf(movedKey);
  const auto keyAt = [&](qsizetype index) { return after.value(ordered.at(index)); };
  ASSERT_TRUE(keyAt(at).has_value()) << "the moved thread has no key";
  if (at > 0) {
    ASSERT_TRUE(keyAt(at - 1).has_value()) << "the thread before has no key";
    EXPECT_LT(*keyAt(at - 1), *keyAt(at)) << "moved before its neighbour";
  }
  if (at + 1 < ordered.size()) {
    ASSERT_TRUE(keyAt(at + 1).has_value()) << "the thread after has no key";
    EXPECT_LT(*keyAt(at), *keyAt(at + 1)) << "moved after its neighbour";
  }
}
FUZZ_TEST(Sidebar, PlanReorderHoldsUp)
    .WithDomains(fuzztest::VectorOf(fuzztest::StructOf<PlanRow>(fuzztest::Arbitrary<bool>(), fuzztest::Arbitrary<bool>(),
                                                                fuzz::Word(kOrderWords), fuzztest::Arbitrary<int>()))
                     .WithMaxSize(8),
                 fuzztest::Arbitrary<int>())
    .WithSeeds([] {
      return std::vector<std::tuple<std::vector<PlanRow>, int>>{
          // Three shown threads with keys, one hidden between them: the drag keeps to its neighbours.
          {{{true, true, "b", 0}, {false, true, "bm", 1}, {true, true, "n", 2}, {true, true, "y", 3}}, 2},
          // A neighbour without a key: the section gets fresh keys.
          {{{true, true, "b", 0}, {true, false, "", 1}, {true, true, "n", 2}}, 0},
          // Corrupt keys (out of order) take the fresh path too.
          {{{true, true, "z", 0}, {true, true, "b", 1}, {false, true, "m", 2}}, 1},
          // A drag to just before a thread whose stored key is empty: it sorts first as text.
          {{{true, true, "", 1}, {true, true, "n", 0}}, 0},
          // Stored keys that are not base-26 letters.
          {{{true, true, "\337", 1}, {true, true, "F", 0}}, 0},
          // A neighbour with a 100k-letter key, and one with the longest key at the open edge.
          {{{true, true, std::string(100000, 'z'), 0}, {true, true, "n", 1}}, 1},
          {{{true, true, std::string(std::size_t(sidebar::kMaxOrderKeyLength), 'z'), 0}, {true, true, "n", 1}}, 1},
      };
    });

// The rows of the MC's shell shape a thread and a project are read from. The
// keys follow the MC's: its ids, timestamps, run and runtime fields, order keys.
void ThreadFromRowHoldsUp(const std::string& environment, const fuzz::JsonSteps& steps) {
  const QString env = fuzz::utf8(environment);
  const QJsonObject row = fuzz::object(steps);
  fuzz::print(row);
  const sidebar::Thread thread = sidebar::threadFromRow(env, row);
  EXPECT_EQ(thread.key(), env + QLatin1Char(':') + thread.id);
  EXPECT_GE(thread.pendingBackgroundTasks, 0);
}
FUZZ_TEST(Sidebar, ThreadFromRowHoldsUp)
    .WithDomains(fuzz::Word({"env-a", "env-b", ""}),
                 fuzz::Json({"id", "projectId", "title", "branch", "createdAt", "updatedAt", "latestUserMessageAt", "archivedAt",
                             "lineage", "relationshipToParent", "interactionMode", "runtimeMode", "modelSelection",
                             "settledOverride", "settledAt", "unsettledAt", "snoozedUntil", "snoozedAt", "pinnedAt",
                             "pinOrderKey", "activeOrderKey", "lastVisitedAt", "moving", "label", "latestRunId",
                             "latestRunRequestedAt", "latestRunStartedAt", "latestRunCompletedAt", "activeRunId",
                             "activityRunStatus", "status", "activeProviderThreadId", "lastErrorClass", "pendingRuntimeRequest",
                             "kind", "hasActionableProposedPlan", "pendingBackgroundTasks", "plugin", "listed"},
                            {"t1", "p1", "Fix it", "main", "2026-09-23T10:00:00.000Z", "2026-09-23T10:05:00.000Z", "subagent",
                             "idle", "running", "completed", "failed", "error", "user_input", "approval", "default",
                             "full-access", "n", "zz", "b", "1", "a"}))
    .WithSeeds([] {
      return std::vector<std::tuple<std::string, fuzz::JsonSteps>>{
          {"env-a", fuzz::steps(R"j({"id":"t1","projectId":"p1","title":"Fix it","createdAt":"2026-09-23T10:00:00.000Z",
              "updatedAt":"2026-09-23T10:05:00.000Z","interactionMode":"default","runtimeMode":"full-access",
              "modelSelection":{"provider":"codex","model":"gpt-5"},"pinOrderKey":"n","activeOrderKey":null,
              "latestRunId":"r1","latestRunStatus":"completed","latestRunRequestedAt":"2026-09-23T10:00:01.000Z",
              "latestRunStartedAt":"2026-09-23T10:00:02.000Z","latestRunCompletedAt":"2026-09-23T10:04:00.000Z",
              "status":"idle","pendingBackgroundTasks":[],"plugin":{"id":"p","kind":"review","listed":false},
              "lineage":{"relationshipToParent":"subagent"},"moving":{"label":"to mac","environmentId":"env-b"}})j")},
          {"env-b", fuzz::steps(R"j({"id":"t2","status":"running","activeRunId":"r2","pendingRuntimeRequest":{"kind":"user_input"},
              "pendingBackgroundTasks":[{"id":"b1"}],"snoozedUntil":"2026-09-24T09:00:00.000Z","unsettledAt":42})j")},
      };
    });

void ProjectFromRowHoldsUp(const std::string& environment, const fuzz::JsonSteps& steps) {
  const QString env = fuzz::utf8(environment);
  const QJsonObject row = fuzz::object(steps);
  fuzz::print(row);
  const sidebar::Project project = sidebar::projectFromRow(env, row);
  EXPECT_EQ(project.key(), env + QLatin1Char(':') + project.id);
}
FUZZ_TEST(Sidebar, ProjectFromRowHoldsUp)
    .WithDomains(fuzz::Word({"env-a", ""}),
                 fuzz::Json({"id", "title", "workspaceRoot", "createdAt", "updatedAt", "repositoryIdentity", "canonicalKey",
                             "rootPath", "displayName", "name"},
                            {"p1", "Shop", "/work/env-a/p1", "2026-09-23T10:00:00.000Z", "repo-p1", "Shop", "null"}))
    .WithSeeds([] {
      return std::vector<std::tuple<std::string, fuzz::JsonSteps>>{
          {"env-a", fuzz::steps(R"j({"id":"p1","title":"Shop","workspaceRoot":"/work/env-a/p1",
              "createdAt":"2026-09-23T10:00:00.000Z","updatedAt":"2026-09-23T10:00:00.000Z",
              "repositoryIdentity":{"canonicalKey":"repo-p1","rootPath":"/work/env-a/p1","displayName":"Shop","name":"shop"}})j")},
      };
    });

}  // namespace
