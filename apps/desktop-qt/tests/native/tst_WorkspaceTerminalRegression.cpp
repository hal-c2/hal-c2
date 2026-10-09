// What tests/prop/tst_WorkspaceTerminalProp.cpp found in TerminalController.

#include <QtTest>

#include <QJsonArray>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "TestTime.h"

namespace {

QString keyOf(const QString& thread, const QString& id) { return thread + QLatin1Char('/') + id; }

// The app on a fake MC with one project of two threads, whose terminal
// manager opens a terminal that is not there when an attach has a cwd, as
// HalC2.Terminal does.
struct App {
  QTemporaryDir home;
  FakeMc mc;
  QSet<QString> terms;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;

  App() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("p1")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (const QString id : {QStringLiteral("t1"), QStringLiteral("t2")}) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    }
    mc.onShape(QStringLiteral("terminals"), [this](int id, const QJsonObject&) {
      QJsonArray list;
      for (const QString& key : std::as_const(terms)) list.append(summary(key));
      mc.send({{QStringLiteral("t"), QStringLiteral("terminals")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}}}});
    });
    mc.onShape(QStringLiteral("terminal"), [this](int id, const QJsonObject& shape) {
      const QString key = keyOfInput(shape.value(QLatin1String("input")).toObject());
      if (!terms.contains(key)) {
        terms.insert(key);
        sendTerminals({{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary(key)}});
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("terminal")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), summary(key)}}}});
    });
    mc.onRpc(QStringLiteral("terminal.close"), [this](const FakeMc::Rpc& rpc) {
      close(keyOfInput(rpc.payload));
      mc.reply(rpc, QJsonValue::Null);
    });
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  bool online() {
    return halc2::test::waitFor([this] {
      return native->isActive() && native->client()->isReady() && mc.connected() &&
             native->store()->threadOnline(QStringLiteral("env-a:t1")) && native->store()->threadOnline(QStringLiteral("env-a:t2")) &&
             !mc.subscribers(QStringLiteral("terminals")).isEmpty();
    });
  }

  TerminalController* terminals() { return native->controller<TerminalController>(); }

  bool show(const QString& thread) {
    bridge.dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), QStringLiteral("env-a:") + thread}});
    return sync() && terminals()->threadKey() == QStringLiteral("env-a:") + thread;
  }

  // Once this is back, what either side sent before it has been read.
  bool sync() {
    for (int round = 0; round < 2; ++round) {
      bool done = false;
      QObject context;
      native->client()->call(&context, {}, QStringLiteral("test.barrier"), {}, [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
      if (!halc2::test::waitFor([&done] { return done; })) return false;
    }
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    return true;
  }

  static QString keyOfInput(const QJsonObject& input) {
    return keyOf(input.value(QLatin1String("threadId")).toString(), input.value(QLatin1String("terminalId")).toString());
  }

  QJsonObject summary(const QString& key) const {
    return {{QStringLiteral("threadId"), key.section(QLatin1Char('/'), 0, 0)},
            {QStringLiteral("terminalId"), key.section(QLatin1Char('/'), 1)},
            {QStringLiteral("cwd"), QStringLiteral("/work/p1")},
            {QStringLiteral("status"), QStringLiteral("running")}};
  }

  void sendTerminals(const QJsonObject& event) {
    for (const int id : mc.subscribers(QStringLiteral("terminals"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
    }
  }

  // Another client closes the terminal.
  void close(const QString& key) {
    if (!terms.remove(key)) return;
    for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
      if (keyOfInput(mc.shapeOf(id).value(QLatin1String("input")).toObject()) != key) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("closed")}}}});
    }
    sendTerminals({{QStringLiteral("type"), QStringLiteral("remove")},
                   {QStringLiteral("threadId"), key.section(QLatin1Char('/'), 0, 0)},
                   {QStringLiteral("terminalId"), key.section(QLatin1Char('/'), 1)}});
  }

  // The terminals the client is attached to.
  QStringList attached() const {
    QStringList keys;
    for (const int id : mc.subscribers(QStringLiteral("terminal"))) keys.append(keyOfInput(mc.shapeOf(id).value(QLatin1String("input")).toObject()));
    return keys;
  }
};

}  // namespace

class WorkspaceTerminalRegression : public QObject {
  Q_OBJECT

private slots:
  // Opening the drawer said `changed` twice: once for the drawer, and again
  // when the MC listed the terminal it had just shown.
  void openingTheDrawerSaysSoOnce() {
    App app;
    QVERIFY(app.online());
    QVERIFY(app.show(QStringLiteral("t1")));
    QSignalSpy changed(app.terminals(), &TerminalController::changed);
    app.bridge.dispatch(QStringLiteral("terminal.toggle"));
    QVERIFY(app.sync());
    QVERIFY(app.terminals()->isOpen());
    QCOMPARE(app.terminals()->activeTerminalId(), QStringLiteral("term-1"));
    QCOMPARE(changed.count(), 1);
  }

  // Another thread whose drawer looked the same (closed, no terminal) said
  // nothing, so the right panel kept offering terminals for the last one.
  void anotherThreadSaysChanged() {
    App app;
    QVERIFY(app.online());
    QVERIFY(app.show(QStringLiteral("t1")));
    QSignalSpy changed(app.terminals(), &TerminalController::changed);
    QVERIFY(app.show(QStringLiteral("t2")));
    QCOMPARE(changed.count(), 1);
  }

  // A terminal closed by another client while its thread was out of sight
  // stayed attached, and the attach after a reconnect opened it again.
  void aTerminalClosedElsewhereIsNotReopenedOnReconnect() {
    App app;
    QVERIFY(app.online());
    QVERIFY(app.show(QStringLiteral("t1")));
    app.bridge.dispatch(QStringLiteral("terminal.toggle"));
    QVERIFY(app.sync());
    QVERIFY(app.show(QStringLiteral("t2")));
    QCOMPARE(app.attached(), QStringList{QStringLiteral("t1/term-1")});
    app.close(QStringLiteral("t1/term-1"));
    QVERIFY(app.sync());
    QCOMPARE(app.attached(), QStringList());
    app.mc.drop();
    QVERIFY(app.online());
    QVERIFY(app.sync());
    QVERIFY(app.terms.isEmpty());
  }

  // Back on a thread whose terminals were all closed meanwhile, the drawer
  // was open with no terminal in it.
  void theDrawerHidesWhenTheTerminalsWentWhileAway() {
    App app;
    QVERIFY(app.online());
    QVERIFY(app.show(QStringLiteral("t1")));
    app.bridge.dispatch(QStringLiteral("terminal.toggle"));
    QVERIFY(app.sync());
    QVERIFY(app.show(QStringLiteral("t2")));
    app.close(QStringLiteral("t1/term-1"));
    QVERIFY(app.sync());
    QVERIFY(app.show(QStringLiteral("t1")));
    QVERIFY(!app.terminals()->isOpen());
    QCOMPARE(app.terminals()->activeTerminalId(), QString());
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/terminal-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  WorkspaceTerminalRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_WorkspaceTerminalRegression.moc"
