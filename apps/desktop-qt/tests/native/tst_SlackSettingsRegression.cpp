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

QJsonObject off() {
  return {{QStringLiteral("state"), QStringLiteral("off")}, {QStringLiteral("tokensSet"), false}};
}

}  // namespace

class SlackSettingsRegression : public QObject {
  Q_OBJECT

private slots:
  // The page's own error (here Slack's refusal of a connect) outlived a newer
  // status: another client connecting Slack left "refused" beside "connected".
  void aNewerStatusReplacesTheLastRefusal() {
    QTemporaryDir home;
    FakeMc mc;
    QJsonObject status = off();
    mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("slack"), [&mc, &status](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), status}});
    });
    mc.onRpc(QStringLiteral("slack.connect"), [&mc](const FakeMc::Rpc& rpc) { mc.refuse(rpc, kRefusal); });
    ShellBridge bridge;
    NativeShell native(&bridge);
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    QTRY_VERIFY(native.isActive() && native.store()->synchronized());
    const auto section = [&bridge] { return bridge.state()->value(QStringLiteral("slackSettings")).toMap(); };

    native.controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/integrations")));
    QTRY_VERIFY(section().value(QStringLiteral("loaded")).toBool());
    bridge.dispatch(QStringLiteral("slackSettings.connect"),
                    QVariantMap{{QStringLiteral("botToken"), QStringLiteral("xoxb-refused")}, {QStringLiteral("appToken"), QStringLiteral("xapp-app")}});
    QTRY_COMPARE(section().value(QStringLiteral("error")).toString(), kRefusal);

    status = QJsonObject{{QStringLiteral("state"), QStringLiteral("connected")},
                         {QStringLiteral("team"), QStringLiteral("acme")},
                         {QStringLiteral("bot"), QStringLiteral("HAL")},
                         {QStringLiteral("tokensSet"), true}};
    for (const int id : mc.subscribers(QStringLiteral("slack"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("slack")}, {QStringLiteral("id"), id}, {QStringLiteral("status"), status}});
    }
    QTRY_COMPARE(section().value(QStringLiteral("state")).toString(), QStringLiteral("connected"));
    QCOMPARE(section().value(QStringLiteral("error")).toString(), QString());
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
