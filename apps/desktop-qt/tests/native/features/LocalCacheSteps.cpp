// What the client keeps between connections and runs (LocalCache): the thread
// list and the threads the user opened, shown before the MC answers and
// resumed from where they stood. The scenarios of
// features/connections/local-cache.feature, the long thread ones of
// timeline/scrolling-and-links.feature, and the steps other files' scenarios
// share to say what a thread cost the MC.

#include <QDir>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSignalSpy>
#include <qpa/qwindowsysteminterface.h>

#include "Brick.h"
#include "ConnectionHealthController.h"
#include "Harness.h"
#include "LocalCache.h"
#include "NativeShell.h"
#include "ShellStore.h"
#include "Stream.h"
#include "ThreadList.h"
#include "World.h"

namespace {

using namespace stream;

const QString kToken = QStringLiteral("mc-token");
const QString kKeptAnswer = QStringLiteral("The cart total includes tax now.");
const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");
// A long thread: more turn items than a client opens a thread with
// (TimelineModel::windowItems), in turns of 25 (a question, 23 calls, an answer).
constexpr int kTurns = 12;
constexpr int kCalls = 23;
constexpr int kTurnItems = kCalls + 2;
// A settled turn shows its question, its folded work and its answer.
constexpr int kRowsPerTurn = 3;
constexpr int kWindowTurns = TimelineModel::windowItems / kTurnItems;

// What a scenario watches across the app closing or a thread being left.
struct Kept {
  QString thread;        // the key of the thread it is about
  int rows = 0;          // the rows it showed
  qsizetype shells = 0;  // `shell` frames the MC had sent before the app started again
  qsizetype subs = 0;    // `sub` frames it had read by then
  qsizetype sent = 0;    // frames it had sent followers by then
  // The row the user was reading, and where it was drawn.
  QString reading;
  qreal readingY = 0;
  QStringList rowIds;
};

Kept& kept(World& world) {
  return world.mc.part<Kept>();
}

FakeStreams& streams(World& world) {
  return world.mc.part<FakeStreams>();
}

QString titleId(const QString& title) {
  return QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

QString keyOf(World& world, const QString& title) {
  return world.mc.environmentId + QLatin1Char(':') + titleId(title);
}

bool shows(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return true;
  }
  return false;
}

// The app starts on the files it left, and reads what it kept.
void launch(World& world) {
  Kept& state = kept(world);
  state.shells = world.mc.shellFrames.size();
  state.subs = world.mc.subscriptions.size();
  state.sent = streams(world).sent.size();
  world.launch();
  world.native().cache()->drain();
}

// And is pointed at its MC, as the desktop's host does once the MC is up.
void start(World& world) {
  launch(world);
  world.native().open(world.mc.origin(), kToken);
  world.native().cache()->drain();
}

// The MC has answered the shell and the thread's stream, and the client has read the answers.
void settle(World& world) {
  world.waitFor([&] { return world.native().isActive() && store(world)->activeTimeline() && timeline(world).status() == QLatin1String("live"); },
                [&] { return QStringLiteral("the thread to follow its MC; %1").arg(store(world)->activeTimeline() ? describe(timeline(world)) : QStringLiteral("none is open")); });
  world.sync();
}

// The last `sub` the MC answered for the scenario's thread.
FakeStreams::Asked lastAsked(World& world) {
  const FakeStreams& fake = streams(world);
  for (qsizetype i = fake.asked.size() - 1; i >= 0; --i) {
    if (fake.asked.at(i).thread == fake.thread) return fake.asked.at(i);
  }
  fail(QStringLiteral("the MC was never asked for %1").arg(fake.thread));
}

int eventsIn(const QList<QJsonObject>& frames) {
  int count = 0;
  for (const QJsonObject& frame : frames) count += frame.value(QLatin1String("events")).toArray().size();
  return count;
}

// The last `shell` frame the MC sent since the app started, once it has.
QJsonObject shellFrame(World& world) {
  world.waitFor([&] { return world.mc.shellFrames.size() > kept(world).shells; }, QStringLiteral("the MC to send its thread list"));
  return world.mc.shellFrames.last();
}

// The MC's own entry of a `shell` frame.
QJsonObject ownMc(World& world, const QJsonObject& frame) {
  for (const QJsonValue& mc : frame.value(QLatin1String("mcs")).toArray()) {
    if (mc.toObject().value(QLatin1String("mc")) == world.mc.name) return mc.toObject();
  }
  return {};
}

void listThread(World& world, const QString& title) {
  const QString id = titleId(title);
  world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), world.mc.projects.firstKey()},
                               {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}});
}

