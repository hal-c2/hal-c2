// What tests/prop/tst_ComposerProp.cpp and tst_ComposerPureProp.cpp found in
// the composer.

#include <QtTest>

#include "ComposerController.h"
#include "ComposerModel.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

// The app on a fake MC with one thread, its stores in `home`.
struct Shell {
  explicit Shell(const QString& home) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{
                                                {QStringLiteral("id"), QStringLiteral("t1")},
                                                {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                {QStringLiteral("title"), QStringLiteral("t1")},
                                                {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                            });
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      const QJsonObject provider{
          {QStringLiteral("instanceId"), QStringLiteral("codex")},
          {QStringLiteral("driver"), QStringLiteral("codex")},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-a")}}}},
      };
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), QJsonArray{provider}},
                                                     {QStringLiteral("settings"), QJsonObject()}}}});
    });
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  ComposerController* composer() const { return native->controller<ComposerController>(); }

  QVariantMap edit() { return {{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++revision}}; }

  void type(const QString& text) {
    bridge.dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), key},
                                                                    {QStringLiteral("edit"), edit()},
                                                                    {QStringLiteral("text"), text},
                                                                    {QStringLiteral("cursor"), text.size()}});
  }

  void submit(const QString& text) {
    bridge.dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("edit"), edit()},
                                                                  {QStringLiteral("text"), text},
                                                                  {QStringLiteral("intent"), QStringLiteral("foreground")}});
  }

  int dispatched() const {
    return int(std::count_if(mc.commands.cbegin(), mc.commands.cend(), [](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("message.dispatch");
    }));
  }

  bool offersRestore() const {
    for (const QVariant& toast : bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      for (const QVariant& action : toast.toMap().value(QStringLiteral("actions")).toList()) {
        if (action.toMap().value(QStringLiteral("label")) == QLatin1String("Restore prompt")) return true;
      }
    }
    return false;
  }

  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  QString key = QStringLiteral("env-a:t1");
  int revision = 0;
};

}  // namespace

class ComposerRegression : public QObject {
  Q_OBJECT

private slots:
  // With the caret at the very start of a draft whose first line is empty and
  // whose second starts with "/", the slash menu opened for a command that
  // started after the caret: start 1, end 0.
  void noTriggerAfterTheCaret() {
    QCOMPARE(composer::trigger(QStringLiteral("\n/"), 0).has_value(), false);
    QCOMPARE(composer::trigger(QStringLiteral("\n/model"), 0).has_value(), false);
    const auto slash = composer::trigger(QStringLiteral("\n/mo"), 3);
    QVERIFY(slash);
    QCOMPARE(slash->start, 1);
    QCOMPARE(slash->end, 3);
  }

  // A send the MC refused came back only into an empty draft: when the user
  // had typed something newer meanwhile, the refused prompt was gone. It is
  // now kept behind the toast's "Restore prompt".
  void aRefusedPromptBehindNewerTypingCanBeRestored() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    shell.bridge.dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), shell.key}});
    QTRY_COMPARE(shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), shell.key);

    shell.mc.hold(QStringLiteral("answers"));
    shell.mc.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("The thread is busy."));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
    QCOMPARE(shell.composer()->draft(shell.key), QString());
    shell.type(QStringLiteral("newer"));
    shell.mc.answerHeld();

    auto* toasts = shell.native->controller<ToastController>();
    QTRY_VERIFY(shell.offersRestore());
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("newer"));
    shell.type(QString());
    QVERIFY(toasts->runAction(QStringLiteral("Restore prompt")));
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("first prompt"));
    QVERIFY(!shell.offersRestore());
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/composer-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  ComposerRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ComposerRegression.moc"
