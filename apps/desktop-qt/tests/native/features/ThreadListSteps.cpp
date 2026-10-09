// The thread list in the domain's words: its sections and order, opening and
// scoping from it, the snoozed and settled shelves, and the state each row
// names (threads/sidebar-list.feature, threads/snooze.feature,
// threads/settle.feature, threads/unread-and-status.feature,
// threads/limited-threads.feature). What only the QML draws (the words, ages,
// folding, the keyboard) is in tst_Sidebar.qml and tst_SidebarThreadRow.qml.

#include <QJsonArray>
#include <QJsonObject>
#include <QSet>

#include "Harness.h"
#include "NavigationController.h"
#include "McClient.h"
#include "Stream.h"
#include "ThreadList.h"
#include "World.h"

namespace {

const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

// The project whose sections threads/sidebar-list.feature reads.
QString& sectionsProject() {
  static QString key;
  return key;
}

// What the list showed across a reconnect.
struct Reconnect {
  int subscriptions = 0;
  qsizetype fewest = 0;
};

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODate);
}

void putThread(World& world, const QString& id, QJsonObject row) {
  row.insert(QStringLiteral("id"), id);
  if (!row.contains(QLatin1String("createdAt"))) row.insert(QStringLiteral("createdAt"), kAt);
  if (!row.contains(QLatin1String("updatedAt"))) row.insert(QStringLiteral("updatedAt"), row.value(QLatin1String("createdAt")));
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  if (world.native().client()->isReady()) world.sync();
}

