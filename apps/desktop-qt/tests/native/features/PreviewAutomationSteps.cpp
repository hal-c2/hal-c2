// The desktop as the agents' browser (PreviewAutomationHost): requests the
// MC sends on the `previewAutomation` shape, answered with
// `previewAutomation.respond`, on pages that hold their scripts or on a real
// browser tab. features/preview/automation.feature.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QElapsedTimer>
#include <QPointer>
#include <QTimer>

#include <algorithm>
#include <memory>
#include <vector>

#include "Browser.h"
#include "BrowserAutomationPage.h"
#include "Browsing.h"
#include "Harness.h"
#include "McClient.h"
#include "Preview.h"
#include "PreviewAutomationHost.h"
#include "PreviewAutomationPage.h"
#include "Stream.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using stream::kThread;

// A page that keeps the scripts it is given until told to answer them.
class HeldPage : public PreviewAutomationPage {
public:
  struct Script {
    QString source;
    ScriptDone done;
  };
  QList<Script> scripts;
  QList<QUrl> loads;
  int clicks = 0;
  QUrl at;

  void runJavaScript(const QString& script, World, ScriptDone done) override { scripts.append({script, std::move(done)}); }
  void grab(ImageDone) override {}
  QUrl url() const override { return at; }
  QString title() const override { return QStringLiteral("Page"); }
  bool loading() const override { return false; }
  void load(const QUrl& url) override { loads.append(url); }
  bool devToolsOpen() const override { return false; }
  bool onScreen() const override { return true; }
  QSize viewport() const override { return {1280, 800}; }
  void setViewport(const QSize&) override {}
  bool click(const QPointF&) override {
    ++clicks;
    return false;
  }
  bool key(int, Qt::KeyboardModifiers, const QString&) override { return false; }
  void setColorScheme(const QString&) override {}

  // Whether the page was asked to run the runtime's operation `name`.
  bool ran(const QString& name) const {
    const QString call = QStringLiteral("(\"%1\",").arg(name);
    return std::any_of(scripts.cbegin(), scripts.cend(), [&](const Script& s) { return s.source.contains(call); });
  }
};

// The MC's end of the shape, and the host and pages a scenario drives.
struct Automation {
  QString connection;
  // Every answer, by request id.
  QHash<QString, QJsonObject> answers;
  int requests = 0;
  QString last;  // the last request's id
  QPointer<PreviewAutomationHost> host;
  std::vector<std::unique_ptr<PreviewAutomationPage>> pages;
  HeldPage* held = nullptr;
  QPointer<PreviewAutomationPage> driver;  // a real tab's
  QString thread = kThread;
  qint64 tookMs = 0;  // how long the last answer took
};

Automation& automation(World& world) {
  return world.mc.part<Automation>();
}

