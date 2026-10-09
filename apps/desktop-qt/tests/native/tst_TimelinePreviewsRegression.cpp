// What tests/prop/tst_TimelinePreviewsProp.cpp found in ThreadPreviews, each
// as the plain case that shows it.

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTest>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadPreviews.h"
#include "TestTime.h"

namespace {

const QString kEnvironment = QStringLiteral("env-a");
const QString kMc = QStringLiteral("mc-a");
const QString kThread = QStringLiteral("t1");

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
    for (const QString& method : {QStringLiteral("preview.list"), QStringLiteral("preview.close"), QStringLiteral("preview.open")}) {
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
    if (!halc2::test::waitFor([this] { return client->isReady(); })) return false;
    previews->setThread(kEnvironment, kThread, kMc);
    previews->setActive(true);
    return halc2::test::waitFor([this] { return !held.value(QStringLiteral("preview.list")).isEmpty() && !mc.subscribers(QStringLiteral("preview")).isEmpty(); });
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
    return halc2::test::waitFor([&answered] { return answered; });
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
    QVERIFY(halc2::test::waitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
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
    QVERIFY(halc2::test::waitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty() && !f.mc.subscribers(QStringLiteral("preview")).isEmpty(); }));
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
    QVERIFY(halc2::test::waitFor([&f] { return !f.held.value(QStringLiteral("preview.close")).isEmpty(); }));
    f.previews->reload();
    QVERIFY(halc2::test::waitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
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
    QVERIFY(halc2::test::waitFor([&f] { return !f.held.value(QStringLiteral("preview.list")).isEmpty(); }));
    QJsonObject later = tab(QStringLiteral("tab-1"), loaded);
    later.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    f.mc.reply(f.held[QStringLiteral("preview.list")].takeFirst(), list({later}, 2));
    QVERIFY(f.barrier());
    QCOMPARE(redrawn.count(), 0);
    QCOMPARE(resets.count(), 0);
  }
};

QTEST_MAIN(tst_TimelinePreviewsRegression)
#include "tst_TimelinePreviewsRegression.moc"
