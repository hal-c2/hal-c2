// Following new output at the end of a long thread
// (features/timeline/scrolling-and-links.feature): the Timeline brick over the
// open thread holds the end while the agent writes, holds still while nothing
// is written, stays where the user scrolled to, and follows again from
// "Scroll to end". The phone proves the same scenarios over its thread screen
// (apps/mobile-qt/tests/features/ScrollingSteps.cpp); this is its seed.
//
// The background's thread opens empty (TimelineSteps' lookAtThread), as the
// link scenarios of the file want it, so these scenarios give it its turns
// in their first step.

#include <QJsonObject>
#include <QPoint>
#include <QQuickItem>
#include <QQuickWindow>
#include <qpa/qwindowsysteminterface.h>

#include <cmath>

#include "Brick.h"
#include "Harness.h"
#include "LocalCache.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;
using S = QString;

// Turns enough to fill several views, and more items than a client opens a
// thread with (TimelineModel::windowItems).
constexpr int kTurns = 28;
constexpr int kCalls = 8;

// What a scenario watches across its steps.
struct Watch {
  bool seeded = false;
  qreal contentY = 0;
  qreal contentHeight = 0;
  QString reading;
  qreal readingY = 0;
};

Watch& watch(World& world) {
  return world.mc.part<Watch>();
}

QQuickItem* rows(World& world) {
  return world.brick->item(S("timelineRows"));
}

// As the brick reads its own end (Timeline.qml nearEnd).
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

void waitStill(World& world) {
  QQuickItem* list = rows(world);
  world.waitFor([&] { return !list->property("moving").toBool(); }, S("the timeline to stop scrolling"));
}

