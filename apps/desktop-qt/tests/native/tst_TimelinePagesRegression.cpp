// A thread paged back through held every page it was sent: TimelineModel only
// ever added a page's turns, so the desktop's heap grew with every turn the
// user scrolled past (330 MB for one thread of 60,000 turn items) and stayed
// that size while the thread was kept warm.

#include <QTemporaryDir>
#include <QtTest>

#include "LocalCache.h"
#include "TimelineModel.h"

namespace {

const QString kKey = QStringLiteral("env-1:thread-1");
const QString kAt = QStringLiteral("2026-09-23T10:00:00Z");
constexpr int kRuns = 30;
constexpr int kItemsPerRun = 50;

QString runId(int run) {
  return QStringLiteral("run-%1").arg(run);
}

// Run `run`'s turn items: the user's message, calls, the agent's reply.
QJsonArray items(int run) {
  QJsonArray rows;
  for (int i = 0; i < kItemsPerRun; ++i) {
    const QString type = i == 0 ? QStringLiteral("user_message") : i + 1 == kItemsPerRun ? QStringLiteral("assistant_message") : QStringLiteral("command_execution");
    const QString id = QStringLiteral("item-%1-%2").arg(run).arg(i);
    rows.append(QJsonArray{QStringLiteral("turn-item"), id,
                           QJsonObject{{QStringLiteral("id"), id},
                                       {QStringLiteral("type"), type},
                                       {QStringLiteral("runId"), runId(run)},
                                       {QStringLiteral("ordinal"), run * 1000 + i},
                                       {QStringLiteral("status"), QStringLiteral("completed")},
                                       {QStringLiteral("text"), QStringLiteral("turn %1").arg(run)}}});
  }
  return rows;
}

QJsonValue nullable(int floor) {
  return floor > 1 ? QJsonValue(floor) : QJsonValue(QJsonValue::Null);
}

// Opens with the newest four runs (windowItems), then is live.
void open(TimelineModel& model) {
  QJsonArray rows;
  for (int run = 1; run <= kRuns; ++run) {
    rows.append(QJsonArray{QStringLiteral("run"), runId(run),
                           QJsonObject{{QStringLiteral("id"), runId(run)},
                                       {QStringLiteral("ordinal"), run},
                                       {QStringLiteral("status"), QStringLiteral("completed")},
                                       {QStringLiteral("startedAt"), kAt}}});
  }
  for (int run = kRuns - 3; run <= kRuns; ++run) {
    for (const QJsonValue& item : items(run)) rows.append(item);
  }
  model.subscribing();
  model.receive({{QStringLiteral("t"), QStringLiteral("snapshot")},
                 {QStringLiteral("part"), 0},
                 {QStringLiteral("rows"), rows},
                 {QStringLiteral("done"), true},
                 {QStringLiteral("offset"), 10},
                 {QStringLiteral("handle"), QStringLiteral("log-1")},
                 {QStringLiteral("floor"), kRuns - 3}});
  model.receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 10}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
}

// Pages back to the thread's first run, four runs a page, as the MC answers `more`.
void pageToStart(TimelineModel& model) {
  while (model.hasEarlier()) {
    const int floor = int(*model.cursor().floor);
    model.loadEarlier();
    QJsonArray rows;
    for (int run = std::max(1, floor - 4); run < floor; ++run) {
      for (const QJsonValue& item : items(run)) rows.append(item);
    }
    model.receive({{QStringLiteral("t"), QStringLiteral("page")},
                   {QStringLiteral("rows"), rows},
                   {QStringLiteral("done"), true},
                   {QStringLiteral("offset"), 10},
                   {QStringLiteral("floor"), nullable(std::max(1, floor - 4))}});
  }
}

}  // namespace

