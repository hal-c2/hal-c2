// What tst_ComposerOutboxProp found of the phone's outbox, kept as a plain
// case: opened again while its MC is away, the phone opened only the thread
// it last showed (NavigationController refused thread.open before the MC
// answered), so another cached thread could not be opened, or written in.

#include <QTest>

#include <memory>

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
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
  QStringList sent() const {
    QStringList texts;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) texts.append(command.value(QLatin1String("text")).toString());
    }
    return texts;
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
};

QTEST_MAIN(ComposerOutboxRegression)
#include "tst_ComposerOutboxRegression.moc"
