// What a page in a browser tab may do beyond itself: open windows, ask for
// permissions, read the clipboard, and hand links to other apps
// (BrowserPanel's handlers and Browser.permissions). features/preview/surfaces.feature.
//
// The page asks from a click, as a page does: the dev server's /ask page is one
// button over the whole page, and clicking it runs `window.act`. What the page
// learnt comes back in its title, "result:<what>".

#include <QClipboard>
#include <QGuiApplication>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <QtWebEngineQuick/QQuickWebEngineProfile>

#include "Alerts.h"
#include "Brick.h"
#include "Browser.h"
#include "Browsing.h"
#include "Harness.h"
#include "Preview.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using preview::model;

struct Asking {
  bool shown = false;
  int asks = 0;    // the clicks on /ask so far
  QString link;    // the outside link the page follows
};

Asking& asking(World& world) {
  return world.mc.part<Asking>();
}

const QString kAsk = QStringLiteral(
    "<button id=ask style=\"position:fixed;left:0;top:0;width:100vw;height:100vh;opacity:0.5\" "
    "onclick=\"window.act && window.act()\">Ask</button>"
    "<script>function done(what) { document.title = 'result:' + what; }"
    // The engine tells a page refused a camera or microphone it was aborted; a
    // device missing after a grant is NotFoundError, which is no refusal.
    " var kRefusedMedia = /^(AbortError|NotAllowedError)$/;</script>");

// The sites the ledger names, as origins of the dev server: one name each for the loopback.
QString hostFor(const QString& site) {
  if (site == QLatin1String("https://example.com")) return QStringLiteral("localhost");
  if (site == QLatin1String("https://other.example")) return QStringLiteral("127.0.0.1");
  fail(QStringLiteral("no stand-in for the site %1").arg(site));
}

QString title(World& world) {
  return webtab::evaluate(world, QStringLiteral("document.title")).toString();
}

QString askUrl(World& world, const QString& host) {
  QString url = webtab::serverUrl(world, QStringLiteral("/ask"));
  return url.replace(QStringLiteral("localhost"), host);
}

// The thread's browser tab on the /ask page of `host`.
void showAsk(World& world, const QString& host = QStringLiteral("localhost")) {
  webtab::servePage(world, QStringLiteral("/ask"), QStringLiteral("Ask"), kAsk);
  Asking& state = asking(world);
  if (!state.shown) {
    webtab::showTab(world, QStringLiteral("/ask"));
    state.shown = true;
    // As the desktop's profile (main.cpp): only Browser.permissions keeps an answer. Set
    // on the profile the page already uses; one made before the first page stops grabs drawing.
    auto* profile = world.brick->item(QStringLiteral("browserView"))->property("profile").value<QQuickWebEngineProfile*>();
    expect(profile != nullptr, QStringLiteral("the tab's view has no profile"));
    profile->setPersistentPermissionsPolicy(QQuickWebEngineProfile::PersistentPermissionsPolicy::AskEveryTime);
  }
  const QString url = askUrl(world, host);
  if (webtab::evaluate(world, QStringLiteral("location.href")).toString() == url) return;
  webtab::evaluate(world, QStringLiteral("location.href = '%1'; true").arg(url));
  // The view, not the page: a script sent while one page replaces another can go unanswered.
  QQuickItem* view = world.brick->item(QStringLiteral("browserView"));
  webtab::waitForEngine(world, [&] { return view->property("url").toUrl() == QUrl(url) && !view->property("loading").toBool(); },
                        [&] { return QStringLiteral("the tab to show %1; it shows %2").arg(url, view->property("url").toString()); });
}

// The page runs `script` from the user's click; `done(what)` reports what it learnt.
void act(World& world, const QString& script) {
  Asking& state = asking(world);
  state.asks += 1;
  webtab::evaluate(world, QStringLiteral("document.title = 'asking %1'; window.acted = false;"
                                         " window.act = function () { if (window.acted) return; window.acted = true; %2 }; true")
                              .arg(state.asks)
                              .arg(script));
  // The user's click, low on the page's left, clear of the question shown at
  // its top. A page that has just replaced another takes no input until it
  // has drawn, so the user clicks again until it does; the page acts once.
  QQuickItem* view = world.brick->item(QStringLiteral("browserView"));
  webtab::waitForEngine(
      world,
      [&] {
        view->window()->requestActivate();
        QTest::mouseClick(view->window(), Qt::LeftButton, Qt::NoModifier, view->mapToScene(QPointF(16, view->height() - 16)).toPoint());
        return webtab::evaluate(world, QStringLiteral("window.acted")).toBool();
      },
      [] { return QStringLiteral("the page to take the user's click"); });
}

