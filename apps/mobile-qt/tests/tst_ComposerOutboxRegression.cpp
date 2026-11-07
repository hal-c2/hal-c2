// What tst_ComposerOutboxProp and review found of the phone's outbox, kept as
// plain cases.

#include <QTest>

#include <memory>

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

struct Phone {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  int edit = 0;

  Phone() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-11-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-11-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (const QString& id : {QStringLiteral("t1"), QStringLiteral("t2")}) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-11-07T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-11-07T09:00:00Z")}});
    }
    const QJsonArray providers{QJsonObject{
        {QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
        {QStringLiteral("driver"), QStringLiteral("claudeAgent")},
        {QStringLiteral("enabled"), true},
        {QStringLiteral("status"), QStringLiteral("ready")},
        {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("claude-sonnet")}}}},
    }};
    mc.onShape(QStringLiteral("config"), [this, providers](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
  }
  ~Phone() { close(); }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<ComposerController>()->setWaitsOffline(true);
    native->controller<ComposerController>()->setOutboxRetryDelays({10});
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }
  void close() {
    native.reset();
    bridge.reset();
  }

  void open(const QString& thread) { bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(thread)}}); }
  QString composerTarget() const {
    return bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString();
  }
  QStringList outbox() const {
    QStringList texts;
    for (const QVariant& entry : bridge->state()->value(QStringLiteral("turn")).toMap().value(QStringLiteral("outbox")).toList()) {
      texts.append(entry.toMap().value(QStringLiteral("text")).toString());
    }
    return texts;
  }
  void send(const QString& text) {
    const QVariantMap typed{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++edit}};
    bridge->dispatch(QStringLiteral("composer.text.set"),
                     QVariantMap{{QStringLiteral("target"), composerTarget()}, {QStringLiteral("edit"), typed}, {QStringLiteral("text"), text},
                                 {QStringLiteral("cursor"), text.size()}});
    const QVariantMap sent{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++edit}};
    bridge->dispatch(QStringLiteral("composer.submit"),
                     QVariantMap{{QStringLiteral("edit"), sent}, {QStringLiteral("text"), text}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  }
  QVariantMap composer() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }
  QString draft() const { return composer().value(QStringLiteral("text")).toString(); }
  QStringList sent(const QString& type = QStringLiteral("message.dispatch")) const {
    QStringList texts;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == type) texts.append(command.value(QLatin1String("text")).toString());
    }
    return texts;
  }
  // The next command of `type` the MC takes, it takes and then drops the
  // connection under, so the phone never hears the answer.
  void dropUnderNext(const QString& type, std::function<void()> then = {}) {
    mc.effects.append([this, type, then, armed = std::make_shared<bool>(true)](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != type || !std::exchange(*armed, false)) return;
      if (then) then();
      mc.drop();
    });
  }
  void dropUnderNextMessage(std::function<void()> then = {}) { dropUnderNext(QStringLiteral("message.dispatch"), std::move(then)); }
  // The open thread's composer in Plan mode.
  void planMode() {
    auto* settings = native->controller<SettingsController>();
    settings->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    QVERIFY(settings->writeDevice(QStringLiteral("planModeEnabled"), true));
    QTRY_VERIFY(composer().value(QStringLiteral("showInteractionModeToggle")).toBool());
    bridge->dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("plan")}});
    QTRY_COMPARE(composer().value(QStringLiteral("interactionMode")).toString(), QStringLiteral("plan"));
  }
  // The command types the MC was sent, in order.
  QStringList types() const {
    QStringList all;
    for (const QJsonObject& command : mc.commands) all.append(command.value(QLatin1String("type")).toString());
    return all;
  }
};

}  // namespace