// preview_automation.ex: a host that subscribes is connected, and answers.
const FakeMc::Extension broker([](FakeMc& mc) {
  mc.onShape(QStringLiteral("previewAutomation"), [&mc](int id, const QJsonObject&) {
    QTimer::singleShot(0, &mc, [&mc, id] {
      mc.part<Automation>().connection = QStringLiteral("connection-1");
      mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("connected")},
                                                     {QStringLiteral("connectionId"), QStringLiteral("connection-1")}}}});
    });
  });
  mc.onRpc(QStringLiteral("previewAutomation.respond"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<Automation>().answers.insert(rpc.payload.value(QLatin1String("requestId")).toString(), rpc.payload);
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("previewAutomation.focusHost"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
});

// The desktop's host, offered to the MC and connected. It goes with the
// client it talks through.
PreviewAutomationHost& host(World& world) {
  Automation& state = automation(world);
  if (!state.host) {
    McClient* client = world.native().client();
    if (!client->isReady()) {
      world.connect();
      world.sync();
    }
    state.host = new PreviewAutomationHost(client, QStringLiteral("desktop-test"), client);
    state.host->setMcs({{world.mc.name, world.mc.environmentId}});
    world.waitFor([&] { return !state.connection.isEmpty() && state.host->connectionId(world.mc.name) == state.connection; },
                  QStringLiteral("the MC to connect the desktop's browser host"));
  }
  return *state.host;
}

HeldPage& heldPage(World& world, const QString& tab = QStringLiteral("tab-1")) {
  Automation& state = automation(world);
  auto page = std::make_unique<HeldPage>();
  page->at = QUrl(QStringLiteral("http://localhost:5173/"));
  HeldPage* raw = page.get();
  state.pages.push_back(std::move(page));
  host(world).attach(world.mc.environmentId, kThread, tab, raw);
  state.held = raw;
  return *raw;
}

// Sends the agent's `operation` as the MC does, and returns its request id.
QString ask(World& world, const QString& operation, const QJsonObject& input, int timeoutMs, const QString& tab = {},
            QString thread = {}) {
  host(world);
  Automation& state = automation(world);
  if (thread.isEmpty()) thread = state.thread;
  const QString id = QStringLiteral("request-%1").arg(++state.requests);
  const QJsonObject request{{QStringLiteral("requestId"), id},
                            {QStringLiteral("threadId"), thread},
                            {QStringLiteral("tabId"), tab.isEmpty() ? QJsonValue() : QJsonValue(tab)},
                            {QStringLiteral("tabIdExplicit"), !tab.isEmpty()},
                            {QStringLiteral("operation"), operation},
                            {QStringLiteral("input"), input},
                            {QStringLiteral("timeoutMs"), timeoutMs}};
  world.mc.send({{QStringLiteral("t"), QStringLiteral("previewAutomation")},
                 {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("previewAutomation")).last()},
                 {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("request")},
                                                       {QStringLiteral("connectionId"), state.connection},
                                                       {QStringLiteral("request"), request}}}});
  state.last = id;
  return id;
}

QString describeAnswers(World& world) {
  QStringList out;
  const Automation& state = automation(world);
  for (auto it = state.answers.cbegin(); it != state.answers.cend(); ++it) {
    out << it.key() + QStringLiteral(": ") + QString::fromUtf8(QJsonDocument(it.value()).toJson(QJsonDocument::Compact)).left(400);
  }
  return out.isEmpty() ? QStringLiteral("no answers") : out.join(QStringLiteral("; "));
}

// The answer to `id`, once it comes (Chromium may take a while).
QJsonObject answer(World& world, const QString& id) {
  webtab::waitForEngine(world, [&] { return automation(world).answers.contains(id); },
                        [&] { return QStringLiteral("an answer to %1; %2").arg(id, describeAnswers(world)); });
  return automation(world).answers.value(id);
}

QString errorOf(const QJsonObject& answer) {
  return QString::fromUtf8(QJsonDocument(answer.value(QLatin1String("error")).toObject()).toJson(QJsonDocument::Compact));
}

// The thread's browser tab on a real page, driven as the desktop does.
void driveTab(World& world, const QString& path) {
  webtab::showTab(world, path);
  Automation& state = automation(world);
  if (state.driver) return;
  // The page keeps its driver, as PreviewAutomationController's do.
  state.driver = new BrowserAutomationPage(webtab::page(world));
  ThreadPreviews& previews = preview::model(world);
  state.thread = previews.threadId();
  host(world).attach(previews.environmentId(), previews.threadId(), webtab::tabId(world), state.driver);
}

const QString kPassword = QStringLiteral("s3cret-Passw0rd");
const QString kPin = QStringLiteral("4417-0096");