class TimelinePagesRegression : public QObject {
  Q_OBJECT

private slots:
  // Back at the end, the model lets go of all but windowItems turn items above
  // the turn read, the cache with it, and asks to follow from the raised floor.
  void turnsScrolledFarAwayAreLetGo() {
    QTemporaryDir dir;
    LocalCache cache;
    cache.open(dir.path());
    TimelineModel model(kKey);
    model.setCache(&cache);
    QSignalSpy raised(&model, &TimelineModel::windowRaised);
    QSignalSpy wanted(&model, &TimelineModel::earlierWanted);
    open(model);
    pageToStart(model);
    QCOMPARE(model.entities(QStringLiteral("turn-item")).size(), kRuns * kItemsPerRun);

    model.keepFrom(model.rowCount() - 1);
    QCOMPARE(raised.size(), 1);
    // The run read and the four above it that hold windowItems.
    QCOMPARE(model.entities(QStringLiteral("turn-item")).size(), 5 * kItemsPerRun);
    QCOMPARE(model.cursor().floor, std::optional<qint64>(kRuns - 4));
    QVERIFY(model.hasEarlier());
    const QJsonObject window = model.subscribing().value(QLatin1String("window")).toObject();
    QCOMPARE(window.value(QLatin1String("floor")).toInt(), kRuns - 4);

    // Read again from the same place, it has nothing more to let go of.
    model.keepFrom(model.rowCount() - 1);
    QCOMPARE(raised.size(), 1);

    // Scrolling back up asks for them again.
    model.receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 10}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    wanted.clear();
    model.loadEarlier();
    QCOMPARE(wanted.size(), 1);

    // The cached copy is as small.
    model.flush();
    cache::Thread kept;
    cache.loadThread(kKey, &cache, [&kept](const cache::Thread& thread) { kept = thread; });
    cache.drain();
    QCOMPARE(kept.cursor.floor, std::optional<qint64>(kRuns - 4));
    qsizetype keptItems = 0;
    for (const cache::Entity& entity : kept.entities) keptItems += entity.kind == QLatin1String("turn-item");
    QCOMPARE(keptItems, 5 * kItemsPerRun);
  }

  // What tests/prop/tst_TimelineModelProp.cpp found: rows and runs need not
  // be in the same order. Read from the fold of a turn whose calls came after
  // a later turn's message, keepFrom() took the run of the row below the fold
  // and let go of the turn being read.
  void aTurnReadIsKeptWhateverTheRowsOrder() {
    const auto entity = [](const QString& id, const QString& type, const QString& run, int ordinal) {
      return QJsonArray{QStringLiteral("turn-item"), id,
                        QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("type"), type}, {QStringLiteral("runId"), run},
                                    {QStringLiteral("ordinal"), ordinal}, {QStringLiteral("status"), QStringLiteral("completed")},
                                    {QStringLiteral("text"), id}}};
    };
    const auto run = [](const QString& id, int ordinal, const QString& status) {
      return QJsonArray{QStringLiteral("run"), id,
                        QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("ordinal"), ordinal}, {QStringLiteral("status"), status},
                                    {QStringLiteral("startedAt"), kAt}}};
    };
    const QJsonArray rows{run(QStringLiteral("run-a"), 1, QStringLiteral("interrupted")), run(QStringLiteral("run-b"), 2, QStringLiteral("completed")),
                          run(QStringLiteral("run-c"), 3, QStringLiteral("running")),
                          entity(QStringLiteral("ask-a"), QStringLiteral("user_message"), QStringLiteral("run-a"), 3),
                          entity(QStringLiteral("ask-b"), QStringLiteral("user_message"), QStringLiteral("run-b"), 4),
                          entity(QStringLiteral("call-a"), QStringLiteral("command_execution"), QStringLiteral("run-a"), 5),
                          entity(QStringLiteral("ask-c"), QStringLiteral("user_message"), QStringLiteral("run-c"), 6)};
    TimelineModel model(kKey);
    model.setKeep(1);
    QSignalSpy raised(&model, &TimelineModel::windowRaised);
    model.subscribing();
    model.receive({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
                   {QStringLiteral("done"), true}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("log-1")},
                   {QStringLiteral("floor"), QJsonValue::Null}});
    model.receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    int fold = -1;
    for (int at = 0; at < model.rowCount(); ++at) {
      if (model.data(model.index(at), TimelineModel::IdRole).toString() == QLatin1String("fold:run-a")) fold = at;
    }
    QVERIFY(fold > 0);
    model.keepFrom(fold);
    QCOMPARE(raised.size(), 0);
    QCOMPARE(model.entities(QStringLiteral("turn-item")).size(), 4);
  }

  // A thread read near its start keeps what is below the row read: the window
  // has a floor and no ceiling.
  void turnsBelowTheRowReadStay() {
    TimelineModel model(kKey);
    QSignalSpy raised(&model, &TimelineModel::windowRaised);
    open(model);
    pageToStart(model);
    model.keepFrom(0);
    QCOMPARE(raised.size(), 0);
    QCOMPARE(model.entities(QStringLiteral("turn-item")).size(), kRuns * kItemsPerRun);
  }
};

QTEST_GUILESS_MAIN(TimelinePagesRegression)
#include "tst_TimelinePagesRegression.moc"