class ComposerOutboxRegression : public QObject {
  Q_OBJECT

private slots:
  // GoDown, Open(t2), Restart, Open(t1).
  void anotherCachedThreadOpensBeforeTheMcAnswers() {
    Phone phone;
    phone.start();
    QTRY_VERIFY(phone.native->isActive());
    phone.open(QStringLiteral("t1"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t1")));
    phone.mc.stopAccepting();
    phone.mc.drop();
    QTRY_VERIFY(!phone.native->client()->isReady());
    phone.open(QStringLiteral("t2"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t2")));

    phone.close();
    phone.start();
    QTRY_VERIFY(phone.native->store()->previewing());
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t2")));
    phone.open(QStringLiteral("t1"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t1")));
    // And what is written there waits, and goes once the MC is back.
    phone.send(QStringLiteral("add a test"));
    QTRY_COMPARE(phone.outbox(), QStringList{QStringLiteral("add a test")});
    QVERIFY(phone.sent().isEmpty());
    phone.mc.startAccepting();
    QTRY_COMPARE(phone.sent(), QStringList{QStringLiteral("add a test")});
    QTRY_VERIFY(phone.outbox().isEmpty());
  }

  // Review of #1159: the MC holds a steer its provider has not taken yet, and
  // answers its repeat "still being sent". That is no refusal: the message
  // waits and is asked again, and the prompt never comes back to the draft,
  // where it would be sent a second time.
  void aSteerTheMcIsStillSendingWaits() {
    Phone phone;
    phone.start();
    QTRY_VERIFY(phone.native->isActive());
    phone.open(QStringLiteral("t1"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t1")));
    const QString key = QStringLiteral("message.dispatch:t1");
    phone.dropUnderNextMessage([&] {
      phone.mc.refusals.insert(key, QStringLiteral("This message is still being sent. Try again."));
      phone.mc.refusalDetails.insert(key, QJsonObject{{QStringLiteral("code"), QStringLiteral("message_still_sending")}});
    });
    phone.send(QStringLiteral("look here instead"));
    // The repeat heard "still being sent", and was asked again.
    QTRY_VERIFY(phone.sent().size() >= 3);
    QCOMPARE(phone.draft(), QString());
    QCOMPARE(phone.outbox(), QStringList{QStringLiteral("look here instead")});
    // The provider takes it: the next repeat hears it was sent.
    phone.mc.refusals.remove(key);
    QTRY_VERIFY(phone.outbox().isEmpty());
    QCOMPARE(phone.draft(), QString());
  }

  // Review of #1159: a send whose answer the connection took goes again as
  // the message alone. Its mode change went with the first attempt, and sent
  // again under a fresh command id it could undo one made since elsewhere.
  void aResentMessageLeavesItsModeChangeBehind() {
    Phone phone;
    phone.start();
    QTRY_VERIFY(phone.native->isActive());
    phone.open(QStringLiteral("t1"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t1")));
    phone.planMode();
    phone.dropUnderNextMessage();
    phone.send(QStringLiteral("plan the fix"));
    QTRY_COMPARE(phone.sent(), (QStringList{QStringLiteral("plan the fix"), QStringLiteral("plan the fix")}));
    QTRY_VERIFY(phone.outbox().isEmpty());
    QCOMPARE(phone.sent(QStringLiteral("thread.interaction-mode.set")).size(), 1);
  }

  // Review of #1159: a mode change whose answer the connection took is not
  // known to have reached the MC, so it goes again ahead of the message. Sent
  // alone, the message would run under the mode the user had left (full
  // access rather than approval, say).
  void aModeChangeTheConnectionDroppedGoesAgainBeforeTheMessage() {
    Phone phone;
    phone.start();
    QTRY_VERIFY(phone.native->isActive());
    phone.open(QStringLiteral("t1"));
    QTRY_COMPARE(phone.composerTarget(), keyOf(QStringLiteral("t1")));
    phone.planMode();
    phone.dropUnderNext(QStringLiteral("thread.interaction-mode.set"));
    phone.send(QStringLiteral("plan the fix"));
    const QStringList expected{QStringLiteral("thread.interaction-mode.set"), QStringLiteral("thread.interaction-mode.set"),
                               QStringLiteral("message.dispatch")};
    QTRY_COMPARE(phone.types(), expected);
    QTRY_VERIFY(phone.outbox().isEmpty());
  }
};

QTEST_MAIN(ComposerOutboxRegression)
#include "tst_ComposerOutboxRegression.moc"
