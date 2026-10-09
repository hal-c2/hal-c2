// What tests/prop/tst_SyncThreadProp.cpp found in the threads the shell
// follows, each as the plain case that shows it.

#include <QtTest>

#include "../fuzz/Reach.h"
#include "FakeMc.h"
#include "LocalCache.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TestTime.h"

namespace halc2::fuzz {
// onFrame is private: the subscription's handler is its only caller.
struct ShellOnFrame {
  using type = void (ShellStore::*)(const QJsonObject&);
  friend type reach(ShellOnFrame);
};
template struct Reach<ShellOnFrame, &ShellStore::onFrame>;
}  // namespace halc2::fuzz

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
    HAL_C2_TRY_VERIFY(native.client()->isReady() && store->synchronized() && store->thread(QStringLiteral("env-a:t1")));

    mc.stopAccepting();
    mc.drop();
    HAL_C2_TRY_VERIFY(!native.client()->isReady());

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
    HAL_C2_TRY_VERIFY(store->snapshots() > snapshots && store->synchronized());
    QVERIFY2(!loaded, "the copy was in before the reconnect: the case did not happen");
    QVERIFY(!store->thread(QStringLiteral("env-a:t1")));

    HAL_C2_TRY_VERIFY(loaded);
    HAL_C2_TRY_COMPARE(threads->openThreads(), QStringList());
  }

  // A rev outside qint64 (1e300 from the MC) was cast anyway, which is
  // undefined. It reads as no rev: the MC is unversioned, so the next
  // subscription asks for all its rows, not the ones since a rev it never had.
  void aRevOutOfRangeLeavesTheMcUnversioned() {
    McClient client;
    ShellStore store(&client);
    const auto onFrame = reach(halc2::fuzz::ShellOnFrame{});
    const auto rows = [&](const char* mc, const QByteArray& rev) {
      const QByteArray json = "{\"t\":\"shell.rows\",\"mc\":\"" + QByteArray(mc) + "\",\"epoch\":\"e1\",\"rev\":" + rev + ",\"rows\":[]}";
      (store.*onFrame)(QJsonDocument::fromJson(json).object());
    };
    rows("mc-ok", "7");
    for (const char* rev : {"1e300", "-1e300", "9.3e18", "1.5"}) rows("mc-bad", rev);
    QCOMPARE(store.have().value(QStringLiteral("mc-ok")).toArray(), (QJsonArray{QStringLiteral("e1"), 7}));
    QVERIFY(!store.have().contains(QStringLiteral("mc-bad")));
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
