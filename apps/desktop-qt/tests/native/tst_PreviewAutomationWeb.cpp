// An agent driving a real web page through the desktop: a WebEngineView with
// its BrowserPage (wired as the BrowserPanel brick wires it), the host
// offered to a fake MC, and the MC's requests answered from the page itself.
// It proves features/preview/automation.feature's desktop scenarios named in
// their comments: the core loop (open, navigate, snapshot with a screenshot,
// click, type, press, evaluate), refusing a tab whose DevTools are open, and
// telling the user's own input from the agent's.

#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTest>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include "Browser.h"
#include "BrowserAutomationPage.h"
#include "McClient.h"
#include "PreviewAutomationHost.h"
#include "features/FakeMc.h"

namespace {

const QString kTab = QStringLiteral("tab-1");
const QString kThread = QStringLiteral("thread-1");

// The fixture page: a button that counts its trusted clicks, a field, and a
// line that says which keys reached the field.
const char kPage[] = R"html(<!doctype html><title>Fixture</title>
<body style="margin:0">
<h1>Checkout</h1>
<button id="buy" style="position:absolute;left:40px;top:120px;width:120px;height:40px"
  onclick="if (event.isTrusted) document.getElementById('clicks').textContent = String(Number(document.getElementById('clicks').textContent) + 1)">Buy</button>
<span id="clicks">0</span>
<input id="name" style="position:absolute;left:40px;top:200px;width:200px"
  onkeydown="if (event.key === 'Enter') document.getElementById('entered').textContent = this.value">
<p id="entered" style="position:absolute;top:260px"></p>
<script>console.log('fixture ready')</script>
</body>)html";

const char kQml[] = R"(
import QtQuick
import QtWebEngine
import HalC2.Shell
Window {
    width: 800; height: 600; visible: true
    property alias page: page
    WebEngineView {
        id: view
        objectName: "view"
        anchors.fill: parent
        onJavaScriptConsoleMessage: (level, message, line, source) => page.consoleMessage(level, message, line, source)
    }
    BrowserPage {
        id: page
        tabId: "tab-1"
        view: view
        onEvaluateRequested: (request, script, world) => view.runJavaScript(script, world, result => page.evaluated(request, result))
        onGrabRequested: request => {
            if (!view.grabToImage(result => page.grabbed(request, result.image)))
                page.grabbed(request, undefined);
        }
    }
}
)";

}  // namespace

class tst_PreviewAutomationWeb : public QObject {
  Q_OBJECT

  FakeMc* m_mc = nullptr;
  McClient* m_client = nullptr;
  PreviewAutomationHost* m_host = nullptr;
  QQmlApplicationEngine* m_engine = nullptr;
  QQuickWindow* m_window = nullptr;
  BrowserPage* m_page = nullptr;
  BrowserAutomationPage* m_driver = nullptr;
  QString m_connection;
  int m_subscription = -1;
  int m_requests = 0;
  QHash<QString, QJsonObject> m_answers;

  // Sends the agent's request and waits for the host's answer.
  QJsonObject ask(const QString& operation, const QJsonObject& input, int timeoutMs = 15000) {
    const QString id = QStringLiteral("preview-%1").arg(++m_requests);
    const QJsonObject request{{QStringLiteral("requestId"), id},
                              {QStringLiteral("threadId"), kThread},
                              {QStringLiteral("tabId"), kTab},
                              {QStringLiteral("tabIdExplicit"), true},
                              {QStringLiteral("operation"), operation},
                              {QStringLiteral("input"), input},
                              {QStringLiteral("timeoutMs"), timeoutMs}};
    m_mc->send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                {QStringLiteral("id"), m_subscription},
                {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                                                      {QStringLiteral("connectionId"), m_connection},
                                                      {QStringLiteral("request"), request}}}});
    QElapsedTimer clock;
    clock.start();
    if (!QTest::qWaitFor([&] { return m_answers.contains(id); }, timeoutMs + 2000)) return {};
    const QJsonObject answer = m_answers.take(id);
    // Before the MC's deadline, or the MC would have dropped the host.
    if (clock.elapsed() >= timeoutMs) return {};
    return answer;
  }

  QJsonValue evaluate(const QString& expression) {
    const QJsonObject answer = ask(QStringLiteral("evaluate"), {{QStringLiteral("expression"), expression}});
    return answer.value(QLatin1String("result"));
  }

