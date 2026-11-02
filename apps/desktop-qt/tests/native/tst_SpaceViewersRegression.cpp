// What review found in who else is on a page: an MC that cannot say answers an error
// on the subscription and forgets it. The client kept the names it last heard and never
// asked again until it changed page or reconnected.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SpaceController.h"

namespace {

const QString kPresence = QStringLiteral("spacePresence");

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QStringList devices{QStringLiteral("Phone")};

  Shell() {
    mc.onShape(kPresence, [this](int id, const QJsonObject&) { mc.send(viewers(id)); });
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    // Held off, so a test sees the wait; `askAgain` ends it.
    space()->setViewersRetryMs(60'000);
  }

  SpaceController* space() { return native.controller<SpaceController>(); }
  QTimer* retry() { return space()->findChild<QTimer*>(QStringLiteral("spaceViewersRetry")); }
  QStringList shown() { return space()->viewers().value(QStringLiteral("devices")).toStringList(); }

  QJsonObject viewers(int id) const {
    return {{QStringLiteral("t"), kPresence}, {QStringLiteral("id"), id},
            {QStringLiteral("viewers"), QJsonArray{QJsonObject{{QStringLiteral("type"), QStringLiteral("user")}, {QStringLiteral("devices"), QJsonArray::fromStringList(devices)}}}}};
  }

  // The route open on a page, with what the MC says about it shown.
  void openPage() {
    QJsonArray rows{QJsonArray{QStringLiteral("space"), QStringLiteral("s1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("s1")}, {QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}}};
    space()->receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    space()->selectSpace(QStringLiteral("s1"));
    QJsonArray pages{QJsonArray{QStringLiteral("page"), QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("Roadmap")}, {QStringLiteral("parentPageId"), QJsonValue::Null}, {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}}};
    space()->receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), pages}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    space()->selectPage(QStringLiteral("p1"));
    native.controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("space")));
  }

  void askAgain() {
    space()->setViewersRetryMs(5);
    retry()->start();
  }

  // The MC turns the one subscriber down.
  void refuse() {
    const int id = mc.subscribers(kPresence).value(0);
    mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("MC unavailable: noconnection")}});
    mc.forget(id);
  }
};

}  // namespace

class SpaceViewersRegression : public QObject {
  Q_OBJECT

private slots:
  void aRefusedPageSaysNobodyAndAsksAgain() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.openPage();
    QTRY_COMPARE(shell.shown(), QStringList{QStringLiteral("Phone")});

    shell.devices = {QStringLiteral("Laptop")};
    shell.refuse();
    QTRY_VERIFY(shell.shown().isEmpty());
    QVERIFY(shell.mc.subscribers(kPresence).isEmpty());
    shell.askAgain();
    QTRY_COMPARE(shell.shown(), QStringList{QStringLiteral("Laptop")});
    QCOMPARE(shell.mc.subscribers(kPresence).size(), 1);
  }

  void aPageLeftWhileRefusedIsNotAskedFor() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());
    shell.openPage();
    QTRY_COMPARE(shell.shown(), QStringList{QStringLiteral("Phone")});

    shell.refuse();
    QTRY_VERIFY(shell.retry()->isActive());
    shell.native.controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("usage")));
    shell.askAgain();
    QTRY_VERIFY(!shell.retry()->isActive());
    QVERIFY(shell.mc.subscribers(kPresence).isEmpty());
    QVERIFY(shell.shown().isEmpty());
  }
};

QTEST_MAIN(SpaceViewersRegression)
#include "tst_SpaceViewersRegression.moc"
