// A thread's conversation on the phone as the agent writes it
// (features/timeline/streaming.feature): the MC's `stream` shape for the
// thread on screen, changed a step at a time (ComposerSteps.cpp serves it),
// and what the phone's timeline makes of it. The timeline is the desktop's
// TimelineModel and Timeline brick, so the steps read the model as the
// desktop harness's TimelineSteps.cpp does, and the screen where the phone
// draws it differently. A reply's shell command run from its code block goes
// to the thread's terminal as FakeTerminals fakes it.

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QPersistentModelIndex>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QTimeZone>

#include <algorithm>
#include <cmath>

#include "FakeTerminals.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "SettingsController.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using S = QString;

const QString kTitle = S("Tax line");
const QString kPeer = S("mc-b");
const QString kPeerEnvironment = S("env-b");
const QString kPeerThread = S("thread-remote");

// The scenarios' clock: 2026-09-23 10:00, UTC.
QDateTime now() {
  return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC);
}

QString iso(const QDateTime &time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

// The turn the steps write: the stream it is on, its run, when that started,
// how the next "the turn settles" ends it, and the rows shown before a step
// that should keep them.
struct Turn {
  QString thread;
  QString run;
  QDateTime started;
  QString settlesAs = S("interrupted");
  QList<QPersistentModelIndex> kept;
  qsizetype connections = 0;
  bool durationShown = false;
};

Turn &turn(World &world) { return world.mc.part<Turn>(); }

ThreadStore *store(World &world) {
  return world.native().controller<ThreadStore>();
}

TimelineModel &timeline(World &world) {
  TimelineModel *model = store(world)->activeTimeline();
  if (!model)
    fail(S("no thread is open"));
  return *model;
}

QVariant role(TimelineModel &model, int row, int role) {
  return model.data(model.index(row), role);
}

QString describe(TimelineModel &model) {
  QStringList rows;
  const QHash<int, QByteArray> names = model.roleNames();
  for (int row = 0; row < model.rowCount(); ++row) {
    QVariantMap shown;
    for (const int key :
         {int(TimelineModel::KindRole), int(TimelineModel::IdRole),
          int(TimelineModel::TitleRole), int(TimelineModel::TextRole),
          int(TimelineModel::ExpandedRole), int(TimelineModel::EntriesRole)}) {
      const QVariant value = role(model, row, key);
      if (value.isValid() && !value.toString().isEmpty() &&
          value != QVariant(false))
        shown.insert(QString::fromUtf8(names.value(key)), value);
    }
    rows.append(show(shown));
  }
  return S("status %1, rows: %2")
      .arg(model.status(), rows.isEmpty() ? S("(none)") : rows.join(S("; ")));
}

QList<int> rowsOf(TimelineModel &model, const QString &kind) {
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind)
      rows.append(row);
  }
  return rows;
}

int lastRowOf(World &world, const QString &kind) {
  const QList<int> rows = rowsOf(timeline(world), kind);
  if (rows.isEmpty())
    fail(S("no %1 row; %2").arg(kind, describe(timeline(world))));
  return rows.last();
}

int rowShowing(World &world, const QString &itemId) {
  TimelineModel &model = timeline(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::IdRole).toString() == itemId)
      return row;
    for (const QVariant &entry :
         role(model, row, TimelineModel::EntriesRole).toList()) {
      if (entry.toMap().value(S("id")).toString() == itemId)
        return row;
    }
  }
  fail(S("no row shows %1; %2").arg(itemId, describe(model)));
}

QVariantMap lastEntry(World &world) {
  const QVariantList entries =
      role(timeline(world), lastRowOf(world, S("work")),
           TimelineModel::EntriesRole)
          .toList();
  if (entries.isEmpty())
    fail(S("the work row shows no calls; %1").arg(describe(timeline(world))));
  return entries.last().toMap();
}

// Waits for `text` to be drawn: a whole text, or part of one.
void onScreen(World &world, const QString &text, bool whole = true) {
  world.waitFor([&] { return world.shows(text, whole); },
                [&] {
                  return S("\"%1\" on screen; the screen says: %2")
                      .arg(text, world.texts().join(S(" | ")));
                });
}

// One change to the turn's thread; the phone has it once it returns, when it
// is connected.
void change(World &world, const QString &kind, const QString &id,
            const QJsonObject &patch, bool quiet = false) {
  changeEntity(world.mc, turn(world).thread, kind, id, patch, quiet);
  if (world.mc.connected())
    world.sync();
}

void set(World &world, const QString &kind, const QString &id,
         const QJsonObject &fields) {
  change(world, kind, id, {{S("s"), fields}});
}

// A new run, started `since` seconds ago (not started when negative), with
// the user's message that asked for it.
QString startRun(World &world, int since = 0,
                 const QString &status = S("running")) {
  FakeStreams &fake = world.mc.part<FakeStreams>();
  Turn &current = turn(world);
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  current.run = world.run = run;
  current.started = since >= 0 ? now().addSecs(-since) : QDateTime();
  QJsonObject fields{
      {S("id"), run},
      {S("ordinal"), ++fake.ordinal},
      {S("status"), status},
      {S("requestedAt"), iso(now().addSecs(-std::max(since, 0)))}};
  if (current.started.isValid())
    fields.insert(S("startedAt"), iso(current.started));
  set(world, S("run"), run, fields);
  set(world, S("turn-item"), S("message:") + run,
      {{S("id"), S("message:") + run},
       {S("type"), S("user_message")},
       {S("runId"), run},
       {S("ordinal"), ++fake.ordinal},
       {S("status"), S("completed")},
       {S("text"), S("Add a tax line to the cart")},
       {S("updatedAt"), iso(now().addSecs(-std::max(since, 0)))}});
  return run;
}

// A turn item of the current run; `fields` adds to and overrides the defaults.
QString addItem(World &world, const QString &type,
                const QJsonObject &fields = {}) {
  FakeStreams &fake = world.mc.part<FakeStreams>();
  QJsonObject item{{S("id"), S("%1:%2").arg(type).arg(fake.ordinal + 1)},
                   {S("type"), type},
                   {S("runId"), turn(world).run},
                   {S("ordinal"), ++fake.ordinal},
                   {S("status"), S("completed")},
                   {S("updatedAt"), iso(now())}};
  for (auto it = fields.begin(); it != fields.end(); ++it)
    item.insert(it.key(), it.value());
  const QString id = item.value(QLatin1String("id")).toString();
  set(world, S("turn-item"), id, item);
  return id;
}

