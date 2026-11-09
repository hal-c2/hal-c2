// What tests/prop/tst_PreviewAutomationHostProp.cpp found in the host agents
// drive the browser through, each as the plain case that shows it.

#include <QtTest>

#include <QJsonObject>

#include "FakeMc.h"
#include "McClient.h"
#include "PreviewAutomationHost.h"
#include "PreviewAutomationPage.h"

namespace {

const QString kTab = QStringLiteral("tab-1");
const QString kThread = QStringLiteral("thread-1");

// A page that keeps every script it is given, never answering.
class HeldPage : public PreviewAutomationPage {
public:
  int held = 0;
  int resized = 0;
  bool busy = false;

  void runJavaScript(const QString&, World, ScriptDone) override { ++held; }
  void grab(ImageDone) override {}
  QUrl url() const override { return QUrl(QStringLiteral("http://localhost:5173/")); }
  QString title() const override { return QStringLiteral("Page"); }
  bool loading() const override { return false; }
  void load(const QUrl&) override {}
  bool devToolsOpen() const override { return false; }
  bool onScreen() const override { return true; }
  QSize viewport() const override { return {1280, 800}; }
  void setViewport(const QSize&) override { ++resized; }
  bool resizing() const override { return busy; }
  bool click(const QPointF&) override { return false; }
  bool key(int, Qt::KeyboardModifiers, const QString&) override { return false; }
  void setColorScheme(const QString&) override {}
};

} // namespace

