// Moving through a long thread on the phone
// (features/timeline/scrolling-and-links.feature): the shared Timeline brick
// over the phone's real thread screen, following new output at the end,
// staying where the user scrolled to, opening another thread at its end, and
// a long thread opening as its newest turns with earlier ones loaded at the
// top. The seeded thread is the desktop harness's long thread
// (LocalCacheSteps.cpp): settled turns of a question, some calls and an
// answer — more turn items in all than a client opens with
// (TimelineModel::windowItems) — and a reply still being written.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QPoint>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSet>
#include <QSignalSpy>
#include <QTest>
#include <QTimeZone>

#include <cmath>
#include <utility>

#include "FakeThreads.h"
#include "Harness.h"
#include "LocalCache.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using S = QString;

const QString kTitle = S("Tax line");
const QString kOtherTitle = S("Second thread");
// Fewer calls a turn than the desktop's seed, so the window's turns fill
// several phone screens: scrolling away from the end need not reach the
// top (and so load earlier turns) to be a page from the end.
constexpr int kTurns = 28;
constexpr int kCalls = 8;
constexpr int kTurnItems = kCalls + 2;
// The settled turns of the opening window: the running turn's two items,
// then whole turns until the window's 200 items are held.
constexpr int kWindowTurns = (TimelineModel::windowItems - 2) / kTurnItems + 1;

QDateTime now() {
  return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC);
}

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

// What a scenario watches across its steps.
struct Watch {
  QSet<QString> seeded;
  qreal contentY = 0;
  qreal contentHeight = 0;
  QString reading;
  qreal readingY = 0;
  qsizetype sent = 0;
};

Watch& watch(World& world) {
  return world.mc.part<Watch>();
}

ThreadStore* store(World& world) {
  return world.native().controller<ThreadStore>();
}

TimelineModel& timeline(World& world) {
  TimelineModel* model = store(world)->activeTimeline();
  if (!model) fail(S("no thread is open"));
  return *model;
}

QVariant role(TimelineModel& model, int row, int role) {
  return model.data(model.index(row), role);
}

QString describe(TimelineModel& model) {
  return S("status %1, %2 rows, first \"%3\"").arg(model.status()).arg(model.rowCount())
      .arg(model.rowCount() > 0 ? role(model, 0, TimelineModel::TextRole).toString() : S());
}

// The conversation's list on the thread screen.
QQuickItem* rows(World& world) {
  return world.item(S("timelineRows"));
}

bool atEnd(QQuickItem* list) {
  return list->property("contentY").toReal() + list->height() >=
         list->property("originY").toReal() + list->property("contentHeight").toReal() - 4;
}

QString describeList(QQuickItem* list) {
  return S("at %1 of %2 from %3, %4 high, following %5, away %6")
      .arg(list->property("contentY").toReal()).arg(list->property("contentHeight").toReal())
      .arg(list->property("originY").toReal()).arg(list->height())
      .arg(list->property("following").toBool()).arg(list->property("away").toBool());
}

void waitAtEnd(World& world) {
  QQuickItem* list = rows(world);
  world.waitFor([&] { return list->property("contentHeight").toReal() > list->height() && atEnd(list) && list->property("following").toBool(); },
                [&] { return S("the view at the end of the thread; %1").arg(describeList(list)); });
}

void waitLive(World& world) {
  world.waitFor([&] { return store(world)->activeTimeline() && timeline(world).status() == QLatin1String("live"); },
                [&] { return S("the thread to follow its MC; the screen says: %1").arg(world.texts().join(S(" | "))); });
}

void waitStill(World& world) {
  QQuickItem* list = rows(world);
  world.waitFor([&] { return !list->property("moving").toBool(); }, S("the timeline to stop scrolling"));
}