QString titleId(const QString& title) {
  return QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

bool hasThread(World& world, const QString& title) {
  for (const QJsonObject& row : std::as_const(world.mc.threads)) {
    if (row.value(QLatin1String("title")).toString() == title) return true;
  }
  return false;
}

// The thread the scenario names, in `projectId` (the first project when
// empty) unless the MC already has it.
QString ensureThread(World& world, const QString& title, QString projectId = {}) {
  if (!hasThread(world, title)) {
    if (projectId.isEmpty()) projectId = world.mc.projects.firstKey();
    putThread(world, titleId(title), {{QStringLiteral("projectId"), projectId}, {QStringLiteral("title"), title}});
  }
  return threadKeyOf(world, title);
}

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QVariantMap sidebar(World& world) {
  return world.state(QStringLiteral("sidebar")).toMap();
}

std::optional<QVariantMap> rowOf(World& world, const QString& key) {
  const QVariantMap state = sidebar(world);
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : state.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return std::nullopt;
}

// The word SidebarThreadRow shows for a row's state (tst_SidebarThreadRow.qml
// checks the row draws these): its status first, then woke, then unread.
QString wordOf(const QVariantMap& row) {
  if (row.value(QStringLiteral("offline")).toBool()) return QStringLiteral("Offline");
  static const QHash<QString, QString> words{
      {QStringLiteral("working"), QStringLiteral("Working")}, {QStringLiteral("waiting"), QStringLiteral("Waiting")},
      {QStringLiteral("approval"), QStringLiteral("Approval")}, {QStringLiteral("input"), QStringLiteral("Input")},
      {QStringLiteral("limited"), QStringLiteral("Limited")},   {QStringLiteral("failed"), QStringLiteral("Failed")},
  };
  const QString word = words.value(row.value(QStringLiteral("status")).toString());
  if (!word.isEmpty()) return word;
  if (!row.value(QStringLiteral("wokeAt")).isNull() && row.value(QStringLiteral("wokeAt")).isValid()) return QStringLiteral("Woke");
  if (row.value(QStringLiteral("unread")).toBool()) return QStringLiteral("Done");
  return {};
}

void waitForSection(World& world, const QString& thread, const QString& section) {
  const QString key = threadKeyOf(world, thread);
  world.waitFor([&] { return sidebarSectionOf(world, key) == section; },
                [&] { return QStringLiteral("%1 in %2; it is in \"%3\"").arg(thread, section, sidebarSectionOf(world, key)); });
}

// Snoozed from an hour ago until tomorrow at nine.
void snoozeUntilTomorrow(World& world, const QString& thread) {
  const QString until = iso(QDateTime(world.now().date().addDays(1), QTime(9, 0)));
  const QString since = iso(world.now().addSecs(-3600));
  updateThreadRow(world, idOf(threadKeyOf(world, thread)), [&](QJsonObject& row) {
    row.insert(QStringLiteral("snoozedUntil"), until);
    row.insert(QStringLiteral("snoozedAt"), since);
  });
}

QSet<QString> activeProjects(World& world) {
  QSet<QString> projects;
  for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList()) {
    projects.insert(row.toMap().value(QStringLiteral("projectKey")).toString());
  }
  return projects;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Backgrounds and the list's contents.
  step(QStringLiteral("a connected environment with the thread %1 on Claude").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")}, {QStringLiteral("title"), QStringLiteral("shop")},
                                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()},
                                                        {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}});
    world.connect();
    putThread(world, QStringLiteral("t1"), {{QStringLiteral("projectId"), QStringLiteral("shop")}, {QStringLiteral("title"), c[0]},
                                            {QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
                                                                                           {QStringLiteral("model"), QStringLiteral("claude-sonnet-4-5")}}}});
  });
  step(QStringLiteral("%1 has a draft, a pinned thread, two active threads, a snoozed thread and a settled thread").arg(q), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    const QString project = c[0];
    const QString later = iso(world.now().addDays(1));
    putThread(world, QStringLiteral("t-pinned"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Pinned")},
                                                  {QStringLiteral("pinnedAt"), kAt}, {QStringLiteral("pinOrderKey"), QStringLiteral("a0")}});
    putThread(world, QStringLiteral("t-first"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("First")}});
    putThread(world, QStringLiteral("t-second"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Second")}});
    putThread(world, QStringLiteral("t-snoozed"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Snoozed")},
                                                   {QStringLiteral("snoozedUntil"), later}, {QStringLiteral("snoozedAt"), kAt}});
    putThread(world, QStringLiteral("t-settled"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Settled")},
                                                   {QStringLiteral("settledOverride"), QStringLiteral("settled")}, {QStringLiteral("settledAt"), kAt}});
    // The list holds the drafts the user wrote in (drafts.feature), once left.
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(project)}});
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.draftId},
                                        {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}}},
                                        {QStringLiteral("text"), QStringLiteral("Plan the release")},
                                        {QStringLiteral("cursor"), 16}});
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, QStringLiteral("First"))}});
    sectionsProject() = world.projectKey(project);
  });
  step(QStringLiteral("%1 was created before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    putThread(world, titleId(c[0]), {{QStringLiteral("projectId"), world.mc.projects.firstKey()}, {QStringLiteral("title"), c[0]},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
    putThread(world, titleId(c[1]), {{QStringLiteral("projectId"), world.mc.projects.firstKey()}, {QStringLiteral("title"), c[1]},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  });
  step(QStringLiteral("there are (\\d+) settled threads"), [](World& world, const Captures& c, const Table&) {
    for (int index = 0; index < c[0].toInt(); ++index) {
      const QString at = iso(world.now().addSecs(-60 * (index + 1)));
      putThread(world, QStringLiteral("t-settled-%1").arg(index),
                {{QStringLiteral("projectId"), world.mc.projects.firstKey()}, {QStringLiteral("title"), QStringLiteral("Settled %1").arg(index)},
                 {QStringLiteral("settledOverride"), QStringLiteral("settled")}, {QStringLiteral("settledAt"), at}});
    }
  });
  step(QStringLiteral("%1 settled after %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Created the other way round, so only when they settled orders them.
    const QString project = world.mc.projects.firstKey();
    putThread(world, titleId(c[0]), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), c[0]}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")},
                                     {QStringLiteral("settledOverride"), QStringLiteral("settled")}, {QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:50:00Z")}});
    putThread(world, titleId(c[1]), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), c[1]}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                     {QStringLiteral("settledOverride"), QStringLiteral("settled")}, {QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:10:00Z")}});
  });
  step(QStringLiteral("%1 was renamed since").arg(q), [](World& world, const Captures& c, const Table&) {
    updateThreadRow(world, titleId(c[0]), [](QJsonObject& row) { row.insert(QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:58:00Z")); });
  });
  step(QStringLiteral("the rows for %1 and %1 count their ages from when they settled").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QString& title : {c[0], c[1]}) {
      const QString settledAt = world.mc.threads.value(titleId(title)).value(QLatin1String("settledAt")).toString();
      for (const QVariant& row : world.state(QStringLiteral("sidebar")).toMap().value(QStringLiteral("settled")).toList()) {
        if (row.toMap().value(QStringLiteral("title")) != title) continue;
        expect(row.toMap().value(QStringLiteral("timeAt")) == settledAt,
               QStringLiteral("%1 settled at %2; its row is %3").arg(title, settledAt, show(row)));
      }
    }
  });
  step(QStringLiteral("the user looks at the settled section"), [](World& world, const Captures&, const Table&) {
    world.sync();
  });

  // Opening and scoping.
  step(QStringLiteral("the user opens \"([^\"./:]*)\""), [](World& world, const Captures& c, const Table&) {
    const QString key = ensureThread(world, c[0]);
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
  });
  step(QStringLiteral("the user opens the draft"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), world.draftId}});
  });
  step(QStringLiteral("the user scopes the thread list to (all projects|%1)").arg(q), [](World& world, const Captures& c, const Table&) {
    // A thread in each project, so the scope has something to leave out.
    for (const QString& project : world.mc.projects.keys()) ensureThread(world, QStringLiteral("Work in ") + project, project);
    const QVariant scope = c.value(1).isEmpty() ? QVariant::fromValue(nullptr) : QVariant(world.projectKey(c[1]));
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), scope}});
  });

  // What the list shows.
  step(QStringLiteral("the sections read drafts, pinned, active, snoozed, settled in that order"), [](World& world, const Captures&, const Table&) {
    // Sidebar.qml draws the sections in this order (tst_Sidebar.qml).
    const QVariantMap state = sidebar(world);
    QStringList counts;
    for (const QString& section : {QStringLiteral("drafts"), QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
      QVariantList rows = state.value(section).toList();
      // The draft the window landed on (navigation/landing.feature) is another project's.
      if (section == QLatin1String("drafts")) {
        rows.removeIf([](const QVariant& row) { return row.toMap().value(QStringLiteral("projectKey")) != sectionsProject(); });
      }
      counts.append(QStringLiteral("%1 %2").arg(section).arg(rows.size()));
    }
    expect(counts.join(u", ") == QLatin1String("drafts 1, pinned 1, active 2, snoozed 1, settled 1"),
           QStringLiteral("the list holds %1").arg(counts.join(u", ")));
  });
  step(QStringLiteral("(\\d+) settled threads are shown"), [](World& world, const Captures& c, const Table&) {
    const qsizetype shown = sidebar(world).value(QStringLiteral("settled")).toList().size();
    expect(shown == c[0].toInt(), QStringLiteral("%1 settled threads are shown").arg(shown));
  });
  step(QStringLiteral("the section says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Sidebar.qml's note under the shelf.
    const QVariantMap state = sidebar(world);
    const qsizetype more = state.value(QStringLiteral("settledTotal")).toInt() - state.value(QStringLiteral("settled")).toList().size();
    const QString note = QStringLiteral("%1 more settled in the app").arg(more);
    expect(more > 0 && note == c[0], QStringLiteral("the section says \"%1\"").arg(note));
  });
  step(QStringLiteral("%1 is shown in the main view").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key &&
                               at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                  [&] { return QStringLiteral("%1 to be shown; the route is %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the draft composer is shown with its unsent text"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap route = world.state(QStringLiteral("route")).toMap();
      const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
      return route.value(QStringLiteral("kind")) == QLatin1String("draft") && route.value(QStringLiteral("draftId")) == world.draftId &&
             composer.value(QStringLiteral("target")) == world.draftId && composer.value(QStringLiteral("text")) == QLatin1String("Unsent work");
    }, [&] { return QStringLiteral("the draft; the route is %1, the composer %2").arg(show(world.state(QStringLiteral("route"))), show(world.state(QStringLiteral("composer")))); });
  });
  step(QStringLiteral("threads from %1 and %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QSet<QString> projects = activeProjects(world);
    expect(projects.contains(world.projectKey(c[0])) && projects.contains(world.projectKey(c[1])),
           QStringLiteral("the list shows %1").arg(QStringList(projects.values()).join(u", ")));
  });

  // Reconnecting: the MC's snapshot brings what the shell missed, and the rows
  // it already listed stay listed all the while.
  step(QStringLiteral("the client was disconnected while two threads were created"), [](World& world, const Captures&, const Table&) {
    const QString project = world.mc.projects.firstKey();
    putThread(world, QStringLiteral("t-earlier"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Earlier work")}});
    world.sync();
    Reconnect& state = world.mc.part<Reconnect>();
    state.subscriptions = world.shellSubscriptions();
    state.fewest = sidebar(world).value(QStringLiteral("active")).toList().size();
    QObject::connect(&world.bridge(), &ShellBridge::stateEntryChanged, &world.bridge(), [&state](const QString& key, const QVariant& value) {
      if (key == QLatin1String("sidebar")) state.fewest = std::min(state.fewest, value.toMap().value(QStringLiteral("active")).toList().size());
    });
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to notice the lost connection"));
    for (const QString& title : {QStringLiteral("Made offline one"), QStringLiteral("Made offline two")}) {
      const QString id = titleId(title);
      world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("projectId"), project}, {QStringLiteral("title"), title},
                                   {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}});
    }
  });
  step(QStringLiteral("the client reconnects"), [](World& world, const Captures&, const Table&) {
    const int before = world.mc.part<Reconnect>().subscriptions;
    world.waitFor([&] { return world.native().client()->isReady() && world.shellSubscriptions() > before; }, QStringLiteral("the shell to reconnect"));
  });
  step(QStringLiteral("both threads are listed without reloading the whole list"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : {QStringLiteral("Made offline one"), QStringLiteral("Made offline two")}) waitForSection(world, title, QStringLiteral("active"));
    const QVariantList active = sidebar(world).value(QStringLiteral("active")).toList();
    expect(active.size() == 3 && world.mc.part<Reconnect>().fewest >= 1,
           QStringLiteral("the list holds %1 threads and held as few as %2").arg(active.size()).arg(world.mc.part<Reconnect>().fewest));
  });

  step(QStringLiteral("the MC sent only the two new threads"), [](World& world, const Captures&, const Table&) {
    // The client said what it held, so nothing it had was sent again.
    QJsonObject have;
    for (const QJsonObject& sub : std::as_const(world.mc.subscriptions)) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) have = sub.value(QLatin1String("have")).toObject();
    }
    const QJsonObject frame = world.mc.shellFrames.last();
    const QJsonObject mc = frame.value(QLatin1String("mcs")).toArray().first().toObject();
    expect(world.mc.shellFrames.size() == 2 && have.value(world.mc.name).toArray().first() == world.mc.epoch &&
               mc.value(QLatin1String("reset")) == false && frame.value(QLatin1String("rows")).toArray().size() == 2,
           QStringLiteral("the client held %1 and the MC sent %2").arg(show(have.toVariantMap()), show(frame.toVariantMap())));
  });
  step(QStringLiteral("the client was disconnected while its MC restarted and lost a thread"), [](World& world, const Captures&, const Table&) {
    const QString project = world.mc.projects.firstKey();
    putThread(world, QStringLiteral("t-earlier"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Earlier work")}});
    putThread(world, QStringLiteral("t-lost"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), QStringLiteral("Lost work")}});
    world.sync();
    waitForSection(world, QStringLiteral("Lost work"), QStringLiteral("active"));
    world.mc.part<Reconnect>().subscriptions = world.shellSubscriptions();
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to notice the lost connection"));
    // Another run of the MC's shell: what a client holds of its rows is of no use.
    world.mc.epoch = QStringLiteral("epoch-2");
    world.mc.threads.remove(QStringLiteral("t-lost"));
  });
  step(QStringLiteral("the MC sent its whole list"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QJsonObject frame = world.mc.shellFrames.last();
    const QJsonObject mc = frame.value(QLatin1String("mcs")).toArray().first().toObject();
    const qsizetype rows = world.mc.threads.size() + world.mc.projects.size();
    expect(world.mc.shellFrames.size() == 2 && mc.value(QLatin1String("reset")) == true && frame.value(QLatin1String("rows")).toArray().size() == rows,
           QStringLiteral("the MC holds %1 rows and sent %2").arg(rows).arg(show(frame.toVariantMap())));
  });
  step(QStringLiteral("the lost thread is no longer listed"), [](World& world, const Captures&, const Table&) {
    QStringList titles;
    for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList()) titles.append(row.toMap().value(QStringLiteral("title")).toString());
    expect(titles == QStringList{QStringLiteral("Earlier work")}, QStringLiteral("the list holds %1").arg(titles.join(QStringLiteral(", "))));
  });

  // Snoozing.
  // A day of the week the scenarios' clock starts in (Wednesday 23 September 2026).
  step(QStringLiteral("the local time is (\\w+day) (\\d+):(\\d+)"), [](World& world, const Captures& c, const Table&) {
    QDate date(2026, 9, 21);
    while (QLocale::c().dayName(date.dayOfWeek()) != c[0]) date = date.addDays(1);
    world.setTime(QDateTime(date, QTime(c[1].toInt(), c[2].toInt())));
  });
  step(QStringLiteral("%1 is snoozed until tomorrow").arg(q), [](World& world, const Captures& c, const Table&) {
    snoozeUntilTomorrow(world, c[0]);
  });
  step(QStringLiteral("%1 is listed in the snoozed section").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForSection(world, c[0], QStringLiteral("snoozed"));
  });
  step(QStringLiteral("the row says when it will wake"), [](World& world, const Captures&, const Table&) {
    const QVariantList snoozed = sidebar(world).value(QStringLiteral("snoozed")).toList();
    expect(snoozed.size() == 1 && snoozed.first().toMap().value(QStringLiteral("wakeLabel")) == QLatin1String("23h"),
           QStringLiteral("the snoozed rows are %1").arg(show(snoozed)));
  });
  step(QStringLiteral("%1 returns to the active threads").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForSection(world, c[0], QStringLiteral("active"));
  });
  step(QStringLiteral("the user points at %1 in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    world.checkedCommands.clear();
    // Sidebar.qml shows the row's snooze action on hover (tst_Sidebar.qml);
    // choosing it opens the snooze menu at the pointer.
    const QString key = threadKeyOf(world, c[0]);
    const auto row = rowOf(world, key);
    expect(row && row->value(QStringLiteral("canSnooze")).toBool(), QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
    world.bridge().dispatch(QStringLiteral("thread.snoozeMenu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 200}, {QStringLiteral("y"), 120}});
  });
  step(QStringLiteral("the user can snooze it from there"), [](World& world, const Captures&, const Table&) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap && !at(menu, QStringLiteral("items")).toList().isEmpty(),
           QStringLiteral("the snooze menu is %1").arg(show(menu)));
  });
  step(QStringLiteral("%1 woke from a snooze").arg(q), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
      row.insert(QStringLiteral("snoozedAt"), iso(world.now().addSecs(-3 * 3600)));
      row.insert(QStringLiteral("snoozedUntil"), iso(world.now().addSecs(-3600)));
      row.insert(QStringLiteral("lastVisitedAt"), iso(world.now().addSecs(-4 * 3600)));
    });
    const auto row = rowOf(world, threadKeyOf(world, c[0]));
    expect(row && wordOf(*row) == QLatin1String("Woke"), QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("the user dismisses its woke marker"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList()) {
      if (wordOf(row.toMap()) != QLatin1String("Woke")) continue;
      world.bridge().dispatch(QStringLiteral("thread.wokeDismiss"), QVariantMap{{QStringLiteral("key"), row.toMap().value(QStringLiteral("key"))}});
      return;
    }
    fail(QStringLiteral("no row is marked as woke"));
  });
  step(QStringLiteral("%1 is no longer marked as woke").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    world.waitFor([&] {
      const auto row = rowOf(world, key);
      return row && wordOf(*row) != QLatin1String("Woke");
    }, [&] { return QStringLiteral("the woke marker to go; the row is %1").arg(show(rowOf(world, key).value_or(QVariantMap()))); });
  });

  // Settling.
  step(QStringLiteral("%1 moves to the settled section").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForSection(world, c[0], QStringLiteral("settled"));
  });
  step(QStringLiteral("%1 is settled").arg(q), [](World& world, const Captures& c, const Table&) {
    if (world.checking) return waitForSection(world, c[0], QStringLiteral("settled"));
    // Another thread began since, so un-settling has to lift it above one.
    putThread(world, QStringLiteral("t-newer"), {{QStringLiteral("projectId"), world.mc.projects.firstKey()}, {QStringLiteral("title"), QStringLiteral("Newer")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}});
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [](QJsonObject& row) {
      row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
      row.insert(QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:40:00Z"));
    });
    waitForSection(world, c[0], QStringLiteral("settled"));
  });
  step(QStringLiteral("%1 returns to the top of the active threads").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    world.waitFor([&] {
      const QVariantList active = sidebar(world).value(QStringLiteral("active")).toList();
      return active.size() > 1 && active.first().toMap().value(QStringLiteral("key")) == key;
    }, [&] { return QStringLiteral("%1 on top; the active threads are %2").arg(key, show(sidebar(world).value(QStringLiteral("active")))); });
  });
  step(QStringLiteral("the pull request is merged on GitHub"), [](World& world, const Captures&, const Table&) {
    // The MC settles a thread whose pull request merged (HalC2.Orchestration.Settlement).
    const QString id = world.mc.threads.firstKey();
    updateThreadRow(world, id, [&](QJsonObject& row) {
      row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
      row.insert(QStringLiteral("settledAt"), iso(world.now()));
    });
  });
  step(QStringLiteral("%1 moves to the settled section without the user settling it").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForSection(world, c[0], QStringLiteral("settled"));
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("type")) != QLatin1String("thread.settle"), QStringLiteral("the MC has %1").arg(world.describeCommands()));
    }
  });

  // The state a row names.
  step(QStringLiteral("%1 (has an agent working|has a queued turn waiting to start|is waiting for an approval|is waiting for an answer to a question|"
                      "has hit a usage limit|stopped on a usage limit|had its last run fail|woke early from a snooze|finished work the user has not seen)")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString state = c[1];
         const QDateTime now = world.now();
         updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
           const auto run = [&](const QString& status) {
             row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
             row.insert(QStringLiteral("status"), status);
             row.insert(QStringLiteral("latestRunStartedAt"), iso(now.addSecs(-900)));
           };
           const auto finished = [&](const QString& visitedAt) {
             run(QStringLiteral("completed"));
             row.insert(QStringLiteral("latestRunCompletedAt"), iso(now.addSecs(-600)));
             // The MC stamps the thread when its run ends.
             row.insert(QStringLiteral("updatedAt"), iso(now.addSecs(-600)));
             row.insert(QStringLiteral("lastVisitedAt"), visitedAt);
           };
           if (state == QLatin1String("has an agent working")) {
             run(QStringLiteral("running"));
             row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
           } else if (state == QLatin1String("has a queued turn waiting to start")) {
             // The session is up and idle; the queued turn has not started a run.
             row.insert(QStringLiteral("activeProviderThreadId"), QStringLiteral("p1"));
             row.insert(QStringLiteral("status"), QStringLiteral("idle"));
           } else if (state.startsWith(QLatin1String("is waiting for an"))) {
             run(QStringLiteral("running"));
             const bool question = state.endsWith(QLatin1String("question"));
             row.insert(QStringLiteral("pendingRuntimeRequest"),
                        QJsonObject{{QStringLiteral("id"), QStringLiteral("q1")},
                                    {QStringLiteral("kind"), question ? QStringLiteral("user_input") : QStringLiteral("command_approval")},
                                    {QStringLiteral("createdAt"), iso(now.addSecs(-60))}});
           } else if (state.contains(QLatin1String("usage limit"))) {
             run(QStringLiteral("failed"));
             row.insert(QStringLiteral("lastErrorClass"), QStringLiteral("usage_limit"));
           } else if (state == QLatin1String("had its last run fail")) {
             run(QStringLiteral("failed"));
           } else if (state == QLatin1String("woke early from a snooze")) {
             // Snoozed until tomorrow, but its run finished after the snooze.
             finished(iso(now.addSecs(-3 * 3600)));
             row.insert(QStringLiteral("snoozedAt"), iso(now.addSecs(-2 * 3600)));
             row.insert(QStringLiteral("snoozedUntil"), iso(now.addDays(1)));
           } else {
             finished(iso(now.addSecs(-3600)));
           }
         });
         // The conversation holds what the agent said when it stopped on the limit.
         if (state.contains(QLatin1String("usage limit"))) {
           stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
           streams.thread = idOf(threadKeyOf(world, c[0]));
           streams.environment = world.mc.environmentId;
           stream::startRun(world, 900, QStringLiteral("failed"));
           stream::addItem(world, QStringLiteral("error"),
                           {{QStringLiteral("status"), QStringLiteral("failed")},
                            {QStringLiteral("failure"), QJsonObject{{QStringLiteral("class"), QStringLiteral("usage_limit")},
                                                                    {QStringLiteral("message"), QStringLiteral("You've hit your usage limit. It resets at 2:00 PM.")}}}});
         }
       });
  step(QStringLiteral("the row for %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto row = rowOf(world, threadKeyOf(world, c[0]));
    expect(row && wordOf(*row) == c[1], QStringLiteral("the row reads \"%1\": %2").arg(row ? wordOf(*row) : QString(), show(row.value_or(QVariantMap()))));
  });
});

}  // namespace
