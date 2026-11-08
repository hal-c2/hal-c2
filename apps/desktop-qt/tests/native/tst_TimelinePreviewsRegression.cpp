// What tests/prop/tst_TimelinePreviewsProp.cpp found in ThreadPreviews and
// the BrowserPage following one of its tabs, each as the plain case that shows it.

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTest>

#include <memory>

#include "FakeMc.h"
#include "Browser.h"
#include "McClient.h"
#include "ThreadPreviews.h"

namespace {

const QString kEnvironment = QStringLiteral("env-a");
const QString kMc = QStringLiteral("mc-a");
const QString kThread = QStringLiteral("t1");
const QString kPageA = QStringLiteral("http://localhost:3000/");
const QString kPageB = QStringLiteral("http://localhost:3000/b");
const QString kPageC = QStringLiteral("http://localhost:3000/c");

QJsonObject phone() {
  return {{QStringLiteral("_tag"), QStringLiteral("preset")}, {QStringLiteral("width"), 375}, {QStringLiteral("height"), 667},
          {QStringLiteral("presetId"), QStringLiteral("iphone-se")}};
}

QJsonObject loadedAt(const QString& url) {
  return {{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), url}};
}

QJsonObject tab(const QString& id, const QJsonObject& nav = {{QStringLiteral("_tag"), QStringLiteral("Idle")}}) {
  return {{QStringLiteral("threadId"), kThread}, {QStringLiteral("tabId"), id}, {QStringLiteral("navStatus"), nav}};
}

QJsonObject list(const QJsonArray& sessions, qint64 revision, const QString& epoch = QStringLiteral("epoch-1")) {
  return {{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), epoch}, {QStringLiteral("revision"), revision}};
}

// A thread's tabs shown against an MC that holds every preview call until the test answers it.
struct Fixture {
  FakeMc mc;
  QHash<QString, QList<FakeMc::Rpc>> held;
  std::unique_ptr<McClient> client;
  std::unique_ptr<ThreadPreviews> previews;

  Fixture() {
    mc.environmentId = kEnvironment;
    mc.name = kMc;
    mc.onShape(QStringLiteral("preview"), [](int, const QJsonObject&) {});
    mc.onShape(QStringLiteral("localServers"), [](int, const QJsonObject&) {});
    for (const QString& method : {QStringLiteral("preview.list"), QStringLiteral("preview.close"), QStringLiteral("preview.open"),
                                  QStringLiteral("preview.resize"), QStringLiteral("preview.reportStatus")}) {
      mc.onRpc(method, [this, method](const FakeMc::Rpc& rpc) { held[method].append(rpc); });
    }
    client = std::make_unique<McClient>();
    client->setRetryDelays({20});
    client->open(mc.origin(), QStringLiteral("token"));
    previews = std::make_unique<ThreadPreviews>(
        client.get(), [](const QString&, const QString&, const QString&) {}, [](const QUrl&) {});
  }

  // Shown and listing: the list call is held.
  bool show() {
    if (!QTest::qWaitFor([this] { return client->isReady(); })) return false;
    previews->setThread(kEnvironment, kThread, kMc);
    previews->setActive(true);
    return QTest::qWaitFor([this] { return !held.value(QStringLiteral("preview.list")).isEmpty() && !mc.subscribers(QStringLiteral("preview")).isEmpty(); });
  }

  bool answerList(const QJsonObject& list) {
    mc.reply(held[QStringLiteral("preview.list")].takeFirst(), list);
    return barrier() && previews->status() == QLatin1String("ready");
  }

  void emitEvent(const QString& type, const QString& tabId, qint64 revision, QJsonObject fields = {}) {
    fields.insert(QStringLiteral("type"), type);
    fields.insert(QStringLiteral("threadId"), kThread);
    fields.insert(QStringLiteral("tabId"), tabId);
    fields.insert(QStringLiteral("serverEpoch"), QStringLiteral("epoch-1"));
    fields.insert(QStringLiteral("revision"), revision);
    for (const int id : mc.subscribers(QStringLiteral("preview"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("preview")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), fields}});
    }
  }

  // Every frame the MC sent before this has been read.
  bool barrier() {
    QObject context;
    bool answered = false;
    client->call(&context, kEnvironment, QStringLiteral("test.barrier"), QJsonObject(),
                 [&answered](const QJsonValue&, const std::optional<QString>&) { answered = true; });
    return QTest::qWaitFor([&answered] { return answered; });
  }

  QStringList tabIds() const {
    QStringList ids;
    for (int row = 0; row < previews->rowCount(); ++row) ids.append(previews->index(row).data(ThreadPreviews::TabIdRole).toString());
    return ids;
  }
};

}  // namespace