// `turns` settled turns of `thread`, each a question, `kCalls` tool calls and
// "Answer <n>" (the last with a table), then a running turn whose reply
// "reply" is still being written: as they were before anyone followed it.
void seedLong(World& world, const QString& thread) {
  if (watch(world).seeded.contains(thread)) return;
  watch(world).seeded.insert(thread);
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const auto put = [&](const QString& kind, const QString& id, QJsonObject fields) {
    fields.insert(S("id"), id);
    changeEntity(world.mc, thread, kind, id, {{S("s"), fields}}, true);
  };
  for (int n = 1; n <= kTurns; ++n) {
    const QDateTime started = now().addSecs(-3600 + n * 60);
    const QString run = S("run-%1").arg(fake.ordinal + 1);
    put(S("run"), run, {{S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")},
                        {S("requestedAt"), iso(started)}, {S("startedAt"), iso(started)},
                        {S("completedAt"), iso(started.addSecs(30))}});
    const auto item = [&](const QString& type, QJsonObject more) {
      QJsonObject fields{{S("type"), type}, {S("runId"), run}, {S("status"), S("completed")}, {S("updatedAt"), iso(started)}};
      for (auto it = more.begin(); it != more.end(); ++it) fields.insert(it.key(), it.value());
      fields.insert(S("ordinal"), ++fake.ordinal);
      put(S("turn-item"), S("%1:%2").arg(type).arg(fake.ordinal), fields);
    };
    item(S("user_message"), {{S("text"), S("Question %1").arg(n)}});
    for (int call = 1; call <= kCalls; ++call) {
      item(S("command_execution"), {{S("input"), S("bun test %1").arg(call)}, {S("exitCode"), 0}});
    }
    QString answer = S("Answer %1").arg(n);
    if (n == kTurns) answer += S("\n\n| Item | Price |\n| --- | --- |\n| Cart | 3 |\n| Tax | 1 |");
    item(S("assistant_message"), {{S("text"), answer}});
  }
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  put(S("run"), run, {{S("ordinal"), ++fake.ordinal}, {S("status"), S("running")},
                      {S("requestedAt"), iso(now())}, {S("startedAt"), iso(now())}});
  put(S("turn-item"), S("message:") + run,
      {{S("type"), S("user_message")}, {S("runId"), run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Add a tax line to the cart")}, {S("updatedAt"), iso(now())}});
  put(S("turn-item"), S("reply"),
      {{S("type"), S("assistant_message")}, {S("runId"), run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("running")}, {S("text"), S("The cart")}, {S("streaming"), true}, {S("updatedAt"), iso(now())}});
}

// The long thread `title`, opened from the thread list and followed.
void lookLong(World& world, const QString& title) {
  world.mc.part<FakeStreams>().handle = S("log-1.1");
  world.thread = haveThread(world, title);
  seedLong(world, world.thread);
  world.setTime(now());
  openThread(world, title);
  waitLive(world);
  waitAtEnd(world);
}

// A finger drags the conversation up, again and again if `until` asks for
// more: true when it holds, or the attempts run out.
bool swipeUpUntil(World& world, const std::function<bool()>& until, int attempts = 12) {
  QQuickItem* list = rows(world);
  for (int i = 0; i < attempts && !until(); ++i) {
    world.swipe(list, QPoint(0, 350));
    waitStill(world);
  }
  return until();
}

// Scrolls well away from the end, as tst_Timeline.qml's scrollUp does: more
// than a page of thread below what is shown.
void scrollAway(World& world) {
  QQuickItem* list = rows(world);
  const auto farUp = [&] {
    return !list->property("following").toBool() &&
           list->property("originY").toReal() + list->property("contentHeight").toReal() -
                   (list->property("contentY").toReal() + list->height()) > list->height();
  };
  expect(swipeUpUntil(world, farUp), S("the view did not scroll away from the end; %1").arg(describeList(list)));
}

// The agent writes another paragraph of "reply".
void grow(World& world) {
  changeEntity(world.mc, world.thread, S("turn-item"), S("reply"),
               {{S("a"), QJsonObject{{S("text"), S("\n\nAnother paragraph of the reply, written just now, with enough words to take a line or two of the phone's screen.")}}}});
  if (world.mc.connected()) world.sync();
}

// Leaves the scenario's thread and forgets what the client holds of it, so
// opening it again asks for its newest turns (LocalCacheSteps' makeLong).
void forgetThread(World& world) {
  const QString key = world.mc.environmentId + QLatin1Char(':') + world.thread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(S("home")));
  store(world)->close(key);
  world.native().cache()->forgetThread(key);
  world.sync();
}

void openAgain(World& world) {
  watch(world).sent = world.mc.part<FakeStreams>().sent.size();
  const QString key = world.mc.environmentId + QLatin1Char(':') + world.thread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return store(world)->activeThread() == key && store(world)->activeTimeline(); }, S("the thread to open"));
  waitLive(world);
  world.sync();
}

// The window's turns are the ones shown: back to "Question <first>".
void expectNewestTurns(World& world) {
  TimelineModel& model = timeline(world);
  const QString first = S("Question %1").arg(kTurns - kWindowTurns + 1);
  expect(model.hasEarlier() && model.rowCount() > 0 && role(model, 0, TimelineModel::TextRole).toString() == first,
         S("the thread does not open as its newest turns; %1, hasEarlier %2").arg(describe(model)).arg(model.hasEarlier()));
}

void expectEveryTurn(World& world) {
  TimelineModel& model = timeline(world);
  world.waitFor([&] { return !model.loadingEarlier() && !model.hasEarlier(); }, S("the earlier turns to arrive"));
  expect(model.rowCount() > 0 && role(model, 0, TimelineModel::TextRole).toString() == QLatin1String("Question 1"),
         S("not every turn is shown; %1").arg(describe(model)));
}

// The frames of type `t` sent to followers since the watch last counted.
QList<QJsonObject> sentSince(World& world, const QString& t) {
  QList<QJsonObject> frames;
  const QList<QJsonObject>& sent = world.mc.part<FakeStreams>().sent;
  for (qsizetype i = watch(world).sent; i < sent.size(); ++i) {
    if (sent.at(i).value(QLatin1String("t")) == t) frames.append(sent.at(i));
  }
  return frames;
}

// The last `sub` the MC answered for the scenario's thread.
QJsonObject lastAskedSub(World& world) {
  const FakeStreams& fake = world.mc.part<FakeStreams>();
  for (qsizetype i = fake.asked.size() - 1; i >= 0; --i) {
    if (fake.asked.at(i).thread == world.thread) return fake.asked.at(i).sub;
  }
  fail(S("the MC was never asked for %1").arg(world.thread));
}

// The drawn row `rowId`, or null while the list has not made it.
QQuickItem* drawnRow(World& world, const QString& rowId) {
  QQuickItem* content = rows(world)->property("contentItem").value<QQuickItem*>();
  for (QQuickItem* child : content->childItems()) {
    if (child->property("rowId").toString() == rowId) return child;
  }
  return nullptr;
}

qreal drawnAt(World& world, const QString& rowId) {
  QQuickItem* row = drawnRow(world, rowId);
  if (!row) fail(S("the row %1 is not drawn").arg(rowId));
  return row->mapToScene(QPointF(0, 0)).y();
}

// A finished reply of the open thread, with `messageId` when one is named.
void answer(World& world, const QString& text, const QString& messageId = QString()) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  setEntity(world.mc, world.thread, S("run"), run,
            {{S("id"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")},
             {S("requestedAt"), iso(now())}, {S("startedAt"), iso(now())}, {S("completedAt"), iso(now().addSecs(30))}});
  QJsonObject item{{S("id"), S("assistant_message:%1").arg(fake.ordinal + 1)}, {S("type"), S("assistant_message")},
                   {S("runId"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")},
                   {S("text"), text}, {S("updatedAt"), iso(now())}};
  if (!messageId.isEmpty()) item.insert(S("messageId"), messageId);
  setEntity(world.mc, world.thread, S("turn-item"), item.value(QLatin1String("id")).toString(), item);
  if (world.mc.connected()) world.sync();
}

void collectNamed(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name && item->isVisible()) out.append(item);
  for (QQuickItem* child : item->childItems()) collectNamed(child, name, out);
}

QList<QQuickItem*> namedItems(World& world, const QString& name) {
  QList<QQuickItem*> items;
  collectNamed(world.window().contentItem(), name, items);
  return items;
}

// A rich text segment's plain text (MarkdownSteps.cpp's plain).
QString plainText(QQuickItem* edit) {
  QString text;
  QMetaObject::invokeMethod(edit, "getText", Q_RETURN_ARG(QString, text), Q_ARG(int, 0), Q_ARG(int, edit->property("length").toInt()));
  return text.replace(QChar(0x2028), QLatin1Char('\n'));
}

QString readable(QString text) {
  return text.remove(QChar(0x2060)).replace(QChar(QChar::Nbsp), QChar(u' '));
}

// Where `needle`, as the reader sees it, lies in `raw` (MarkdownSteps.cpp).
std::pair<int, int> drawnRange(const QString& raw, const QString& needle) {
  QList<int> at;
  QString read;
  for (int i = 0; i < raw.size(); ++i) {
    if (raw[i] == QChar(0x2060)) continue;
    at.append(i);
    read.append(raw[i] == QChar(QChar::Nbsp) ? QChar(u' ') : raw[i]);
  }
  const int found = int(read.indexOf(needle));
  if (found < 0 || needle.isEmpty()) return {-1, -1};
  return {at[found], at[found + needle.size() - 1] + 1};
}

// The link under the middle of `needle` in a rich text segment, and the point
// the user would tap in the window.
QString linkAt(QQuickItem* edit, const QString& needle, QPoint* point = nullptr) {
  const auto [start, end] = drawnRange(plainText(edit), needle);
  expect(start >= 0, S("\"%1\" is not shown in \"%2\"").arg(needle, readable(plainText(edit))));
  QRectF rect;
  QMetaObject::invokeMethod(edit, "positionToRectangle", Q_RETURN_ARG(QRectF, rect), Q_ARG(int, (start + end) / 2));
  const QPointF local(rect.x() + 1, rect.y() + rect.height() / 2);
  QString link;
  QMetaObject::invokeMethod(edit, "linkAt", Q_RETURN_ARG(QString, link), Q_ARG(qreal, local.x()), Q_ARG(qreal, local.y()));
  if (point) *point = edit->mapToScene(local).toPoint();
  return link;
}

// The drawn prose segment showing `needle`, waited for.
QQuickItem* proseShowing(World& world, const QString& needle, const QString& name = S("markdownProse")) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    for (QQuickItem* item : namedItems(world, name)) {
      if (readable(plainText(item)).contains(needle)) found = item;
    }
    return found != nullptr;
  }, [&] { return S("\"%1\" drawn; the screen says: %2").arg(needle, world.texts().join(S(" | "))); });
  return found;
}