QString addCommand(World &world, int n,
                   const QString &status = S("completed")) {
  return addItem(world, S("command_execution"),
                 {{S("input"), S("bun test cart-%1").arg(n)},
                  {S("status"), status},
                  {S("exitCode"), 0}});
}

QString addReply(World &world, const QString &id, const QString &text,
                 bool streaming = false) {
  return addItem(
      world, S("assistant_message"),
      {{S("id"), id}, {S("text"), text}, {S("streaming"), streaming}});
}

// The run ends as `status`, `after` seconds from its start.
void settleRun(World &world, const QString &status, int after) {
  QJsonObject fields{{S("status"), status}};
  if (turn(world).started.isValid())
    fields.insert(S("completedAt"), iso(turn(world).started.addSecs(after)));
  set(world, S("run"), turn(world).run, fields);
}

// Opens the thread `key` by its route and waits for it to follow its MC.
void look(World &world, const QString &key) {
  world.native().controller<NavigationController>()->open(
      NavigationController::Route::thread(key));
  world.waitFor(
      [&] {
        return store(world)->activeThread() == key &&
               store(world)->activeTimeline();
      },
      S("the thread to open"));
  world.waitFor(
      [&] { return timeline(world).status() == QLatin1String("live"); },
      [&] {
        return S("the thread to follow its MC; %1")
            .arg(describe(timeline(world)));
      });
}

// Taps `target` in the timeline, scrolled into view as the user would first,
// once the list has stopped moving: a tap on a list in motion only stops it.
void tapStill(World &world, QQuickItem *target) {
  QQuickItem *rows = world.item(S("timelineRows"));
  world.window().grabWindow(); // lays out what the last step changed
  const qreal top = target->mapToItem(rows, QPointF(0, 0)).y();
  if (top < 0 || top + target->height() > rows->height()) {
    const qreal contentY =
        rows->property("contentY").toReal() + top - rows->height() / 2;
    const qreal lowest = rows->property("originY").toReal() +
                         rows->property("contentHeight").toReal() -
                         rows->height();
    rows->setProperty("contentY", std::max(rows->property("originY").toReal(),
                                           std::min(contentY, lowest)));
  }
  world.waitFor([&] { return !rows->property("moving").toBool(); },
                S("the timeline to stop scrolling"));
  world.tap(target);
}

void expectAnswer(World &world, const QString &text) {
  TimelineModel &model = timeline(world);
  for (const int row : rowsOf(model, S("message"))) {
    if (role(model, row, TimelineModel::TextRole).toString() == text)
      return;
  }
  fail(S("\"%1\" is not shown; %2").arg(text, describe(model)));
}

void keepRows(World &world) {
  TimelineModel &model = timeline(world);
  Turn &current = turn(world);
  current.kept.clear();
  for (int row = 0; row < model.rowCount(); ++row)
    current.kept.append(QPersistentModelIndex(model.index(row)));
}

// The fold of the turn: its title, open or not.
QString foldTitle(World &world) {
  return role(timeline(world), lastRowOf(world, S("fold")),
              TimelineModel::TitleRole)
      .toString();
}

bool noFoldStartingWith(World &world, const QString &title) {
  TimelineModel &model = timeline(world);
  for (const int row : rowsOf(model, S("fold"))) {
    if (role(model, row, TimelineModel::TitleRole).toString().startsWith(title))
      return false;
  }
  return true;
}

void expectFolded(World &world, const QString &label) {
  TimelineModel &model = timeline(world);
  const int fold = lastRowOf(world, S("fold"));
  const QString title = role(model, fold, TimelineModel::TitleRole).toString();
  expect(title == label, S("the work folds behind \"%1\"").arg(title));
  expect(!role(model, fold, TimelineModel::ExpandedRole).toBool() &&
             rowsOf(model, S("work")).isEmpty(),
         S("the work is not folded away; %1").arg(describe(model)));
  onScreen(world, label);
}

// "340 milliseconds", "1 hour 5 seconds": in milliseconds.
qint64 durationOf(const QString &spoken) {
  static const QRegularExpression part(
      S("([\\d.]+) (millisecond|second|minute|hour)s?"));
  static const QHash<QString, double> unit{{S("millisecond"), 1},
                                           {S("second"), 1000},
                                           {S("minute"), 60000},
                                           {S("hour"), 3600000}};
  double ms = 0;
  auto it = part.globalMatch(spoken);
  if (!it.hasNext())
    fail(S("unknown duration: %1").arg(spoken));
  while (it.hasNext()) {
    const QRegularExpressionMatch match = it.next();
    ms += match.captured(1).toDouble() * unit.value(match.captured(2));
  }
  return std::llround(ms);
}

// The thread "Tax line", on the scenarios' clock and in US English, opened
// from the thread list. Its MC names its log, so a phone that comes back
// resumes from where it was.
void lookAtThread(World &world) {
  world.mc.part<FakeStreams>().handle = S("log-1.1");
  world.thread = haveThread(world, kTitle);
  turn(world).thread = world.thread;
  world.setTime(now());
  store(world)->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
  openThread(world, kTitle);
  world.waitFor(
      [&] {
        return store(world)->activeTimeline() &&
               timeline(world).status() == QLatin1String("live");
      },
      [&] {
        return S("the thread to follow its MC; the screen says: %1")
            .arg(world.texts().join(S(" | ")));
      });
}

void collect(QQuickItem *item, const QString &name, QList<QQuickItem *> &out) {
  if (item->objectName() == name && item->isVisible())
    out.append(item);
  for (QQuickItem *child : item->childItems())
    collect(child, name, out);
}

// The items named `name` the phone shows.
QList<QQuickItem *> visible(World &world, const QString &name) {
  QList<QQuickItem *> items;
  collect(world.window().contentItem(), name, items);
  return items;
}

const QString kCommand = S("bun test cart");

// A reply of a thread on screen holding `block`, written or still streaming.
void replyWith(World &world, const QString &block, bool streaming = false) {
  if (world.thread.isEmpty())
    lookAtThread(world);
  startRun(world, 30);
  addItem(world, S("assistant_message"),
          {{S("id"), S("reply")},
           {S("text"), S("Run the tests:\n\n") + block},
           {S("streaming"), streaming},
           {S("status"), streaming ? S("running") : S("completed")}});
  if (!streaming)
    settleRun(world, S("completed"), 30);
  onScreen(world, S("Run the tests:"), false);
}

QString preferredScript(World &world) {
  return world.state(S("workspace"))
      .toMap()
      .value(S("preferredScriptId"))
      .toString();
}

// The workspace's preferred script before the user ran a reply's command.
struct Before {
  QString preferred;
};