class tst_PreviewAutomationHostRegression : public QObject {
  Q_OBJECT

private slots:
  // An action naming no tab ran on the current tab beside one naming it: the
  // first waited in the thread's queue, the second in the tab's.
  void anActionOnTheCurrentTabWaitsForOneNamingIt() {
    FakeMc mc;
    QString connection;
    mc.onShape(QStringLiteral("previewAutomation"), [&](int id, const QJsonObject&) {
      QTimer::singleShot(0, &mc, [&, id] {
        connection = QStringLiteral("connection-1");
        mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")},
                                                       {QStringLiteral("connectionId"), connection}}}});
      });
    });
    QStringList answered;
    mc.onRpc(QStringLiteral("previewAutomation.respond"), [&](const FakeMc::Rpc& rpc) {
      answered.append(rpc.payload.value(QLatin1String("requestId")).toString());
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(QStringLiteral("previewAutomation.focusHost"), [&](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
    McClient client;
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    PreviewAutomationHost host(&client, QStringLiteral("desktop-test"));
    HeldPage page;
    host.setMcs({{mc.name, mc.environmentId}});
    host.attach(mc.environmentId, kThread, kTab, &page);
    QTRY_VERIFY(!connection.isEmpty() && host.connectionId(mc.name) == connection);

    const auto ask = [&](const QString& id, const QString& tab, int timeoutMs) {
      const QJsonObject request{{QStringLiteral("requestId"), id},
                                {QStringLiteral("threadId"), kThread},
                                {QStringLiteral("tabId"), tab},
                                {QStringLiteral("tabIdExplicit"), !tab.isEmpty()},
                                {QStringLiteral("operation"), QStringLiteral("evaluate")},
                                {QStringLiteral("input"), QJsonObject{{QStringLiteral("expression"), QStringLiteral("1")}}},
                                {QStringLiteral("timeoutMs"), timeoutMs}};
      mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
               {QStringLiteral("id"), mc.subscribers(QStringLiteral("previewAutomation")).last()},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                                                     {QStringLiteral("connectionId"), connection},
                                                     {QStringLiteral("request"), request}}}});
    };
    ask(QStringLiteral("current"), QString(), 400);
    QTRY_COMPARE(page.held, 1);
    ask(QStringLiteral("named"), kTab, 15000);
    bool synced = false;
    client.call(&mc, {}, QStringLiteral("test.barrier"), {}, [&](const QJsonValue&, const std::optional<QString>&) { synced = true; });
    QTRY_VERIFY(synced);
    // The named one waits for the page.
    QCOMPARE(page.held, 1);
    QVERIFY(answered.isEmpty());

    // The first gives up; only then does the second reach the page.
    QTRY_COMPARE(answered, QStringList{QStringLiteral("current")});
    QTRY_COMPARE(page.held, 2);
  }

  // A failed open named no tab, so the MC could only guess which new tab of
  // the thread was the one it made, and closed others' with it.
  void aFailedOpenNamesTheTabItMade() {
    FakeMc mc;
    QString connection;
    mc.onShape(QStringLiteral("previewAutomation"), [&](int id, const QJsonObject&) {
      QTimer::singleShot(0, &mc, [&, id] {
        connection = QStringLiteral("connection-1");
        mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")},
                                                       {QStringLiteral("connectionId"), connection}}}});
      });
    });
    QJsonObject response;
    mc.onRpc(QStringLiteral("previewAutomation.respond"), [&](const FakeMc::Rpc& rpc) {
      response = rpc.payload;
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(QStringLiteral("previewAutomation.focusHost"), [&](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
    // The MC makes the tab; its page never registers here, so the open fails.
    mc.onRpc(QStringLiteral("preview.open"), [&](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("tabId"), QStringLiteral("tab-new")}});
    });
    McClient client;
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    PreviewAutomationHost host(&client, QStringLiteral("desktop-test"));
    HeldPage page;
    host.setMcs({{mc.name, mc.environmentId}});
    host.attach(mc.environmentId, kThread, kTab, &page);
    QTRY_VERIFY(!connection.isEmpty() && host.connectionId(mc.name) == connection);

    const QJsonObject request{{QStringLiteral("requestId"), QStringLiteral("open")},
                              {QStringLiteral("threadId"), kThread},
                              {QStringLiteral("tabIdExplicit"), false},
                              {QStringLiteral("operation"), QStringLiteral("open")},
                              {QStringLiteral("input"), QJsonObject{{QStringLiteral("reuseExistingTab"), false}}},
                              {QStringLiteral("timeoutMs"), 400}};
    mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
             {QStringLiteral("id"), mc.subscribers(QStringLiteral("previewAutomation")).last()},
             {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                                                   {QStringLiteral("connectionId"), connection},
                                                   {QStringLiteral("request"), request}}}});

    QTRY_VERIFY(response.contains(QLatin1String("ok")));
    QCOMPARE(response.value(QLatin1String("ok")).toBool(), false);
    QCOMPARE(response.value(QLatin1String("error")).toObject().value(QLatin1String("tabId")).toString(),
             QStringLiteral("tab-new"));
  }

  // A person's size pick still outstanding made the page ignore the agent's
  // resize, and the host waited on a size that never came until the agent's
  // own wait ran out. It now refuses at once, and takes the resize after.
  void aResizeDuringAPendingPickIsRefusedAtOnce_data() {
    QTest::addColumn<QJsonObject>("input");
    QTest::newRow("freeform") << QJsonObject{{QStringLiteral("mode"), QStringLiteral("freeform")}, {QStringLiteral("width"), 390}, {QStringLiteral("height"), 844}};
    QTest::newRow("preset") << QJsonObject{{QStringLiteral("mode"), QStringLiteral("preset")}, {QStringLiteral("preset"), QStringLiteral("iphone-se")}};
    // Fill is a resize too: it was reported as done while the page stayed device-sized.
    QTest::newRow("fill") << QJsonObject{{QStringLiteral("mode"), QStringLiteral("fill")}};
  }

  void aResizeDuringAPendingPickIsRefusedAtOnce() {
    QFETCH(QJsonObject, input);
    FakeMc mc;
    QString connection;
    mc.onShape(QStringLiteral("previewAutomation"), [&](int id, const QJsonObject&) {
      QTimer::singleShot(0, &mc, [&, id] {
        connection = QStringLiteral("connection-1");
        mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")},
                                                       {QStringLiteral("connectionId"), connection}}}});
      });
    });
    QJsonObject response;
    mc.onRpc(QStringLiteral("previewAutomation.respond"), [&](const FakeMc::Rpc& rpc) {
      response = rpc.payload;
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(QStringLiteral("previewAutomation.focusHost"), [&](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
    McClient client;
    client.open(mc.origin(), QStringLiteral("token"));
    QTRY_VERIFY(client.isReady());
    PreviewAutomationHost host(&client, QStringLiteral("desktop-test"));
    HeldPage page;
    page.busy = true;
    host.setMcs({{mc.name, mc.environmentId}});
    host.attach(mc.environmentId, kThread, kTab, &page);
    QTRY_VERIFY(!connection.isEmpty() && host.connectionId(mc.name) == connection);

    // The agent's wait is long: only an answer from the host ends this in time.
    mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
             {QStringLiteral("id"), mc.subscribers(QStringLiteral("previewAutomation")).last()},
             {QStringLiteral("event"),
              QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                          {QStringLiteral("connectionId"), connection},
                          {QStringLiteral("request"),
                           QJsonObject{{QStringLiteral("requestId"), QStringLiteral("resize")},
                                       {QStringLiteral("threadId"), kThread},
                                       {QStringLiteral("tabId"), kTab},
                                       {QStringLiteral("tabIdExplicit"), true},
                                       {QStringLiteral("operation"), QStringLiteral("resize")},
                                       {QStringLiteral("input"), input},
                                       {QStringLiteral("timeoutMs"), 60000}}}}}});
    QTRY_VERIFY_WITH_TIMEOUT(response.contains(QLatin1String("ok")), 3000);
    QCOMPARE(response.value(QLatin1String("ok")).toBool(), false);
    QCOMPARE(response.value(QLatin1String("error")).toObject().value(QLatin1String("_tag")).toString(),
             QStringLiteral("PreviewAutomationViewportBusyError"));
    QVERIFY(response.value(QLatin1String("error")).toObject().value(QLatin1String("message")).toString().contains(
        QLatin1String("already in progress")));
    QCOMPARE(page.resized, 0);
  }
};

QTEST_MAIN(tst_PreviewAutomationHostRegression)
#include "tst_PreviewAutomationHostRegression.moc"