const QString kSentence = S("The cart caches its tax rate, so a change needs a new cart.");

// The composer's citations.
QVariantList citations(World& world) {
  return world.state(S("composer")).toMap().value(S("citations")).toList();
}

// The row at the top of the view, the one being read: where the brick's own
// hold() looks (Timeline.qml). Its drawn place is what "the view stays on
// that message" means, through whatever the list remeasures above it.
QString topRow(World& world) {
  QQuickItem* list = rows(world);
  int index = -1;
  const qreal y = list->property("contentY").toReal() + list->property("topMargin").toReal() + 1;
  QMetaObject::invokeMethod(list, "indexAt", Q_RETURN_ARG(int, index), Q_ARG(qreal, list->width() / 2), Q_ARG(qreal, y));
  if (index < 0) fail(S("no row at the top of the view; %1").arg(describeList(list)));
  return role(timeline(world), index, TimelineModel::IdRole).toString();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the user is looking at a long thread in %1").arg(q), [](World& world, const Captures&, const Table&) { lookLong(world, kTitle); });

  // Following the end.
  step(S("the user is at the end of the thread"), [](World& world, const Captures&, const Table&) { waitAtEnd(world); });
  step(S("the agent writes more of its reply"), [](World& world, const Captures&, const Table&) {
    watch(world).contentHeight = rows(world)->property("contentHeight").toReal();
    grow(world);
    grow(world);
  });
  step(S("the new text stays in view"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    world.waitFor([&] { return list->property("contentHeight").toReal() > watch(world).contentHeight && atEnd(list); },
                  [&] { return S("the new text in view; %1").arg(describeList(list)); });
    expect(list->property("following").toBool(), S("the view stopped following; %1").arg(describeList(list)));
    world.waitFor([&] { return world.shows(S("Another paragraph of the reply"), false); },
                  [&] { return S("the new text on screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });

  // The end holding still.
  step(S("a reply with a table sits just above the end"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    bool table = false;
    for (int row = 0; row < model.rowCount(); ++row) table = table || role(model, row, TimelineModel::TextRole).toString().contains(S("| Cart |"));
    expect(table, S("no reply with a table is loaded; %1").arg(describe(model)));
    waitAtEnd(world);
  });
  step(S("nothing new is written"), [](World& world, const Captures&, const Table&) {
    world.window().grabWindow();  // lays out what opening the thread changed
    waitStill(world);
    watch(world).contentY = rows(world)->property("contentY").toReal();
  });
  step(S("the view does not move"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.window().grabWindow();
    waitStill(world);
    const qreal y = rows(world)->property("contentY").toReal();
    expect(std::abs(y - watch(world).contentY) < 1, S("the view moved from %1 to %2").arg(watch(world).contentY).arg(y));
  });

  // Scrolling away and coming back.
  step(S("the agent is writing its reply"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    bool streaming = false;
    for (int row = 0; row < model.rowCount(); ++row) streaming = streaming || role(model, row, TimelineModel::StreamingRole).toBool();
    expect(streaming, S("no reply is being written; %1").arg(describe(model)));
    waitAtEnd(world);
  });
  step(S("the user scrolls up to an earlier message"), [](World& world, const Captures&, const Table&) {
    scrollAway(world);
    world.window().grabWindow();
    watch(world).reading = topRow(world);
    watch(world).readingY = drawnAt(world, watch(world).reading);
    grow(world);
  });
  step(S("the view stays on that message while the reply grows"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    grow(world);
    world.window().grabWindow();
    const qreal y = drawnAt(world, watch(world).reading);
    expect(std::abs(y - watch(world).readingY) < 1,
           S("the message being read moved from %1 to %2 while the reply grew").arg(watch(world).readingY).arg(y));
    expect(!list->property("following").toBool(), S("the view is following again; %1").arg(describeList(list)));
  });
  step(S("the user is offered a way to scroll to the end"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* jump = world.find(S("jumpToLatest")); return jump && jump->isVisible(); },
                  S("\"Scroll to end\" to be offered"));
  });
  step(S("the user has scrolled away from the end while the agent writes"), [](World& world, const Captures&, const Table&) {
    scrollAway(world);
    grow(world);
  });
  step(S("the user has scrolled away from the end of the thread"), [](World& world, const Captures&, const Table&) { scrollAway(world); });
  step(S("the user scrolls to the end"), [](World& world, const Captures&, const Table&) {
    world.tap(S("jumpToLatest"));
  });
  step(S("the latest output is shown"), [](World& world, const Captures&, const Table&) { waitAtEnd(world); });
  step(S("the view follows new output again"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    expect(list->property("following").toBool(), S("the view is not following; %1").arg(describeList(list)));
    const qreal before = list->property("contentHeight").toReal();
    grow(world);
    world.waitFor([&] { return list->property("contentHeight").toReal() > before && atEnd(list); },
                  [&] { return S("the view to follow new output; %1").arg(describeList(list)); });
  });

  // Another thread opens at its end.
  step(S("the user opens another thread"), [](World& world, const Captures&, const Table&) {
    const QString other = haveThread(world, kOtherTitle);
    seedLong(world, other);
    world.back();
    world.item(S("homeScreen"));
    world.thread = other;
    openThread(world, kOtherTitle);
    waitLive(world);
  });
  step(S("the other thread shows its latest output"), [](World& world, const Captures&, const Table&) { waitAtEnd(world); });
  step(S("the composer is not resting"), [](World& world, const Captures&, const Table&) {
    // The composer rests on one line while the user reads away from the end
    // (Composer.conversationScrolled, fed by the timeline's scrolledAway).
    expect(!rows(world)->property("away").toBool(), S("the view counts as scrolled away; %1").arg(describeList(rows(world))));
  });

  // A long thread opens as its newest turns.
  step(S("the thread has more turns than a client loads at once"), [](World& world, const Captures&, const Table&) { forgetThread(world); });
  step(S("the user opens it again"), [](World& world, const Captures&, const Table&) { openAgain(world); });
  step(S("the client asks its MC for the newest turns only"), [](World& world, const Captures&, const Table&) {
    const QJsonObject sub = lastAskedSub(world);
    expect(sub.value(QLatin1String("offset")).isNull() &&
               sub.value(QLatin1String("window")).toObject().value(QLatin1String("items")).toInt() == TimelineModel::windowItems &&
               sub.value(QLatin1String("shape")).toObject().value(QLatin1String("kinds")).toObject().contains(QLatin1String("turn-item")),
           S("it asked with %1").arg(show(sub.toVariantMap())));
  });
  step(S("only those turns are sent and shown"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> snapshots = sentSince(world, S("snapshot"));
    expect(snapshots.size() == 1, S("the MC sent %1 snapshots").arg(snapshots.size()));
    int items = 0;
    for (const QJsonValue& row : snapshots.first().value(QLatin1String("rows")).toArray()) {
      if (row.toArray().at(0) == QLatin1String("turn-item")) ++items;
    }
    const int want = 2 + kWindowTurns * kTurnItems;
    expect(items == want && snapshots.first().value(QLatin1String("floor")).isDouble(),
           S("the MC sent %1 of the thread's %2 turn items").arg(items).arg(2 + kTurns * kTurnItems));
    expectNewestTurns(world);
  });

  // Earlier turns.
  step(S("the thread has more turns than are loaded"), [](World& world, const Captures&, const Table&) {
    forgetThread(world);
    openAgain(world);
    expectNewestTurns(world);
    waitAtEnd(world);
  });
  step(S("the user loads earlier turns"), [](World& world, const Captures&, const Table&) {
    expect(!timeline(world).loadingEarlier(), S("earlier turns were asked for before the user reached the top"));
    // The MC takes its time, so the user sees the wait.
    world.mc.hold(S("pages"));
    expect(swipeUpUntil(world, [&] { return timeline(world).loadingEarlier(); }, 30),
           S("reaching the top did not ask for earlier turns; %1").arg(describeList(rows(world))));
  });
  step(S("the user sees that earlier turns are loading"), [](World& world, const Captures&, const Table&) {
    QQuickItem* label = world.item(S("loadingEarlier"));
    expect(label->isVisible() && world.shows(S("Loading earlier turns…")), S("nothing says earlier turns are loading"));
    world.sync();
    const QList<QJsonObject> asked = sentSince(world, S("more"));
    expect(asked.size() == 1 && asked.first().value(QLatin1String("items")).toInt() == TimelineModel::windowItems,
           S("the MC was asked for earlier turns %1 times").arg(asked.size()));
  });
  step(S("the earlier turns appear above without moving the message being read"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    waitStill(world);
    Watch& state = watch(world);
    state.reading = role(model, 0, TimelineModel::IdRole).toString();
    world.window().grabWindow();
    state.readingY = drawnAt(world, state.reading);
    QStringList ids;
    for (int row = 0; row < model.rowCount(); ++row) ids.append(role(model, row, TimelineModel::IdRole).toString());
    QSignalSpy inserted(&model, &TimelineModel::rowsInserted);
    QSignalSpy removed(&model, &TimelineModel::rowsRemoved);
    QSignalSpy reset(&model, &TimelineModel::modelReset);
    world.mc.answerHeld();
    expectEveryTurn(world);
    expect(inserted.size() == 1 && inserted.first().at(1).toInt() == 0 && removed.isEmpty() && reset.isEmpty(),
           S("the earlier turns came as %1 inserts, %2 removes and %3 resets").arg(inserted.size()).arg(removed.size()).arg(reset.size()));
    const int added = inserted.first().at(2).toInt() + 1;
    QStringList after;
    for (int row = added; row < model.rowCount(); ++row) after.append(role(model, row, TimelineModel::IdRole).toString());
    expect(after == ids, S("the rows held changed"));
    QQuickItem* list = rows(world);
    world.waitFor([&] { return drawnRow(world, state.reading) != nullptr && !list->property("atYBeginning").toBool(); },
                  [&] { return S("the view to lay the earlier turns out above; %1").arg(describeList(list)); });
    world.window().grabWindow();
    const qreal y = drawnAt(world, state.reading);
    expect(std::abs(y - state.readingY) < 1, S("the message being read moved from %1 to %2").arg(state.readingY).arg(y));
    expect(world.find(S("loadingEarlier")) == nullptr, S("the thread still says earlier turns are loading"));
  });
  step(S("what is loaded leaves room in the view"), [](World& world, const Captures&, const Table&) {
    // A window taller than the loaded turns, as the desktop's brick is made:
    // taller than they measure, whatever the rows come to.
    QQuickItem* list = rows(world);
    world.window().grabWindow();
    const int room = int(list->property("contentHeight").toReal()) + int(world.window().height() - list->height()) + 600;
    world.resize(412, room);
    world.sync();
    world.waitFor([&] { return list->property("contentHeight").toReal() < list->height(); },
                  [&] { return S("room in the view; %1").arg(describeList(list)); });
  });
  step(S("the earlier turns are loaded without the user scrolling"), [](World& world, const Captures&, const Table&) {
    expectEveryTurn(world);
    expect(!sentSince(world, S("more")).isEmpty(), S("the MC was not asked for earlier turns"));
  });

  // A thread still loading, and switching to one.
  step(S("the user opens a thread whose agent is still working"), [](World& world, const Captures&, const Table&) {
    // The long thread's agent is still writing (its running turn), and its
    // messages are held back: the MC is slow to answer its stream.
    world.back();
    world.item(S("homeScreen"));
    forgetThread(world);
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.slow = true;
    openThread(world, kTitle);
    expect(store(world)->activeTimeline() && timeline(world).status() != QLatin1String("live"),
           S("the thread's messages arrived at once; %1").arg(describe(timeline(world))));
  });
  step(S("the thread's messages arrive"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.slow = false;
    const QList<std::function<void()>> waiting = std::exchange(fake.waiting, {});
    for (const std::function<void()>& answer : waiting) answer();
    waitLive(world);
  });
  step(S("the view shows the latest output at the end, not the start of the thread"), [](World& world, const Captures&, const Table&) {
    waitAtEnd(world);
    world.waitFor([&] { return world.shows(S("The cart"), false); },
                  [&] { return S("the latest output on screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the user is reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = haveThread(world, c[0]);
    seedLong(world, id);
    // Its own last words, so another thread showing them would show.
    setEntity(world.mc, id, S("turn-item"), S("reply"), {{S("text"), S("Tax totals are done")}});
    world.back();
    world.item(S("homeScreen"));
    world.thread = id;
    openThread(world, c[0]);
    waitLive(world);
    world.waitFor([&] { return world.shows(S("Tax totals are done"), false); },
                  [&] { return S("the thread's own reply on screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the user switches to %1 while its messages are still loading").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = haveThread(world, c[0]);
    seedLong(world, id);
    world.thread = id;
    forgetThread(world);
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.slow = true;
    world.item(S("homeScreen"));
    openThread(world, c[0]);
    expect(store(world)->activeTimeline() && timeline(world).status() != QLatin1String("live"),
           S("the thread's messages arrived at once; %1").arg(describe(timeline(world))));
  });
  step(S("no message of %1 is shown under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(shownThread(world) == c[1], S("the screen shows %1").arg(shownThread(world)));
    expect(!world.shows(S("Tax totals are done"), false),
           S("a message of %1 is shown under %2; the screen says: %3").arg(c[0], c[1], world.texts().join(S(" | "))));
    TimelineModel& model = timeline(world);
    bool foreign = false;
    for (int row = 0; row < model.rowCount(); ++row) foreign = foreign || role(model, row, TimelineModel::TextRole).toString().contains(S("Tax totals"));
    expect(!foreign, S("the open thread holds %1's messages; %2").arg(c[0], describe(model)));
    // The held messages arrive for the next scenario's clean state.
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.slow = false;
    const QList<std::function<void()>> waiting = std::exchange(fake.waiting, {});
    for (const std::function<void()>& answer : waiting) answer();
    waitLive(world);
  });

  // A tall reply that arrived while the user was elsewhere (upstream #24622):
  // taller than the view, with a table in it, as tst_Timeline.qml makes one.
  step(S("%1 got a long reply while the user was in another thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = haveThread(world, c[0]);
    seedLong(world, id);
    const QString words = S("words that run on long enough to wrap the column they are in onto a second line");
    QString text = S("A paragraph before the table, %1.\n\nAnother one, %1.\n\n").arg(words);
    text += S("| Item | Finding | Now |\n|---|---|---|\n");
    for (int i = 0; i < 16; ++i) text += S("| #%1 | `code` and %2 | a worker fixing it, with %2 |\n").arg(400 + i).arg(words);
    text += S("\nThese are still going:\n");
    for (int i = 0; i < 3; ++i) text += S("- **#%1:** %2.\n").arg(470 + i).arg(words);
    text += S("\nA paragraph after the list, %1.").arg(words);
    setEntity(world.mc, id, S("turn-item"), S("reply"), {{S("text"), text}});
    watch(world).reading = id;
  });
  // A thread's name, not a terminal's (term-1 is TerminalSteps' step).
  step(S("the user switches to \"(?!term-)([^\"]*)\""), [](World& world, const Captures& c, const Table&) {
    world.thread = haveThread(world, c[0]);
    world.back();
    world.item(S("homeScreen"));
    openThread(world, c[0]);
    waitLive(world);
  });
  step(S("the user presses %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == S("Scroll to end"), S("no such control as %1").arg(c[0]));
    world.thread = haveThread(world, c[1]);
    world.back();
    world.item(S("homeScreen"));
    openThread(world, c[1]);
    waitLive(world);
    scrollAway(world);
    world.tap(S("jumpToLatest"));
  });
  step(S("the end of the reply is in view, with no %1 left to press").arg(q), [](World& world, const Captures&, const Table&) {
    waitAtEnd(world);
    world.waitFor([&] { return world.shows(S("A paragraph after the list"), false); },
                  [&] { return S("the end of the reply on screen; %1").arg(describeList(rows(world))); });
    expect(world.find(S("jumpToLatest")) == nullptr, S("\"Scroll to end\" is still offered at the end"));
  });

  // Bare web addresses, and citing a reply (the links half of the file).
  step(S("the agent writes %1").arg(q), [](World& world, const Captures& c, const Table&) { answer(world, c[0]); });
  step(S("%1 can be opened as a link").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* prose = proseShowing(world, c[0]);
    QPoint point;
    const QString link = linkAt(prose, c[0], &point);
    expect(link == c[0], S("\"%1\" links to \"%2\"").arg(c[0], link));
    // A finger has no Ctrl, so a tap on a phone opens it: a touch at the
    // link's point, as the world's own finger taps an item's middle.
    static QPointingDevice* finger = QTest::createTouchDevice();
    QTest::touchEvent(&world.window(), finger).press(0, point, &world.window());
    QTest::touchEvent(&world.window(), finger).release(0, point, &world.window());
    world.waitFor([&] { return world.openedUrls.contains(QUrl(c[0])); },
                  [&] { return S("the browser to open %1; it opened %2").arg(c[0], QUrl::toStringList(world.openedUrls).join(S(", "))); });
  });
  step(S("web addresses inside code are left as text"), [](World& world, const Captures&, const Table&) {
    const QString address = S("https://example.com/docs");
    answer(world, S("Try `%1` or:\n\n```\ncurl %1\n```").arg(address));
    const QString inlineLink = linkAt(proseShowing(world, address), address);
    expect(inlineLink.isEmpty(), S("inline code links to \"%1\"").arg(inlineLink));
    QQuickItem* code = proseShowing(world, address, S("codeText"));
    const QString codeLink = linkAt(code, address);
    expect(codeLink.isEmpty() && !code->property("text").toString().contains(QLatin1String("href")),
           S("the code block links to \"%1\"").arg(codeLink));
  });
  step(S("the user selects a sentence in the agent's reply and cites it"), [](World& world, const Captures&, const Table&) {
    answer(world, kSentence + S(" Refunds reuse the old rate."), S("message:caching"));
    QQuickItem* prose = proseShowing(world, kSentence);
    prose->forceActiveFocus();
    const auto [start, end] = drawnRange(plainText(prose), kSentence);
    expect(start >= 0, S("the sentence is not drawn"));
    QMetaObject::invokeMethod(prose, "select", Q_ARG(int, start), Q_ARG(int, end));
    QQuickItem* button = nullptr;
    world.waitFor([&] {
      const QList<QQuickItem*> buttons = namedItems(world, S("citeSelection"));
      button = buttons.isEmpty() ? nullptr : buttons.last();
      return button != nullptr;
    }, [&] { return S("Cite on the selection %1").arg(show(prose->property("selectedText").toString())); });
    world.tap(button);
  });
  step(S("the composer holds a citation of that sentence"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return citations(world).size() == 1 && citations(world).constFirst().toMap().value(S("text")).toString() == kSentence; },
                  [&] { return S("a quote of the sentence; the composer shows %1").arg(show(citations(world))); });
  });
  step(S("the user can add a comment to the citation"), [](World& world, const Captures&, const Table&) {
    QQuickItem* chip = world.findWhere([](QQuickItem* item) { return item->objectName().startsWith(QLatin1String("citation-")); });
    expect(chip != nullptr, S("no citation chip is shown"));
    world.tap(chip);
    QQuickItem* comment = world.item(S("citationComment"));
    world.tap(comment);
    world.type(S("Too slow?"));
    world.press(S("Return"));
    world.waitFor([&] { return citations(world).size() == 1 && citations(world).constFirst().toMap().value(S("comment")).toString() == S("Too slow?"); },
                  [&] { return S("the comment on the citation; the composer shows %1").arg(show(citations(world))); });
  });

  // Nothing left to load.
  step(S("every turn of the thread is loaded"), [](World& world, const Captures&, const Table&) {
    forgetThread(world);
    openAgain(world);
    timeline(world).loadEarlier();
    expectEveryTurn(world);
    watch(world).sent = world.mc.part<FakeStreams>().sent.size();
  });
  step(S("no way to load earlier turns is offered"), [](World& world, const Captures&, const Table&) {
    expect(!timeline(world).hasEarlier(), S("the thread still has earlier turns"));
    expect(swipeUpUntil(world, [&] { return rows(world)->property("atYBeginning").toBool(); }, 30), S("the view never reached the top"));
    world.sync();
    expect(sentSince(world, S("more")).isEmpty(), S("the MC was asked for earlier turns there are none of"));
    expect(world.find(S("loadingEarlier")) == nullptr, S("the thread says earlier turns are loading"));
  });
});

}  // namespace
