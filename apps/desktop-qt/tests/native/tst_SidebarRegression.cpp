// What tests/prop/tst_SidebarProp.cpp found in the sidebar and in where the
// window goes, each as the plain case that shows it.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "TestTime.h"

namespace {

const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

QJsonObject threadRow(const QString& id) {
  return {
      {QStringLiteral("id"), id},
      {QStringLiteral("projectId"), QStringLiteral("p1")},
      {QStringLiteral("title"), id},
      {QStringLiteral("createdAt"), kAt},
      {QStringLiteral("updatedAt"), kAt},
  };
}

// The app on a fake MC with one project and the threads `ids`, its stores in `home`.
struct Shell {
  Shell(const QString& home, const QStringList& ids) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), kAt},
                                                 {QStringLiteral("updatedAt"), kAt},
                                             });
    for (const QString& id : ids) mc.threads.insert(id, threadRow(id));
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  QString key(const QString& id) const { return mc.environmentId + QLatin1Char(':') + id; }
  NavigationController* navigation() const { return native->controller<NavigationController>(); }
  const NavigationController::Route& route() const { return navigation()->route(); }
  QVariantMap sidebar() const { return bridge.state()->value(QStringLiteral("sidebar")).toMap(); }

  // The MC changes the row, and the shell has it.
  void send(const QString& id, const QJsonObject& row) {
    mc.threads.insert(id, row);
    mc.sendRow(id, row);
    HAL_C2_TRY_VERIFY(native->store()->threadRow(key(id)) == row);
  }

  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
};

// How many times the store lists the thread at `key`.
int listed(const ShellStore& store, const QString& key) {
  const QList<sidebar::Thread> threads = store.threads();
  return int(std::count_if(threads.begin(), threads.end(), [&key](const sidebar::Thread& thread) { return thread.key() == key; }));
}

}  // namespace

class SidebarRegression : public QObject {
  Q_OBJECT

private slots:
  // Two threads snoozed until the same time read in the same order whichever
  // MC's rows came first, as ties do in the other sections.
  void snoozedTiesReadTheSameEveryTime() {
    const QString until = QStringLiteral("2026-09-23T12:00:00Z");
    const auto snoozed = [&until](const QString& environment, const QString& id) {
      QJsonObject row = threadRow(id);
      row.insert(QStringLiteral("snoozedUntil"), until);
      return sidebar::threadFromRow(environment, row);
    };
    const auto order = [](const QList<sidebar::Thread>& threads) {
      sidebar::Capabilities capabilities;
      capabilities.snooze = true;
      capabilities.settlement = true;
      const sidebar::View view =
          sidebar::build(threads, sidebar::Input{}, std::nullopt, [capabilities](const QString&) { return capabilities; },
                         *sidebar::parseIso(kAt));
      return view.orderedKeys;
    };
    const sidebar::Thread own = snoozed(QStringLiteral("env-a"), QStringLiteral("t2"));
    const sidebar::Thread peer = snoozed(QStringLiteral("b"), QStringLiteral("t1"));
    const QStringList expected{QStringLiteral("b:t1"), QStringLiteral("env-a:t2")};
    QCOMPARE(order({own, peer}), expected);
    QCOMPARE(order({peer, own}), expected);
  }

  // A drag writes keys that sort the section as dropped, whatever the
  // neighbours hold: the MC kept a client's key unchecked, and an empty one
  // read as the section's edge while it sorts first (tst_SidebarOrderFuzz).
  void aDragPastACorruptKeyKeepsTheOrder() {
    const QString longKey(100000, QLatin1Char('z'));
    const QList<std::pair<QString, QString>> corrupt{
        {QString(), QStringLiteral("n")},
        {QStringLiteral("\u00df"), QStringLiteral("F")},
        {longKey, QStringLiteral("n")},
    };
    for (const auto& [first, second] : corrupt) {
      const QHash<QString, sidebar::Nullable> keys{{QStringLiteral("t0"), first}, {QStringLiteral("t1"), second}};
      const QStringList ordered{QStringLiteral("t1"), QStringLiteral("t0")};
      QHash<QString, sidebar::Nullable> after = keys;
      for (const sidebar::OrderAssignment& assignment : sidebar::planReorder(ordered, keys, QStringLiteral("t1"))) {
        after.insert(assignment.key, assignment.orderKey);
      }
      QVERIFY2(*after.value(QStringLiteral("t1")) < *after.value(QStringLiteral("t0")), qPrintable(first.left(8) + QLatin1Char('/') + second));
    }
  }

  // A key next to a very long one is found without a walk per letter, and a
  // key no client can store is no bound.
  void aKeyBesideALongOneIsQuick() {
    const QString longKey(100000, QLatin1Char('z'));
    QCOMPARE(sidebar::orderKeyBetween(longKey, std::nullopt), sidebar::Nullable());
    QCOMPARE(sidebar::orderKeyBetween(std::nullopt, longKey), sidebar::Nullable());
    const QString longest(sidebar::kMaxOrderKeyLength, QLatin1Char('z'));
    QCOMPARE(sidebar::orderKeyBetween(longest, std::nullopt), sidebar::Nullable());
    const sidebar::Nullable before = sidebar::orderKeyBetween(std::nullopt, longest);
    QVERIFY(before && *before < longest && before->size() <= sidebar::kMaxOrderKeyLength);
  }

