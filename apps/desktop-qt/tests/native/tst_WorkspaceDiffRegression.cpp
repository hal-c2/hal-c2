// What tests/prop/tst_WorkspaceDiffProp.cpp and tst_WorkspaceThreadDiffProp.cpp
// found in DiffModel and ThreadDiff.

#include <QtTest>

#include <QJsonArray>

#include "DiffModel.h"
#include "FakeMc.h"
#include "McClient.h"
#include "ThreadDiff.h"
#include "TimelineModel.h"

namespace {

QString patchOf(const QStringList& files) {
  QString patch;
  for (const QString& file : files) {
    patch += QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1 +1 @@\n-old\n+new\n").arg(file);
  }
  return patch;
}

// An MC that holds every diff until the test answers it, and a thread whose
// checkpoints stream into its timeline.
struct Held {
  FakeMc mc;
  McClient client;
  QList<FakeMc::Rpc> calls;
  TimelineModel timeline{QStringLiteral("env-a:t1")};
  ThreadDiff diff{&client, [](const QString&, const QString&, const QString&) {}};

  Held() {
    const auto hold = [this](const FakeMc::Rpc& rpc) { calls.append(rpc); };
    for (const char* method : {"orchestration.getTurnDiff", "orchestration.getFullThreadDiff", "review.getDiffPreview"}) {
      mc.onRpc(QString::fromLatin1(method), hold);
    }
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
  }

  bool ready() { return QTest::qWaitFor([this] { return client.isReady(); }); }
  bool asked(qsizetype count) { return sync() && calls.size() == count; }
  // Once this comes back, every call sent before it reached the MC and every
  // answer sent before it was read.
  bool sync() {
    bool done = false;
    QObject context;
    client.call(&context, {}, QStringLiteral("test.barrier"), {}, [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    return QTest::qWaitFor([&done] { return done; });
  }
  bool answer(qsizetype call, const QJsonObject& result) {
    mc.reply(calls.at(call), result);
    return sync();
  }
  bool answer(qsizetype call, const QStringList& files) { return answer(call, QJsonObject{{QStringLiteral("diff"), patchOf(files)}}); }
  bool answerReview(qsizetype call, const QString& base) {
    QJsonArray sources;
    for (const QString& kind : {QStringLiteral("working-tree"), QStringLiteral("branch-range")}) {
      sources.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("diff"), patchOf({QStringLiteral("a.txt")})},
                                 {QStringLiteral("baseRef"), base}, {QStringLiteral("headRef"), QStringLiteral("feature")}});
    }
    return answer(call, QJsonObject{{QStringLiteral("sources"), sources}});
  }

  // The thread's checkpoints: {id, turn, status}.
  void stream(const QList<std::tuple<QString, int, QString>>& checkpoints) {
    QJsonArray rows;
    for (const auto& [id, turn, status] : checkpoints) {
      rows.append(QJsonArray{QStringLiteral("checkpoint"), id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("appRunOrdinal"), turn}, {QStringLiteral("status"), status}}});
    }
    timeline.receive({{QStringLiteral("t"), QStringLiteral("snapshot")},
                      {QStringLiteral("part"), 0},
                      {QStringLiteral("done"), true},
                      {QStringLiteral("rows"), rows},
                      {QStringLiteral("offset"), int(checkpoints.size())},
                      {QStringLiteral("handle"), QStringLiteral("log")}});
  }
};

}  // namespace

