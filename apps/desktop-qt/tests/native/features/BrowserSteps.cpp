// The in-app browser (BrowserPanel on QtWebEngine): a thread's browser tab
// drawn beside it, against a dev server this file serves on the loopback.
// features/preview/surfaces.feature's "The desktop shows the page beside the
// thread". A build without QtWebEngine has no page to show: its scenarios
// fail, as the app opens pages in the user's browser there.
//
// HAL_C2_BROWSER_GRABS=<dir> keeps a picture of the panel from the scenarios
// that draw something worth looking at.

#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QQuickWindow>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTest>

#include <memory>
#include <optional>

#include "Brick.h"
#include "Browser.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Preview.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using preview::model;

// A dev server on the loopback: each path's page, answered and closed.
class DevServer : public QObject {
public:
  DevServer() {
    connect(&m_server, &QTcpServer::newConnection, this, [this] {
      while (QTcpSocket* socket = m_server.nextPendingConnection()) {
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket] { read(socket); });
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
      }
    });
  }

  // Listens on `port` (any free one when 0); false when it is taken.
  bool listen(quint16 port = 0) {
    if (m_server.isListening()) return true;
    const bool listening = m_server.listen(QHostAddress::LocalHost, port ? port : m_port);
    if (listening) m_port = m_server.serverPort();
    return listening;
  }
  void stop() { m_server.close(); }
  quint16 port() const { return m_port; }
  QString url(const QString& path = QStringLiteral("/")) const { return QStringLiteral("http://localhost:%1%2").arg(m_port).arg(path); }

  // The page at `path`: a document titled `title` with `body`, which may script.
  void page(const QString& path, const QString& title, const QString& body = {}) {
    m_pages.insert(path, QStringLiteral("<!doctype html><html><head><meta charset=utf-8><title>%1</title>"
                                        "<meta name=viewport content=\"width=device-width\"></head>"
                                        "<body style=\"font: 16px sans-serif; margin: 24px\"><h1>%1</h1>%2</body></html>")
                             .arg(title, body)
                             .toUtf8());
  }
  // `path` redirects to `to`.
  void redirect(const QString& path, const QString& to) { m_redirects.insert(path, to); }
  // Requests wait for release() while held.
  void hold() { m_holding = true; }
  void release() {
    m_holding = false;
    for (const QPointer<QTcpSocket>& socket : std::exchange(m_held, {})) {
      if (socket) answer(socket);
    }
  }
  int requests = 0;
  // The path of each request, in order.
  QStringList paths;

private:
  void read(QTcpSocket* socket) {
    m_buffers[socket] += socket->readAll();
    if (!m_buffers[socket].contains("\r\n\r\n")) return;
    ++requests;
    paths.append(QString::fromLatin1(m_buffers[socket].split(' ').value(1)));
    if (m_holding) {
      m_held.append(socket);
      return;
    }
    answer(socket);
  }

  void answer(QTcpSocket* socket) {
    const QString path = QString::fromLatin1(m_buffers.take(socket).split(' ').value(1));
    QByteArray reply;
    if (m_redirects.contains(path)) {
      reply = "HTTP/1.1 302 Found\r\nLocation: " + m_redirects.value(path).toUtf8() + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    } else {
      const QByteArray body = m_pages.value(path, QByteArrayLiteral("<!doctype html><title>Not found</title>"));
      reply = QByteArrayLiteral("HTTP/1.1 ") + (m_pages.contains(path) ? "200 OK" : "404 Not Found") +
              "\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: " + QByteArray::number(body.size()) +
              "\r\nConnection: close\r\n\r\n" + body;
    }
    socket->write(reply);
    socket->disconnectFromHost();
  }

  QTcpServer m_server;
  quint16 m_port = 0;
  bool m_holding = false;
  QList<QPointer<QTcpSocket>> m_held;
  QHash<QString, QByteArray> m_pages;
  QHash<QString, QString> m_redirects;
  QHash<QTcpSocket*, QByteArray> m_buffers;
};

// What a browser scenario keeps: the dev server, and the tab it is about.
struct Browsing {
  std::unique_ptr<DevServer> server;
  QString tabId;
  QString typed;  // what the user typed in the address field
};

Browsing& browsing(World& world) {
  return world.mc.part<Browsing>();
}