// What the page learnt from its last ask.
QString result(World& world) {
  QString seen;
  webtab::waitForEngine(world, [&] { seen = title(world); return seen.startsWith(QLatin1String("result:")); },
                        [&] { return QStringLiteral("the page to learn its answer; it says \"%1\"").arg(seen); });
  return seen.mid(7);
}

// What the system was asked to open.
QString opened(World& world) {
  QStringList urls;
  for (const QUrl& url : std::as_const(world.openedUrls)) urls << url.toString();
  return urls.join(QStringLiteral(", "));
}

// The question on screen, as Browser.permissions puts it.
QVariantMap question() {
  return Browser::instance()->permissions()->question();
}

QQuickItem* questionCard(World& world) {
  return world.brick->item(QStringLiteral("browserQuestion"));
}

QString questionText(World& world) {
  return world.brick->item(QStringLiteral("browserQuestionText"))->property("text").toString();
}

void waitForQuestion(World& world) {
  webtab::waitForEngine(world, [&] { return questionCard(world)->isVisible(); }, [&] { return QStringLiteral("a question; the page says \"%1\" (%2)").arg(title(world), webtab::evaluate(world, QStringLiteral("String(window.why)")).toString()); });
}

// The page's work after its last ask has been seen through: a round trip to it.
void settle(World& world) {
  webtab::evaluate(world, QStringLiteral("true"));
  world.sync();
}

void expectNoQuestion(World& world) {
  settle(world);
  expect(!questionCard(world)->isVisible(), QStringLiteral("the user was asked \"%1\"").arg(questionText(world)));
}

const QString kReadClipboard = QStringLiteral("document.title = 'reading, focused ' + document.hasFocus(); navigator.clipboard.readText().then(function (t) { done('read ' + t); }, function (e) { window.why = e.message; done('nothing'); });");

void askToRead(World& world) {
  QGuiApplication::clipboard()->setText(QStringLiteral("copied text"));
  act(world, kReadClipboard);
}

void followLink(World& world, const QString& link) {
  asking(world).link = link;
  act(world, QStringLiteral("location.href = '%1';").arg(link));
}

// How each thing a page can ask for is asked for, and how the page learns the answer.
const QHash<QString, QString> kAsks{
    {QStringLiteral("to put text on the clipboard"),
     QStringLiteral("navigator.clipboard.writeText('hi').then(function () { done('allowed'); }, function (e) { done('refused'); });")},
    {QStringLiteral("to show notifications"),
     QStringLiteral("Notification.requestPermission().then(function (r) { done(r === 'granted' ? 'allowed' : 'refused'); });")},
    {QStringLiteral("the user's location"),
     QStringLiteral("navigator.geolocation.getCurrentPosition(function () { done('allowed'); },"
                    " function (e) { done(e.code === e.PERMISSION_DENIED ? 'refused' : 'allowed'); }, {timeout: 3000});")},
    {QStringLiteral("the camera"),
     QStringLiteral("navigator.mediaDevices.getUserMedia({video: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },"
                    " function (e) { done(kRefusedMedia.test(e.name) ? 'refused' : 'allowed, but ' + e.name); });")},
    {QStringLiteral("the microphone"),
     QStringLiteral("navigator.mediaDevices.getUserMedia({audio: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },"
                    " function (e) { done(kRefusedMedia.test(e.name) ? 'refused' : 'allowed, but ' + e.name); });")},
    {QStringLiteral("the list of installed fonts"),
     QStringLiteral("window.queryLocalFonts().then(function (fonts) { done(fonts.length ? 'allowed' : 'refused'); }, function () { done('refused'); });")},
    // Chromium asks for the pointer only from a focused window, which the offscreen test window is not.
    {QStringLiteral("to lock the mouse pointer"),
     QStringLiteral("document.onpointerlockchange = function () { if (document.pointerLockElement) { document.exitPointerLock(); done('allowed'); } };"
                    " document.onpointerlockerror = function () { done('refused'); };"
                    " try { var locked = document.body.requestPointerLock(); if (locked && locked.catch) locked.catch(function () { done('refused'); }); }"
                    " catch (e) { done('refused'); }")},
    {QStringLiteral("anything else a page can ask for"),
     QStringLiteral("navigator.mediaDevices.getDisplayMedia({video: true}).then(function (s) { s.getTracks().forEach(function (t) { t.stop(); }); done('allowed'); },"
                    " function () { done('refused'); });")},
};