class WorkspaceDiffRegression : public QObject {
  Q_OBJECT

private slots:
  // expansionChanged (allExpanded's signal) fired once per file on expand
  // all, and on every toggle even when allExpanded stayed false.
  void expandingSaysOnceThatAllAreExpanded() {
    DiffModel model;
    model.setCollapsedByDefault(true);
    model.setPatch(patchOf({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")}));
    QSignalSpy expansion(&model, &DiffModel::expansionChanged);
    model.setExpanded(0, true);
    QCOMPARE(expansion.count(), 0);
    model.expandAll();
    QCOMPARE(expansion.count(), 1);
    QVERIFY(model.allExpanded());
    model.expandAll();
    QCOMPARE(expansion.count(), 1);
  }

  // excerpt returned early on first <= 0 before swapping a reversed range, so
  // lines 1 to 0 read as line 1 while 0 to 1 read as nothing.
  void anExcerptReadsTheSameEitherWayRound() {
    DiffModel model;
    model.setPatch(QStringLiteral("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n"));
    QCOMPARE(model.excerpt(0, QStringLiteral("new"), 3, 1), model.excerpt(0, QStringLiteral("new"), 1, 3));
    QVERIFY(!model.excerpt(0, QStringLiteral("new"), 1, 3).isEmpty());
    QCOMPARE(model.excerpt(0, QStringLiteral("new"), 1, 0), model.excerpt(0, QStringLiteral("new"), 0, 1));
    QVERIFY(model.excerpt(0, QStringLiteral("new"), 1, 0).isEmpty());
    QVERIFY(model.excerpt(0, QStringLiteral("new"), -2, 2).isEmpty());
    QVERIFY(model.excerpt(0, QStringLiteral("new"), 2, -2).isEmpty());
  }

  // The latest turn's file summary came after its checkpoint was ready, and
  // turnsChanged stayed quiet: the right panel never opened the diff of a
  // turn that changed many files.
  void aLateFileSummarySaysTurnsChanged() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("ready")}});
    QCOMPARE(held.diff.latestTurn(), 1);
    QSignalSpy turns(&held.diff, &ThreadDiff::turnsChanged);
    const QJsonArray files{QJsonObject{{QStringLiteral("path"), QStringLiteral("a.txt")}, {QStringLiteral("additions"), 1}, {QStringLiteral("deletions"), 1}}};
    held.timeline.receive({{QStringLiteral("t"), QStringLiteral("snapshot")},
                           {QStringLiteral("part"), 0},
                           {QStringLiteral("done"), true},
                           {QStringLiteral("rows"), QJsonArray{QJsonArray{QStringLiteral("checkpoint"), QStringLiteral("cp-1"),
                                                                          QJsonObject{{QStringLiteral("id"), QStringLiteral("cp-1")},
                                                                                      {QStringLiteral("appRunOrdinal"), 1},
                                                                                      {QStringLiteral("status"), QStringLiteral("ready")},
                                                                                      {QStringLiteral("files"), files}}}}},
                           {QStringLiteral("offset"), 1},
                           {QStringLiteral("handle"), QStringLiteral("log")}});
    QCOMPARE(held.diff.latestCheckpoint().value(QLatin1String("files")).toArray(), files);
    QCOMPARE(turns.count(), 1);
  }

  // A turn's diff was asked once the turn was ready, and not again when the
  // turn before it became ready: it stayed a diff against no checkpoint.
  void aTurnIsDiffedAgainWhenTheTurnBeforeItIsReady() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setActive(true);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("pending")}, {QStringLiteral("cp-2"), 2, QStringLiteral("ready")}});
    QVERIFY(held.asked(1));
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("ready")}, {QStringLiteral("cp-2"), 2, QStringLiteral("ready")}});
    QVERIFY(held.asked(2));
    QCOMPARE(held.diff.status(), QStringLiteral("loading"));
  }

  // Rewound while hidden, and the next turn took the rewound one's number:
  // showing the tab again showed the rewound turn's diff.
  void aRewoundTurnsDiffIsNotShownForTheTurnThatTookItsNumber() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setActive(true);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("ready")}});
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringList{QStringLiteral("before-rewind.txt")}));
    held.diff.setActive(false);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("stale")}, {QStringLiteral("cp-2"), 1, QStringLiteral("ready")}});
    held.diff.setActive(true);
    QVERIFY(held.asked(2));
    QVERIFY(held.answer(1, QStringList{QStringLiteral("after-rewind.txt")}));
    QCOMPARE(held.diff.model()->paths(), QStringList{QStringLiteral("after-rewind.txt")});
  }

  // All changes stayed selected once the thread had no turns, though the
  // picker no longer offered it.
  void allChangesIsNotSelectedWithoutATurn() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.select(0);
    QCOMPARE(held.diff.selection(), -1);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("ready")}});
    held.diff.select(0);
    QCOMPARE(held.diff.selection(), 0);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("stale")}});
    QCOMPARE(held.diff.selection(), -1);
  }

  // The branch stayed selected after the checkout went away, and was asked
  // for with no checkout.
  void theBranchIsNotSelectedWithoutACheckout() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setCheckout(QStringLiteral("/c"));
    held.diff.select(ThreadDiff::Branch);
    held.diff.setCheckout(QString());
    QCOMPARE(held.diff.selection(), -1);
    QVERIFY(!held.diff.reviewing());
  }

  // The timeline went away and came back: the tab said "loading" for good,
  // since what it had loaded was still the same.
  void aTimelineThatComesBackLoadsAgain() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setCheckout(QStringLiteral("/c"));
    held.diff.setActive(true);
    QVERIFY(held.asked(1));
    QVERIFY(held.answerReview(0, QStringLiteral("main")));
    QCOMPARE(held.diff.status(), QStringLiteral("ready"));
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), nullptr);
    QCOMPARE(held.diff.status(), QStringLiteral("loading"));
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    QVERIFY(held.asked(2));
    QVERIFY(held.answerReview(1, QStringLiteral("main")));
    QCOMPARE(held.diff.status(), QStringLiteral("ready"));
  }

  // Another thread kept the last one's compared refs.
  void anotherThreadForgetsTheComparedRefs() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setCheckout(QStringLiteral("/c"));
    held.diff.setActive(true);
    QVERIFY(held.asked(1));
    QVERIFY(held.answerReview(0, QStringLiteral("main")));
    QCOMPARE(held.diff.comparedBase(), QStringLiteral("main"));
    QSignalSpy review(&held.diff, &ThreadDiff::reviewChanged);
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t2"), nullptr);
    QCOMPARE(held.diff.comparedBase(), QString());
    QCOMPARE(held.diff.comparedHead(), QString());
    QCOMPARE(review.count(), 1);
  }

  // Picking the turn shown (the latest, by number) while one file was
  // focused said all files were shown, and kept showing the one.
  void pickingTheSameDiffShowsAllItsFiles() {
    Held held;
    QVERIFY(held.ready());
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setActive(true);
    held.stream({{QStringLiteral("cp-1"), 1, QStringLiteral("ready")}});
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringList{QStringLiteral("a.txt"), QStringLiteral("b.txt")}));
    held.diff.focusFile(QStringLiteral("b.txt"));
    QCOMPARE(held.diff.model()->paths(), QStringList{QStringLiteral("b.txt")});
    held.diff.select(1);
    QVERIFY(held.asked(1));
    QCOMPARE(held.diff.focusPath(), QString());
    QCOMPARE(held.diff.model()->paths(), (QStringList{QStringLiteral("a.txt"), QStringLiteral("b.txt")}));
  }

  // Opening another thread in the same state flashed "idle" and back
  // (statusChanged twice); opening a thread said its focus changed when
  // nothing was focused.
  void anotherThreadInTheSameStateChangesNothing() {
    Held held;
    QVERIFY(held.ready());
    TimelineModel other(QStringLiteral("env-a:t2"));
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t1"), &held.timeline);
    held.diff.setActive(true);
    QCOMPARE(held.diff.status(), QStringLiteral("empty"));
    QSignalSpy status(&held.diff, &ThreadDiff::statusChanged);
    QSignalSpy focus(&held.diff, &ThreadDiff::focusChanged);
    QSignalSpy selection(&held.diff, &ThreadDiff::selectionChanged);
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t2"), &other);
    QCOMPARE(status.count(), 0);
    QCOMPARE(focus.count(), 0);
    QCOMPARE(selection.count(), 0);
    held.diff.setThread(QStringLiteral("env-a"), QStringLiteral("t2"), nullptr);
  }
};

QTEST_GUILESS_MAIN(WorkspaceDiffRegression)
#include "tst_WorkspaceDiffRegression.moc"
