// What tests/prop/tst_WorkspaceFilesProp.cpp found in WorkspaceFiles, and how
// a media file previews from the address its environment signs.

#include <QtTest>

#include <QDateTime>
#include <QJsonArray>

#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"

namespace {

// An MC that holds every listing and search until the test answers it.
struct Held {
  FakeMc mc;
  McClient client;
  QList<FakeMc::Rpc> calls;

  Held() {
    const auto hold = [this](const FakeMc::Rpc& rpc) { calls.append(rpc); };
    mc.onRpc(QStringLiteral("projects.listEntries"), hold);
    mc.onRpc(QStringLiteral("projects.searchEntries"), hold);
    mc.onRpc(QStringLiteral("assets.createUrl"), hold);
    mc.onRpc(QStringLiteral("projects.readFile"), hold);
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
  }

  bool ready() { return QTest::qWaitFor([this] { return client.isReady(); }); }
  bool asked(qsizetype count) { return QTest::qWaitFor([this, count] { return calls.size() == count; }); }
  // Answers the call with one file, and waits for the client to read it.
  bool answer(qsizetype call, const QString& file) {
    mc.reply(calls.at(call), QJsonObject{{QStringLiteral("entries"),
                                          QJsonArray{QJsonObject{{QStringLiteral("path"), file}, {QStringLiteral("kind"), QStringLiteral("file")}}}}});
    return settled();
  }
  // The calls of one method, in order.
  QList<FakeMc::Rpc> callsOf(const QString& method) const {
    QList<FakeMc::Rpc> found;
    for (const FakeMc::Rpc& rpc : calls) {
      if (rpc.method == method) found.append(rpc);
    }
    return found;
  }
  qsizetype signings() const { return callsOf(QStringLiteral("assets.createUrl")).size(); }
  // Answers the newest signing with `relative`, good for `seconds`.
  bool sign(const QString& relative, qint64 seconds = 3600) {
    mc.reply(callsOf(QStringLiteral("assets.createUrl")).last(),
             QJsonObject{{QStringLiteral("relativeUrl"), relative},
                         {QStringLiteral("expiresAt"), double(QDateTime::currentMSecsSinceEpoch() + seconds * 1000)}});
    return settled();
  }
  // Waits until the client has read every answer sent so far.
  bool settled() {
    bool done = false;
    QObject context;
    client.call(&context, {}, QStringLiteral("test.barrier"), {}, [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    return QTest::qWaitFor([&done] { return done; });
  }
};

}  // namespace

class WorkspaceFilesRegression : public QObject {
  Q_OBJECT

private slots:
  // Two listings of one folder answered out of order: the older one, read
  // before the agent changed the workspace, replaced the newer.
  void anOlderListingAnsweredLateIsDropped() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
    files.setActive(true);
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringLiteral("first")));
    files.tree()->refresh();
    files.tree()->refresh();
    QVERIFY(held.asked(3));
    QVERIFY(held.answer(2, QStringLiteral("newer")));
    QVERIFY(held.answer(1, QStringLiteral("older")));
    QCOMPARE(files.tree()->visiblePaths(), QStringList{QStringLiteral("newer")});
  }

  // Switching workspace while a search was on its way showed the old
  // workspace's matches in the new one.
  void aSearchOfTheWorkspaceLeftIsDropped() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w1"));
    files.setQuery(QStringLiteral("x"));
    QVERIFY(held.asked(1));
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w2"));
    QVERIFY(held.answer(0, QStringLiteral("x-of-w1")));
    QVERIFY(!files.tree()->filtered());
    QVERIFY(files.tree()->visiblePaths().isEmpty());
  }

  // What a file previews as, by its extension; HTML renders as text.
  void mediaKindsFollowTheExtension() {
    const QList<std::pair<QString, QString>> kinds{
        {QStringLiteral("assets/logo.png"), QStringLiteral("image")}, {QStringLiteral("a/B.JPG"), QStringLiteral("image")},
        {QStringLiteral("icon.svg"), QStringLiteral("image")},        {QStringLiteral("media/intro.mp4"), QStringLiteral("video")},
        {QStringLiteral("clip.webm"), QStringLiteral("video")},       {QStringLiteral("media/theme.mp3"), QStringLiteral("audio")},
        {QStringLiteral("a.wav"), QStringLiteral("audio")},           {QStringLiteral("a.ogg"), QStringLiteral("audio")},
        {QStringLiteral("a.m4a"), QStringLiteral("audio")},           {QStringLiteral("a.flac"), QStringLiteral("audio")},
        {QStringLiteral("docs/manual.pdf"), QStringLiteral("pdf")},   {QStringLiteral("public/index.html"), QString()},
        {QStringLiteral("src/app.ts"), QString()},                    {QStringLiteral("Makefile"), QString()},
        {QStringLiteral("logo.png/README"), QString()},
    };
    for (const auto& [path, kind] : kinds) QCOMPARE(WorkspaceFiles::mediaKindOf(path), kind);
  }

  // An image is signed for, never read; a load that fails is retried with a
  // new address; and an address that has run out is signed again when the
  // file is opened again or the tab shows.
  void anImageIsSignedLoadedAndSignedAgain() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"), QStringLiteral("t1"));
    files.openFile(QStringLiteral("assets/logo.png"));
    QCOMPARE(files.fileStatus(), QStringLiteral("loading"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 1; }));
    const FakeMc::Rpc signing = held.callsOf(QStringLiteral("assets.createUrl")).first();
    QCOMPARE(signing.environment, QStringLiteral("env-a"));
    QCOMPARE(signing.payload.value(QLatin1String("resource")).toObject(),
             (QJsonObject{{QStringLiteral("_tag"), QStringLiteral("workspace-file")},
                          {QStringLiteral("threadId"), QStringLiteral("t1")},
                          {QStringLiteral("path"), QStringLiteral("assets/logo.png")}}));
    QVERIFY(held.sign(QStringLiteral("/api/assets/one/logo.png")));
    QCOMPARE(files.fileStatus(), QStringLiteral("ready"));
    QCOMPARE(files.mediaKind(), QStringLiteral("image"));
    QCOMPARE(files.mediaUrl(), held.client.origin().resolved(QUrl(QStringLiteral("/api/assets/one/logo.png"))));
    QVERIFY(!files.editable() && !files.fileEmpty());

    // A failure of an address no longer shown changes nothing.
    files.mediaFailed(QUrl(QStringLiteral("http://elsewhere/logo.png")));
    QCOMPARE(files.fileStatus(), QStringLiteral("ready"));
    files.mediaFailed(files.mediaUrl());
    QCOMPARE(files.fileStatus(), QStringLiteral("error"));
    QCOMPARE(files.fileProblem(), QStringLiteral("The image could not be loaded."));
    QVERIFY(files.mediaUrl().isEmpty());
    files.reloadFile();
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 2; }));
    // Good for less than the minute kept in hand: run out at once.
    QVERIFY(held.sign(QStringLiteral("/api/assets/two/logo.png"), 30));
    QCOMPARE(files.fileStatus(), QStringLiteral("ready"));
    QCOMPARE(files.mediaUrl().path(), QStringLiteral("/api/assets/two/logo.png"));

    files.openFile(QStringLiteral("assets/logo.png"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 3; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/three/logo.png"), 30));
    files.setActive(true);
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 4; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/four/logo.png")));
    // An address that still works is kept.
    files.setActive(false);
    files.setActive(true);
    files.openFile(QStringLiteral("assets/logo.png"));
    QVERIFY(held.settled());
    QCOMPARE(held.signings(), 4);
    QCOMPARE(files.mediaUrl().path(), QStringLiteral("/api/assets/four/logo.png"));
    QVERIFY(held.callsOf(QStringLiteral("projects.readFile")).isEmpty());

    // Closing the file lets the address go.
    files.closeFile();
    QVERIFY(files.mediaUrl().isEmpty());
  }

  // The browser is handed an address that works: the one shown while it
  // lasts, else a new one once signed.
  void theBrowserGetsAnAddressThatWorks() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    QList<QUrl> opened;
    QObject::connect(&files, &WorkspaceFiles::mediaOpened, [&opened](const QUrl& url) { opened.append(url); });
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"), QStringLiteral("t1"));
    files.openFile(QStringLiteral("media/intro.mp4"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 1; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/one/intro.mp4")));
    files.openMedia();
    QCOMPARE(opened, QList<QUrl>{files.mediaUrl()});

    files.reloadFile();
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 2; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/two/intro.mp4"), 30));
    files.openMedia();
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 3; }));
    QCOMPARE(opened.size(), 1);
    QVERIFY(held.sign(QStringLiteral("/api/assets/three/intro.mp4")));
    QCOMPARE(opened.size(), 2);
    QCOMPARE(opened.last().path(), QStringLiteral("/api/assets/three/intro.mp4"));

    // A file opened before the new address arrives is not handed over.
    files.reloadFile();
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 4; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/four/intro.mp4"), 30));
    files.openMedia();
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 5; }));
    files.openFile(QStringLiteral("media/other.mp4"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 6; }));
    QVERIFY(held.sign(QStringLiteral("/api/assets/six/other.mp4")));
    QCOMPARE(opened.size(), 2);
  }

  // Of two opens signed out of order, the later one's address is shown.
  void theLatestOpenWins() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"), QStringLiteral("t1"));
    files.openFile(QStringLiteral("a.png"));
    files.openFile(QStringLiteral("b.png"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 2; }));
    const QList<FakeMc::Rpc> signings = held.callsOf(QStringLiteral("assets.createUrl"));
    const auto answer = [&](const FakeMc::Rpc& rpc, const QString& relative) {
      held.mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), relative},
                                     {QStringLiteral("expiresAt"), double(QDateTime::currentMSecsSinceEpoch() + 3600'000)}});
      return held.settled();
    };
    QVERIFY(answer(signings.at(1), QStringLiteral("/api/assets/b/b.png")));
    QVERIFY(answer(signings.at(0), QStringLiteral("/api/assets/a/a.png")));
    QCOMPARE(files.openPath(), QStringLiteral("b.png"));
    QCOMPARE(files.mediaUrl().path(), QStringLiteral("/api/assets/b/b.png"));
  }

  // A file outside the workspace is signed as a media file; with no thread,
  // the workspace's folder names it; a file the MC will not sign says why.
  void theResourceFollowsThePathAndTheThread() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"), QStringLiteral("t1"));
    files.openFile(QStringLiteral("/home/me/shot.png"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 1; }));
    QCOMPARE(held.callsOf(QStringLiteral("assets.createUrl")).last().payload.value(QLatin1String("resource")).toObject(),
             (QJsonObject{{QStringLiteral("_tag"), QStringLiteral("media-file")},
                          {QStringLiteral("threadId"), QStringLiteral("t1")},
                          {QStringLiteral("path"), QStringLiteral("/home/me/shot.png")}}));
    held.mc.refuse(held.callsOf(QStringLiteral("assets.createUrl")).last(), QStringLiteral("Media file was not found."));
    QVERIFY(held.settled());
    QCOMPARE(files.fileStatus(), QStringLiteral("error"));
    QCOMPARE(files.fileProblem(), QStringLiteral("Media file was not found."));

    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/draft"));
    files.openFile(QStringLiteral("media/theme.mp3"));
    QVERIFY(QTest::qWaitFor([&] { return held.signings() == 2; }));
    QCOMPARE(held.callsOf(QStringLiteral("assets.createUrl")).last().payload.value(QLatin1String("resource")).toObject(),
             (QJsonObject{{QStringLiteral("_tag"), QStringLiteral("draft-workspace-file")},
                          {QStringLiteral("cwd"), QStringLiteral("/draft")},
                          {QStringLiteral("path"), QStringLiteral("media/theme.mp3")}}));
  }

  // A full path is the thread's machine's: on Windows it has a drive or a
  // share, and with forward slashes it was signed as a workspace file.
  void aWindowsPathIsAMediaFile() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("C:/w"), QStringLiteral("t1"));
    const QStringList paths{QStringLiteral("C:/Users/me/shot.png"), QStringLiteral("D:\\shots\\b.png"),
                            QStringLiteral("\\\\server\\share\\c.png")};
    for (const QString& path : paths) {
      files.openFile(path);
      QVERIFY(QTest::qWaitFor([&] { return held.signings() == paths.indexOf(path) + 1; }));
      QCOMPARE(held.callsOf(QStringLiteral("assets.createUrl")).last().payload.value(QLatin1String("resource")).toObject()
                   .value(QLatin1String("_tag")).toString(),
               QStringLiteral("media-file"));
    }
  }

  // A query typed with no workspace said a search was on its way, forever.
  void aQueryWithoutAWorkspaceIsNotSearching() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QString());
    files.setQuery(QStringLiteral("x"));
    QVERIFY(!files.searching());
  }

  // The tab shown with a search's matches on screen never listed the top
  // folder: it judged "never listed" by the tree having no rows.
  void showingTheTabOverASearchListsTheTopFolder() {
    Held held;
    QVERIFY(held.ready());
    WorkspaceFiles files(&held.client);
    files.setSearchDelay(0);
    files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
    files.setQuery(QStringLiteral("x"));
    QVERIFY(held.asked(1));
    QVERIFY(held.answer(0, QStringLiteral("x")));
    files.setActive(true);
    QVERIFY(held.asked(2));
    QCOMPARE(held.calls.at(1).method, QStringLiteral("projects.listEntries"));
    // The search stays on screen until the query is cleared.
    QVERIFY(files.tree()->filtered());
    QVERIFY(held.answer(1, QStringLiteral("top")));
    files.setQuery({});
    QCOMPARE(files.tree()->visiblePaths(), QStringList{QStringLiteral("top")});
  }
};

QTEST_GUILESS_MAIN(WorkspaceFilesRegression)
#include "tst_WorkspaceFilesRegression.moc"