// The app is up on the MC's own rows.
void waitForList(World& world) {
  world.waitFor([&] { return world.native().isActive() && world.native().store()->synchronized(); }, QStringLiteral("the shell to start on its MC's rows"));
  world.sync();
}

// Leaves the scenario's thread, forgets what the client holds of it, and
// gives it more turns than a client opens a thread with.
void makeLong(World& world) {
  Kept& state = kept(world);
  state.thread = world.mc.environmentId + QLatin1Char(':') + kThread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  store(world)->close(state.thread);
  world.native().cache()->forgetThread(state.thread);
  world.sync();
  seedTurns(world, kTurns, kCalls);
}

void openAgain(World& world) {
  kept(world).sent = streams(world).sent.size();
  look(world, kept(world).thread);
  world.sync();
}

void expectNewestTurns(World& world) {
  TimelineModel& model = timeline(world);
  expect(model.hasEarlier() && model.rowCount() == kWindowTurns * kRowsPerTurn &&
             role(model, 0, TimelineModel::TextRole).toString() == QStringLiteral("Question %1").arg(kTurns - kWindowTurns + 1),
         QStringLiteral("the thread shows %1 rows from \"%2\" and %3 earlier turns")
             .arg(model.rowCount()).arg(role(model, 0, TimelineModel::TextRole).toString(), model.hasEarlier() ? QStringLiteral("has") : QStringLiteral("has no")));
}

void expectEveryTurn(World& world) {
  TimelineModel& model = timeline(world);
  world.waitFor([&] { return !model.loadingEarlier() && !model.hasEarlier(); }, QStringLiteral("the earlier turns to arrive"));
  expect(model.rowCount() == kTurns * kRowsPerTurn && role(model, 0, TimelineModel::TextRole).toString() == QLatin1String("Question 1"),
         QStringLiteral("the thread shows %1 rows from \"%2\"").arg(model.rowCount()).arg(role(model, 0, TimelineModel::TextRole).toString()));
}

// The open thread as the Timeline brick draws it, `height` tall.
Brick& timelineBrick(World& world, int height) {
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n", QSize(820, height));
  world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  return *world.brick;
}

QQuickItem* rows(World& world) {
  return world.brick->item(QStringLiteral("timelineRows"));
}

// The drawn row `rowId`, or null while the list has not made it.
QQuickItem* drawnRow(World& world, const QString& rowId) {
  QQuickItem* content = rows(world)->property("contentItem").value<QQuickItem*>();
  for (QQuickItem* child : content->childItems()) {
    if (child->property("rowId").toString() == rowId) return child;
  }
  return nullptr;
}

// Where the row is drawn in the window, from its top.
qreal drawnAt(World& world, const QString& rowId) {
  QQuickItem* row = drawnRow(world, rowId);
  if (!row) fail(QStringLiteral("the row %1 is not drawn").arg(rowId));
  return row->mapToScene(QPointF(0, 0)).y();
}

