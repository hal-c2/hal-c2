// What tests/prop/tst_SyncThreadProp.cpp found in the threads the shell
// follows, each as the plain case that shows it.

#include <QtTest>

#include "FakeMc.h"
#include "LocalCache.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"

class SyncThreadRegression : public QObject {
  Q_OBJECT

private slots:
  // A thread opened while its MC is away, and deleted there meanwhile, closes
  // when the reconnect says so, even if its cached copy was still loading:
  // it was only counted as listed once the copy was in, so it stayed open.
  void aThreadDeletedWhileItsCopyLoadsCloses() {
    QTemporaryDir home;
    FakeMc mc;
    mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("P")}});
    mc.threads.insert(QStringLiteral("t1"),
                      {{QStringLiteral("id"), QStringLiteral("t1")}, {QStringLiteral("title"), QStringLiteral("t1")}, {QStringLiteral("projectId"), QStringLiteral("p1")}});
    ShellBridge bridge;
    NativeShell native(&bridge);
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native.controller<PluginController>()->setConfigDir(home.filePath(QStringLiteral("config")));
    native.open(mc.origin(), QStringLiteral("token"));
    ShellStore* store = native.store();
    QTRY_VERIFY(native.client()->isReady() && store->synchronized() && store->thread(QStringLiteral("env-a:t1")));

    mc.stopAccepting();
    mc.drop();
    QTRY_VERIFY(!native.client()->isReady());

    // Work queued ahead of the copy keeps it loading until the reconnect lands.
    LocalCache* cache = native.cache();
    for (int i = 0; i < 60; ++i) {
      cache::ThreadUpdate busy{QStringLiteral("env-a:busy%1").arg(i), {QStringLiteral("h"), 1, {}}, true, {}, {}};
      for (int j = 0; j < 2000; ++j) busy.put.append({QStringLiteral("plan"), QString::number(j), {{QStringLiteral("n"), j}}, {}});
      cache->storeThread(busy);
    }
    QObject waiting;
    bool loaded = false;
    cache->loadThread(QStringLiteral("env-a:busy0"), &waiting, [&loaded](const cache::Thread&) { loaded = true; });
    ThreadStore* threads = native.controller<ThreadStore>();
    threads->open(QStringLiteral("env-a:t1"));

    const quint64 snapshots = store->snapshots();
    mc.threads.remove(QStringLiteral("t1"));
    mc.startAccepting();
    QTRY_VERIFY(store->snapshots() > snapshots && store->synchronized());
    QVERIFY2(!loaded, "the copy was in before the reconnect: the case did not happen");
    QVERIFY(!store->thread(QStringLiteral("env-a:t1")));

    QTRY_VERIFY(loaded);
    QTRY_COMPARE(threads->openThreads(), QStringList());
  }

  // A thread paged back through and left held every turn it was sent while it
  // was kept warm. Left, it keeps about what it opens with, and follows again
  // from the floor that raises, once, on one subscription.
  void aThreadLeftLetsGoOfItsEarlierTurns() {
    QTemporaryDir home;
    FakeMc mc;
    mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("P")}});
    for (const QString& id : {QStringLiteral("t1"), QStringLiteral("t2")}) {
      mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("projectId"), QStringLiteral("p1")}});
    }
    // t1 has ten runs of 50 turn items; the MC sends a new follower the
    // whole thread, and one that resumes only that it is live.
    // (The handler sees the shape; where the follower resumes is in its `sub` frame.)
    mc.onShape(QStringLiteral("stream"), [&mc](int id, const QJsonObject& shape) {
      const QJsonObject live{{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("log-1")}};
      if (mc.subscriptions.last().value(QLatin1String("offset")).isDouble()) return mc.send(live);
      QJsonArray rows;
      if (shape.value(QLatin1String("stream")).toString() == QLatin1String("t1")) {
        for (int run = 1; run <= 10; ++run) {
          const QString runId = QStringLiteral("run-%1").arg(run);
          rows.append(QJsonArray{QStringLiteral("run"), runId,
                                 QJsonObject{{QStringLiteral("id"), runId}, {QStringLiteral("ordinal"), run}, {QStringLiteral("status"), QStringLiteral("completed")}}});
          for (int i = 0; i < 50; ++i) {
            const QString item = QStringLiteral("item-%1-%2").arg(run).arg(i);
            rows.append(QJsonArray{QStringLiteral("turn-item"), item,
                                   QJsonObject{{QStringLiteral("id"), item},
                                               {QStringLiteral("type"), i == 0 ? QStringLiteral("user_message") : QStringLiteral("assistant_message")},
                                               {QStringLiteral("runId"), runId},
                                               {QStringLiteral("ordinal"), run * 100 + i},
                                               {QStringLiteral("status"), QStringLiteral("completed")},
                                               {QStringLiteral("text"), item}}});
          }
        }
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 1},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send(live);
    });
    ShellBridge bridge;
    NativeShell native(&bridge);
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native.controller<PluginController>()->setConfigDir(home.filePath(QStringLiteral("config")));
    native.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(native.client()->isReady() && native.store()->synchronized() && native.store()->thread(QStringLiteral("env-a:t1")));
    ThreadStore* threads = native.controller<ThreadStore>();
    threads->open(QStringLiteral("env-a:t1"));
    TimelineModel* t1 = threads->timeline(QStringLiteral("env-a:t1"));
    QTRY_COMPARE(t1->status(), QStringLiteral("live"));
    QCOMPARE(t1->entities(QStringLiteral("turn-item")).size(), 500);

    threads->open(QStringLiteral("env-a:t2"));
    // The run read (the last) and the four above it that hold windowItems.
    QCOMPARE(t1->entities(QStringLiteral("turn-item")).size(), 250);
    // One subscription follows t1, the one made from the raised floor.
    const auto following = [&mc] {
      QList<QJsonObject> subs;
      for (const QJsonObject& sub : std::as_const(mc.subscriptions)) {
        if (mc.subscribers(QStringLiteral("stream")).contains(sub.value(QLatin1String("id")).toInt()) &&
            sub.value(QLatin1String("shape")).toObject().value(QLatin1String("stream")).toString() == QLatin1String("t1")) {
          subs.append(sub);
        }
      }
      return subs;
    };
    QTRY_VERIFY(!following().isEmpty() && following().first().value(QLatin1String("offset")).isDouble());
    QCOMPARE(following().size(), 1);
    QCOMPARE(following().first().value(QLatin1String("window")).toObject().value(QLatin1String("floor")).toInt(), 6);
    QTRY_COMPARE(t1->status(), QStringLiteral("live"));
    QCOMPARE(t1->entities(QStringLiteral("turn-item")).size(), 250);
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/sync-thread-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SyncThreadRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SyncThreadRegression.moc"