// The tab's page and address, as the scenario found them.
void expectUnmoved(World& world) {
  const QString home = webtab::serverUrl(world, QStringLiteral("/"));
  expect(webtab::evaluate(world, QStringLiteral("location.href + ' ' + document.title")).toString() == home + QStringLiteral(" Dev server"),
         QStringLiteral("the page is %1").arg(webtab::evaluate(world, QStringLiteral("location.href + ' ' + document.title")).toString()));
  expect(model(world).index(0).data(ThreadPreviews::UrlRole).toString() == home,
         QStringLiteral("the MC's tab is at %1").arg(model(world).index(0).data(ThreadPreviews::UrlRole).toString()));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Windows a page opens.
  step(QStringLiteral("the page opens a window at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    webtab::showTab(world);
    webtab::evaluate(world, QStringLiteral("window.opened = window.open(%1); true").arg(QStringLiteral("'%1'").arg(QString(c[0]).replace(QLatin1Char('\''), QStringLiteral("\\'")))));
  });
  step(QStringLiteral("the page opens a blank window"), [](World& world, const Captures&, const Table&) {
    webtab::showTab(world);
    webtab::evaluate(world, QStringLiteral("window.opened = window.open(); true"));
  });
  step(QStringLiteral("no tab or window opens and the page is told it was refused"), [](World& world, const Captures&, const Table&) {
    webtab::waitForEngine(world, [&] { return webtab::evaluate(world, QStringLiteral("!window.opened || window.opened.closed")).toBool(); },
                          [] { return QStringLiteral("the page to be told its window was refused"); });
    world.sync();
    expect(webtab::popups(world).isEmpty(), QStringLiteral("%1 windows opened").arg(webtab::popups(world).size()));
    expect(model(world).rowCount() == 1, QStringLiteral("the thread has %1 tabs").arg(model(world).rowCount()));
    expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1").arg(opened(world)));
  });
  step(QStringLiteral("the page(?: and its address)? stays? as (?:it was|they were)"), [](World& world, const Captures&, const Table&) { expectUnmoved(world); });

  // Permissions.
  step(QStringLiteral("a page in a browser tab asks for (.+)"), [](World& world, const Captures& c, const Table&) {
    expect(kAsks.contains(c[0]), QStringLiteral("no way to ask for %1").arg(c[0]));
    showAsk(world);
    act(world, kAsks.value(c[0]));
  });
  step(QStringLiteral("the request is (allowed|refused)"), [](World& world, const Captures& c, const Table&) {
    const QString learnt = result(world);
    expect(learnt == c[0], QStringLiteral("the request was %1").arg(learnt));
    expect(!questionCard(world)->isVisible(), QStringLiteral("the user was asked \"%1\"").arg(questionText(world)));
  });

  // The clipboard.
  step(QStringLiteral("a page from %1 in a browser tab asks to read the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    showAsk(world, hostFor(c[0]));
    askToRead(world);
  });
  step(QStringLiteral("a page from %1 asks to read the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    showAsk(world, hostFor(c[0]));
    askToRead(world);
  });
  step(QStringLiteral("the user is asked (?:whether|about) %1(?: may see what was copied)?").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForQuestion(world);
    const QString host = hostFor(c[0]);
    expect(question().value(QStringLiteral("kind")) == QLatin1String("clipboard") && questionText(world).contains(host),
           QStringLiteral("the user was asked \"%1\"").arg(questionText(world)));
  });
  step(QStringLiteral("the user (allows|blocks) it"), [](World& world, const Captures& c, const Table&) {
    world.brick->click(c[0] == QLatin1String("allows") ? QStringLiteral("browserQuestionAllow") : QStringLiteral("browserQuestionRefuse"));
  });
  step(QStringLiteral("the page (reads the clipboard|gets nothing)"), [](World& world, const Captures& c, const Table&) {
    const QString learnt = result(world);
    const QString wanted = c[0] == QLatin1String("gets nothing") ? QStringLiteral("nothing") : QStringLiteral("read copied text");
    expect(learnt == wanted, QStringLiteral("the page learnt %1").arg(learnt));
    expect(!questionCard(world)->isVisible(), QStringLiteral("the question is still up"));
  });
  step(QStringLiteral("%1 is not asked again while the browser stays open").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString first = result(world);
    askToRead(world);
    expect(result(world) == first, QStringLiteral("the page learnt something else the second time"));
    expectNoQuestion(world);
    (void)c;
  });
  step(QStringLiteral("the user allowed %1 to read the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    showAsk(world, hostFor(c[0]));
    askToRead(world);
    waitForQuestion(world);
    world.brick->click(QStringLiteral("browserQuestionAllow"));
    expect(result(world) == QLatin1String("read copied text"), QStringLiteral("the page could not read the clipboard"));
  });

  // A prompt's default.
  step(QStringLiteral("a page asks to (read the clipboard|open an outside link)"), [](World& world, const Captures& c, const Table&) {
    showAsk(world);
    if (c[0] == QLatin1String("read the clipboard"))
      askToRead(world);
    else
      followLink(world, QStringLiteral("slack://channel?team=T1"));
    waitForQuestion(world);
  });
  step(QStringLiteral("the prompt's default choice refuses it"), [](World& world, const Captures&, const Table&) {
    const bool link = question().value(QStringLiteral("kind")) == QLatin1String("link");
    QQuickItem* refuse = world.brick->item(QStringLiteral("browserQuestionRefuse"));
    world.waitFor([&] { return refuse->hasActiveFocus(); }, QStringLiteral("the refusing choice to have the keyboard"));
    expect(world.brick->press(QStringLiteral("enter")), QStringLiteral("Enter went nowhere"));
    world.sync();
    expect(!questionCard(world)->isVisible(), QStringLiteral("Enter did not answer the question"));
    if (link) {
      settle(world);
      expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1").arg(opened(world)));
    } else {
      expect(result(world) == QLatin1String("nothing"), QStringLiteral("the page read the clipboard"));
    }
  });
  step(QStringLiteral("a request that arrives while another prompt is open is refused without being remembered"), [](World& world, const Captures&, const Table&) {
    // Another site, so the answer just given is not the one that counts.
    showAsk(world, QStringLiteral("127.0.0.1"));
    followLink(world, QStringLiteral("slack://channel?team=T2"));
    waitForQuestion(world);
    askToRead(world);
    expect(result(world) == QLatin1String("nothing"), QStringLiteral("the page read the clipboard behind the question"));
    expect(question().value(QStringLiteral("kind")) == QLatin1String("link"), QStringLiteral("the question on screen changed"));
    world.brick->click(QStringLiteral("browserQuestionRefuse"));
    world.sync();
    askToRead(world);
    waitForQuestion(world);
    expect(question().value(QStringLiteral("kind")) == QLatin1String("clipboard"), QStringLiteral("the site was not asked about the clipboard"));
  });

  // Notifications.
  step(QStringLiteral("a page in a browser tab asks to show notifications"), [](World& world, const Captures&, const Table&) {
    awaitSystemNotifications(world);
    showAsk(world);
    act(world, kAsks.value(QStringLiteral("to show notifications")));
    expect(result(world) == QLatin1String("refused"), QStringLiteral("the page may show notifications"));
  });
  step(QStringLiteral("the page tries to raise a system notification"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("var n = new Notification('Prize', {body: 'Claim it'}); n.onshow = function () { done('shown'); };"
                              " n.onerror = function () { done('refused'); };"));
    expect(result(world) == QLatin1String("refused"), QStringLiteral("the page's notification was shown"));
  });
  step(QStringLiteral("no system notification appears"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(systemNotifications(world).isEmpty() && alertsSeen(world).shown.isEmpty(),
           QStringLiteral("notifications appeared for %1").arg(systemNotifications(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the app's own notifications, such as a finished turn, still appear"), [](World& world, const Captures&, const Table&) {
    finishTurnInBackground(world, QStringLiteral("Tax fix"));
    world.sync();
    expect(systemNotifications(world).size() == 1, QStringLiteral("%1 notifications appeared").arg(systemNotifications(world).size()));
  });

  // Links to other apps.
  step(QStringLiteral("a page in a browser tab follows the link %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showAsk(world);
    followLink(world, c[0]);
  });
  step(QStringLiteral("the user is asked whether to open this (\\w+) link"), [](World& world, const Captures& c, const Table&) {
    waitForQuestion(world);
    expect(question().value(QStringLiteral("kind")) == QLatin1String("link") && questionText(world).contains(c[0]),
           QStringLiteral("the user was asked \"%1\"").arg(questionText(world)));
  });
  step(QStringLiteral("the link opens in the system only if the user agrees"), [](World& world, const Captures&, const Table&) {
    settle(world);
    expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1 before the user agreed").arg(opened(world)));
    world.brick->click(QStringLiteral("browserQuestionAllow"));
    world.sync();
    expect(world.openedUrls == QList<QUrl>{QUrl(asking(world).link)}, QStringLiteral("the system opened %1").arg(opened(world)));
  });
  step(QStringLiteral("a second such link waits until the first question is answered"), [](World& world, const Captures&, const Table&) {
    world.openedUrls.clear();
    followLink(world, QStringLiteral("slack://channel?team=T2"));
    waitForQuestion(world);
    followLink(world, QStringLiteral("slack://channel?team=T3"));
    settle(world);
    expect(question().value(QStringLiteral("url")).toUrl() == QUrl(QStringLiteral("slack://channel?team=T2")),
           QStringLiteral("the user is asked about %1").arg(question().value(QStringLiteral("url")).toString()));
    world.brick->click(QStringLiteral("browserQuestionRefuse"));
    world.sync();
    waitForQuestion(world);
    expect(question().value(QStringLiteral("url")).toUrl() == QUrl(QStringLiteral("slack://channel?team=T3")),
           QStringLiteral("the second link was not asked about; %1").arg(question().value(QStringLiteral("url")).toString()));
    world.brick->click(QStringLiteral("browserQuestionAllow"));
    world.sync();
    expect(world.openedUrls == QList<QUrl>{QUrl(QStringLiteral("slack://channel?team=T3"))},
           QStringLiteral("the system opened %1").arg(opened(world)));
  });
  // A tab that is not shown.
  step(QStringLiteral("the question is withdrawn and the link does not open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([] { return question().isEmpty(); }, [] { return QStringLiteral("the question to go; it asks about %1").arg(question().value(QStringLiteral("url")).toString()); });
    settle(world);
    expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1").arg(opened(world)));
  });
  step(QStringLiteral("the page in the hidden tab follows the link %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* view = world.brick->item(QStringLiteral("browserView"));
    expect(!view->isVisible(), QStringLiteral("the browser tab still shows"));
    // No click reaches a hidden page: its script moves it.
    webtab::evaluate(world, QStringLiteral("window.followed = false; setTimeout(function () { window.followed = true; location.href = '%1'; }, 0); true").arg(c[0]));
    webtab::waitForEngine(world, [&] { return webtab::evaluate(world, QStringLiteral("window.followed")).toBool(); },
                          [] { return QStringLiteral("the hidden page to follow the link"); });
  });
  step(QStringLiteral("the user is not asked about it and the system is not asked to open it"), [](World& world, const Captures&, const Table&) {
    settle(world);
    expect(question().isEmpty(), QStringLiteral("the user is asked about %1").arg(question().value(QStringLiteral("url")).toString()));
    expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1").arg(opened(world)));
  });
  step(QStringLiteral("the user switches back to the browser tab"), [](World& world, const Captures&, const Table&) {
    QString browser;
    for (const QVariant& tab : at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList()) {
      if (at(tab, QStringLiteral("id")).toString().startsWith(QLatin1String("browser:"))) browser = at(tab, QStringLiteral("id")).toString();
    }
    expect(!browser.isEmpty(), QStringLiteral("no browser tab in the panel"));
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), browser}});
    QQuickItem* view = world.brick->item(QStringLiteral("browserView"));
    world.waitFor([&] { return view->isVisible(); }, QStringLiteral("the browser tab to show"));
  });
  step(QStringLiteral("a page in a browser tab follows a link with the scheme %1 to another app").arg(q), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> links{
        {QStringLiteral("file"), QStringLiteral("location.href = 'file:///etc/hosts';")},
        {QStringLiteral("javascript"), QStringLiteral("location.href = 'javascript:void(0)';")},
        {QStringLiteral("data"), QStringLiteral("location.href = 'data:text/plain,hi';")},
        {QStringLiteral("blob"), QStringLiteral("location.href = URL.createObjectURL(new Blob(['hi'], {type: 'text/plain'}));")},
    };
    expect(links.contains(c[0]), QStringLiteral("no link with the scheme %1").arg(c[0]));
    showAsk(world);
    act(world, links.value(c[0]));
  });
  step(QStringLiteral("the system is not asked to open it"), [](World& world, const Captures&, const Table&) {
    expectNoQuestion(world);
    expect(world.openedUrls.isEmpty(), QStringLiteral("the system opened %1").arg(opened(world)));
  });
});

}  // namespace