// preview.ex report_status/1 and resize/1, for the pages here.
const FakeMc::Extension pages([](FakeMc& mc) {
  const auto update = [&mc](const FakeMc::Rpc& rpc, const QStringList& keys) -> std::optional<QJsonObject> {
    FakePreviews& fake = mc.part<FakePreviews>();
    for (QJsonObject& tab : fake.tabs) {
      if (tab.value(QLatin1String("tabId")) != rpc.payload.value(QLatin1String("tabId"))) continue;
      for (const QString& key : keys) {
        if (rpc.payload.contains(key)) tab.insert(key, rpc.payload.value(key));
      }
      return tab;
    }
    mc.refuse(rpc, QStringLiteral("Unknown preview session"));
    return std::nullopt;
  };
  mc.onRpc(QStringLiteral("preview.reportStatus"), [&mc, update](const FakeMc::Rpc& rpc) {
    const auto tab = update(rpc, {QStringLiteral("navStatus"), QStringLiteral("canGoBack"), QStringLiteral("canGoForward")});
    if (!tab) return;
    const QJsonObject status = tab->value(QLatin1String("navStatus")).toObject();
    if (status.value(QLatin1String("_tag")) == QLatin1String("LoadFailed")) {
      preview::emitEvent(mc, *tab, QStringLiteral("failed"),
                         {{QStringLiteral("url"), status.value(QLatin1String("url"))}, {QStringLiteral("title"), status.value(QLatin1String("title"))},
                          {QStringLiteral("code"), status.value(QLatin1String("code"))}, {QStringLiteral("description"), status.value(QLatin1String("description"))}});
    } else {
      preview::emitEvent(mc, *tab, QStringLiteral("navigated"), {{QStringLiteral("snapshot"), *tab}});
    }
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("preview.resize"), [&mc, update](const FakeMc::Rpc& rpc) {
    const auto tab = update(rpc, {QStringLiteral("viewport")});
    if (!tab) return;
    preview::emitEvent(mc, *tab, QStringLiteral("resized"), {{QStringLiteral("snapshot"), *tab}});
    mc.reply(rpc, *tab);
  });
});

DevServer& devServer(World& world) {
  Browsing& state = browsing(world);
  if (!state.server) {
    state.server = std::make_unique<DevServer>();
    expect(state.server->listen(), QStringLiteral("the dev server could not listen"));
    state.server->page(QStringLiteral("/"), QStringLiteral("Dev server"));
  }
  return *state.server;
}

// The thread's previews show pages here, as a build with QtWebEngine does
// (main.cpp), and DevTools' layout is kept in this device's settings.
void embed(World& world) {
  model(world).setEmbedded(true);
  Browser* browser = Browser::instance();
  browser->setStore(nullptr, nullptr);
  browser->setDevToolsDock(QStringLiteral("bottom"));
  browser->setDevToolsShare(0.4);
  browser->setDevicesView(false);
  browser->setDevicesPresetIds({QStringLiteral("iphone-12-pro"), QStringLiteral("ipad-air"), QStringLiteral("desktop")});
  browser->setDevices3d(false);
  auto* settings = world.native().controller<SettingsController>();
  browser->setStore([settings](const QString& key) { return settings->deviceValue(key); },
                    [settings](const QString& key, const QVariant& value) { settings->writeDevice(key, value); });
}

QString activeTab(World& world) {
  return at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")).toString();
}

// The right panel, drawn, as the user sees it beside the thread.
void drawPanel(World& world) {
  if (world.brick) return;
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { RightPanel { anchors.fill: parent } }\n", QSize(900, 760));
  world.brick->takesKeys = true;
}

QQuickItem* find(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = find(child, objectName)) return found;
  }
  return nullptr;
}

// The named item of the showing tab, or null.
QQuickItem* find(World& world, const QString& objectName) {
  return world.brick ? find(world.brick->window().contentItem(), objectName) : nullptr;
}

QQuickItem* view(World& world) {
  return world.brick->item(QStringLiteral("browserView"));
}

QQuickItem* panel(World& world) {
  return world.brick->item(QStringLiteral("browserPanel"));
}

BrowserPage* page(World& world) {
  BrowserPage* found = Browser::page(browsing(world).tabId);
  expect(found != nullptr, QStringLiteral("no page shows %1").arg(browsing(world).tabId));
  return found;
}

// Waits on the page's engine: Chromium runs in its own processes, and on a
// busy machine it answers more slowly than the fake MC, so its bound is longer.
void waitForEngine(World&, const std::function<bool()>& condition, const std::function<QString()>& what) {
  if (!QTest::qWaitFor(condition, 20000)) fail(QStringLiteral("timed out waiting for ") + what());
}

void waitForEngine(World& world, const std::function<bool()>& condition, const QString& what) {
  waitForEngine(world, condition, [what] { return what; });
}

QString viewUrl(World& world) {
  return view(world)->property("url").toUrl().toString();
}

bool loading(World& world) {
  return view(world)->property("loading").toBool();
}

QString failure(World& world) {
  QQuickItem* overlay = find(world, QStringLiteral("browserFailure"));
  return overlay && overlay->isVisible() ? world.brick->item(QStringLiteral("browserFailureMessage"))->property("text").toString() : QString();
}

QString state(World& world) {
  QQuickItem* shown = find(world, QStringLiteral("browserView"));
  if (!shown) return QStringLiteral("no browser view; the panel is %1").arg(show(world.state(QStringLiteral("panel"))));
  return QStringLiteral("the view is at %1 (%2, \"%3\", zoom %4)%5; the panel is %6; %7")
      .arg(shown->property("url").toUrl().toString(), shown->property("loading").toBool() ? QStringLiteral("loading") : QStringLiteral("idle"),
           shown->property("title").toString())
      .arg(shown->property("zoomFactor").toDouble())
      .arg(failure(world).isEmpty() ? QString() : QStringLiteral(" failing with \"%1\"").arg(failure(world)), show(world.state(QStringLiteral("panel"))),
           preview::describe(world));
}


QVariant evaluate(World& world, const QString& script);

void waitForTitle(World& world, const QString& title) {
  waitForEngine(world, [&] { return find(world, QStringLiteral("browserView")) && view(world)->property("title").toString() == title && !loading(world) &&
                             evaluate(world, QStringLiteral("document.readyState + ' ' + document.title")) == QStringLiteral("complete ") + title; },
                [&] { return QStringLiteral("the page to be titled \"%1\"; %2").arg(title, state(world)); });
}

// Runs `script` in the tab's page, as the preview automation does.
QVariant evaluate(World& world, const QString& script) {
  std::optional<QVariant> result;
  page(world)->evaluate(script, [&result](const QVariant& value) { result = value; });
  waitForEngine(world, [&] { return result.has_value(); }, [&] { return QStringLiteral("the page to run %1; %2").arg(script, state(world)); });
  return *result;
}