// The scenario's thread given `kTurns` settled turns, each a question,
// `kCalls` tool calls and "Answer <n>" (the last with a table), then a running
// turn whose reply "reply" is still being written; reopened from scratch and
// drawn by the Timeline brick at its end.
void seedLong(World& world) {
  if (std::exchange(watch(world).seeded, true)) return;
  const QString key = world.mc.environmentId + QLatin1Char(':') + kThread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(S("home")));
  store(world)->close(key);
  world.native().cache()->forgetThread(key);
  world.sync();
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const auto put = [&](const QString& kind, const QString& id, QJsonObject fields) {
    fields.insert(S("id"), id);
    change(world, kind, id, {{S("s"), fields}}, true);
  };
  for (int n = 1; n <= kTurns; ++n) {
    const QDateTime started = now().addSecs(-3600 + n * 60);
    const QString run = S("run-%1").arg(fake.ordinal + 1);
    put(S("run"), run, {{S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")},
                        {S("requestedAt"), iso(started)}, {S("startedAt"), iso(started)},
                        {S("completedAt"), iso(started.addSecs(30))}});
    const auto item = [&](const QString& type, const QJsonObject& more) {
      QJsonObject fields{{S("type"), type}, {S("runId"), run}, {S("status"), S("completed")}, {S("updatedAt"), iso(started)}};
      for (auto it = more.begin(); it != more.end(); ++it) fields.insert(it.key(), it.value());
      fields.insert(S("ordinal"), ++fake.ordinal);
      put(S("turn-item"), S("%1:%2").arg(type).arg(fake.ordinal), fields);
    };
    item(S("user_message"), {{S("text"), S("Question %1").arg(n)}});
    for (int call = 1; call <= kCalls; ++call) item(S("command_execution"), {{S("input"), S("bun test %1").arg(call)}, {S("exitCode"), 0}});
    QString answer = S("Answer %1").arg(n);
    if (n == kTurns) answer += S("\n\n| Item | Price |\n| --- | --- |\n| Cart | 3 |\n| Tax | 1 |");
    item(S("assistant_message"), {{S("text"), answer}});
  }
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  fake.run = run;
  put(S("run"), run, {{S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), iso(now())}, {S("startedAt"), iso(now())}});
  put(S("turn-item"), S("message:") + run,
      {{S("type"), S("user_message")}, {S("runId"), run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Add a tax line to the cart")}, {S("updatedAt"), iso(now())}});
  put(S("turn-item"), S("reply"),
      {{S("type"), S("assistant_message")}, {S("runId"), run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("running")}, {S("text"), S("The cart")}, {S("streaming"), true}, {S("updatedAt"), iso(now())}});
  look(world, key);
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n", QSize(820, 600));
  world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  waitAtEnd(world);
}

// The agent writes another paragraph of "reply".
void grow(World& world) {
  change(world, S("turn-item"), S("reply"),
         {{S("a"), QJsonObject{{S("text"), S("\n\nAnother paragraph of the reply, written just now, with enough words to take a line or two of the view.")}}}});
  world.sync();
}

// The wheel turned up until the view is more than a page from the end, as
// tst_Timeline.qml's scrollUp leaves it.
void scrollAway(World& world) {
  QQuickItem* list = rows(world);
  const QPoint at = world.brick->at(list);
  world.waitFor([&] {
    const bool farUp = !list->property("following").toBool() &&
                       list->property("originY").toReal() + list->property("contentHeight").toReal() -
                               (list->property("contentY").toReal() + list->height()) > list->height();
    if (farUp) return true;
    QWindowSystemInterface::handleWheelEvent(&world.brick->window(), at, world.brick->window().mapToGlobal(at), QPoint(), QPoint(0, 120));
    return false;
  }, [&] { return S("the view away from the end; %1").arg(describeList(list)); });
  waitStill(world);
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

// The row at the top of the view, where the brick's own hold() looks.
QString topRow(World& world) {
  QQuickItem* list = rows(world);
  int index = -1;
  const qreal y = list->property("contentY").toReal() + list->property("topMargin").toReal() + 1;
  QMetaObject::invokeMethod(list, "indexAt", Q_RETURN_ARG(int, index), Q_ARG(qreal, list->width() / 2), Q_ARG(qreal, y));
  if (index < 0) fail(S("no row at the top of the view; %1").arg(describeList(list)));
  return role(timeline(world), index, TimelineModel::IdRole).toString();
}

// Whether the reply's drawn row ends inside the view.
bool replyEndInView(World& world) {
  QQuickItem* list = rows(world);
  QQuickItem* row = drawnRow(world, S("reply"));
  if (!row) return false;
  const qreal bottom = row->mapToItem(list, QPointF(0, row->height())).y();
  return bottom > 0 && bottom <= list->height() + 1;
}

const Steps steps([] {
  // Following the end.
  step(S("the user is at the end of the thread"), [](World& world, const Captures&, const Table&) {
    seedLong(world);
    waitAtEnd(world);
  });
  step(S("the agent writes more of its reply"), [](World& world, const Captures&, const Table&) {
    watch(world).contentHeight = rows(world)->property("contentHeight").toReal();
    grow(world);
    grow(world);
  });
  step(S("the new text stays in view"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    world.waitFor([&] { return list->property("contentHeight").toReal() > watch(world).contentHeight && atEnd(list) && replyEndInView(world); },
                  [&] { return S("the new text in view; %1").arg(describeList(list)); });
    expect(list->property("following").toBool(), S("the view stopped following; %1").arg(describeList(list)));
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
    world.brick->window().grabWindow();  // lays out what opening the thread changed
    waitStill(world);
    watch(world).contentY = rows(world)->property("contentY").toReal();
  });
  step(S("the view does not move"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.brick->window().grabWindow();
    waitStill(world);
    const qreal y = rows(world)->property("contentY").toReal();
    expect(std::abs(y - watch(world).contentY) < 1, S("the view moved from %1 to %2").arg(watch(world).contentY).arg(y));
  });

  // Scrolling away and coming back.
  step(S("the agent is writing its reply"), [](World& world, const Captures&, const Table&) {
    seedLong(world);
    TimelineModel& model = timeline(world);
    bool streaming = false;
    for (int row = 0; row < model.rowCount(); ++row) streaming = streaming || role(model, row, TimelineModel::StreamingRole).toBool();
    expect(streaming, S("no reply is being written; %1").arg(describe(model)));
    waitAtEnd(world);
  });
  step(S("the user scrolls up to an earlier message"), [](World& world, const Captures&, const Table&) {
    scrollAway(world);
    world.brick->window().grabWindow();
    watch(world).reading = topRow(world);
    watch(world).readingY = drawnAt(world, watch(world).reading);
    grow(world);
  });
  step(S("the view stays on that message while the reply grows"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    grow(world);
    world.brick->window().grabWindow();
    const qreal y = drawnAt(world, watch(world).reading);
    expect(std::abs(y - watch(world).readingY) < 1,
           S("the message being read moved from %1 to %2 while the reply grew").arg(watch(world).readingY).arg(y));
    expect(!list->property("following").toBool(), S("the view is following again; %1").arg(describeList(list)));
  });
  step(S("the user is offered a way to scroll to the end"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* jump = world.brick->find(S("jumpToLatest")); return jump && jump->isVisible(); },
                  S("\"Scroll to end\" to be offered"));
  });
  step(S("the user has scrolled away from the end while the agent writes"), [](World& world, const Captures&, const Table&) {
    seedLong(world);
    scrollAway(world);
    grow(world);
  });
  step(S("the user scrolls to the end"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* jump = world.brick->find(S("jumpToLatest")); return jump && jump->isVisible(); },
                  S("\"Scroll to end\" to be offered"));
    world.brick->click(S("jumpToLatest"));
  });
  step(S("the latest output is shown"), [](World& world, const Captures&, const Table&) {
    waitAtEnd(world);
    world.waitFor([&] { return replyEndInView(world); }, [&] { return S("the reply's end in view; %1").arg(describeList(rows(world))); });
  });
  step(S("the view follows new output again"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rows(world);
    expect(list->property("following").toBool(), S("the view is not following; %1").arg(describeList(list)));
    const qreal before = list->property("contentHeight").toReal();
    grow(world);
    world.waitFor([&] { return list->property("contentHeight").toReal() > before && atEnd(list); },
                  [&] { return S("the view to follow new output; %1").arg(describeList(list)); });
  });
});

}  // namespace
