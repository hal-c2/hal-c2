// What tests/prop/tst_RightPanelProp.cpp found in the right panel and the
// stage, each as the plain case that shows it.

#include <QtTest>

#include "Browser.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadPreviews.h"

namespace {

const QString kAt = QStringLiteral("2026-09-01T09:00:00Z");

// The app on a fake MC, looking at thread t1, kept in `home` (a temporary
// one when none is given). The MC lists `browsers` as t1's browser tabs.
struct Shell {
  QTemporaryDir temporary;
  QDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};

  explicit Shell(const QString& at = QString(), const QStringList& browsers = {}) : home(at.isEmpty() ? temporary.path() : at) {
    mc.onRpc(QStringLiteral("preview.list"), [this, browsers](const FakeMc::Rpc& rpc) {
      QJsonArray sessions;
      for (const QString& tabId : browsers) {
        sessions.append(QJsonObject{{QStringLiteral("tabId"), tabId},
                                    {QStringLiteral("threadId"), QStringLiteral("t1")},
                                    {QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("url"), QStringLiteral("http://localhost:5173/")}}}});
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), QStringLiteral("e1")}, {QStringLiteral("revision"), 1}});
    });
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), kAt},
                                                         {QStringLiteral("updatedAt"), kAt},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("Thread")},
                                                        {QStringLiteral("createdAt"), kAt},
                                                        {QStringLiteral("updatedAt"), kAt}});
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
  }

  RightPanelController* panel() { return native.controller<RightPanelController>(); }

  void openThread() {
    QTRY_VERIFY(native.isActive() && native.store()->threadOnline(QStringLiteral("env-a:t1")));
    native.controller<NavigationController>()->open(NavigationController::Route::thread(QStringLiteral("env-a:t1")));
  }

  // Waits for the MC's list of the thread's browser tabs to be read.
  bool listed() {
    return QTest::qWaitFor([this] { return panel()->previews()->status() == QLatin1String("ready"); }, 5000);
  }
};

}  // namespace

class RightPanelRegression : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { Browser::setSupported(true); }

  // Dismissing the stage while its focused pane is empty opened the panel on
  // no tab: it opens on a tab the stage showed.
  void dismissingTheStageFromAnEmptyPaneOpensATab() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->threadOnline(QStringLiteral("env-a:t1")));
    shell.native.controller<NavigationController>()->open(NavigationController::Route::thread(QStringLiteral("env-a:t1")));
    RightPanelController* panel = shell.panel();
    panel->showTab(QStringLiteral("diff"));
    panel->moveToStage(QStringLiteral("diff"));
    panel->setStageLayout(QStringLiteral("columns"));
    panel->focusPane(1);
    QCOMPARE(panel->stage().focusedTab(), QString());

    panel->dismissStage();

    QVERIFY(panel->stage().isEmpty());
    QVERIFY(panel->isOpen());
    QCOMPARE(panel->activeTab(), QStringLiteral("diff"));
    QCOMPARE(panel->shownTabs(), QStringList{QStringLiteral("diff")});
  }

  // A browser tab on the stage went to the side panel after a restart (and a
  // stage of only it closed, focus and all): it comes back on the stage once
  // the MC lists it again, and goes once the MC no longer does.
  void aStagedBrowserTabComesBackOnTheStage() {
    QTemporaryDir home;
    const QString tab = QStringLiteral("browser:tab-1");
    {
      Shell shell(home.path(), {QStringLiteral("tab-1")});
      shell.openThread();
      QVERIFY(shell.listed());
      RightPanelController* panel = shell.panel();
      QVERIFY(panel->tabIds().contains(tab));
      panel->moveToStage(tab);
      panel->toggleFocus();
      QCOMPARE(panel->stage().tabs, QStringList{tab});
      QVERIFY(panel->stage().focus);
    }
    {
      Shell shell(home.path(), {QStringLiteral("tab-1")});
      shell.openThread();
      QVERIFY(shell.listed());
      RightPanelController* panel = shell.panel();
      QCOMPARE(panel->stage().tabs, QStringList{tab});
      QVERIFY(panel->stage().focus);
      QCOMPARE(panel->stage().focusedTab(), tab);
      QVERIFY(panel->tabIds().contains(tab));
      QVERIFY(!panel->isOpen());
    }
    Shell shell(home.path());
    shell.openThread();
    QVERIFY(shell.listed());
    QVERIFY(shell.panel()->stage().isEmpty());
    QVERIFY(!shell.panel()->tabIds().contains(tab));
  }
};

QTEST_MAIN(RightPanelRegression)
#include "tst_RightPanelRegression.moc"
