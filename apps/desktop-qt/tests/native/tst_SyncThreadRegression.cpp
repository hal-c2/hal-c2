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