const Steps steps([] {
  // A queued action whose caller gave up.
  step(QStringLiteral("an agent's click is queued behind another action in the same browser"), [](World& world, const Captures&, const Table&) {
    HeldPage& page = heldPage(world);
    ask(world, QStringLiteral("evaluate"), {{QStringLiteral("expression"), QStringLiteral("1")}}, 15000, QStringLiteral("tab-1"));
    world.waitFor([&] { return page.scripts.size() == 1; }, QStringLiteral("the first action to reach the page"));
    ask(world, QStringLiteral("click"), {{QStringLiteral("selector"), QStringLiteral("#buy")}}, 600, QStringLiteral("tab-1"));
  });
  step(QStringLiteral("the click's time limit passes before its turn comes"), [](World& world, const Captures&, const Table&) {
    const QJsonObject click = answer(world, QStringLiteral("request-2"));
    expect(!click.value(QLatin1String("ok")).toBool() && errorOf(click).contains(QLatin1String("PreviewAutomationTimeoutError")),
           QStringLiteral("the click was answered %1").arg(describeAnswers(world)));
    // Then the action ahead of it finishes.
    HeldPage& page = *automation(world).held;
    page.scripts.first().done(QStringLiteral("{\"done\":true,\"value\":\"1\"}"));
    answer(world, QStringLiteral("request-1"));
    world.sync();
  });
  step(QStringLiteral("the click is never performed"), [](World& world, const Captures&, const Table&) {
    const HeldPage& page = *automation(world).held;
    expect(page.scripts.size() == 1 && !page.ran(QStringLiteral("clickTarget")) && page.clicks == 0,
           QStringLiteral("the page ran %1 scripts and took %2 clicks").arg(page.scripts.size()).arg(page.clicks));
  });

  // Opening a dev server's port.
  const auto openPort = [](World& world, const QJsonObject& input) {
    ask(world, QStringLiteral("open"), input, 15000);
    FakePreviews& fake = world.mc.part<FakePreviews>();
    world.waitFor([&] { return !fake.opens.isEmpty(); }, QStringLiteral("the desktop to open an MC tab"));
    // The browser shows the new tab and attaches its page, as Browser does.
    HeldPage& page = heldPage(world, QStringLiteral("tab-%1").arg(fake.tabs.size()));
    page.at = QUrl(fake.opens.last().value(QLatin1String("url")).toString());
    answer(world, automation(world).last);
  };
  step(QStringLiteral("an agent opens a preview of port (\\d+) in its environment"), [openPort](World& world, const Captures& c, const Table&) {
    openPort(world, {{QStringLiteral("target"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("environment-port")}, {QStringLiteral("port"), c[0].toInt()}}}});
  });
  step(QStringLiteral("an agent opens a preview of port (\\d+) in its environment and also gives the address %1").arg(kQuoted),
       [openPort](World& world, const Captures& c, const Table&) {
         openPort(world, {{QStringLiteral("target"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("environment-port")}, {QStringLiteral("port"), c[0].toInt()}}},
                          {QStringLiteral("url"), c[1]}});
       });
  step(QStringLiteral("the tab opens on that environment's port (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject opened = answer(world, automation(world).last);
    const QUrl url(world.mc.part<FakePreviews>().opens.last().value(QLatin1String("url")).toString());
    expect(opened.value(QLatin1String("ok")).toBool() && url.port() == c[0].toInt() && url.host() == QLatin1String("localhost"),
           QStringLiteral("the MC was asked to open %1; %2").arg(url.toString(), describeAnswers(world)));
    const QString status = at(opened.value(QLatin1String("result")).toVariant(), QStringLiteral("url")).toString();
    expect(status == url.toString(), QStringLiteral("the agent was told the tab is at %1").arg(status));
  });
  step(QStringLiteral("the agent did not have to navigate the tab afterwards"), [](World& world, const Captures&, const Table&) {
    expect(automation(world).requests == 1 && world.mc.part<FakePreviews>().navigations.isEmpty() && automation(world).held->loads.isEmpty(),
           QStringLiteral("the tab was loaded again: %1").arg(show(QVariant::fromValue(automation(world).held->loads))));
  });

  // Snapshots and passwords.
  step(QStringLiteral("an agent's current tab shows a sign-in form with a password typed in"), [](World& world, const Captures&, const Table&) {
    webtab::servePage(world, QStringLiteral("/sign-in"), QStringLiteral("Sign in"),
                      QStringLiteral("<form><label>Email <input id=email value=ada@example.com></label>"
                                     "<label>Password <input id=password type=password></label>"
                                     "<label>Code <input id=code style=\"-webkit-text-security: disc\"></label>"
                                     "<p>PIN <span id=pin style=\"-webkit-text-security: disc\">%1</span></p>"
                                     "<button type=button>Sign in</button></form>")
                          .arg(kPin));
    driveTab(world, QStringLiteral("/sign-in"));
    webtab::evaluate(world, QStringLiteral("document.getElementById('password').value = '%1'; "
                                           "document.getElementById('code').value = '%1'; true").arg(kPassword));
  });
  step(QStringLiteral("an agent's current tab shows a password field whose value changes while the snapshot is taken"),
       [](World& world, const Captures&, const Table&) {
         webtab::servePage(world, QStringLiteral("/busy"), QStringLiteral("Busy"),
                           QStringLiteral("<input id=password type=password>"
                                          "<script>var n = 0; setInterval(function () {"
                                          " document.getElementById('password').value = 'p' + (n++); }, 1);</script>"));
         driveTab(world, QStringLiteral("/busy"));
       });
  step(QStringLiteral("the agent takes a snapshot"), [](World& world, const Captures&, const Table&) {
    QElapsedTimer clock;
    clock.start();
    answer(world, ask(world, QStringLiteral("snapshot"), {}, 30000));
    automation(world).tookMs = clock.elapsed();
  });
  step(QStringLiteral("the snapshot shows the password field with its value masked"), [](World& world, const Captures&, const Table&) {
    const QJsonObject snapshot = answer(world, automation(world).last);
    expect(snapshot.value(QLatin1String("ok")).toBool(), describeAnswers(world));
    const QJsonArray elements = snapshot.value(QLatin1String("result")).toObject().value(QLatin1String("interactiveElements")).toArray();
    const bool listed = std::any_of(elements.cbegin(), elements.cend(), [](const QJsonValue& e) {
      return e.toObject().value(QLatin1String("selector")) == QLatin1String("#password") &&
             e.toObject().value(QLatin1String("name")) == QLatin1String("Password");
    });
    expect(listed, QStringLiteral("the password field is not listed: %1").arg(QString::fromUtf8(QJsonDocument(elements).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("the password appears nowhere in the page text, including fields drawn as dots"), [](World& world, const Captures&, const Table&) {
    QJsonObject result = answer(world, automation(world).last).value(QLatin1String("result")).toObject();
    result.remove(QStringLiteral("screenshot"));
    const QString text = QString::fromUtf8(QJsonDocument(result).toJson(QJsonDocument::Compact));
    expect(!text.contains(kPassword) && !text.contains(kPin), QStringLiteral("the snapshot says %1").arg(text.left(2000)));
    // What else the page says is still there.
    const QString visible = result.value(QLatin1String("visibleText")).toString();
    expect(visible.contains(QLatin1String("PIN")) && visible.contains(QStringLiteral("•")), QStringLiteral("the page text is %1").arg(visible));
  });
  step(QStringLiteral("the tool fails saying the page was too busy to read safely"), [](World& world, const Captures&, const Table&) {
    const QJsonObject snapshot = answer(world, automation(world).last);
    expect(!snapshot.value(QLatin1String("ok")).toBool() && errorOf(snapshot).contains(QLatin1String("too busy to read safely")), describeAnswers(world));
  });
  step(QStringLiteral("it answers within (\\d+) seconds"), [](World& world, const Captures& c, const Table&) {
    expect(automation(world).tookMs < c[0].toLongLong() * 1000, QStringLiteral("it answered after %1ms").arg(automation(world).tookMs));
  });
});

}  // namespace