private slots:
  void initTestCase() {
    m_mc = new FakeMc();
    m_mc->onShape(QStringLiteral("previewAutomation"), [this](int id, const QJsonObject&) {
      QTimer::singleShot(0, this, [this, id] {
        m_subscription = id;
        m_connection = QStringLiteral("connection-%1").arg(id);
        m_mc->send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                    {QStringLiteral("id"), id},
                    {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")},
                                                          {QStringLiteral("connectionId"), m_connection}}}});
      });
    });
    m_mc->onRpc(QStringLiteral("previewAutomation.respond"), [this](const FakeMc::Rpc& rpc) {
      m_answers.insert(rpc.payload.value(QLatin1String("requestId")).toString(), rpc.payload);
      m_mc->reply(rpc, QJsonValue::Null);
    });
    m_mc->onRpc(QStringLiteral("previewAutomation.focusHost"), [this](const FakeMc::Rpc& rpc) { m_mc->reply(rpc, QJsonValue::Null); });

    m_client = new McClient();
    m_client->open(m_mc->origin(), QStringLiteral("token"));
    QVERIFY(QTest::qWaitFor([this] { return m_client->isReady(); }, 10000));
    m_host = new PreviewAutomationHost(m_client, QStringLiteral("desktop-web"));
    m_host->setMcs({{m_mc->name, m_mc->environmentId}});
    QVERIFY(QTest::qWaitFor([this] { return !m_host->connectionId(m_mc->name).isEmpty(); }, 10000));

    m_engine = new QQmlApplicationEngine();
    m_engine->loadData(kQml);
    QCOMPARE(m_engine->rootObjects().size(), 1);
    m_window = qobject_cast<QQuickWindow*>(m_engine->rootObjects().first());
    QVERIFY(m_window);
    QVERIFY(QTest::qWaitForWindowExposed(m_window));
    m_page = Browser::page(kTab);
    QVERIFY(m_page);
    m_driver = new BrowserAutomationPage(m_page);
    m_host->attach(m_mc->environmentId, kThread, kTab, m_driver);
  }

  void cleanupTestCase() {
    delete m_engine;
    delete m_host;
    delete m_client;
    delete m_mc;
  }

  // "An agent's request to navigate reaches the browser", and the loop after it.
  void navigatesAndSnapshots() {
    const QString url = QStringLiteral("data:text/html;charset=utf-8,") + QString::fromUtf8(QUrl::toPercentEncoding(QString::fromUtf8(kPage)));
    const QJsonObject navigated = ask(QStringLiteral("navigate"), {{QStringLiteral("url"), url}});
    QVERIFY2(navigated.value(QLatin1String("ok")).toBool(), QJsonDocument(navigated).toJson().constData());
    QCOMPARE(navigated.value(QLatin1String("result")).toObject().value(QLatin1String("tabId")).toString(), kTab);

    const QJsonObject snapshot = ask(QStringLiteral("snapshot"), {});
    QVERIFY2(snapshot.value(QLatin1String("ok")).toBool(), QJsonDocument(snapshot).toJson().constData());
    const QJsonObject result = snapshot.value(QLatin1String("result")).toObject();
    QCOMPARE(result.value(QLatin1String("title")).toString(), QStringLiteral("Fixture"));
    QVERIFY(result.value(QLatin1String("visibleText")).toString().contains(QLatin1String("Checkout")));
    const QJsonObject shot = result.value(QLatin1String("screenshot")).toObject();
    QCOMPARE(shot.value(QLatin1String("mimeType")).toString(), QStringLiteral("image/png"));
    QVERIFY(shot.value(QLatin1String("width")).toInt() > 0);
    QVERIFY(!shot.value(QLatin1String("data")).toString().isEmpty());
    bool buy = false;
    for (const QJsonValue& element : result.value(QLatin1String("interactiveElements")).toArray()) {
      buy = buy || element.toObject().value(QLatin1String("name")).toString() == QLatin1String("Buy") ||
            element.toObject().value(QLatin1String("text")).toString() == QLatin1String("Buy");
    }
    QVERIFY2(buy, QJsonDocument(result.value(QLatin1String("interactiveElements")).toArray()).toJson().constData());
    bool logged = false;
    for (const QJsonValue& entry : result.value(QLatin1String("consoleEntries")).toArray()) {
      logged = logged || entry.toObject().value(QLatin1String("text")).toString() == QLatin1String("fixture ready");
    }
    QVERIFY(logged);
  }

  // A click is the user's kind of click: the page sees a trusted event.
  void clicksTypesAndPresses() {
    const QJsonObject clicked = ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}});
    QVERIFY2(clicked.value(QLatin1String("ok")).toBool(), QJsonDocument(clicked).toJson().constData());
    QCOMPARE(evaluate(QStringLiteral("document.getElementById('clicks').textContent")).toString(), QStringLiteral("1"));
    QVERIFY(m_host->activity().value(kTab).toMap().contains(QStringLiteral("pointer")));

    const QJsonObject typed = ask(QStringLiteral("type"), {{QStringLiteral("selector"), QStringLiteral("#name")},
                                                           {QStringLiteral("text"), QStringLiteral("Ada")}});
    QVERIFY2(typed.value(QLatin1String("ok")).toBool(), QJsonDocument(typed).toJson().constData());
    QCOMPARE(evaluate(QStringLiteral("document.getElementById('name').value")).toString(), QStringLiteral("Ada"));

    const QJsonObject pressed = ask(QStringLiteral("press"), {{QStringLiteral("key"), QStringLiteral("Enter")}});
    QVERIFY2(pressed.value(QLatin1String("ok")).toBool(), QJsonDocument(pressed).toJson().constData());
    QCOMPARE(evaluate(QStringLiteral("document.getElementById('entered').textContent")).toString(), QStringLiteral("Ada"));
  }

  void evaluates() {
    QCOMPARE(evaluate(QStringLiteral("6 * 7")).toInt(), 42);
    QCOMPARE(evaluate(QStringLiteral("Promise.resolve({a: [1, 2]})")).toObject().value(QLatin1String("a")).toArray().size(), 2);
    const QJsonObject thrown = ask(QStringLiteral("evaluate"), {{QStringLiteral("expression"), QStringLiteral("(() => { throw new Error('nope') })()")}});
    QVERIFY(!thrown.value(QLatin1String("ok")).toBool());
    QVERIFY(thrown.value(QLatin1String("error")).toObject().value(QLatin1String("message")).toString().contains(QLatin1String("nope")));
  }

  // "An agent cannot control a tab while its developer tools are open", and
  // "Agent control comes back once the developer tools are closed".
  void keepsOffDevTools() {
    m_page->setDevTools(true);
    const QJsonObject refused = ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}});
    QVERIFY(!refused.value(QLatin1String("ok")).toBool());
    QVERIFY(refused.value(QLatin1String("error")).toObject().value(QLatin1String("message")).toString().contains(QLatin1String("developer tools")));
    m_page->setDevTools(false);
    QVERIFY(ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}}).value(QLatin1String("ok")).toBool());
  }

  // The user's own input in the page is told from the agent's: the agent's
  // click is not the user taking over, the platform's is.
  void tellsTheUserFromTheAgent() {
    QSignalSpy human(m_driver, &PreviewAutomationPage::humanInput);
    QVERIFY(ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}}).value(QLatin1String("ok")).toBool());
    QCOMPARE(human.count(), 0);
    QTest::mouseClick(m_window, Qt::LeftButton, {}, QPoint(300, 400));
    QTRY_VERIFY(human.count() > 0);
  }

  // The user acting in the page while the agent clicks stops the agent's click.
  void yieldsToTheUser() {
    auto once = std::make_shared<QMetaObject::Connection>();
    *once = connect(m_page, &BrowserPage::evaluateRequested, this, [this, once] {
      disconnect(*once);
      emit m_driver->humanInput();
    });
    const QJsonObject answer = ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}});
    QVERIFY(!answer.value(QLatin1String("ok")).toBool());
    QCOMPARE(answer.value(QLatin1String("error")).toObject().value(QLatin1String("_tag")).toString(),
             QStringLiteral("PreviewAutomationControlInterruptedError"));
    // The next action is the agent's again.
    QVERIFY(ask(QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}}).value(QLatin1String("ok")).toBool());
  }
};

int main(int argc, char** argv) {
  QtWebEngineQuick::initialize();
  QGuiApplication app(argc, argv);
  Browser::setSupported(true);
  tst_PreviewAutomationWeb test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_PreviewAutomationWeb.moc"