  // A thread selected while archived, or archived while selected, is not
  // selected once it is back in the list.
  void anArchivedThreadComesBackUnselected() {
    QTemporaryDir home;
    Shell shell(home.path(), {QStringLiteral("t1")});
    const QString key = shell.key(QStringLiteral("t1"));
    HAL_C2_TRY_VERIFY(shell.native->store()->thread(key).has_value());
    QJsonObject archived = threadRow(QStringLiteral("t1"));
    archived.insert(QStringLiteral("archivedAt"), kAt);
    shell.send(QStringLiteral("t1"), archived);

    shell.bridge.dispatch(QStringLiteral("thread.select.range"), QVariantMap{{QStringLiteral("key"), key}});
    shell.send(QStringLiteral("t1"), threadRow(QStringLiteral("t1")));

    QCOMPARE(shell.sidebar().value(QStringLiteral("selectedKeys")).toList(), QVariantList());
    QVERIFY(shell.native->sidebar()->selection().isEmpty());
  }

  // A frame that names no MC is no member's: it once made a member of its own
  // that took the environment's rows too, so the thread was listed twice
  // (tst_ShellStoreFuzz).
  void aFrameNamingNoMcChangesNothing() {
    QTemporaryDir home;
    Shell shell(home.path(), {});
    shell.mc.join(QStringLiteral("b"));
    shell.mc.sendPeerRow(QStringLiteral("b"), QStringLiteral("t3"), threadRow(QStringLiteral("t3")));
    ShellStore* store = shell.native->store();
    HAL_C2_TRY_VERIFY(store->thread(QStringLiteral("b:t3")).has_value());

    shell.mc.sendShell({{QStringLiteral("t"), QStringLiteral("shell.rows")},
                        {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("t3"), QStringLiteral("thread"), threadRow(QStringLiteral("t3"))})}}});
    shell.mc.sendShell({{QStringLiteral("t"), QStringLiteral("shell.environment")},
                        {QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), QStringLiteral("b")}}}});
    // The frames come in order: once this row is in, so are they.
    shell.send(QStringLiteral("t1"), threadRow(QStringLiteral("t1")));

    QCOMPARE(listed(*store, QStringLiteral("b:t3")), 1);
    QCOMPARE(store->mcServing(QStringLiteral("b")), QStringLiteral("mc-b"));
  }

  // A member announced under another name (an MC's node name changes when it
  // becomes distributed) is the same machine: its former name goes, and its
  // threads are listed once.
  void aMemberUnderANewNameIsListedOnce() {
    QTemporaryDir home;
    Shell shell(home.path(), {});
    shell.mc.join(QStringLiteral("b"));
    shell.mc.sendPeerRow(QStringLiteral("b"), QStringLiteral("t3"), threadRow(QStringLiteral("t3")));
    ShellStore* store = shell.native->store();
    HAL_C2_TRY_VERIFY(store->thread(QStringLiteral("b:t3")).has_value());

    shell.mc.join(QStringLiteral("mc-b2"), QStringLiteral("b"));
    shell.send(QStringLiteral("t1"), threadRow(QStringLiteral("t1")));

    QCOMPARE(listed(*store, QStringLiteral("b:t3")), 1);
    QCOMPARE(store->mcServing(QStringLiteral("b")), QStringLiteral("mc-b2"));
    QCOMPARE(store->environmentOf(QStringLiteral("mc-b")), QString());
    QVERIFY(store->threadOnline(QStringLiteral("b:t3")));
  }

  // Back does not open a thread deleted since the window left it.
  void backSkipsADeletedThread() {
    QTemporaryDir home;
    Shell shell(home.path(), {QStringLiteral("t1")});
    const QString key = shell.key(QStringLiteral("t1"));
    HAL_C2_TRY_COMPARE(shell.route().kind, QStringLiteral("draft"));
    shell.bridge.dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    QCOMPARE(shell.route().threadKey, key);
    shell.bridge.dispatch(QStringLiteral("settings.open"), QVariantMap());
    QCOMPARE(shell.route().kind, QStringLiteral("settings"));

    shell.mc.threads.remove(QStringLiteral("t1"));
    shell.mc.sendRow(QStringLiteral("t1"), {{QStringLiteral("id"), QStringLiteral("t1")}, {QStringLiteral("deletedAt"), kAt}});
    HAL_C2_TRY_VERIFY(!shell.native->store()->thread(key));
    shell.navigation()->back();

    QCOMPARE(shell.route().kind, QStringLiteral("draft"));
  }

  // Back past the oldest place lands on a draft, and forward still goes to
  // where back left.
  void forwardSurvivesBackPastTheOldestPlace() {
    QTemporaryDir home;
    Shell shell(home.path(), {});
    HAL_C2_TRY_COMPARE(shell.route().kind, QStringLiteral("draft"));
    shell.bridge.dispatch(QStringLiteral("settings.open"), QVariantMap());
    shell.navigation()->back();
    QCOMPARE(shell.route().kind, QStringLiteral("draft"));
    shell.navigation()->back();
    QCOMPARE(shell.route().kind, QStringLiteral("draft"));

    shell.navigation()->forward();
    QCOMPARE(shell.route().kind, QStringLiteral("settings"));
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/sidebar-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SidebarRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SidebarRegression.moc"