// The thread's project offers "lint" first, as if the user had run it last, so
// a change to the selected script shows.
void preferScript(World &world) {
  const QString project = S("shop");
  QJsonObject row = world.mc.projects.value(project);
  QJsonArray scripts = row.value(QLatin1String("scripts")).toArray();
  scripts.append(QJsonObject{{S("id"), S("lint")},
                             {S("name"), S("Lint")},
                             {S("command"), S("bun run lint")},
                             {S("icon"), S("play")},
                             {S("runOnWorktreeCreate"), false}});
  row.insert(S("scripts"), scripts);
  world.mc.projects.insert(project, row);
  world.native().controller<SettingsController>()->writeDevice(
      S("lastProjectScripts"),
      QVariantMap{
          {world.mc.environmentId + QLatin1Char(':') + project, S("lint")}});
  QJsonArray rows;
  rows.append(QJsonArray{project, S("project"), row});
  world.mc.sendRows(world.mc.name, rows);
  world.waitFor(
      [&] {
        return world.state(S("workspace"))
                   .toMap()
                   .value(S("preferredScriptId")) == S("lint");
      },
      [&] {
        return S("the project to offer lint first; the workspace is %1")
            .arg(show(world.state(S("workspace"))));
      });
}

QString terminalCalls(World &world) {
  QStringList lines;
  for (const QJsonObject &call :
       std::as_const(world.mc.part<terminalfake::FakeTerminals>().calls))
    lines.append(show(call));
  return lines.isEmpty() ? S("(none)") : lines.join(S("; "));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The thread "Tax line", on the scenarios' clock and in US English, opened
  // from the thread list. Its MC names its log, so a phone that comes back
  // resumes from where it was.
  step(S("the user is looking at a thread in %1").arg(q),
       [](World &world, const Captures &, const Table &) {
         lookAtThread(world);
       });

  // Reasoning.
  step(S("the agent is reasoning before it answers"),
       [](World &world, const Captures &, const Table &) {
         startRun(world);
         addItem(world, S("reasoning"),
                 {{S("streaming"), true},
                  {S("status"), S("running")},
                  {S("text"), S("The cart total needs")}});
       });
  step(S("the reasoning is streaming"), [](World &world, const Captures &,
                                           const Table &) {
    change(world, S("turn-item"), lastEntry(world).value(S("id")).toString(),
           {{S("a"), QJsonObject{{S("text"), S(" a tax line")}}}});
  });
  step(S("the reasoning is finished"),
       [](World &world, const Captures &, const Table &) {
         set(world, S("turn-item"), lastEntry(world).value(S("id")).toString(),
             {{S("streaming"), false}, {S("status"), S("completed")}});
       });
  step(S("the agent reasoned in Markdown"), [](World &world, const Captures &,
                                               const Table &) {
    startRun(world);
    addItem(world, S("reasoning"),
            {{S("streaming"), false},
             {S("status"), S("completed")},
             {S("text"), S("**Checking** the [cart](https://shop.example/cart) "
                           "`total`\n\n![a chart](chart.png)")}});
  });
  step(S("the reasoning is labelled %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         const QString label = lastEntry(world).value(S("label")).toString();
         expect(label == c[0],
                S("the reasoning is labelled \"%1\"").arg(label));
         onScreen(world, c[0], false);
       });

  // Working.
  step(S("the agent has been working for (\\d+) seconds"),
       [](World &world, const Captures &c, const Table &) {
         startRun(world, c[0].toInt());
       });
  step(S("the thread says the agent is working"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         expect(model.working(),
                S("the thread is not working; %1").arg(describe(model)));
         expect(model.workingLabel() == QLatin1String("Working for 12s"),
                S("the thread says \"%1\"").arg(model.workingLabel()));
         world.item(S("workingLabel"));
       });
  step(S("the elapsed time keeps counting"),
       [](World &world, const Captures &, const Table &) {
         world.setTime(now().addSecs(5));
         const QString label = timeline(world).workingLabel();
         expect(label == QLatin1String("Working for 17s"),
                S("five seconds later the thread says \"%1\"").arg(label));
       });
  // The run is asked for but not begun: it has no startedAt yet.
  step(S("the user sent a message and the agent's session is still starting"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, -1, S("starting"));
         set(world, S("run"), turn(world).run,
             {{S("requestedAt"), iso(now().addSecs(-12))}});
       });
  step(S("the agent has not yet begun the turn"), [](World &world,
                                                     const Captures &,
                                                     const Table &) {
    const QString status = timeline(world).working() ? S("working") : S("idle");
    expect(status == QLatin1String("working"),
           S("the thread is %1; %2").arg(status, describe(timeline(world))));
  });
  step(S("the elapsed time counts from when the message was sent"),
       [](World &world, const Captures &, const Table &) {
         const QDateTime since = timeline(world).workingSince();
         expect(since == now().addSecs(-12),
                S("the thread counts from %1").arg(iso(since)));
       });
  step(S("it does not disappear and come back when the agent begins"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         bool stopped = false;
         const QMetaObject::Connection watch =
             QObject::connect(&model, &TimelineModel::workingChanged,
                              [&] { stopped = stopped || !model.working(); });
         set(world, S("run"), turn(world).run,
             {{S("status"), S("running")},
              {S("startedAt"), iso(now().addSecs(-2))}});
         QObject::disconnect(watch);
         expect(!stopped && model.working(),
                S("the thread stopped working as the agent began; %1")
                    .arg(describe(model)));
       });
  // A settled turn's fold reads how long it took.
  step(S("the thread shows a duration of (.+)"),
       [](World &world, const Captures &c, const Table &) {
         const qint64 ms = durationOf(c[0]);
         startRun(world, -1);
         turn(world).started = now().addMSecs(-ms);
         set(world, S("run"), turn(world).run,
             {{S("startedAt"), iso(turn(world).started)}});
         addCommand(world, 1);
         addReply(world, S("answer"), S("The cart now shows tax."));
         set(world, S("run"), turn(world).run,
             {{S("status"), S("completed")}, {S("completedAt"), iso(now())}});
         turn(world).durationShown = true;
       });

  // Folds.
  const auto fourCallsAndAnswer = [](World &world) {
    startRun(world);
    for (int n = 1; n <= 4; ++n)
      addCommand(world, n);
    addReply(world, S("answer"), S("The cart now shows tax."));
  };
  step(S("the agent ran four tool calls and then answered"),
       [fourCallsAndAnswer](World &world, const Captures &, const Table &) {
         fourCallsAndAnswer(world);
       });
  step(S("the turn completes after 2 minutes"),
       [](World &world, const Captures &, const Table &) {
         settleRun(world, S("completed"), 120);
       });
  step(S("the tool calls fold behind %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         expectFolded(world, c[0]);
       });
  step(S("the answer stays visible"),
       [](World &world, const Captures &, const Table &) {
         expectAnswer(world, S("The cart now shows tax."));
         onScreen(world, S("The cart now shows tax."));
       });
  step(S("a finished turn is folded behind %1").arg(q),
       [fourCallsAndAnswer](World &world, const Captures &c, const Table &) {
         fourCallsAndAnswer(world);
         settleRun(world, S("completed"), 120);
         expectFolded(world, c[0]);
       });
  const auto toggleFold = [](World &world, const Captures &, const Table &) {
    TimelineModel &model = timeline(world);
    model.toggle(role(model, lastRowOf(world, S("fold")), TimelineModel::IdRole)
                     .toString());
  };
  step(S("the user opens the folded work"), toggleFold);
  step(S("the user closes it again"), toggleFold);
  step(S("its tool calls are shown"), [](World &world, const Captures &,
                                         const Table &) {
    TimelineModel &model = timeline(world);
    const int work = lastRowOf(world, S("work"));
    const int calls =
        role(model, work, TimelineModel::EntriesRole).toList().size() +
        role(model, work, TimelineModel::HiddenCountRole).toInt();
    expect(
        calls == 4,
        S("the open fold shows %1 calls; %2").arg(calls).arg(describe(model)));
    world.item(S("workGroupToggle"));
  });
  step(S("the tool calls fold away"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         expect(rowsOf(model, S("work")).isEmpty(),
                S("the calls are still shown; %1").arg(describe(model)));
       });
  step(S("the user interrupted a turn after (\\d+) seconds"),
       [](World &world, const Captures &c, const Table &) {
         startRun(world, c[0].toInt());
         addCommand(world, 1, S("interrupted"));
       });
  step(S("the user interrupted a turn before it did any work"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, -1, S("starting"));
         addItem(world, S("run_interrupt_result"),
                 {{S("message"), S("Interrupted by the user")}});
       });
  step(
      S("the turn settles"), [](World &world, const Captures &, const Table &) {
        const Turn &current = turn(world);
        settleRun(world, current.settlesAs,
                  current.started.isValid() ? int(current.started.secsTo(now()))
                                            : 0);
      });
  step(S("its work folds behind %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         const QString title = foldTitle(world);
         expect(title == c[0], S("the work folds behind \"%1\"").arg(title));
         onScreen(world, c[0]);
       });
  // Stopped from the composer's Stop, which the MC answers by ending the run
  // and cutting off the call that was running.
  step(S("the user interrupted the running turn a moment ago"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 10);
         addCommand(world, 1);
         const QString running = addCommand(world, 2, S("running"));
         updateRow(world.mc, world.thread,
                   {{S("activeRunId"), turn(world).run},
                    {S("latestRunId"), turn(world).run}});
         world.sync();
         QQuickItem *action = world.item(S("primaryAction"));
         world.waitFor([&] { return action->property("stopMode").toBool(); },
                       S("the composer to offer Stop"));
         world.tap(action);
         world.waitFor(
             [&] {
               return std::any_of(
                   world.mc.commands.cbegin(), world.mc.commands.cend(),
                   [](const QJsonObject &command) {
                     return command.value(QLatin1String("type")) ==
                            QLatin1String("run.interrupt");
                   });
             },
             S("the MC to be asked to stop"));
         set(world, S("turn-item"), running, {{S("status"), S("interrupted")}});
         updateRow(world.mc, world.thread,
                   {{S("activeRunId"), QJsonValue::Null}});
       });
  step(S("its work stays expanded so the user can see where it stopped"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         const int fold = lastRowOf(world, S("fold"));
         expect(role(model, fold, TimelineModel::ExpandedRole).toBool() &&
                    role(model, fold, TimelineModel::TitleRole)
                        .toString()
                        .startsWith(QLatin1String("You stopped")),
                S("the fold is not open; %1").arg(describe(model)));
         const QVariantList calls = role(model, lastRowOf(world, S("work")),
                                         TimelineModel::EntriesRole)
                                        .toList();
         expect(calls.size() == 2 &&
                    calls.last().toMap().value(S("command")) ==
                        QLatin1String("bun test cart-2") &&
                    calls.last().toMap().value(S("statusLabel")) ==
                        QLatin1String("Stopped"),
                S("the calls shown are %1").arg(show(calls)));
         onScreen(world, S("bun test cart-2"), false);
         // The way back: the user can still fold it away.
         model.toggle(role(model, fold, TimelineModel::IdRole).toString());
         expect(rowsOf(model, S("work")).isEmpty(),
                S("the work cannot be folded away; %1").arg(describe(model)));
       });

  // A long message of the user's, shortened until the user taps to see it all.
  step(S("a message longer than the preview length"),
       [](World &world, const Captures &, const Table &) {
         const QString run = startRun(world);
         QStringList lines;
         for (int n = 1; n <= 30; ++n)
           lines.append(S("Requirement %1").arg(n));
         set(world, S("turn-item"), S("message:") + run,
             {{S("text"), lines.join(QLatin1Char('\n'))}});
         QQuickItem *body = world.item(S("userMessageBody"));
         world.waitFor(
             [&] {
               return body->property("collapsed").toBool() &&
                      body->height() <= 200;
             },
             [&] {
               return S("the message to show its preview; it is %1 high")
                   .arg(body->height());
             });
       });
  step(S("the user shows the full message"), [](World &world, const Captures &,
                                                const Table &) {
    QQuickItem *link = world.item(S("messageExpand"));
    expect(
        link->property("text") == QLatin1String("Show full message"),
        S("the message offers \"%1\"").arg(link->property("text").toString()));
    tapStill(world, link);
  });
  step(S("the whole message is shown"),
       [](World &world, const Captures &, const Table &) {
         QQuickItem *body = world.item(S("userMessageBody"));
         QQuickItem *clip = body->findChild<QQuickItem *>(S("userMessageClip"));
         expect(clip != nullptr, S("the message has no clip"));
         world.waitFor(
             [&] {
               return !body->property("collapsed").toBool() &&
                      body->height() > 400 && !clip->clip();
             },
             [&] {
               return S("the whole message; it is %1 high").arg(body->height());
             });
         expect(world.item(S("messageExpand"))->property("text") ==
                    QLatin1String("Show less"),
                S("the message does not offer to show less"));
       });
  step(S("the user shows less"),
       [](World &world, const Captures &, const Table &) {
         tapStill(world, world.item(S("messageExpand")));
       });
  step(S("the message returns to its preview"), [](World &world,
                                                   const Captures &,
                                                   const Table &) {
    QQuickItem *body = world.item(S("userMessageBody"));
    QQuickItem *clip = body->findChild<QQuickItem *>(S("userMessageClip"));
    expect(clip != nullptr, S("the message has no clip"));
    // Cut off inside the padding, as far from the bottom edge as the top.
    world.waitFor(
        [&] {
          return body->property("collapsed").toBool() &&
                 body->height() <= 200 && clip->clip() && clip->y() > 0 &&
                 qFuzzyCompare(body->height() - (clip->y() + clip->height()),
                               clip->y());
        },
        [&] {
          return S("the preview; the message is %1 high").arg(body->height());
        });
    expect(world.item(S("messageExpand"))->property("text") ==
               QLatin1String("Show full message"),
           S("the message does not offer to show it in full"));
  });

  // Copying a reply, with its copy button.
  step(S("the agent has answered"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 30);
         addReply(world, S("answer"), S("The cart adds **tax** now."));
         settleRun(world, S("completed"), 30);
       });
  step(S("the user copies the reply"),
       [](World &world, const Captures &, const Table &) {
         QGuiApplication::clipboard()->clear();
         QQuickItem *button = nullptr;
         world.waitFor(
             [&] {
               button = world.findWhere([](QQuickItem *item) {
                 return item->objectName() == QLatin1String("copyMessage") &&
                        item->property("rowId").toString() ==
                            QLatin1String("answer");
               });
               return button != nullptr;
             },
             [&] {
               return S("the reply's copy button; %1")
                   .arg(describe(timeline(world)));
             });
         world.tap(button);
       });
  step(S("the reply's markdown is on the clipboard"),
       [](World &, const Captures &, const Table &) {
         const QString copied = QGuiApplication::clipboard()->text();
         expect(copied == QLatin1String("The cart adds **tax** now."),
                S("the clipboard holds \"%1\"").arg(copied));
       });

  // A turn's last reply carries its time and actions.
  step(S("the agent commented, ran a tool call and then answered"),
       [](World &world, const Captures &, const Table &) {
         startRun(world);
         addReply(world, S("comment"), S("Looking at the cart first."));
         addCommand(world, 1);
         addReply(world, S("answer"), S("The cart now shows tax."));
       });
  const auto carriesMeta = [](World &world, const QString &id) {
    return role(timeline(world), rowShowing(world, id), TimelineModel::MetaRole)
        .toBool();
  };
  step(S("neither message shows its time and actions while the agent works"),
       [carriesMeta](World &world, const Captures &, const Table &) {
         expect(!carriesMeta(world, S("comment")) &&
                    !carriesMeta(world, S("answer")),
                S("a message of a running turn shows its time and actions"));
       });
  step(S("only the answer shows its time and actions"),
       [carriesMeta](World &world, const Captures &, const Table &) {
         expect(carriesMeta(world, S("answer")),
                S("the answer shows no time and actions"));
         expect(!carriesMeta(world, S("comment")),
                S("the comment shows its time and actions"));
       });

  // Times, read on the scenarios' clock.
  step(S("this device's %1 is set to %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         SettingsController *settings =
             world.native().controller<SettingsController>();
         QJsonObject device = settings->deviceSettings();
         device.insert(c[0], c[1]);
         expect(settings->setDeviceSettings(device),
                S("the preferences were not saved"));
       });
  step(S("the user sent a message (today|yesterday|on .+) at 9:05 in the "
         "morning"),
       [](World &world, const Captures &c, const Table &) {
         const QLocale english(QLocale::English, QLocale::UnitedStates);
         QDate day = now().date();
         if (c[0] == QLatin1String("yesterday")) {
           day = day.addDays(-1);
         } else if (c[0].startsWith(QLatin1String("on "))) {
           const QString date = c[0].mid(3);
           day = english.toDate(date, S("MMMM d, yyyy"));
           if (!day.isValid())
             day = english.toDate(date + S(", 2026"), S("MMMM d, yyyy"));
           if (!day.isValid())
             fail(S("unknown day: %1").arg(date));
         }
         startRun(
             world,
             int(QDateTime(day, QTime(9, 5), QTimeZone::UTC).secsTo(now())));
       });
  step(S("the message is stamped %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         const QString stamp =
             role(timeline(world),
                  rowShowing(world, S("message:") + turn(world).run),
                  TimelineModel::TimeRole)
                 .toString();
         expect(stamp == c[0], S("the message is stamped \"%1\"").arg(stamp));
         onScreen(world, c[0]);
       });
  step(S("its full time reads %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         const QString title =
             timeline(world).timeTitle(S("message:") + turn(world).run);
         expect(title == c[0], S("its full time reads \"%1\"").arg(title));
       });

  // Catching up.
  step(S("the agent is writing a reply"),
       [](World &world, const Captures &, const Table &) {
         startRun(world);
         addCommand(world, 1);
         addReply(world, S("reply"), S("The cart"), true);
         keepRows(world);
       });
  step(S("the MC drops the connection"),
       [](World &world, const Captures &, const Table &) {
         turn(world).connections = world.mc.connections.size();
         world.mc.drop();
         world.waitFor([&] { return !world.native().client()->isReady(); },
                       S("the phone to see the drop"));
       });
  const auto finishReply = [](World &world) {
    change(world, S("turn-item"), S("reply"),
           {{S("a"), QJsonObject{{S("text"), S(" now shows tax.")}}},
            {S("s"), QJsonObject{{S("streaming"), false}}}});
    settleRun(world, S("completed"), 30);
  };
  step(S("the agent finishes the reply while the shell is disconnected"),
       [finishReply](World &world, const Captures &, const Table &) {
         expect(!world.mc.connected(), S("the phone is connected"));
         finishReply(world);
       });
  step(S("the shell reconnects to the MC"),
       [](World &world, const Captures &, const Table &) {
         world.waitFor(
             [&] {
               return world.mc.connections.size() > turn(world).connections &&
                      world.native().client()->isReady();
             },
             S("a second connection"));
         world.waitFor(
             [&] { return timeline(world).status() == QLatin1String("live"); },
             [&] { return describe(timeline(world)); });
         world.sync();
       });
  step(S("the agent finishes the reply while the MC cannot be reached"),
       [finishReply](World &world, const Captures &, const Table &) {
         // No retry gets through until the MC is back, so the phone misses both
         // changes.
         world.mc.stopAccepting();
         world.mc.drop();
         world.waitFor([&] { return !world.native().client()->isReady(); },
                       S("the phone to see the drop"));
         finishReply(world);
       });
  step(S("the MC is back and the connection drops again part-way through the "
         "catch-up"),
       [](World &world, const Captures &, const Table &) {
         FakeStreams &fake = world.mc.part<FakeStreams>();
         fake.cutCatchUp = true;
         const qsizetype asked = fake.asked.size();
         world.mc.startAccepting();
         world.waitFor(
             [&] {
               return !fake.cutCatchUp && fake.asked.size() >= asked + 2 &&
                      timeline(world).status() == QLatin1String("live");
             },
             [&] {
               return S("the thread to catch up on a second connection; it was "
                        "asked for %1 times and %2")
                   .arg(fake.asked.size() - asked)
                   .arg(describe(timeline(world)));
             });
         world.sync();
       });
  step(S("the MC sends only what the client lacks"), [](World &world,
                                                        const Captures &,
                                                        const Table &) {
    const FakeStreams &fake = world.mc.part<FakeStreams>();
    expect(!fake.asked.isEmpty(), S("the MC was never asked for the thread"));
    const FakeStreams::Asked &asked = fake.asked.last();
    int snapshots = 0;
    int events = 0;
    for (qsizetype i = asked.sent; i < fake.sent.size(); ++i) {
      const QJsonObject &frame = fake.sent.at(i);
      if (frame.value(QLatin1String("id")) !=
          asked.sub.value(QLatin1String("id")))
        continue;
      if (frame.value(QLatin1String("t")) == QLatin1String("live"))
        break;
      if (frame.value(QLatin1String("t")) == QLatin1String("snapshot"))
        ++snapshots;
      if (frame.value(QLatin1String("t")) == QLatin1String("events"))
        events += int(frame.value(QLatin1String("events")).toArray().size());
    }
    expect(snapshots == 0 && events == asked.lacked,
           S("the MC sent %1 snapshots and %2 events for the %3 changes the "
             "phone lacked; it was asked with %4")
               .arg(snapshots)
               .arg(events)
               .arg(asked.lacked)
               .arg(show(asked.sub.toVariantMap())));
  });
  step(S("the client asked again from where it was"), [](World &world,
                                                         const Captures &,
                                                         const Table &) {
    const FakeStreams &fake = world.mc.part<FakeStreams>();
    expect(fake.asked.size() >= 3,
           S("the thread was asked for %1 times").arg(fake.asked.size()));
    const QJsonObject cut = fake.asked.at(fake.asked.size() - 2).sub;
    const QJsonObject again = fake.asked.last().sub;
    // The part it was sent moved nothing: the same offset, and both changes
    // once more, no snapshot.
    int events = 0;
    int snapshots = 0;
    for (qsizetype i = fake.asked.at(fake.asked.size() - 2).sent;
         i < fake.sent.size(); ++i) {
      if (fake.sent.at(i).value(QLatin1String("t")) ==
          QLatin1String("snapshot"))
        ++snapshots;
    }
    for (qsizetype i = fake.asked.last().sent; i < fake.sent.size(); ++i) {
      if (fake.sent.at(i).value(QLatin1String("t")) == QLatin1String("events"))
        events += int(
            fake.sent.at(i).value(QLatin1String("events")).toArray().size());
    }
    expect(cut.value(QLatin1String("offset")).isDouble() &&
               again.value(QLatin1String("offset")) ==
                   cut.value(QLatin1String("offset")) &&
               events == 2 && snapshots == 0,
           S("it asked with %1 and then %2, and was sent %3 events and %4 "
             "snapshots")
               .arg(show(cut.toVariantMap()), show(again.toVariantMap()))
               .arg(events)
               .arg(snapshots));
  });
  step(S("the agent writes more than the shell has read"),
       [](World &world, const Captures &, const Table &) {
         change(world, S("turn-item"), S("reply"),
                {{S("a"), QJsonObject{{S("text"), S(" now shows tax.")}}}},
                true);
       });
  step(S("the MC tells the shell to resync the thread"),
       [](World &world, const Captures &, const Table &) {
         const FakeStreams &fake = world.mc.part<FakeStreams>();
         const qsizetype before = world.mc.subscriptions.size();
         // The MC drops the subscription and names the offset before the first
         // event it could not send (socket.ex): here, the last one it did send.
         QJsonValue offset = 0;
         for (const QJsonObject &frame : fake.sent) {
           if (frame.value(QLatin1String("t")) == QLatin1String("events"))
             offset = frame.value(QLatin1String("offset"));
         }
         for (const int id : world.mc.subscribers(S("stream"))) {
           if (world.mc.shapeOf(id).value(QLatin1String("stream")).toString() !=
               turn(world).thread)
             continue;
           world.mc.send(
               {{S("t"), S("resync")}, {S("id"), id}, {S("offset"), offset}});
           world.mc.forget(id);
         }
         world.waitFor([&] { return world.mc.subscriptions.size() > before; },
                       S("the phone to subscribe again"));
         world.sync();
       });
  step(S("the whole reply is shown"), [](World &world, const Captures &,
                                         const Table &) {
    world.waitFor(
        [&] {
          const QList<int> messages = rowsOf(timeline(world), S("message"));
          return !messages.isEmpty() &&
                 role(timeline(world), messages.last(), TimelineModel::TextRole)
                         .toString() ==
                     QLatin1String("The cart now shows tax.");
        },
        [&] {
          return S("the whole reply; %1").arg(describe(timeline(world)));
        });
    onScreen(world, S("The cart now shows tax."));
  });
  step(S("the rows shown before are kept"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         const QList<QPersistentModelIndex> kept = turn(world).kept;
         expect(!kept.isEmpty(), S("no rows were shown before"));
         // Rows only go when the turn settles and folds its calls away; the
         // reply's row stays.
         for (const QPersistentModelIndex &index : kept) {
           expect(index.isValid() || !rowsOf(model, S("fold")).isEmpty(),
                  S("a row was dropped; %1").arg(describe(model)));
         }
         expect(model.indexOf(S("reply")) >= 0 && kept.last().isValid() &&
                    kept.last().data(TimelineModel::IdRole).toString() ==
                        QLatin1String("reply"),
                S("the reply's row was replaced; %1").arg(describe(model)));
       });

  // A thread on another MC of the cluster.
  step(S("the user is looking at a thread on another MC of the cluster"),
       [](World &world, const Captures &, const Table &) {
         world.mc.join(kPeer, kPeerEnvironment);
         world.mc.send(
             {{S("t"), S("shell.rows")},
              {S("id"), world.mc.subscribers(S("shell")).value(0)},
              {S("mc"), kPeer},
              {S("rows"),
               QJsonArray{QJsonValue(QJsonArray{
                   kPeerThread, S("thread"),
                   QJsonObject{
                       {S("id"), kPeerThread},
                       {S("title"), S("Remote")},
                       {S("projectId"), S("shop")},
                       {S("createdAt"), S("2026-09-23T09:00:00Z")},
                       {S("updatedAt"), S("2026-09-23T09:00:00Z")}}})}}});
         world.sync();
         turn(world).thread = kPeerThread;
         look(world, kPeerEnvironment + QLatin1Char(':') + kPeerThread);
       });
  step(S("the agent has answered %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         startRun(world, 30);
         addReply(world, S("answer"), c[0]);
         settleRun(world, S("completed"), 30);
       });
  const auto setPeer = [](World &world, bool online) {
    FakeStreams &fake = world.mc.part<FakeStreams>();
    if (online) {
      fake.offline.remove(kPeerEnvironment);
    } else {
      fake.offline.insert(kPeerEnvironment);
      for (const int id : world.mc.subscribers(S("stream"))) {
        if (world.mc.shapeOf(id).value(QLatin1String("stream")).toString() !=
            turn(world).thread)
          continue;
        world.mc.send({{S("t"), S("error")},
                       {S("id"), id},
                       {S("reason"), S("unknown MC")}});
        world.mc.forget(id);
      }
    }
    world.mc.send({{S("t"), S("shell.mc")},
                   {S("id"), world.mc.subscribers(S("shell")).value(0)},
                   {S("mc"), kPeer},
                   {S("online"), online}});
    world.sync();
  };
  step(S("that MC leaves the cluster"),
       [setPeer](World &world, const Captures &, const Table &) {
         setPeer(world, false);
       });
  step(S("that MC rejoins the cluster"),
       [setPeer](World &world, const Captures &, const Table &) {
         setPeer(world, true);
       });
  step(S("the thread says its MC cannot be reached"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         world.waitFor(
             [&] { return model.status() == QLatin1String("unreachable"); },
             [&] { return describe(model); });
         expect(!model.problem().isEmpty(), S("the thread does not say why"));
       });
  step(S("the answer %1 is still shown").arg(q),
       [](World &world, const Captures &c, const Table &) {
         expectAnswer(world, c[0]);
         onScreen(world, c[0]);
       });
  step(S("the thread follows its MC again"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         world.waitFor([&] { return model.status() == QLatin1String("live"); },
                       [&] { return describe(model); });
       });

  // A thread with nothing in it yet.
  step(S("a thread has no messages and no work has started"),
       [](World &world, const Captures &, const Table &) {
         world.thread = haveThread(world, S("Fresh start"));
       });
  step(S("the user opens it"),
       [](World &world, const Captures &, const Table &) {
         world.native().controller<NavigationController>()->open(
             NavigationController::Route::thread(
                 world.mc.environmentId + QLatin1Char(':') + world.thread));
         world.waitFor(
             [&] { return shownThread(world) == QLatin1String("Fresh start"); },
             [&] {
               return S("the thread; the screen says: %1")
                   .arg(world.texts().join(S(" | ")));
             });
       });
  step(S("it says there is no conversation yet"),
       [](World &world, const Captures &, const Table &) {
         onScreen(world, S("No conversation yet"));
       });
  step(S("it suggests asking the agent to inspect the repository, run a "
         "command or continue the thread"),
       [](World &world, const Captures &, const Table &) {
         onScreen(world, S("Ask the agent to inspect the repo, run a command, "
                           "or continue the active thread."));
       });

  // How the phone folds a settled turn.
  step(S("the agent ran three tool calls and the turn then failed"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 30);
         for (int n = 1; n <= 3; ++n)
           addCommand(world, n);
         addItem(world, S("error"),
                 {{S("id"), S("failure")},
                  {S("title"), S("The agent stopped responding.")}});
         turn(world).settlesAs = S("failed");
       });
  step(S("the three tool calls are shown one row each"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         const QList<int> work = rowsOf(model, S("work"));
         bool single = work.size() == 3;
         for (const int row : work)
           single =
               single &&
               role(model, row, TimelineModel::EntriesRole).toList().size() ==
                   1;
         expect(single, S("the calls are shown as %1").arg(describe(model)));
         for (int n = 1; n <= 3; ++n)
           onScreen(world, S("bun test cart-%1").arg(n), false);
       });
  step(S("the failure is shown after them"), [](World &world, const Captures &,
                                                const Table &) {
    TimelineModel &model = timeline(world);
    const int failure = rowShowing(world, S("failure"));
    expect(role(model, failure, TimelineModel::KindRole) == S("error") &&
               failure > lastRowOf(world, S("work")),
           S("the failure is not after the calls; %1").arg(describe(model)));
    onScreen(world, S("The agent stopped responding."), false);
  });
  step(S("no %1 row (?:hides them|is added)").arg(q),
       [](World &world, const Captures &c, const Table &) {
         expect(noFoldStartingWith(world, c[0]),
                S("a fold was added; %1").arg(describe(timeline(world))));
       });
  step(S("a turn in which the agent wrote a first reply, ran tool calls, wrote "
         "a reply in the middle and wrote a final reply"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 60);
         addReply(world, S("first"), S("I will look at the cart first."));
         addCommand(world, 1);
         addReply(world, S("middle"), S("The cart sums its lines."));
         addCommand(world, 2);
         addReply(world, S("final"), S("The cart now shows tax."));
       });
  step(S("a notice from an automation arrived during the turn"),
       [](World &world, const Captures &, const Table &) {
         addItem(world, S("notification"),
                 {{S("id"), S("notice")},
                  {S("summary"), S("Nightly checks finished")},
                  {S("outcome"), S("completed")}});
       });
  step(S("the tool calls and the reply in the middle fold behind %1").arg(q),
       [](World &world, const Captures &c, const Table &) {
         TimelineModel &model = timeline(world);
         const int fold = lastRowOf(world, S("fold"));
         expect(role(model, fold, TimelineModel::TitleRole)
                        .toString()
                        .startsWith(c[0]) &&
                    !role(model, fold, TimelineModel::ExpandedRole).toBool(),
                S("the turn does not fold; %1").arg(describe(model)));
         expect(rowsOf(model, S("work")).isEmpty() &&
                    model.indexOf(S("middle")) < 0,
                S("the calls or the middle reply are shown; %1")
                    .arg(describe(model)));
       });
  step(S("the first reply, the final reply and the notice stay shown"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         for (const QString &id : {S("first"), S("final"), S("notice")}) {
           expect(model.indexOf(id) >= 0,
                  S("%1 is not shown; %2").arg(id, describe(model)));
         }
         onScreen(world, S("I will look at the cart first."));
         onScreen(world, S("The cart now shows tax."));
       });
  step(S("the only work in a finished turn is a context compaction"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 30);
         addItem(
             world, S("compaction"),
             {{S("id"), S("compaction")}, {S("summary"), S("Earlier turns")}});
         turn(world).settlesAs = S("completed");
       });
  step(S("the compaction is shown on its own"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         const int row = rowShowing(world, S("compaction"));
         expect(role(model, row, TimelineModel::KindRole) == S("marker"),
                S("the compaction is shown as %1").arg(describe(model)));
         world.item(S("markerTitle"));
       });
  step(S("the run has ended but its last reply is still arriving"),
       [](World &world, const Captures &, const Table &) {
         startRun(world, 30);
         addCommand(world, 1);
         addReply(world, S("reply"), S("The cart"), true);
         settleRun(world, S("completed"), 30);
       });
  step(S("the turn's work is shown"),
       [](World &world, const Captures &, const Table &) {
         TimelineModel &model = timeline(world);
         expect(!rowsOf(model, S("work")).isEmpty() &&
                    rowsOf(model, S("fold")).isEmpty(),
                S("the work is not shown; %1").arg(describe(model)));
         onScreen(world, S("bun test cart-1"), false);
       });
  step(S("the reply is complete"),
       [](World &world, const Captures &, const Table &) {
         change(world, S("turn-item"), S("reply"),
                {{S("a"), QJsonObject{{S("text"), S(" now shows tax.")}}},
                 {S("s"), QJsonObject{{S("streaming"), false}}}});
       });
  step(S("the turn's work folds behind how long it took"),
       [](World &world, const Captures &, const Table &) {
         expectFolded(world, S("Worked for 30s"));
       });

  // A reply's shell command, run from its code block.
  step(S("the agent's reply has a single-line shell command in a code block"),
       [](World &world, const Captures &, const Table &) {
         replyWith(world, S("```bash\n") + kCommand + S("\n```"));
         preferScript(world);
       });
  step(S("the user runs the command from its code block"),
       [](World &world, const Captures &, const Table &) {
         world.mc.part<Before>().preferred = preferredScript(world);
         expect(world.mc.part<Before>().preferred == QLatin1String("lint"),
                S("the project offers %1 first, not lint")
                    .arg(world.mc.part<Before>().preferred));
         world.waitFor([&] { return visible(world, S("runCode")).size() == 1; },
                       [&] {
                         return S("the code block to offer Run; %1 offered")
                             .arg(visible(world, S("runCode")).size());
                       });
         tapStill(world, visible(world, S("runCode")).constFirst());
         world.sync();
       });
  step(S("the command runs in the thread's terminal in the thread's folder"),
       [](World &world, const Captures &, const Table &) {
         const QVariantMap workspace = world.state(S("workspace")).toMap();
         const QString worktree = workspace.value(S("worktreePath")).toString();
         const QString folder =
             worktree.isEmpty() ? workspace.value(S("projectRoot")).toString()
                                : worktree;
         world.waitFor(
             [&] {
               const auto &calls =
                   world.mc.part<terminalfake::FakeTerminals>().calls;
               const bool opened = std::any_of(
                   calls.begin(), calls.end(), [&](const QJsonObject &call) {
                     const QJsonObject payload =
                         call.value(QLatin1String("payload")).toObject();
                     return call.value(QLatin1String("method")) ==
                                QLatin1String("terminal.open") &&
                            payload.value(QLatin1String("threadId")) ==
                                world.thread &&
                            payload.value(QLatin1String("terminalId")) ==
                                QLatin1String("term-1") &&
                            payload.value(QLatin1String("cwd")) == folder;
                   });
               return opened && !folder.isEmpty() &&
                      terminalfake::writes(world, S("term-1")) ==
                          QStringList{kCommand + QLatin1Char('\r')};
             },
             [&] {
               return S("%1 in %2; the MC got %3")
                   .arg(kCommand, folder, terminalCalls(world));
             });
       });
  step(S("the project's selected script is not changed"),
       [](World &world, const Captures &, const Table &) {
         world.sync();
         expect(preferredScript(world) == world.mc.part<Before>().preferred,
                S("the project's script went from %1 to %2")
                    .arg(world.mc.part<Before>().preferred,
                         preferredScript(world)));
       });
  step(S("the agent's reply has (a shell command still streaming|a shell "
         "command that spans several lines|an empty shell block|"
         "a shell command ending in a backslash|a Python snippet) in a code "
         "block"),
       [](World &world, const Captures &c, const Table &) {
         if (c[0] == QLatin1String("a shell command still streaming"))
           replyWith(world, S("```bash\n") + kCommand + S("\n```"), true);
         else if (c[0] ==
                  QLatin1String("a shell command that spans several lines"))
           replyWith(world, S("```bash\nbun install\nbun test cart\n```"));
         else if (c[0] == QLatin1String("an empty shell block"))
           replyWith(world, S("```bash\n\n```"));
         else if (c[0] ==
                  QLatin1String("a shell command ending in a backslash"))
           replyWith(world, S("```bash\nbun test cart \\\n```"));
         else
           replyWith(world, S("```python\nprint(\"cart\")\n```"));
       });
  step(S("the code block offers no run action"),
       [](World &world, const Captures &, const Table &) {
         world.waitFor([&] { return !visible(world, S("copyCode")).isEmpty(); },
                       S("the code block to be drawn"));
         const qsizetype offered = visible(world, S("runCode")).size();
         expect(offered == 0,
                S("the code block offers Run %1 times").arg(offered));
       });
});

} // namespace

// "it reads" after "the thread shows a duration of": the turn's fold says how
// long it worked. False when the scenario showed no duration, for
// ToolCallSteps' activity group to read instead.
bool expectShownDuration(World &world, const QString &shown) {
  if (!turn(world).durationShown)
    return false;
  const QString title = foldTitle(world);
  expect(title == S("Worked for ") + shown,
         S("the turn's fold reads \"%1\"").arg(title));
  return true;
}

// "the turn completes" for a turn these steps started. False when they started
// none, for ToolCallSteps' turn to complete instead.
bool completeStreamedTurn(World &world) {
  if (turn(world).run.isEmpty())
    return false;
  settleRun(world, S("completed"), 60);
  return true;
}