// Waits for the tab's view to have loaded `url`: the view says so before its
// load starts, so the document is asked too.
void waitForPage(World& world, const QString& url) {
  waitForEngine(world, [&] { return find(world, QStringLiteral("browserView")) && viewUrl(world) == url && !loading(world) &&
                             evaluate(world, QStringLiteral("document.readyState + ' ' + location.href")) == QStringLiteral("complete ") + url; },
                [&] { return state(world); });
}

// The panel as drawn, to HAL_C2_BROWSER_GRABS/<name>.png when that is set.
void saveGrab(World& world, const QString& name) {
  const QString dir = qEnvironmentVariable("HAL_C2_BROWSER_GRABS");
  if (!dir.isEmpty()) world.brick->grab().save(dir + QLatin1Char('/') + name + QStringLiteral(".png"));
}

void run(World& world, const QString& command) {
  expect(world.native().controller<KeybindingController>()->commands()->run(command), QStringLiteral("%1 is not a command").arg(command));
  world.sync();
}

// Waits for the tab's browser tab to show, and its page to load `url`.
void waitForTab(World& world, const QString& url) {
  waitForEngine(world, [&] { return activeTab(world).startsWith(QLatin1String("browser:")); },
                [&] { return QStringLiteral("a browser tab to show; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
  browsing(world).tabId = activeTab(world).mid(8);
  if (!url.isEmpty()) waitForPage(world, url);
}

// The thread has one browser tab showing the dev server's `path`.
void showTab(World& world, const QString& path = QStringLiteral("/")) {
  DevServer& server = devServer(world);
  preview::showPreviews(world);
  embed(world);
  drawPanel(world);
  model(world).openAddress(server.url(path));
  waitForTab(world, server.url(path));
}

// Types `text` into whatever has the brick's keyboard, once the field the
// user just focused has selected what it holds.
void typeText(World& world, const QString& text) {
  world.sync();
  for (const QChar c : text) QTest::keyClick(&world.brick->window(), c.toLatin1());
}

// The menu entry `objectName` of the tab's chrome menu `menu`, chosen.
void choose(World& world, const QString& menu, const QString& objectName) {
  world.brick->click(menu);
  waitForEngine(world, [&] { QQuickItem* entry = find(world, objectName); return entry && entry->isVisible(); },
                QStringLiteral("%1 to offer %2").arg(menu, objectName));
  world.brick->click(objectName);
  // The menu closes behind the choice.
  waitForEngine(world, [&] { QQuickItem* entry = find(world, objectName); return !entry || !entry->isVisible(); },
                QStringLiteral("%1 to close").arg(menu));
}

// The popup windows the page opened.
QList<QQuickWindow*> popups(World& world) {
  return panel(world)->findChildren<QQuickWindow*>();
}

QQuickItem* popupView(QQuickWindow* window) {
  QQuickItem* found = find(window->contentItem(), QStringLiteral("popupView"));
  expect(found != nullptr, QStringLiteral("the popup has no page"));
  return found;
}

// Chromium's net error for each name the ledger uses.
const QHash<QString, int> kNetErrors{
    {QStringLiteral("ERR_NAME_NOT_RESOLVED"), -105},   {QStringLiteral("ERR_CONNECTION_REFUSED"), -102},
    {QStringLiteral("ERR_CONNECTION_TIMED_OUT"), -118}, {QStringLiteral("ERR_INTERNET_DISCONNECTED"), -106},
    {QStringLiteral("ERR_CERT_AUTHORITY_INVALID"), -202}, {QStringLiteral("ERR_TOO_MANY_REDIRECTS"), -310},
};

// A device size's preset id, from its label ("Pixel 7": pixel-7).
QString presetId(const QString& label) {
  return label.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // Opening a page beside the thread.
  step(QStringLiteral("the thread's dev server is listening locally"), [](World& world, const Captures&, const Table&) {
    DevServer& server = devServer(world);
    server.page(QStringLiteral("/"), QStringLiteral("Vite App"));
    // What the MC's scan of its machine finds.
    world.mc.part<FakePreviews>().servers = QJsonArray{QJsonObject{
        {QStringLiteral("host"), QStringLiteral("localhost")}, {QStringLiteral("port"), server.port()}, {QStringLiteral("url"), server.url()},
        {QStringLiteral("processName"), QStringLiteral("vite")}, {QStringLiteral("pid"), 4242}, {QStringLiteral("terminal"), QJsonValue::Null}}};
    preview::showPreviews(world);
    embed(world);
    drawPanel(world);
  });
  step(QStringLiteral("the user opens the preview"), [](World& world, const Captures&, const Table&) {
    // The dev server's link in the agent's reply, followed.
    model(world).openAddress(devServer(world).url());
  });
  step(QStringLiteral("the page opens in a browser tab beside the thread instead of a desktop-only notice"), [](World& world, const Captures&, const Table&) {
    waitForTab(world, devServer(world).url());
    expect(world.openedUrls.isEmpty(), QStringLiteral("the user's browser opened %1").arg(show(QVariant::fromValue(world.openedUrls))));
    waitForTitle(world, QStringLiteral("Vite App"));
    expect(world.brick->item(QStringLiteral("browserAddress"))->property("text").toString() == devServer(world).url(), state(world));
    // The MC heard where the page is.
    waitForEngine(world, [&] { return model(world).index(0).data(ThreadPreviews::StatusRole) == QLatin1String("loaded") &&
                               model(world).index(0).data(ThreadPreviews::TitleRole) == QLatin1String("Vite App"); },
                  [&] { return preview::describe(world); });
    saveGrab(world, QStringLiteral("browser-page"));
  });
  step(QStringLiteral("a browser tab showing the thread's dev server"), [](World& world, const Captures&, const Table&) { showTab(world); });
  step(QStringLiteral("a browser tab that (?:fills its space|is not playing audio)"), [](World& world, const Captures&, const Table&) { showTab(world); });

  // The start page.
  step(QStringLiteral("the user adds a browser tab from the side panel"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("browser")}});
    waitForTab(world, {});
  });
  step(QStringLiteral("the start page offers the dev server to open"), [](World& world, const Captures&, const Table&) {
    waitForEngine(world, [&] { QQuickItem* start = find(world, QStringLiteral("browserStart"));
                        QQuickItem* first = find(world, QStringLiteral("browserSuggestion-0"));
                        return start && start->isVisible() && first && first->isVisible() && first->property("text").toString().startsWith(devServer(world).url()); },
                  [&] { return QStringLiteral("the start page to offer %1; %2").arg(devServer(world).url(), state(world)); });
    saveGrab(world, QStringLiteral("browser-start"));
  });
  step(QStringLiteral("the user picks it"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("browserSuggestion-0")); });
  step(QStringLiteral("the tab loads the dev server"), [](World& world, const Captures&, const Table&) {
    waitForPage(world, devServer(world).url());
    expect(!find(world, QStringLiteral("browserStart"))->isVisible(), QStringLiteral("the start page still shows"));
    waitForEngine(world, [&] { return model(world).index(0).data(ThreadPreviews::UrlRole) == devServer(world).url(); }, [&] { return preview::describe(world); });
    expect(world.openedUrls.isEmpty(), QStringLiteral("the user's browser opened %1").arg(show(QVariant::fromValue(world.openedUrls))));
  });

  // Failing pages.
  step(QStringLiteral("a browser tab whose page fails with (\\w+)"), [](World& world, const Captures& c, const Table&) {
    showTab(world);
    DevServer& server = devServer(world);
    if (c[0] == QLatin1String("ERR_CONNECTION_REFUSED")) {
      // The dev server stops, and the page is asked again.
      server.stop();
      run(world, QStringLiteral("preview.refresh"));
    } else if (c[0] == QLatin1String("ERR_TOO_MANY_REDIRECTS")) {
      server.redirect(QStringLiteral("/loop"), QStringLiteral("/loop"));
      world.brick->item(QStringLiteral("browserPanel"));
      QMetaObject::invokeMethod(panel(world), "go", Q_ARG(QVariant, server.url(QStringLiteral("/loop"))), Q_ARG(QVariant, true));
    } else {
      // What the network does not do on the loopback, as the engine says it.
      QMetaObject::invokeMethod(panel(world), "failed", Q_ARG(QVariant, kNetErrors.value(c[0])), Q_ARG(QVariant, c[0]), Q_ARG(QVariant, server.url()));
    }
    waitForEngine(world, [&] { return !failure(world).isEmpty(); }, [&] { return QStringLiteral("the page to fail; %1").arg(state(world)); });
  });
  step(QStringLiteral("the tab says %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.brick->shows(c[0]) && failure(world) == c[1], state(world));
    saveGrab(world, QStringLiteral("browser-failure"));
  });
  step(QStringLiteral("the user can reload the page"), [](World& world, const Captures&, const Table&) {
    DevServer& server = devServer(world);
    server.listen();
    server.page(QStringLiteral("/loop"), QStringLiteral("Dev server"));
    server.redirect(QStringLiteral("/loop"), QStringLiteral("/"));
    world.brick->click(QStringLiteral("browserFailureReload"));
    waitForTitle(world, QStringLiteral("Dev server"));
    expect(failure(world).isEmpty(), state(world));
  });
  step(QStringLiteral("a browser tab whose page starts another load before the first finishes"), [](World& world, const Captures&, const Table&) {
    showTab(world);
    DevServer& server = devServer(world);
    server.page(QStringLiteral("/next"), QStringLiteral("Next"));
    server.page(QStringLiteral("/slow"), QStringLiteral("Slow"));
    // The page leaves for a page that is slow to answer, then changes its
    // mind while that page is still on its way.
    server.hold();
    evaluate(world, QStringLiteral("location.href = '/slow'; setTimeout(function () { location.href = '/next'; }, 0); true"));
    waitForEngine(world, [&] { return server.paths.contains(QLatin1String("/next")); },
                  [&] { return QStringLiteral("the page to ask for /next; it asked for %1; %2").arg(server.paths.join(QLatin1String(", ")), state(world)); });
    server.release();
    waitForTitle(world, QStringLiteral("Next"));
  });
  step(QStringLiteral("the tab does not say the page failed to load"), [](World& world, const Captures&, const Table&) {
    expect(failure(world).isEmpty(), state(world));
    waitForEngine(world, [&] { return model(world).index(0).data(ThreadPreviews::StatusRole) == QLatin1String("loaded"); }, [&] { return preview::describe(world); });
  });
  step(QStringLiteral("a browser tab whose page failed to load"), [](World& world, const Captures&, const Table&) {
    showTab(world);
    devServer(world).stop();
    run(world, QStringLiteral("preview.refresh"));
    waitForEngine(world, [&] { return !failure(world).isEmpty(); }, [&] { return QStringLiteral("the page to fail; %1").arg(state(world)); });
  });
  step(QStringLiteral("the load is reported as having stopped"), [](World& world, const Captures&, const Table&) {
    QMetaObject::invokeMethod(view(world), "stop");
    world.sync();
  });
  step(QStringLiteral("the tab still says the page failed to load"), [](World& world, const Captures&, const Table&) {
    expect(failure(world) == QLatin1String("Connection refused"), state(world));
  });
  step(QStringLiteral("the user reloads the page"), [](World& world, const Captures&, const Table&) {
    DevServer& server = devServer(world);
    server.listen();
    server.hold();
    world.brick->click(QStringLiteral("browserReload"));
    waitForEngine(world, [&] { return server.requests > 0; }, QStringLiteral("the page to be asked for again"));
  });
  step(QStringLiteral("the failure is cleared while the new load runs"), [](World& world, const Captures&, const Table&) {
    waitForEngine(world, [&] { return failure(world).isEmpty(); }, [&] { return state(world); });
    expect(loading(world), state(world));
    devServer(world).release();
    waitForTitle(world, QStringLiteral("Dev server"));
  });
  step(QStringLiteral("the agent restarts the dev server and the user reloads the tab"), [](World& world, const Captures&, const Table&) {
    DevServer& server = devServer(world);
    server.stop();
    server.page(QStringLiteral("/"), QStringLiteral("Dev server, restarted"));
    expect(server.listen(), QStringLiteral("the dev server could not listen again on %1").arg(server.port()));
    // mod+r, with the page focused.
    run(world, QStringLiteral("preview.refresh"));
  });
  step(QStringLiteral("the page reloads without the user leaving the thread"), [](World& world, const Captures&, const Table&) {
    waitForTitle(world, QStringLiteral("Dev server, restarted"));
    expect(activeTab(world) == QLatin1String("browser:") + browsing(world).tabId && world.openedUrls.isEmpty(), state(world));
  });

  // Zoom.
  step(QStringLiteral("a browser tab at (\\d+)% zoom"), [](World& world, const Captures& c, const Table&) {
    showTab(world);
    page(world)->setZoom(c[0].toInt() / 100.0);
    world.sync();
  });
  step(QStringLiteral("the user zooms (in|out|reset)"), [](World& world, const Captures& c, const Table&) {
    run(world, c[0] == QLatin1String("in") ? QStringLiteral("preview.zoomIn") : c[0] == QLatin1String("out") ? QStringLiteral("preview.zoomOut") : QStringLiteral("preview.resetZoom"));
  });
  step(QStringLiteral("the (?:tab|page in the tab) (?:is|stays) at (\\d+)% zoom"), [](World& world, const Captures& c, const Table&) {
    const double zoom = c[0].toInt() / 100.0;
    waitForEngine(world, [&] { return qFuzzyCompare(view(world)->property("zoomFactor").toDouble(), zoom); }, [&] { return state(world); });
    expect(qFuzzyCompare(page(world)->zoom(), zoom), state(world));
    // The zoom shows in the chrome unless it is 100%.
    QQuickItem* reset = world.brick->item(QStringLiteral("browserZoomReset"));
    expect(reset->isVisible() == (c[0] != QLatin1String("100")), QStringLiteral("the zoom button is %1").arg(reset->isVisible() ? "shown" : "hidden"));
  });
  step(QStringLiteral("the user zooms the whole app in"), [](World& world, const Captures&, const Table&) {
    run(world, QStringLiteral("view.zoomIn"));
    waitForEngine(world, [&] { return panel(world)->property("appZoom").toDouble() > 1.0; }, QStringLiteral("the app to zoom in"));
    // The page is drawn at the screen's pixels: the app's zoom is undone around it.
    QQuickItem* stage = world.brick->item(QStringLiteral("browserPage"));
    const double appZoom = panel(world)->property("appZoom").toDouble();
    expect(qFuzzyCompare(stage->scale() * appZoom, 1.0), QStringLiteral("the page is drawn at %1 of the app's %2").arg(stage->scale()).arg(appZoom));
  });

  // Device sizes.
  step(QStringLiteral("the user picks the %1 device size").arg(q), [](World& world, const Captures& c, const Table&) {
    choose(world, QStringLiteral("browserDevice"), QStringLiteral("browserPreset-") + presetId(c[0]));
    browsing(world).typed = presetId(c[0]);
  });
  step(QStringLiteral("the page renders at that device's size"), [](World& world, const Captures&, const Table&) {
    const QVariantMap viewport = page(world)->viewport();
    expect(viewport.value(QStringLiteral("presetId")) == browsing(world).typed, show(viewport));
    const QString size = QStringLiteral("%1x%2").arg(viewport.value(QStringLiteral("width")).toInt()).arg(viewport.value(QStringLiteral("height")).toInt());
    waitForEngine(world, [&] { return evaluate(world, QStringLiteral("window.innerWidth + 'x' + window.innerHeight")).toString() == size; },
                  [&] { return QStringLiteral("the page to be %1; it is %2").arg(size, evaluate(world, QStringLiteral("window.innerWidth + 'x' + window.innerHeight")).toString()); });
    // The MC keeps the size picked.
    waitForEngine(world, [&] { return world.mc.part<FakePreviews>().tabs.first().value(QLatin1String("viewport")).toObject().value(QLatin1String("presetId")) == browsing(world).typed; },
                  [&] { return preview::describe(world); });
  });
  step(QStringLiteral("the page is scaled down to fit the tab and centred in it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* shown = view(world);
    QQuickItem* area = shown->parentItem();
    const double scale = shown->scale();
    const double width = shown->width() * scale;
    expect(scale < 1.0 && shown->height() * scale <= area->height(), QStringLiteral("the page is drawn at %1 in %2x%3").arg(scale).arg(area->width()).arg(area->height()));
    expect(qAbs(shown->x() + width / 2 - area->width() / 2) <= 1, QStringLiteral("the page is at x %1, %2 wide, in %3").arg(shown->x()).arg(width).arg(area->width()));
  });
  step(QStringLiteral("the tab names the device, its size and the scale"), [](World& world, const Captures&, const Table&) {
    const QString label = world.brick->item(QStringLiteral("browserDeviceLabel"))->property("text").toString();
    const int percent = qRound(view(world)->scale() * 100);
    expect(label == QStringLiteral("iPad Air · 820 × 1180 · %1%").arg(percent), label);
    saveGrab(world, QStringLiteral("browser-device"));
  });

  // The Devices view.
  const auto devicesFrame = [](World& world, const QString& presetId) {
    return find(world, QStringLiteral("browserDevicesFrame-") + presetId);
  };
  const auto openDevicesView = [devicesFrame](World& world) {
    if (!Browser::instance()->devicesView()) world.brick->click(QStringLiteral("browserDevices"));
    waitForEngine(world, [&] { QQuickItem* shown = find(world, QStringLiteral("browserDevicesView")); return shown && shown->isVisible(); },
                  QStringLiteral("the Devices view to show"));
  };
  step(QStringLiteral("the user opens the Devices view"), [openDevicesView](World& world, const Captures&, const Table&) { openDevicesView(world); });
  step(QStringLiteral("a browser tab showing the Devices view"), [openDevicesView](World& world, const Captures&, const Table&) {
    showTab(world);
    openDevicesView(world);
  });
  step(QStringLiteral("the page shows side by side at a phone, a tablet, and a desktop size"), [devicesFrame](World& world, const Captures&, const Table&) {
    QQuickItem* phone = devicesFrame(world, QStringLiteral("iphone-12-pro"));
    QQuickItem* tablet = devicesFrame(world, QStringLiteral("ipad-air"));
    QQuickItem* desktop = devicesFrame(world, QStringLiteral("desktop"));
    waitForEngine(world, [&] { return phone && tablet && desktop && phone->isVisible() && tablet->isVisible() && desktop->isVisible(); },
                  QStringLiteral("a phone, a tablet, and a desktop frame to show"));
    expect(phone->parentItem()->x() < tablet->parentItem()->x() && tablet->parentItem()->x() < desktop->parentItem()->x(),
           QStringLiteral("the frames are not left to right: phone %1, tablet %2, desktop %3")
               .arg(phone->parentItem()->x()).arg(tablet->parentItem()->x()).arg(desktop->parentItem()->x()));
    waitForEngine(world, [&] { return phone->property("url").toUrl().toString() == viewUrl(world) && tablet->property("url").toUrl().toString() == viewUrl(world) &&
                               desktop->property("url").toUrl().toString() == viewUrl(world); },
                  [&] { return QStringLiteral("every frame to load %1; %2").arg(viewUrl(world), state(world)); });
    saveGrab(world, QStringLiteral("browser-devices"));
  });
  step(QStringLiteral("the user navigates to another page"), [](World& world, const Captures&, const Table&) {
    devServer(world).page(QStringLiteral("/other"), QStringLiteral("Other"));
    evaluate(world, QStringLiteral("location.href = '/other'; true"));
    waitForTitle(world, QStringLiteral("Other"));
  });
  step(QStringLiteral("every device in the view shows that page"), [](World& world, const Captures&, const Table&) {
    const QString url = devServer(world).url(QStringLiteral("/other"));
    for (const QString& presetId : {QStringLiteral("iphone-12-pro"), QStringLiteral("ipad-air"), QStringLiteral("desktop")}) {
      QQuickItem* frame = find(world, QStringLiteral("browserDevicesFrame-") + presetId);
      waitForEngine(world, [&] { return frame && frame->property("url").toUrl().toString() == url; },
                    [&] { return QStringLiteral("the \"%1\" frame to show %2").arg(presetId, url); });
    }
  });
  const auto toggleDevicesPreset = [](World& world, const QString& presetId) {
    // The picker's own checkbox items only exist in the window's overlay
    // (the Popup itself is not a QQuickItem to find) once it is open.
    QQuickItem* entry = find(world, QStringLiteral("browserDevicesPreset-") + presetId);
    if (!entry || !entry->isVisible()) {
      world.brick->click(QStringLiteral("browserDevicesPick"));
      waitForEngine(world, [&] { QQuickItem* opened = find(world, QStringLiteral("browserDevicesPreset-") + presetId); return opened && opened->isVisible(); },
                    QStringLiteral("the devices picker to offer %1").arg(presetId));
    }
    // The list has more entries than the picker shows at once; bring the
    // one the click targets into its scrolled viewport first.
    entry = find(world, QStringLiteral("browserDevicesPreset-") + presetId);
    if (QQuickItem* scroll = find(world, QStringLiteral("browserDevicesScroll"))) {
      const double top = entry->mapToItem(scroll, QPointF(0, 0)).y();
      if (top < 0 || top + entry->height() > scroll->height()) {
        const double max = qMax(0.0, scroll->property("contentHeight").toDouble() - scroll->height());
        scroll->setProperty("contentY", qBound(0.0, top + entry->height() / 2 - scroll->height() / 2, max));
        world.sync();
      }
    }
    world.brick->click(QStringLiteral("browserDevicesPreset-") + presetId);
    world.sync();
  };
  step(QStringLiteral("the user adds the %1 device to the view").arg(q), [toggleDevicesPreset](World& world, const Captures& c, const Table&) {
    toggleDevicesPreset(world, presetId(c[0]));
  });
  step(QStringLiteral("the user removes the %1 device from the view").arg(q), [toggleDevicesPreset](World& world, const Captures& c, const Table&) {
    toggleDevicesPreset(world, presetId(c[0]));
  });
  step(QStringLiteral("the view also shows a %1 frame").arg(q), [devicesFrame](World& world, const Captures& c, const Table&) {
    waitForEngine(world, [&] { QQuickItem* frame = devicesFrame(world, presetId(c[0])); return frame && frame->isVisible(); },
                  QStringLiteral("a \"%1\" frame to show").arg(c[0]));
  });
  step(QStringLiteral("the view no longer shows a %1 frame").arg(q), [devicesFrame](World& world, const Captures& c, const Table&) {
    waitForEngine(world, [&] { return devicesFrame(world, presetId(c[0])) == nullptr; }, QStringLiteral("the \"%1\" frame to go away").arg(c[0]));
  });

  // Mute.
  step(QStringLiteral("the user mutes the tab from its menu"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("browserMore"), QStringLiteral("browserMuteItem"));
  });
  step(QStringLiteral("the tab stays silent when its page starts playing sound"), [](World& world, const Captures&, const Table&) {
    expect(view(world)->property("audioMuted").toBool() && page(world)->muted(), state(world));
    // The chrome says so, and unmutes.
    expect(world.brick->item(QStringLiteral("browserMute"))->isVisible(), QStringLiteral("the tab does not show it is muted"));
  });
  step(QStringLiteral("a muted browser tab"), [](World& world, const Captures&, const Table&) {
    showTab(world);
    choose(world, QStringLiteral("browserMore"), QStringLiteral("browserMuteItem"));
  });
  step(QStringLiteral("the tab moves to another page"), [](World& world, const Captures&, const Table&) {
    devServer(world).page(QStringLiteral("/other"), QStringLiteral("Other"));
    evaluate(world, QStringLiteral("location.href = '/other'; true"));
    waitForTitle(world, QStringLiteral("Other"));
  });
  step(QStringLiteral("the tab is still muted"), [](World& world, const Captures&, const Table&) {
    expect(view(world)->property("audioMuted").toBool(), state(world));
  });

  // Popups.
  const auto signInPage = [](World& world) {
    DevServer& server = devServer(world);
    server.page(QStringLiteral("/"), QStringLiteral("Dev server"),
                QStringLiteral("<a id=away href=/away target=_blank>Docs</a>"
                               "<script>window.addEventListener('message', function (e) { document.title = 'Signed in as ' + e.data; });"
                               "function signIn() { window.open('/sign-in', 'sign-in', 'width=420,height=560'); }</script>"));
    server.page(QStringLiteral("/sign-in"), QStringLiteral("Sign in"));
    server.page(QStringLiteral("/away"), QStringLiteral("Away"));
    showTab(world);
  };
  const auto openPopup = [](World& world) {
    evaluate(world, QStringLiteral("signIn(); true"));
    waitForEngine(world, [&] { return popups(world).size() == 1 && popupView(popups(world).first())->property("title").toString() == QLatin1String("Sign in"); },
                  [&] { return QStringLiteral("a sign-in window; %1 windows; %2").arg(popups(world).size()).arg(state(world)); });
  };
  step(QStringLiteral("a page in a browser tab starts a sign-in flow in a popup"), [signInPage, openPopup](World& world, const Captures&, const Table&) {
    signInPage(world);
    openPopup(world);
  });
  step(QStringLiteral("the popup opens as a real window that can report back to the page"), [](World& world, const Captures&, const Table&) {
    QQuickWindow* window = popups(world).first();
    expect(window->isVisible() && window->width() == 420, QStringLiteral("the sign-in window is %1 wide, %2").arg(window->width()).arg(window->isVisible() ? "shown" : "hidden"));
    QMetaObject::invokeMethod(popupView(window), "runJavaScript", Q_ARG(QString, QStringLiteral("window.opener.postMessage('ada', '*'); window.close();")));
    waitForTitle(world, QStringLiteral("Signed in as ada"));
    waitForEngine(world, [&] { return popups(world).isEmpty(); }, QStringLiteral("the sign-in window to close itself"));
  });
  step(QStringLiteral("the user follows a link on the page that targets a new window"), [signInPage](World& world, const Captures&, const Table&) {
    signInPage(world);
    evaluate(world, QStringLiteral("document.getElementById('away').click(); true"));
  });
  step(QStringLiteral("the page loads in the same browser tab"), [](World& world, const Captures&, const Table&) {
    waitForPage(world, devServer(world).url(QStringLiteral("/away")));
    expect(popups(world).isEmpty() && world.openedUrls.isEmpty(), state(world));
    waitForEngine(world, [&] { return model(world).index(0).data(ThreadPreviews::UrlRole) == devServer(world).url(QStringLiteral("/away")); }, [&] { return preview::describe(world); });
  });
  step(QStringLiteral("a sign-in popup opened by a page in a browser tab"), [signInPage, openPopup](World& world, const Captures&, const Table&) {
    signInPage(world);
    openPopup(world);
  });
  step(QStringLiteral("the popup tries to open another popup"), [](World& world, const Captures&, const Table&) {
    QQuickItem* popup = popupView(popups(world).first());
    QMetaObject::invokeMethod(popup, "runJavaScript",
                              Q_ARG(QString, QStringLiteral("var w = window.open('/sign-in', 'more', 'width=300,height=300'); document.title = 'Asked';")));
    waitForEngine(world, [&] { return popup->property("title").toString() == QLatin1String("Asked"); }, QStringLiteral("the sign-in window to ask for another"));
  });
  step(QStringLiteral("the second popup is refused"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(popups(world).size() == 1, QStringLiteral("%1 windows are open").arg(popups(world).size()));
    const QList<QQuickWindow*> nested = popups(world).first()->findChildren<QQuickWindow*>();
    expect(nested.isEmpty(), QStringLiteral("the sign-in window opened another"));
  });

  // The address field.
  step(QStringLiteral("the user types the address of another of its pages without \"http://\" and presses Enter"), [](World& world, const Captures&, const Table&) {
    devServer(world).page(QStringLiteral("/docs"), QStringLiteral("Docs"));
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    field->forceActiveFocus();
    QMetaObject::invokeMethod(field, "selectAll");
    browsing(world).typed = QStringLiteral("localhost:%1/docs").arg(devServer(world).port());
    typeText(world, browsing(world).typed);
    world.brick->press(QStringLiteral("enter"));
  });
  step(QStringLiteral("the tab loads that page over http"), [](World& world, const Captures&, const Table&) {
    waitForPage(world, QStringLiteral("http://") + browsing(world).typed);
    waitForTitle(world, QStringLiteral("Docs"));
  });
  step(QStringLiteral("the address field shows the page's address"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    waitForEngine(world, [&] { return field->property("text").toString() == viewUrl(world); }, [&] { return QStringLiteral("the field shows %1; %2").arg(field->property("text").toString(), state(world)); });
    expect(!field->hasActiveFocus(), QStringLiteral("the address field kept the keyboard"));
  });
  step(QStringLiteral("the user has typed a different address in the field"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    field->forceActiveFocus();
    QMetaObject::invokeMethod(field, "selectAll");
    typeText(world, QStringLiteral("example.com"));
    expect(field->property("text").toString() == QLatin1String("example.com"), field->property("text").toString());
  });
  step(QStringLiteral("the field shows the page's address again"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    expect(field->property("text").toString() == devServer(world).url(), field->property("text").toString());
  });
  step(QStringLiteral("the field no longer has focus"), [](World& world, const Captures&, const Table&) {
    expect(!world.brick->item(QStringLiteral("browserAddress"))->hasActiveFocus(), QStringLiteral("the address field kept the keyboard"));
  });
  step(QStringLiteral("the user focuses the address field"), [](World& world, const Captures&, const Table&) {
    // mod+l, with the page focused.
    run(world, QStringLiteral("preview.focusUrl"));
  });
  step(QStringLiteral("the whole address is selected, ready to be replaced"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    expect(field->hasActiveFocus(), QStringLiteral("the address field does not have the keyboard"));
    expect(field->property("selectedText").toString() == devServer(world).url(), QStringLiteral("\"%1\" is selected").arg(field->property("selectedText").toString()));
  });
  step(QStringLiteral("the user types %1 in the address field and presses Enter").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* field = world.brick->item(QStringLiteral("browserAddress"));
    field->forceActiveFocus();
    QMetaObject::invokeMethod(field, "selectAll");
    typeText(world, c[0]);
    world.brick->press(QStringLiteral("enter"));
  });
  step(QStringLiteral("the tab stays on the thread's dev server"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(viewUrl(world) == devServer(world).url() && world.mc.part<FakePreviews>().navigations.isEmpty(), state(world));
  });
  step(QStringLiteral("the address field says only web addresses can be opened"), [](World& world, const Captures&, const Table&) {
    const QString problem = panel(world)->property("addressProblem").toString();
    expect(problem.contains(QLatin1String("http")), QStringLiteral("the field says \"%1\"").arg(problem));
  });

  // DevTools.
  step(QStringLiteral("the user opens DevTools for the tab"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("browserDevTools")); });
  const auto devToolsShown = [](World& world, bool right) {
    waitForEngine(world, [&] { QQuickItem* tools = find(world, QStringLiteral("browserDevToolsView")); return tools && tools->isVisible() && !tools->property("loading").toBool() &&
                                                                                                  tools->property("url").toUrl().scheme() == QLatin1String("devtools"); },
                  [&] { return QStringLiteral("DevTools to load; %1").arg(state(world)); });
    QQuickItem* tools = world.brick->item(QStringLiteral("browserDevToolsView"));
    // Drawn once DevTools have named the page they inspect.
    waitForEngine(world, [&] { return tools->property("title").toString().contains(QLatin1String("DevTools")); },
                  [&] { return QStringLiteral("DevTools to name the page; they are \"%1\"").arg(tools->property("title").toString()); });
    QQuickItem* shown = view(world);
    const QPointF at = tools->mapToItem(shown->parentItem(), QPointF());
    expect(right ? at.x() >= shown->width() && tools->height() > shown->height() / 2 : at.y() >= shown->height() && tools->width() >= shown->width(),
           QStringLiteral("DevTools are at %1,%2 (%3x%4); the page is %5x%6").arg(at.x()).arg(at.y()).arg(tools->width()).arg(tools->height()).arg(shown->width()).arg(shown->height()));
  };
  step(QStringLiteral("DevTools for that page show below it"), [devToolsShown](World& world, const Captures&, const Table&) {
    devToolsShown(world, false);
    saveGrab(world, QStringLiteral("browser-devtools"));
  });
  step(QStringLiteral("the user docks DevTools to the right"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("browserMore"), QStringLiteral("browserDevToolsDock"));
  });
  step(QStringLiteral("DevTools show beside the page"), [devToolsShown](World& world, const Captures&, const Table&) {
    devToolsShown(world, true);
    saveGrab(world, QStringLiteral("browser-devtools-right"));
  });
  step(QStringLiteral("the next browser tab opens DevTools on the right"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<SettingsController>()->deviceValue(QStringLiteral("browserDevToolsDock")) == QLatin1String("right"),
           QStringLiteral("the dock is not kept on this device"));
  });

  // The user's own browser.
  step(QStringLiteral("the user opens the page in the system browser from the tab's menu"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("browserMore"), QStringLiteral("browserOpenExternal"));
  });
  step(QStringLiteral("the user's browser opens the page's address"), [](World& world, const Captures&, const Table&) {
    waitForEngine(world, [&] { return world.openedUrls == QList<QUrl>{QUrl(devServer(world).url())}; },
                  [&] { return QStringLiteral("the browser opened %1").arg(show(QVariant::fromValue(world.openedUrls))); });
  });
});

}  // namespace