const Steps steps([] {
  const QString q = kQuoted;

  // The app closing and starting.
  step(QStringLiteral("the user was reading a thread in %1 when the app quit").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    startRun(world, 60);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), kKeptAnswer}});
    settleRun(world, QStringLiteral("completed"), 30);
    Kept& state = kept(world);
    state.thread = world.mc.environmentId + QLatin1Char(':') + kThread;
    state.rows = timeline(world).rowCount();
    world.quit();
  });
  step(QStringLiteral("the app starts again"), [](World& world, const Captures&, const Table&) { start(world); });
  step(QStringLiteral("the app starts while its MC is not answering"), [](World& world, const Captures&, const Table&) {
    world.mc.stopAccepting();
    start(world);
  });
  step(QStringLiteral("the app starts and has not been told where its MC is"), [](World& world, const Captures&, const Table&) { launch(world); });
  step(QStringLiteral("the app starts pointed at another MC"), [](World& world, const Captures&, const Table&) {
    launch(world);
    expect(!sidebarSectionOf(world, kept(world).thread).isEmpty(), QStringLiteral("nothing was kept to show"));
    // Nobody answers there.
    world.native().open(QUrl(QStringLiteral("http://127.0.0.1:9")), kToken);
    world.native().cache()->drain();
  });
  step(QStringLiteral("nothing the client kept of the first MC is shown"), [](World& world, const Captures&, const Table&) {
    const QString thread = kept(world).thread;
    expect(sidebarSectionOf(world, thread).isEmpty() && world.native().store()->environments().isEmpty() && !world.native().store()->thread(thread),
           QStringLiteral("the thread list is %1").arg(show(world.state(QStringLiteral("sidebar")))));
    // Nor the conversation that was open on it.
    expect(store(world)->activeTimeline() == nullptr && store(world)->openThreads().isEmpty(),
           QStringLiteral("the first MC's thread %1 is still open").arg(store(world)->activeThread()));
    // Nor is its thread list kept for a later start.
    expect(world.native().cache()->shell().origin.isEmpty(), QStringLiteral("the first MC's thread list is still kept"));
  });
  step(QStringLiteral("what the client kept was deleted"), [](World& world, const Captures&, const Table&) {
    QDir cache(QDir(world.homeDir()).filePath(QStringLiteral("cache")));
    expect(cache.exists(QStringLiteral("client-cache.sqlite")) && cache.removeRecursively(), QStringLiteral("there was no cache to delete in %1").arg(cache.path()));
  });

  // What happens meanwhile: while the app is closed, or the thread is not followed.
  step(QStringLiteral("the agent answered %1 meanwhile").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC has heard that the thread is no longer followed.
    world.sync();
    startRun(world, 20);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), c[0]}});
    settleRun(world, QStringLiteral("completed"), 10);
  });
  step(QStringLiteral("the thread moved to an MC that keeps another log"), [](World& world, const Captures&, const Table&) {
    streams(world).handle = QStringLiteral("log-2.1");
  });
  step(QStringLiteral("the thread was deleted while the app was closed"), [](World& world, const Captures&, const Table&) {
    world.mc.threads.remove(kThread);
  });

  // The thread, as kept and as resumed.
  step(QStringLiteral("the thread shows the conversation it kept"), [](World& world, const Captures&, const Table&) {
    const Kept& state = kept(world);
    world.waitFor([&] { return store(world)->activeThread() == state.thread && store(world)->activeTimeline() && timeline(world).rowCount() == state.rows; },
                  [&] { return QStringLiteral("%1 rows of %2; %3").arg(state.rows).arg(state.thread, store(world)->activeTimeline() ? describe(timeline(world)) : QStringLiteral("no thread is open")); });
    expect(shows(timeline(world), kKeptAnswer), QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
    // And the window draws it, whether or not the MC has answered.
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 700));
    world.waitFor([&] { return world.brick->shows(kKeptAnswer); }, QStringLiteral("the window to draw the conversation"));
    expect(!world.brick->item(QStringLiteral("threadPlaceholder"))->isVisible(), QStringLiteral("the window says the thread is loading"));
  });
  step(QStringLiteral("the thread list shows what the client kept"), [](World& world, const Captures&, const Table&) {
    expect(!sidebarSectionOf(world, kept(world).thread).isEmpty(), QStringLiteral("the thread list is %1").arg(show(world.state(QStringLiteral("sidebar")))));
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n", QSize(256, 600));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("Tax line")); }, QStringLiteral("the window to draw the thread list"));
  });
  step(QStringLiteral("the first-run screen does not cover them"), [](World& world, const Captures&, const Table&) {
    // WelcomeWizard covers the window for any gate but "app".
    const QVariantMap onboarding = world.state(QStringLiteral("onboarding")).toMap();
    expect(onboarding.value(QStringLiteral("gate")) == QLatin1String("app") && onboarding.value(QStringLiteral("recovery")).toString().isEmpty(),
           QStringLiteral("the first-run gate is \"%1\"").arg(onboarding.value(QStringLiteral("gate")).toString()));
  });
  step(QStringLiteral("neither is shown as live"), [](World& world, const Captures&, const Table&) {
    ShellStore* shell = world.native().store();
    QStringList online;
    for (const QString& environment : shell->environments()) {
      if (shell->environmentOnline(environment)) online.append(environment);
    }
    const QString phase = world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("phase")).toString();
    expect(timeline(world).status() != QLatin1String("live") && online.isEmpty() && !shell->synchronized() && phase != QLatin1String("connected") &&
               !world.native().isActive(),
           QStringLiteral("the thread is %1, the connection %2, and %3 environments read as online").arg(timeline(world).status(), phase).arg(online.size()));
    // And nothing was heard from the MC to show it.
    expect(world.mc.shellFrames.size() == kept(world).shells, QStringLiteral("the MC sent its thread list"));
  });
  step(QStringLiteral("the client asks for the thread from where its copy stands"), [](World& world, const Captures&, const Table&) {
    settle(world);
    const QJsonObject sub = lastAsked(world).sub;
    expect(sub.value(QLatin1String("offset")).isDouble() && sub.value(QLatin1String("handle")) == streams(world).handle &&
               sub.value(QLatin1String("window")).toObject().contains(QLatin1String("floor")),
           QStringLiteral("it asked with %1").arg(show(sub.toVariantMap())));
  });
  step(QStringLiteral("the MC sends only what the client lacks"), [](World& world, const Captures&, const Table&) {
    settle(world);
    const FakeStreams::Asked asked = lastAsked(world);
    const int snapshots = int(answerTo(world, asked, QStringLiteral("snapshot")).size());
    const int events = eventsIn(answerTo(world, asked, QStringLiteral("events")));
    expect(snapshots == 0 && events == asked.lacked,
           QStringLiteral("the MC sent %1 snapshots and %2 events for the %3 changes the client lacked; it was asked with %4")
               .arg(snapshots).arg(events).arg(asked.lacked).arg(show(asked.sub.toVariantMap())));
  });
  step(QStringLiteral("the thread shows %1 after the conversation it kept").arg(q), [](World& world, const Captures& c, const Table&) {
    settle(world);
    TimelineModel& model = timeline(world);
    int keptAt = -1;
    int newAt = -1;
    for (int row = 0; row < model.rowCount(); ++row) {
      const QString text = role(model, row, TimelineModel::TextRole).toString();
      if (text == kKeptAnswer) keptAt = row;
      if (text == c[0]) newAt = row;
    }
    expect(keptAt >= 0 && newAt > keptAt, QStringLiteral("the thread shows %1").arg(describe(model)));
  });
  step(QStringLiteral("the MC sends the thread whole"), [](World& world, const Captures&, const Table&) {
    settle(world);
    const FakeStreams::Asked asked = lastAsked(world);
    const QList<QJsonObject> snapshots = answerTo(world, asked, QStringLiteral("snapshot"));
    expect(snapshots.size() == 1 && !snapshots.first().value(QLatin1String("rows")).toArray().isEmpty() &&
               answerTo(world, asked, QStringLiteral("events")).isEmpty(),
           QStringLiteral("the MC sent %1 snapshots; it was asked with %2").arg(snapshots.size()).arg(show(asked.sub.toVariantMap())));
  });
  step(QStringLiteral("the client resumes from the new log after a reconnect"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = streams(world).asked.size();
    world.mc.drop();
    world.waitFor([&] { return streams(world).asked.size() > before && timeline(world).status() == QLatin1String("live"); },
                  [&] { return QStringLiteral("the thread to be followed again; %1").arg(describe(timeline(world))); });
    const FakeStreams::Asked asked = lastAsked(world);
    expect(asked.sub.value(QLatin1String("handle")) == QLatin1String("log-2.1") && asked.sub.value(QLatin1String("offset")).isDouble() &&
               answerTo(world, asked, QStringLiteral("snapshot")).isEmpty(),
           QStringLiteral("it asked with %1").arg(show(asked.sub.toVariantMap())));
  });
  step(QStringLiteral("the client keeps nothing of its conversation"), [](World& world, const Captures&, const Table&) {
    waitForList(world);
    const QString thread = kept(world).thread;
    expect(!keptCopy(world, thread).found() && !store(world)->timeline(thread),
           QStringLiteral("the client still holds %1").arg(thread));
  });

  // The thread list, as kept and as resumed.
  step(QStringLiteral("the app quit with the threads %1 and %1 in the list").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : c) {
      listThread(world, title);
      world.mc.sendRow(titleId(title), world.mc.threads.value(titleId(title)));
    }
    world.sync();
    for (const QString& title : c) {
      expect(!sidebarSectionOf(world, keyOf(world, title)).isEmpty(), QStringLiteral("\"%1\" is not in the list").arg(title));
    }
    world.quit();
  });
  step(QStringLiteral("the thread %1 was created while the app was closed").arg(q), [](World& world, const Captures& c, const Table&) {
    listThread(world, c[0]);
  });
  step(QStringLiteral("the MC restarted and lost %1 while the app was closed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.epoch = QStringLiteral("epoch-2");
    world.mc.threads.remove(titleId(c[0]));
  });
  step(QStringLiteral("the client says which thread list it holds"), [](World& world, const Captures&, const Table&) {
    shellFrame(world);
    QJsonObject sub;
    for (qsizetype i = kept(world).subs; i < world.mc.subscriptions.size(); ++i) {
      if (world.mc.subscriptions.at(i).value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) sub = world.mc.subscriptions.at(i);
    }
    const QJsonArray held = sub.value(QLatin1String("have")).toObject().value(world.mc.name).toArray();
    expect(held.size() == 2 && held.at(0) == world.mc.epoch && held.at(1).toInt() > 0, QStringLiteral("it asked with %1").arg(show(sub.toVariantMap())));
  });
  step(QStringLiteral("the MC sends only the row of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject frame = shellFrame(world);
    const QJsonArray sent = frame.value(QLatin1String("rows")).toArray();
    expect(ownMc(world, frame).value(QLatin1String("reset")) == false && sent.size() == 1 &&
               sent.first().toArray().at(3).toObject().value(QLatin1String("title")) == c[0],
           QStringLiteral("the MC sent %1").arg(show(frame.toVariantMap())));
  });
  step(QStringLiteral("the MC sends its whole thread list"), [](World& world, const Captures&, const Table&) {
    const QJsonObject frame = shellFrame(world);
    const qsizetype rows = world.mc.threads.size() + world.mc.projects.size();
    expect(ownMc(world, frame).value(QLatin1String("reset")) == true && frame.value(QLatin1String("rows")).toArray().size() == rows,
           QStringLiteral("the MC holds %1 rows and sent %2").arg(rows).arg(show(frame.toVariantMap())));
  });
  step(QStringLiteral("the thread list shows %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForList(world);
    for (const QString& title : c) {
      expect(!sidebarSectionOf(world, keyOf(world, title)).isEmpty(), QStringLiteral("\"%1\" is not in the list: %2").arg(title, show(world.state(QStringLiteral("sidebar")))));
    }
  });
  step(QStringLiteral("the thread list shows %1 but not %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForList(world);
    expect(!sidebarSectionOf(world, keyOf(world, c[0])).isEmpty() && sidebarSectionOf(world, keyOf(world, c[1])).isEmpty(),
           QStringLiteral("the list is %1").arg(show(world.state(QStringLiteral("sidebar")))));
  });
  step(QStringLiteral("the thread list no longer shows the thread"), [](World& world, const Captures&, const Table&) {
    waitForList(world);
    expect(sidebarSectionOf(world, kept(world).thread).isEmpty(), QStringLiteral("the list is %1").arg(show(world.state(QStringLiteral("sidebar")))));
  });

  // A long thread.
  step(QStringLiteral("the thread has more turns than a client loads at once"), [](World& world, const Captures&, const Table&) { makeLong(world); });
  step(QStringLiteral("the user opens it again"), [](World& world, const Captures&, const Table&) { openAgain(world); });
  step(QStringLiteral("the thread has more turns than are loaded"), [](World& world, const Captures&, const Table&) {
    makeLong(world);
    openAgain(world);
    expectNewestTurns(world);
  });
  step(QStringLiteral("the client asks its MC for the newest turns only"), [](World& world, const Captures&, const Table&) {
    const QJsonObject sub = lastAsked(world).sub;
    expect(sub.value(QLatin1String("offset")).isNull() && sub.value(QLatin1String("window")).toObject().value(QLatin1String("items")).toInt() == TimelineModel::windowItems &&
               sub.value(QLatin1String("shape")).toObject().value(QLatin1String("kinds")).toObject().contains(QLatin1String("turn-item")),
           QStringLiteral("it asked with %1").arg(show(sub.toVariantMap())));
  });
  step(QStringLiteral("only those turns are sent and shown"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> snapshots = sentSince(world, kept(world).sent, QStringLiteral("snapshot"));
    expect(snapshots.size() == 1, QStringLiteral("the MC sent %1 snapshots").arg(snapshots.size()));
    int items = 0;
    for (const QJsonValue& row : snapshots.first().value(QLatin1String("rows")).toArray()) {
      if (row.toArray().at(0) == QLatin1String("turn-item")) ++items;
    }
    expect(items == kWindowTurns * kTurnItems && snapshots.first().value(QLatin1String("floor")).isDouble(),
           QStringLiteral("the MC sent %1 of the thread's %2 turn items").arg(items).arg(kTurns * kTurnItems));
    expectNewestTurns(world);
  });
  step(QStringLiteral("the user loads earlier turns"), [](World& world, const Captures&, const Table&) {
    // A view the newest turns overflow, at their end.
    timelineBrick(world, 480);
    QQuickItem* list = rows(world);
    world.waitFor([&] {
      // As the brick reads its own end (Timeline.qml nearEnd).
      const qreal end = list->property("originY").toReal() + list->property("contentHeight").toReal() - 4;
      return list->property("contentHeight").toReal() > list->height() && list->property("contentY").toReal() + list->height() >= end;
    },
                  [&] { return QStringLiteral("the view to show the end of the thread; it is at %1 of %2 from %3, %4 high, with %5 rows")
                            .arg(list->property("contentY").toReal()).arg(list->property("contentHeight").toReal()).arg(list->property("originY").toReal())
                            .arg(list->height()).arg(list->property("count").toInt()); });
    expect(!timeline(world).loadingEarlier(), QStringLiteral("earlier turns were asked for before the user reached the top"));
    // The MC takes its time, so the user sees the wait.
    world.mc.hold(QStringLiteral("pages"));
    // The wheel, up to the top of what is loaded.
    const QPoint at = world.brick->at(list);
    world.waitFor([&] {
      if (timeline(world).loadingEarlier()) return true;
      QWindowSystemInterface::handleWheelEvent(&world.brick->window(), at, world.brick->window().mapToGlobal(at), QPoint(), QPoint(0, 480));
      return false;
    }, [&] { return QStringLiteral("the top of the thread; the view is at %1 of %2").arg(list->property("contentY").toReal()).arg(list->property("contentHeight").toReal()); });
  });
  step(QStringLiteral("the user sees that earlier turns are loading"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->item(QStringLiteral("loadingEarlier"))->isVisible() && world.brick->shows(QStringLiteral("Loading earlier turns…")),
           QStringLiteral("nothing says earlier turns are loading"));
    // Asked for once, however long the user stays at the top.
    world.sync();
    const QList<QJsonObject> asked = sentSince(world, kept(world).sent, QStringLiteral("more"));
    expect(asked.size() == 1 && asked.first().value(QLatin1String("items")).toInt() == TimelineModel::windowItems,
           QStringLiteral("the MC was asked for earlier turns %1 times").arg(asked.size()));
  });
  step(QStringLiteral("the earlier turns appear above without moving the message being read"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    QQuickItem* list = rows(world);
    // The scroll has come to rest on the first loaded row.
    world.waitFor([&] { return !list->property("moving").toBool(); }, QStringLiteral("the view to come to rest"));
    Kept& state = kept(world);
    state.reading = role(model, 0, TimelineModel::IdRole).toString();
    state.readingY = drawnAt(world, state.reading);
    QStringList ids;
    for (int row = 0; row < model.rowCount(); ++row) ids.append(role(model, row, TimelineModel::IdRole).toString());
    QSignalSpy inserted(&model, &TimelineModel::rowsInserted);
    QSignalSpy removed(&model, &TimelineModel::rowsRemoved);
    QSignalSpy moved(&model, &TimelineModel::rowsMoved);
    QSignalSpy reset(&model, &TimelineModel::modelReset);
    world.mc.answerHeld();
    expectEveryTurn(world);
    // One insert above the rows held, which keep their ids and their order.
    const int added = (kTurns - kWindowTurns) * kRowsPerTurn;
    expect(inserted.size() == 1 && inserted.first().at(1).toInt() == 0 && inserted.first().at(2).toInt() == added - 1 && removed.isEmpty() &&
               moved.isEmpty() && reset.isEmpty(),
           QStringLiteral("the earlier turns came as %1 inserts, %2 removes, %3 moves and %4 resets").arg(inserted.size()).arg(removed.size()).arg(moved.size()).arg(reset.size()));
    QStringList after;
    for (int row = added; row < model.rowCount(); ++row) after.append(role(model, row, TimelineModel::IdRole).toString());
    expect(after == ids, QStringLiteral("the rows held changed"));
    // Drawn where it was, with the earlier turns above it to scroll to.
    world.waitFor([&] { return drawnRow(world, state.reading) != nullptr && !list->property("atYBeginning").toBool(); }, [&] {
      return QStringLiteral("the view to lay the earlier turns out above; it is at %1 from %2 of %3, the message %4")
          .arg(list->property("contentY").toReal()).arg(list->property("originY").toReal()).arg(list->property("contentHeight").toReal())
          .arg(drawnRow(world, state.reading) ? QStringLiteral("at %1, from %2").arg(drawnAt(world, state.reading)).arg(state.readingY) : QStringLiteral("not drawn"));
    });
    const qreal y = drawnAt(world, state.reading);
    expect(qAbs(y - state.readingY) < 1, QStringLiteral("the message being read moved from %1 to %2").arg(state.readingY).arg(y));
    expect(!world.brick->item(QStringLiteral("loadingEarlier"))->isVisible(), QStringLiteral("the thread still says earlier turns are loading"));
  });
  step(QStringLiteral("what is loaded leaves room in the view"), [](World& world, const Captures&, const Table&) {
    timelineBrick(world, 4000);
  });
  step(QStringLiteral("the earlier turns are loaded without the user scrolling"), [](World& world, const Captures&, const Table&) {
    expectEveryTurn(world);
    expect(!sentSince(world, kept(world).sent, QStringLiteral("more")).isEmpty(), QStringLiteral("the MC was not asked for earlier turns"));
  });

  // A long thread the user left.
  step(QStringLiteral("the user loaded the earlier turns of a long thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    makeLong(world);
    openAgain(world);
    expectNewestTurns(world);
    timeline(world).loadEarlier();
    expectEveryTurn(world);
  });
  step(QStringLiteral("the user leaves the thread for more than five minutes and returns"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
    world.setTime(world.now().addSecs(6 * 60));
    expect(!store(world)->timeline(kept(world).thread), QStringLiteral("the thread is still held"));
    openAgain(world);
  });
  step(QStringLiteral("the thread comes back as its newest turns without being sent again"), [](World& world, const Captures&, const Table&) {
    expectNewestTurns(world);
    const FakeStreams::Asked asked = lastAsked(world);
    expect(asked.sub.value(QLatin1String("offset")).isDouble() && asked.sub.value(QLatin1String("window")).toObject().value(QLatin1String("floor")).isDouble() &&
               answerTo(world, asked, QStringLiteral("snapshot")).isEmpty() && answerTo(world, asked, QStringLiteral("events")).isEmpty(),
           QStringLiteral("it asked with %1").arg(show(asked.sub.toVariantMap())));
  });
  step(QStringLiteral("its earlier turns can be loaded again"), [](World& world, const Captures&, const Table&) {
    timeline(world).loadEarlier();
    expectEveryTurn(world);
  });
});

}  // namespace
