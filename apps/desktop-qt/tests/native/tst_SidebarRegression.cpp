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
    QTRY_VERIFY(native->store()->threadRow(key(id)) == row);
  }

  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
};

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

  // A row's age counts from its last message, or on the settled shelf from when it
  // settled, not from the update time that pinning and settling also move.
  void aRowsAgeIsNotItsLastTidyUp() {
    const QString message = QStringLiteral("2026-09-23T06:00:00Z");
    const QString settledAt = QStringLiteral("2026-09-23T07:00:00Z");
    QJsonObject pinned = threadRow(QStringLiteral("t1"));
    pinned.insert(QStringLiteral("latestUserMessageAt"), message);
    pinned.insert(QStringLiteral("pinnedAt"), kAt);
    QJsonObject settled = threadRow(QStringLiteral("t2"));
    settled.insert(QStringLiteral("latestUserMessageAt"), message);
    settled.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
    settled.insert(QStringLiteral("settledAt"), settledAt);
    QJsonObject quiet = threadRow(QStringLiteral("t3"));
    sidebar::Capabilities capabilities;
    capabilities.snooze = true;
    capabilities.settlement = true;
    const sidebar::View view = sidebar::build({sidebar::threadFromRow(QStringLiteral("env-a"), pinned),
                                               sidebar::threadFromRow(QStringLiteral("env-a"), settled),
                                               sidebar::threadFromRow(QStringLiteral("env-a"), quiet)},
                                              sidebar::Input{}, std::nullopt, [capabilities](const QString&) { return capabilities; },
                                              *sidebar::parseIso(kAt));
    const auto timeAt = [&view](const char* section) {
      const QVariantList rows = view.state.value(QLatin1String(section)).toList();
      return rows.size() == 1 ? rows.first().toMap().value(QStringLiteral("timeAt")).toString() : QStringLiteral("not one row");
    };
    QCOMPARE(timeAt("pinned"), message);
    QCOMPARE(timeAt("settled"), settledAt);
    // A thread nobody has written in yet has only its update time.
    QCOMPARE(timeAt("active"), kAt);
  }

  // A thread selected while archived, or archived while selected, is not
  // selected once it is back in the list.
  void anArchivedThreadComesBackUnselected() {
    QTemporaryDir home;
    Shell shell(home.path(), {QStringLiteral("t1")});
    const QString key = shell.key(QStringLiteral("t1"));
    QTRY_VERIFY(shell.native->store()->thread(key).has_value());
    QJsonObject archived = threadRow(QStringLiteral("t1"));
    archived.insert(QStringLiteral("archivedAt"), kAt);
    shell.send(QStringLiteral("t1"), archived);

    shell.bridge.dispatch(QStringLiteral("thread.select.range"), QVariantMap{{QStringLiteral("key"), key}});
    shell.send(QStringLiteral("t1"), threadRow(QStringLiteral("t1")));

    QCOMPARE(shell.sidebar().value(QStringLiteral("selectedKeys")).toList(), QVariantList());
    QVERIFY(shell.native->sidebar()->selection().isEmpty());
  }

  // Back does not open a thread deleted since the window left it.
  void backSkipsADeletedThread() {
    QTemporaryDir home;
    Shell shell(home.path(), {QStringLiteral("t1")});
    const QString key = shell.key(QStringLiteral("t1"));
    QTRY_COMPARE(shell.route().kind, QStringLiteral("draft"));
    shell.bridge.dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    QCOMPARE(shell.route().threadKey, key);
    shell.bridge.dispatch(QStringLiteral("settings.open"), QVariantMap());
    QCOMPARE(shell.route().kind, QStringLiteral("settings"));

    shell.mc.threads.remove(QStringLiteral("t1"));
    shell.mc.sendRow(QStringLiteral("t1"), {{QStringLiteral("id"), QStringLiteral("t1")}, {QStringLiteral("deletedAt"), kAt}});
    QTRY_VERIFY(!shell.native->store()->thread(key));
    shell.navigation()->back();

    QCOMPARE(shell.route().kind, QStringLiteral("draft"));
  }

  // Back past the oldest place lands on a draft, and forward still goes to
  // where back left.
  void forwardSurvivesBackPastTheOldestPlace() {
    QTemporaryDir home;
    Shell shell(home.path(), {});
    QTRY_COMPARE(shell.route().kind, QStringLiteral("draft"));
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
