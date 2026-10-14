// What tests/prop/tst_SlackSettingsProp.cpp found in SlackSettingsController.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const QString kRefusal = QStringLiteral("Slack refused the bot token: invalid_auth");
const QString kIntegrations = QStringLiteral("/settings/integrations");

QJsonObject off() {
  return {{QStringLiteral("state"), QStringLiteral("off")}, {QStringLiteral("tokensSet"), false}};
}

QJsonObject connected() {
  return {{QStringLiteral("state"), QStringLiteral("connected")},
          {QStringLiteral("team"), QStringLiteral("acme")},
          {QStringLiteral("bot"), QStringLiteral("HAL")},
          {QStringLiteral("tokensSet"), true}};
}

// A fake MC whose HalC2.Slack holds `status`, pushed with push(). While
// `down` names why, the MC turns the slack shape down as the real one does
// when HalC2.Slack or the MC serving it cannot be reached.
struct Mc {
  FakeMc mc;
  QJsonObject status = off();
  QString down;

  Mc() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("slack"), [this](int id, const QJsonObject&) {
      if (!down.isEmpty()) {
        mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), down}});
        mc.forget(id);
        return;
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), status}});
    });
  }

  void push(const QJsonObject& now) {
    status = now;
    for (const int id : mc.subscribers(QStringLiteral("slack"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), status}});
    }
  }
};

// The app on `mc`, its stores in `home`.
struct Shell {
  ShellBridge bridge;
  NativeShell native{&bridge};

  Shell(const QTemporaryDir& home, FakeMc& mc) {
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
  }

  QVariantMap section() const { return bridge.state()->value(QStringLiteral("slackSettings")).toMap(); }
  void openIntegrations() { native.controller<NavigationController>()->open(NavigationController::Route::settings(kIntegrations)); }
};

}  // namespace

class SlackSettingsRegression : public QObject {
  Q_OBJECT

private slots:
  // The page's own error (here Slack's refusal of a connect) outlived a newer
  // status: another client connecting Slack left "refused" beside "connected".
  void aNewerStatusReplacesTheLastRefusal() {
    QTemporaryDir home;
    Mc mc;
    mc.mc.onRpc(QStringLiteral("slack.connect"), [&mc](const FakeMc::Rpc& rpc) { mc.mc.refuse(rpc, kRefusal); });
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.openIntegrations();
    QTRY_VERIFY(shell.section().value(QStringLiteral("loaded")).toBool());
    shell.bridge.dispatch(QStringLiteral("slackSettings.connect"),
                          QVariantMap{{QStringLiteral("botToken"), QStringLiteral("xoxb-refused")}, {QStringLiteral("appToken"), QStringLiteral("xapp-app")}});
    QTRY_COMPARE(shell.section().value(QStringLiteral("error")).toString(), kRefusal);

    mc.push(connected());
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("connected"));
    QCOMPARE(shell.section().value(QStringLiteral("error")).toString(), QString());
  }

  // A window restored on Integrations showed no Slack section until the user
  // went elsewhere and back: the route was there before the controller.
  void aWindowRestoredOnIntegrationsShowsSlack() {
    QTemporaryDir home;
    Mc mc;
    {
      Shell first(home, mc.mc);
      QTRY_VERIFY(first.native.isActive() && first.native.store()->synchronized());
      first.openIntegrations();
      QTRY_VERIFY(first.section().value(QStringLiteral("open")).toBool());
    }
    Shell again(home, mc.mc);
    QTRY_VERIFY(again.section().value(QStringLiteral("loaded")).toBool());
    QVERIFY(again.section().value(QStringLiteral("open")).toBool());
  }

  // The MC answers a call and pushes its status along different paths: a
  // connect's answer that arrived after another client's disconnect put back
  // "connected" with nothing more to come.
  void anAnswerOlderThanAPushedStatusIsIgnored() {
    QTemporaryDir home;
    Mc mc;
    mc.mc.onRpc(QStringLiteral("slack.connect"), [&mc](const FakeMc::Rpc& rpc) {
      mc.push(connected());
      mc.push(off());
      mc.mc.reply(rpc, connected());
    });
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.openIntegrations();
    QTRY_VERIFY(shell.section().value(QStringLiteral("loaded")).toBool());
    shell.bridge.dispatch(QStringLiteral("slackSettings.connect"),
                          QVariantMap{{QStringLiteral("botToken"), QStringLiteral("xoxb-bot")}, {QStringLiteral("appToken"), QStringLiteral("xapp-app")}});
    QCOMPARE(shell.section().value(QStringLiteral("pending")).toString(), QStringLiteral("connect"));
    QTRY_COMPARE(shell.section().value(QStringLiteral("pending")).toString(), QString());
    QCOMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("off"));
  }

  // The MC turning the slack shape down (HalC2.Slack not running, the MC
  // serving the environment out of reach) left the page loading for good,
  // every action off, with nothing to bring it back once Slack was up again.
  void aSlackThatCouldNotLoadSaysWhyAndTriesAgain() {
    QTemporaryDir home;
    Mc mc;
    mc.down = QStringLiteral("MC unavailable: noconnection");
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.openIntegrations();
    QTRY_VERIFY(shell.section().value(QStringLiteral("failed")).toBool());
    QCOMPARE(shell.section().value(QStringLiteral("error")).toString(), mc.down);
    QVERIFY(!shell.section().value(QStringLiteral("loaded")).toBool());
    QVERIFY(!shell.section().value(QStringLiteral("editable")).toBool());

    mc.down.clear();
    mc.status = connected();
    shell.bridge.dispatch(QStringLiteral("slackSettings.retry"), QVariantMap{});
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("connected"));
    QVERIFY(shell.section().value(QStringLiteral("loaded")).toBool());
    QVERIFY(!shell.section().value(QStringLiteral("failed")).toBool());
    QCOMPARE(shell.section().value(QStringLiteral("error")).toString(), QString());
    // The dead subscription went with the failure: only the retry's is live.
    QCOMPARE(mc.mc.subscribers(QStringLiteral("slack")).size(), 1);
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/slack-settings-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SlackSettingsRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SlackSettingsRegression.moc"