class tst_TimelinePreviewsRegression : public QObject {
  Q_OBJECT

private slots:
  // A tab closed while the first list was on its way came back with that
  // list, which was read before the close: events before the list were dropped.
  // Nor does the list show it for a moment, resetting the rows for nothing.
  void aTabClosedWhileTheListIsOnItsWayStaysClosed() {
    Fixture f;
    QVERIFY(f.show());
    QSignalSpy resets(f.previews.get(), &QAbstractItemModel::modelReset);
    f.emitEvent(QStringLiteral("closed"), QStringLiteral("tab-1"), 2);
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    QCOMPARE(f.tabIds(), QStringList());
    QCOMPARE(resets.count(), 0);
  }

  // An MC that restarted while the client was away kept showing the tabs it
  // no longer has: nothing asked for the list again on the reconnect.
  void aReconnectListsTheTabsAgain() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    QCOMPARE(f.tabIds(), QStringList{QStringLiteral("tab-1")});
    f.mc.drop();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QVERIFY(f.answerList(list({}, 0, QStringLiteral("epoch-2"))));
    QCOMPARE(f.tabIds(), QStringList());
  }

  // A list read before an event the client had already applied was dropped
  // whole, so a tab closed while nobody watched stayed shown.
  void aListOlderThanAnEventStillDropsWhatItClosed() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    f.previews->setActive(false);
    // The MC closes tab-1 (revision 2) unwatched, then lists, then opens tab-2.
    f.previews->setActive(true);
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty() && !f.mc.subscribers(QStringLiteral("preview")).isEmpty(); }));
    f.emitEvent(QStringLiteral("opened"), QStringLiteral("tab-2"), 3, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-2"))}});
    QVERIFY(f.barrier());
    f.mc.reply(f.held[QStringLiteral("preview.list")].takeFirst(), list({}, 2));
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList{QStringLiteral("tab-2")});
  }

  // A close the MC refused after the list was read again did not put the tab
  // back: the reload made its answer look like one for another thread.
  void aRefusedCloseAfterAReloadPutsTheTabBack() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    f.previews->close(QStringLiteral("tab-1"));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.close")).isEmpty(); }));
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    f.mc.reply(f.held[QStringLiteral("preview.list")].takeFirst(), list({tab(QStringLiteral("tab-1"))}, 1));
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList());
    f.mc.refuse(f.held[QStringLiteral("preview.close")].takeFirst(), QStringLiteral("no"));
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList{QStringLiteral("tab-1")});
  }

  // A tab whose snapshot changed only where no row reads it repainted, and a
  // list with such a change reset every row.
  void aChangeNoRoleShowsRepaintsNothing() {
    Fixture f;
    QVERIFY(f.show());
    const QJsonObject loaded{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), QStringLiteral("http://localhost:3000/")}};
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loaded)}, 1)));
    QSignalSpy redrawn(f.previews.get(), &QAbstractItemModel::dataChanged);
    QSignalSpy resets(f.previews.get(), &QAbstractItemModel::modelReset);
    QJsonObject titled = loaded;
    titled.insert(QStringLiteral("title"), QString());
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 2, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), titled)}});
    QVERIFY(f.barrier());
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QJsonObject later = tab(QStringLiteral("tab-1"), loaded);
    later.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    f.mc.reply(f.held[QStringLiteral("preview.list")].takeFirst(), list({later}, 2));
    QVERIFY(f.barrier());
    QCOMPARE(redrawn.count(), 0);
    QCOMPARE(resets.count(), 0);
  }

  // A link opened for a thread on another MC gets a tab there first; when the
  // answers came after the user had gone to another thread, that tab showed in
  // the other thread's list.
  void aLinkForAThreadLeftBehindAddsNoTabToTheNextOne() {
    Fixture f;
    QVERIFY(QTest::qWaitFor([&f] { return f.client->isReady(); }));
    const QString remote = QStringLiteral("t2");
    f.previews->setThread(QStringLiteral("env-b"), remote, QStringLiteral("mc-b"));
    f.previews->openAddress(QStringLiteral("http://localhost:3000/"));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    const FakeMc::Rpc remoteList = f.held[QStringLiteral("preview.list")].takeFirst();
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({}, 1)));
    f.mc.reply(remoteList, list({}, 1));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.open")).isEmpty(); }));
    const QJsonObject opened{{QStringLiteral("threadId"), remote},
                             {QStringLiteral("tabId"), QStringLiteral("tab-9")},
                             {QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Loading")},
                                                                       {QStringLiteral("url"), QStringLiteral("http://localhost:3000/")}}}};
    f.mc.reply(f.held[QStringLiteral("preview.open")].takeFirst(), opened);
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList());
  }

  // A close the MC refused put the row back without saying the tab changed,
  // so a page following it kept thinking it was gone.
  void aRefusedCloseSaysTheTabIsBack() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    f.previews->close(QStringLiteral("tab-1"));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.close")).isEmpty(); }));
    QSignalSpy changed(f.previews.get(), &ThreadPreviews::tabChanged);
    f.mc.refuse(f.held[QStringLiteral("preview.close")].takeFirst(), QStringLiteral("no"));
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList{QStringLiteral("tab-1")});
    QVERIFY(!changed.isEmpty());
    QCOMPARE(changed.constLast().constFirst().toString(), QStringLiteral("tab-1"));
  }

  // A link opened after the tabs could not be listed again showed a row the
  // MC may no longer have instead of asking it for a tab.
  void aLinkAfterAFailedListAsksForATab() {
    Fixture f;
    f.previews->setEmbedded(true);
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    f.mc.refuse(f.held[QStringLiteral("preview.list")].takeFirst(), QStringLiteral("no"));
    QVERIFY(f.barrier());
    QCOMPARE(f.previews->status(), QStringLiteral("failed"));
    QSignalSpy shown(f.previews.get(), &ThreadPreviews::showRequested);
    f.previews->openAddress(kPageA);
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.open")).isEmpty(); }));
    QCOMPARE(shown.count(), 0);
  }

  // A link opened while the tabs were listed again (as after a reconnect)
  // showed a row the MC may no longer have instead of asking it for a tab.
  void aLinkWhileListingAsksForATab() {
    Fixture f;
    f.previews->setEmbedded(true);
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QSignalSpy shown(f.previews.get(), &ThreadPreviews::showRequested);
    f.previews->openAddress(kPageA);
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.open")).isEmpty(); }));
    QCOMPARE(shown.count(), 0);
  }

  // A tab the user opened was never shown when the list was read again
  // before the MC answered.
  void aNewTabShowsThoughTheListWasReadAgain() {
    Fixture f;
    f.previews->setEmbedded(true);
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({}, 1)));
    f.previews->newTab();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.open")).isEmpty(); }));
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QSignalSpy shown(f.previews.get(), &ThreadPreviews::showRequested);
    f.mc.reply(f.held[QStringLiteral("preview.open")].takeFirst(), tab(QStringLiteral("tab-2")));
    QVERIFY(f.barrier());
    QCOMPARE(shown.count(), 1);
    QCOMPARE(shown.constFirst().constFirst().toString(), QStringLiteral("tab-2"));
  }

  // An agent taking a tab back to an address its page had been at left the
  // page where it was: every address the page had been at counted as its own.
  void aPageFollowsAnAgentBackToAnEarlierAddress() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    QSignalSpy loads(&page, &BrowserPage::loadRequested);
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 2, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageB))}});
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 3, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageA))}});
    QVERIFY(f.barrier());
    QCOMPARE(loads.count(), 2);
    QCOMPARE(loads.at(0).constFirst().toString(), kPageB);
    QCOMPARE(loads.at(1).constFirst().toString(), kPageA);
    // Where the page went by itself is no news when the MC says it back.
    page.report(QStringLiteral("loaded"), kPageB, QString(), 0, QString(), true, false);
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 4, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageB))}});
    QVERIFY(f.barrier());
    QCOMPARE(loads.count(), 2);
  }

  // A page whose tab went from the list (another thread shown) and came back
  // thought its view was still at the tab's address, and never loaded it.
  void aPageWhoseTabComesBackLoadsIt() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    QSignalSpy loads(&page, &BrowserPage::loadRequested);
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QVERIFY(f.answerList(list({}, 2)));
    QVERIFY(!page.exists());
    f.previews->reload();
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 3)));
    QCOMPARE(loads.count(), 1);
    QCOMPARE(loads.constFirst().constFirst().toString(), kPageA);
  }

  // A tab the user closed while its size was on its way came back with the
  // size's answer, read as the tab's latest snapshot.
  void aSizeAnsweredWhileTheTabClosesLeavesItClosed() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    page.setViewport(phone().toVariantMap());
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.resize")).isEmpty(); }));
    f.previews->close(QStringLiteral("tab-1"));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.close")).isEmpty(); }));
    QJsonObject sized = tab(QStringLiteral("tab-1"));
    sized.insert(QStringLiteral("viewport"), phone());
    f.mc.reply(f.held[QStringLiteral("preview.resize")].takeFirst(), sized);
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList());
  }

  // A size the MC took stops waiting on the answer alone: the tab's `resized`
  // event may never reach a client (one still listing drops it).
  void aSizeTakenStopsWaitingOnTheAnswer() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    page.setViewport(phone().toVariantMap());
    QVERIFY(page.resizing());
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.resize")).isEmpty(); }));
    QJsonObject sized = tab(QStringLiteral("tab-1"));
    sized.insert(QStringLiteral("viewport"), phone());
    f.mc.reply(f.held[QStringLiteral("preview.resize")].takeFirst(), sized);
    QVERIFY(f.barrier());
    QVERIFY(!page.resizing());
    QCOMPARE(QJsonObject::fromVariantMap(page.viewport()), phone());
  }

  // The tab resized while the page's new address was on its way to the MC:
  // the old address in the resized tab took the page back there.
  void aResizedTabLeavesThePageWhereItWent() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    QSignalSpy loads(&page, &BrowserPage::loadRequested);
    page.report(QStringLiteral("loaded"), kPageB, QString(), 0, QString(), true, false);
    QJsonObject sized = tab(QStringLiteral("tab-1"), loadedAt(kPageA));
    sized.insert(QStringLiteral("viewport"), phone());
    f.emitEvent(QStringLiteral("resized"), QStringLiteral("tab-1"), 2, {{QStringLiteral("snapshot"), sized}});
    QVERIFY(f.barrier());
    QCOMPARE(loads.count(), 0);
  }

  // The MC said back the page's first address while a later one was on its
  // way: the page took itself to be at the first, so when the MC never heard
  // the later one the page stayed where the MC's tab is not.
  void aPageTheMcDidNotHearFollowsItsTab() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    QSignalSpy loads(&page, &BrowserPage::loadRequested);
    page.report(QStringLiteral("loaded"), kPageB, QString(), 0, QString(), true, false);
    page.report(QStringLiteral("loaded"), kPageC, QString(), 0, QString(), true, false);
    QVERIFY(QTest::qWaitFor([&f] { return f.held.value(QStringLiteral("preview.reportStatus")).size() == 2; }));
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 2, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageB))}});
    f.mc.reply(f.held[QStringLiteral("preview.reportStatus")].takeFirst(), QJsonValue::Null);
    f.mc.refuse(f.held[QStringLiteral("preview.reportStatus")].takeFirst(), QStringLiteral("no"));
    QVERIFY(f.barrier());
    QCOMPARE(loads.count(), 1);
    QCOMPARE(loads.constFirst().constFirst().toString(), kPageB);
  }

  // The MC said back the page's second report from where its tab already was,
  // which left that echo waiting: an agent taking the tab back there later
  // was taken for it, and the page stayed put.
  void aPageFollowsAnAgentToWhereItSaidItWas() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"), loadedAt(kPageA))}, 1)));
    BrowserPage page;
    page.setPreviews(f.previews.get());
    page.setTabId(QStringLiteral("tab-1"));
    QSignalSpy loads(&page, &BrowserPage::loadRequested);
    const QJsonObject loadingB{{QStringLiteral("_tag"), QStringLiteral("Loading")}, {QStringLiteral("url"), kPageB}};
    page.report(QStringLiteral("loading"), kPageB, QString(), 0, QString(), true, false);
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 2, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadingB)}});
    QVERIFY(f.barrier());
    page.report(QStringLiteral("loaded"), kPageB, QString(), 0, QString(), true, false);
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 3, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageB))}});
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 4, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageC))}});
    f.emitEvent(QStringLiteral("navigated"), QStringLiteral("tab-1"), 5, {{QStringLiteral("snapshot"), tab(QStringLiteral("tab-1"), loadedAt(kPageB))}});
    QVERIFY(f.barrier());
    QCOMPARE(loads.count(), 2);
    QCOMPARE(loads.at(0).constFirst().toString(), kPageC);
    QCOMPARE(loads.at(1).constFirst().toString(), kPageB);
  }

  // A tab the MC closed while the user's close of it was on its way came back
  // when the MC refused that close.
  void aTabTheMcClosedStaysClosedThoughTheUsersCloseIsRefused() {
    Fixture f;
    QVERIFY(f.show());
    QVERIFY(f.answerList(list({tab(QStringLiteral("tab-1"))}, 1)));
    f.previews->close(QStringLiteral("tab-1"));
    QVERIFY(QTest::qWaitFor([&f] { return !f.held.value(QStringLiteral("preview.close")).isEmpty(); }));
    f.emitEvent(QStringLiteral("closed"), QStringLiteral("tab-1"), 2);
    f.mc.refuse(f.held[QStringLiteral("preview.close")].takeFirst(), QStringLiteral("no such tab"));
    QVERIFY(f.barrier());
    QCOMPARE(f.tabIds(), QStringList());
  }
};

QTEST_MAIN(tst_TimelinePreviewsRegression)
#include "tst_TimelinePreviewsRegression.moc"
