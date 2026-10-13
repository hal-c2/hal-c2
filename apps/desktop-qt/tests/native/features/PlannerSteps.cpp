// The planner plugin's own UI (features/planning/planner.feature): its real package
// from plugins/planner, drawn by the desktop against a fake of its MC part that
// publishes `plan`, `runs` and `threads` as the MC part does and answers the calls
// the UI makes.

#include <algorithm>

#include <QDate>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>

#include "Harness.h"
#include "Plugins.h"
#include "SharedSteps.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("planner");
const QString kProject = QStringLiteral("p1");
const QString kToday = QStringLiteral("2026-10-20");

QString package() { return QDir(QStringLiteral(HAL_C2_FEATURES_DIR "/../plugins/planner")).absolutePath(); }

// The MC part's state: its settings, the plan and the runs of its actions.
struct FakePlanner {
  QJsonObject settings;
  // The manifest's actions, which the settings reset a prompt to.
  QJsonObject defaultActions;
  // How many `plugins.saveSettings` calls are in `settings` already.
  qsizetype merged = 0;
  QStringList order;
  QHash<QString, QJsonObject> items;
  QJsonArray views;
  QList<QJsonObject> runs;
  bool slack = false;
  // The GitHub boards `boards` lists, and each one's date fields by `owner/number`.
  QJsonArray boards;
  QHash<QString, QJsonArray> dateFields;
  int next = 0;
};

QString dump(const QJsonValue& value) {
  if (value.isObject()) return QString::fromUtf8(QJsonDocument(value.toObject()).toJson(QJsonDocument::Compact));
  if (value.isArray()) return QString::fromUtf8(QJsonDocument(value.toArray()).toJson(QJsonDocument::Compact));
  return value.toVariant().toString();
}

FakePlanner& state(World& world) { return world.mc.part<FakePlanner>(); }

QString nextId(World& world, const QString& prefix) { return prefix + QString::number(++state(world).next); }

QJsonObject view(const QString& id, const QString& name, const QString& layout, const QJsonObject& fields = {}) {
  QJsonObject view{{QStringLiteral("id"), id},
                   {QStringLiteral("name"), name},
                   {QStringLiteral("layout"), layout},
                   {QStringLiteral("filter"), QJsonObject{{QStringLiteral("text"), QString()},
                                                          {QStringLiteral("statuses"), QJsonArray()},
                                                          {QStringLiteral("labels"), QJsonArray()},
                                                          {QStringLiteral("projects"), QJsonArray()},
                                                          {QStringLiteral("owners"), QJsonArray()},
                                                          {QStringLiteral("hideDone"), false}}},
                   {QStringLiteral("groupBy"), QStringLiteral("none")},
                   {QStringLiteral("sortBy"), QStringLiteral("manual")},
                   {QStringLiteral("zoom"), QStringLiteral("week")},
                   {QStringLiteral("fields"), QJsonArray{QStringLiteral("status"), QStringLiteral("owner"), QStringLiteral("start"), QStringLiteral("due"), QStringLiteral("progress")}},
                   {QStringLiteral("showDependencies"), true},
                   {QStringLiteral("showBaseline"), false}};
  for (auto it = fields.begin(); it != fields.end(); ++it) view.insert(it.key(), it.value());
  return view;
}

// The views a new plan has, as the MC part makes them.
QJsonArray defaultViews() {
  return {view(QStringLiteral("timeline"), QStringLiteral("Timeline"), QStringLiteral("gantt")),
          view(QStringLiteral("board"), QStringLiteral("Board"), QStringLiteral("board"), {{QStringLiteral("groupBy"), QStringLiteral("status")}}),
          view(QStringLiteral("list"), QStringLiteral("All tasks"), QStringLiteral("list"))};
}

QString idOf(World& world, const QString& title) {
  const FakePlanner& fake = state(world);
  for (const QString& id : fake.order) {
    if (fake.items.value(id).value(QLatin1String("title")) == title) return id;
  }
  return {};
}

// The task `title`, added to the plan in "api" when it has none.
QJsonObject& item(World& world, const QString& title) {
  FakePlanner& fake = state(world);
  QString id = idOf(world, title);
  if (id.isEmpty()) {
    id = nextId(world, QStringLiteral("t"));
    fake.order.append(id);
    fake.items.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                      {QStringLiteral("title"), title},
                                      {QStringLiteral("notes"), QString()},
                                      {QStringLiteral("kind"), QStringLiteral("task")},
                                      {QStringLiteral("status"), QStringLiteral("todo")},
                                      {QStringLiteral("start"), QJsonValue::Null},
                                      {QStringLiteral("due"), QJsonValue::Null},
                                      {QStringLiteral("progress"), QJsonValue::Null},
                                      {QStringLiteral("parent"), QJsonValue::Null},
                                      {QStringLiteral("after"), QJsonArray()},
                                      {QStringLiteral("labels"), QJsonArray()},
                                      {QStringLiteral("owner"), QJsonValue::Null},
                                      {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("order"), fake.order.size()},
                                      {QStringLiteral("issue"), QJsonValue::Null},
                                      {QStringLiteral("pullRequests"), QJsonArray()},
                                      {QStringLiteral("threads"), QJsonArray()},
                                      {QStringLiteral("feedback"), QJsonArray()},
                                      {QStringLiteral("baseline"), QJsonValue::Null},
                                      {QStringLiteral("syncError"), QJsonValue::Null}});
  }
  return fake.items[id];
}

QJsonObject& dated(World& world, const QString& title, const QString& start, const QString& due) {
  QJsonObject& task = item(world, title);
  task.insert(QStringLiteral("start"), start);
  task.insert(QStringLiteral("due"), due);
  return task;
}

// A plan to look at when a scenario gives none: two tasks of "api".
void seedWhenEmpty(World& world) {
  if (!state(world).order.isEmpty()) return;
  QJsonObject& limits = dated(world, QStringLiteral("Rate limits"), QStringLiteral("2026-10-19"), QStringLiteral("2026-10-30"));
  limits.insert(QStringLiteral("owner"), QStringLiteral("sam"));
  limits.insert(QStringLiteral("labels"), QJsonArray{QStringLiteral("backend")});
  QJsonObject& docs = dated(world, QStringLiteral("Docs"), QStringLiteral("2026-11-02"), QStringLiteral("2026-11-06"));
  docs.insert(QStringLiteral("owner"), QStringLiteral("dana"));
}

QString actionId(World& world, const QString& label) {
  const QJsonObject actions = state(world).settings.value(QLatin1String("actions")).toObject();
  for (auto it = actions.begin(); it != actions.end(); ++it) {
    if (it.value().toObject().value(QLatin1String("label")) == label) return it.key();
  }
  fail(QStringLiteral("planner has no action %1").arg(label));
}

// What the MC part derives for each item: late, early, its progress, its subtasks.
QJsonArray derived(World& world) {
  const FakePlanner& fake = state(world);
  QJsonArray items;
  for (const QString& id : fake.order) {
    QJsonObject task = fake.items.value(id);
    const QString status = task.value(QLatin1String("status")).toString();
    const QString start = task.value(QLatin1String("start")).toString();
    const QString due = task.value(QLatin1String("due")).toString();
    QJsonArray early;
    for (const QJsonValue& before : task.value(QLatin1String("after")).toArray()) {
      const QString ends = fake.items.value(before.toString()).value(QLatin1String("due")).toString();
      if (!start.isEmpty() && !ends.isEmpty() && ends >= start) early.append(before);
    }
    int children = 0;
    for (const QJsonObject& other : fake.items) children += other.value(QLatin1String("parent")) == id ? 1 : 0;
    const QJsonValue progress = task.value(QLatin1String("progress"));
    task.insert(QStringLiteral("late"), !due.isEmpty() && due < kToday && status != QLatin1String("done") && status != QLatin1String("dropped"));
    task.insert(QStringLiteral("early"), early);
    task.insert(QStringLiteral("derivedProgress"), progress.isDouble() ? progress.toInt() : status == QLatin1String("done") ? 100 : 0);
    task.insert(QStringLiteral("slip"), QJsonValue::Null);
    task.insert(QStringLiteral("children"), children);
    items.append(task);
  }
  return items;
}

// A run's thread as `threads` has it: what its mark and header show.
QJsonObject threadOf(World& world, const QJsonObject& run) {
  QJsonArray titles;
  const QJsonArray itemIds = run.value(QLatin1String("itemIds")).toArray();
  for (const QJsonValue& id : itemIds) titles.append(state(world).items.value(id.toString()).value(QLatin1String("title")));
  const QJsonArray changes = run.value(QLatin1String("changes")).toArray();
  const auto kept = std::count_if(changes.begin(), changes.end(), [](const QJsonValue& each) { return !each.toObject().value(QLatin1String("dismissed")).toBool(); });
  const bool work = run.value(QLatin1String("kind")) == QLatin1String("work");
  return {{QStringLiteral("runId"), run.value(QLatin1String("id"))},
          {QStringLiteral("kind"), run.value(QLatin1String("kind"))},
          {QStringLiteral("label"), run.value(QLatin1String("label"))},
          {QStringLiteral("status"), run.value(QLatin1String("status"))},
          {QStringLiteral("items"), titles},
          {QStringLiteral("changes"), qint64(kept)},
          {QStringLiteral("health"), run.value(QLatin1String("health"))},
          {QStringLiteral("itemId"), work && !itemIds.isEmpty() ? itemIds.first() : QJsonValue()}};
}

// What the MC part publishes: the plan, the runs, and each run's thread.
void publish(World& world) {
  FakePlanner& fake = state(world);
  QJsonArray actions;
  const QJsonObject configured = fake.settings.value(QLatin1String("actions")).toObject();
  for (auto it = configured.begin(); it != configured.end(); ++it) {
    const QJsonObject action = it.value().toObject();
    actions.append(QJsonObject{{QStringLiteral("id"), it.key()},
                               {QStringLiteral("label"), action.value(QLatin1String("label"))},
                               {QStringLiteral("scope"), action.value(QLatin1String("scope"))},
                               {QStringLiteral("kind"), action.value(QLatin1String("kind"))},
                               {QStringLiteral("apply"), action.value(QLatin1String("apply"))}});
  }
  QJsonArray runs;
  QJsonObject threads;
  for (const QJsonObject& run : std::as_const(fake.runs)) {
    runs.append(run);
    const QString thread = run.value(QLatin1String("threadId")).toString();
    if (!thread.isEmpty()) threads.insert(thread, threadOf(world, run));
  }
  FakePluginPart& part = fakePluginPart(world, kId);
  part.topics.insert(QStringLiteral("plan"),
                     QJsonObject{{QStringLiteral("items"), derived(world)},
                                 {QStringLiteral("views"), fake.views},
                                 {QStringLiteral("updates"), QJsonArray()},
                                 {QStringLiteral("today"), kToday},
                                 {QStringLiteral("actions"), actions},
                                 {QStringLiteral("projects"), QJsonArray{QJsonObject{{QStringLiteral("id"), kProject},
                                                                                     {QStringLiteral("title"), QStringLiteral("api")},
                                                                                     {QStringLiteral("repository"), QStringLiteral("acme/api")}}}},
                                 {QStringLiteral("sync"), QJsonObject{{QStringLiteral("repositories"), fake.settings.value(QLatin1String("repositories"))},
                                                                      {QStringLiteral("board"), fake.settings.value(QLatin1String("board"))},
                                                                      {QStringLiteral("mode"), fake.settings.value(QLatin1String("sync"))},
                                                                      {QStringLiteral("problem"), QJsonValue::Null},
                                                                      {QStringLiteral("unwatched"), QJsonArray()},
                                                                      {QStringLiteral("checkedAt"), QJsonValue::Null},
                                                                      {QStringLiteral("slack"), QJsonObject{{QStringLiteral("channel"), fake.settings.value(QLatin1String("slackChannel")).toString().isEmpty() ? QJsonValue() : QJsonValue(fake.settings.value(QLatin1String("slackChannel")).toString())},
                                                                                                    {QStringLiteral("problem"), QJsonValue::Null}}}}},
                                 {QStringLiteral("planFeedback"), QJsonArray()}});
  part.topics.insert(QStringLiteral("runs"), QJsonObject{{QStringLiteral("runs"), runs}});
  part.topics.insert(QStringLiteral("threads"), threads);
  for (const char* topic : {"plan", "runs", "threads"}) publishTopic(world, kId, QLatin1String(topic));
}

// A run of the action `label` on `titles` (none for the whole plan), with its thread.
QJsonObject& addRun(World& world, const QString& label, const QStringList& titles, const QString& status) {
  FakePlanner& fake = state(world);
  QJsonArray itemIds;
  for (const QString& title : titles) itemIds.append(item(world, title).value(QLatin1String("id")));
  const QString id = nextId(world, QStringLiteral("r"));
  fake.runs.append(QJsonObject{{QStringLiteral("id"), id},
                               {QStringLiteral("action"), actionId(world, label)},
                               {QStringLiteral("label"), label},
                               {QStringLiteral("kind"), QStringLiteral("action")},
                               {QStringLiteral("status"), status},
                               {QStringLiteral("itemIds"), itemIds},
                               {QStringLiteral("projectId"), kProject},
                               {QStringLiteral("threadId"), QStringLiteral("t-run-%1").arg(id)},
                               {QStringLiteral("startedAt"), QStringLiteral("2026-10-20T09:00:00Z")},
                               {QStringLiteral("summary"), QString()},
                               {QStringLiteral("feedback"), QJsonArray()},
                               {QStringLiteral("changes"), QJsonArray()}});
  return fake.runs.last();
}

// The run's thread, in the thread list unless the plugin shows its runs only on its page.
void listThread(World& world, const QJsonObject& run) {
  const bool listed = state(world).settings.value(QLatin1String("display")) != QLatin1String("page");
  addPluginThread(world, run.value(QLatin1String("threadId")).toString(), run.value(QLatin1String("label")).toString(),
                  {{QStringLiteral("id"), kId}, {QStringLiteral("kind"), QStringLiteral("action")}, {QStringLiteral("listed"), listed}});
}

// The run proposing that `title` ends on `due`.
QJsonObject& propose(World& world, const QString& label, const QString& title, const QString& due) {
  QJsonObject& task = item(world, title);
  if (task.value(QLatin1String("due")).isNull()) dated(world, title, QStringLiteral("2026-10-21"), QStringLiteral("2026-10-30"));
  QJsonObject& run = addRun(world, label, {}, QStringLiteral("proposed"));
  run.insert(QStringLiteral("summary"), QStringLiteral("Schema slipped, so API moves."));
  run.insert(QStringLiteral("changes"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("c1")},
                                                               {QStringLiteral("op"), QStringLiteral("update")},
                                                               {QStringLiteral("itemId"), task.value(QLatin1String("id"))},
                                                               {QStringLiteral("fields"), QJsonObject{{QStringLiteral("due"), due}}},
                                                               {QStringLiteral("reason"), QStringLiteral("Schema slipped")},
                                                               {QStringLiteral("dismissed"), false}}});
  return run;
}

QJsonObject manifest() {
  QFile file(QDir(package()).filePath(QStringLiteral("plugin.json")));
  expect(file.open(QIODevice::ReadOnly), QStringLiteral("%1 cannot be read").arg(file.fileName()));
  return QJsonDocument::fromJson(file.readAll()).object();
}

// The plugin as the MC lists it: its manifest, running with its permissions granted.
QJsonObject entry(const QJsonObject& manifest, const QJsonObject& settings) {
  QJsonArray permissions;
  for (const QJsonValue& each : manifest.value(QLatin1String("permissions")).toArray()) {
    QJsonObject permission = each.toObject();
    permission.insert(QStringLiteral("label"), permission.value(QLatin1String("id")));
    permission.insert(QStringLiteral("granted"), true);
    permissions.append(permission);
  }
  return {{QStringLiteral("id"), kId},
          {QStringLiteral("name"), manifest.value(QLatin1String("name"))},
          {QStringLiteral("version"), manifest.value(QLatin1String("version"))},
          {QStringLiteral("description"), manifest.value(QLatin1String("description"))},
          {QStringLiteral("author"), manifest.value(QLatin1String("author"))},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("error"), QJsonValue::Null},
          {QStringLiteral("lastError"), QJsonValue::Null},
          {QStringLiteral("revision"), QStringLiteral("1")},
          {QStringLiteral("runsCode"), true},
          {QStringLiteral("permissions"), permissions},
          {QStringLiteral("settingsSchema"), manifest.value(QLatin1String("settings"))},
          {QStringLiteral("settings"), settings},
          {QStringLiteral("contributes"), manifest.value(QLatin1String("contributes"))}};
}

// The settings each `plugins.saveSettings` since the last look sent, as the MC
// part keeps them: a key sent as null goes back to the plugin's.
void mergeSaved(World& world) {
  FakePlanner& fake = state(world);
  QList<QJsonObject> saves;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("plugins.saveSettings")) saves.append(rpc.payload.value(QLatin1String("settings")).toObject());
  }
  QJsonObject defaults;
  for (const QJsonValue& each : manifest().value(QLatin1String("settings")).toArray()) defaults.insert(each.toObject().value(QLatin1String("key")).toString(), each.toObject().value(QLatin1String("default")));
  for (; fake.merged < saves.size(); ++fake.merged) {
    const QJsonObject& saved = saves.at(fake.merged);
    for (auto it = saved.begin(); it != saved.end(); ++it) fake.settings.insert(it.key(), it.value().isNull() ? defaults.value(it.key()) : it.value());
  }
}

QJsonObject* runById(World& world, const QJsonValue& id) {
  for (QJsonObject& run : state(world).runs) {
    if (run.value(QLatin1String("id")) == id) return &run;
  }
  return nullptr;
}

// The calls the UI makes, answered as the MC part answers them.
void answer(World& world, const FakeMc::Rpc& rpc) {
  FakePlanner& fake = state(world);
  const QString method = rpc.payload.value(QLatin1String("method")).toString();
  const QJsonObject input = rpc.payload.value(QLatin1String("input")).toObject();
  if (method == QLatin1String("settings")) {
    mergeSaved(world);
    QJsonArray channels;
    if (fake.slack) {
      channels = {QJsonObject{{QStringLiteral("id"), QStringLiteral("C1")}, {QStringLiteral("name"), QStringLiteral("planning")}},
                  QJsonObject{{QStringLiteral("id"), QStringLiteral("C2")}, {QStringLiteral("name"), QStringLiteral("releases")}}};
    }
    return world.mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), fake.settings},
                                           {QStringLiteral("defaultActions"), fake.defaultActions},
                                           {QStringLiteral("providers"), QJsonArray{QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
                                                                                                {QStringLiteral("name"), QStringLiteral("Claude")},
                                                                                                {QStringLiteral("models"), QJsonArray()}}}},
                                           {QStringLiteral("projects"), QJsonArray{QJsonObject{{QStringLiteral("id"), kProject}, {QStringLiteral("title"), QStringLiteral("api")}}}},
                                           {QStringLiteral("repositories"), QJsonArray{QStringLiteral("acme/api")}},
                                           {QStringLiteral("slackChannels"), channels},
                                           {QStringLiteral("slackConnected"), fake.slack}});
  }
  if (method == QLatin1String("boards")) return world.mc.reply(rpc, QJsonObject{{QStringLiteral("boards"), fake.boards}, {QStringLiteral("problems"), QJsonArray()}});
  if (method == QLatin1String("boardFields")) {
    const QString board = input.value(QLatin1String("board")).toString();
    if (!fake.dateFields.contains(board)) return world.mc.refuse(rpc, QStringLiteral("%1 was not found.").arg(board));
    return world.mc.reply(rpc, QJsonObject{{QStringLiteral("dateFields"), fake.dateFields.value(board)}});
  }
  QJsonValue result = QJsonValue::Null;
  const QString id = input.value(QLatin1String("id")).toString();
  if (method == QLatin1String("updateItem") || method == QLatin1String("addItem")) {
    if (method == QLatin1String("updateItem") && !fake.items.contains(id)) return world.mc.refuse(rpc, QStringLiteral("No task %1.").arg(id));
    QJsonObject& task = method == QLatin1String("addItem") ? item(world, input.value(QLatin1String("fields")).toObject().value(QLatin1String("title")).toString()) : fake.items[id];
    const QJsonObject fields = input.value(QLatin1String("fields")).toObject();
    for (auto it = fields.begin(); it != fields.end(); ++it) task.insert(it.key(), it.value());
    result = QJsonObject{{QStringLiteral("item"), task}};
  } else if (method == QLatin1String("removeItem")) {
    fake.items.remove(id);
    fake.order.removeAll(id);
  } else if (method == QLatin1String("saveView")) {
    QJsonObject saved = input.value(QLatin1String("view")).toObject();
    if (!saved.contains(QLatin1String("id"))) saved.insert(QStringLiteral("id"), nextId(world, QStringLiteral("v")));
    saved = view(saved.value(QLatin1String("id")).toString(), saved.value(QLatin1String("name")).toString(), saved.value(QLatin1String("layout")).toString(), saved);
    bool replaced = false;
    for (QJsonValueRef each : fake.views) {
      if (each.toObject().value(QLatin1String("id")) == saved.value(QLatin1String("id"))) {
        each = saved;
        replaced = true;
      }
    }
    if (!replaced) fake.views.append(saved);
    result = QJsonObject{{QStringLiteral("view"), saved}};
  } else if (method == QLatin1String("run")) {
    const QString action = input.value(QLatin1String("action")).toString();
    const QJsonObject configured = fake.settings.value(QLatin1String("actions")).toObject().value(action).toObject();
    if (configured.isEmpty()) return world.mc.refuse(rpc, QStringLiteral("No action %1.").arg(action));
    QStringList titles;
    for (const QJsonValue& each : input.value(QLatin1String("itemIds")).toArray()) titles.append(fake.items.value(each.toString()).value(QLatin1String("title")).toString());
    result = QJsonObject{{QStringLiteral("run"), addRun(world, configured.value(QLatin1String("label")).toString(), titles, QStringLiteral("running"))}};
  } else if (QJsonObject* run = runById(world, input.value(QLatin1String("runId")))) {
    if (method == QLatin1String("dismissChange")) {
      QJsonArray changes = run->value(QLatin1String("changes")).toArray();
      for (QJsonValueRef each : changes) {
        QJsonObject change = each.toObject();
        if (change.value(QLatin1String("id")) == input.value(QLatin1String("changeId"))) change.insert(QStringLiteral("dismissed"), input.value(QLatin1String("dismissed")));
        each = change;
      }
      run->insert(QStringLiteral("changes"), changes);
    } else if (method == QLatin1String("apply")) {
      for (const QJsonValue& each : run->value(QLatin1String("changes")).toArray()) {
        const QJsonObject change = each.toObject();
        const QString target = change.value(QLatin1String("itemId")).toString();
        if (change.value(QLatin1String("dismissed")).toBool() || !fake.items.contains(target)) continue;
        const QJsonObject fields = change.value(QLatin1String("fields")).toObject();
        for (auto it = fields.begin(); it != fields.end(); ++it) fake.items[target].insert(it.key(), it.value());
      }
      run->insert(QStringLiteral("status"), QStringLiteral("applied"));
    } else if (method == QLatin1String("discard")) {
      fake.runs.removeIf([&](const QJsonObject& each) { return each.value(QLatin1String("id")) == input.value(QLatin1String("runId")); });
    } else {
      return world.mc.refuse(rpc, QStringLiteral("no such call"));
    }
  } else {
    return world.mc.refuse(rpc, QStringLiteral("no such call"));
  }
  world.mc.reply(rpc, result);
  publish(world);
}

// The calls of `method` the UI made, with their input.
QList<QJsonObject> asked(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("plugins.call") && rpc.payload.value(QLatin1String("method")) == method) found.append(rpc.payload.value(QLatin1String("input")).toObject());
  }
  return found;
}

QString showAsked(World& world, const QString& method) {
  QJsonArray all;
  for (const QJsonObject& each : asked(world, method)) all.append(each);
  return dump(all);
}

void waitAsked(World& world, const QString& method, const QJsonObject& input) {
  world.waitFor([&] { return asked(world, method).contains(input); },
                [&] { return QStringLiteral("%1 %2 to be asked, not %3").arg(method, dump(input), showAsked(world, method)); });
}

void click(World& world, QQuickItem* item) {
  world.waitFor([&] { return item->isEnabled(); }, QStringLiteral("%1 to be enabled").arg(item->objectName()));
  clickItem(world, item);
}

QString textOf(World& world, const QString& objectName) { return waitShownNamed(world, objectName)->property("text").toString(); }

void waitText(World& world, const QString& objectName, const QString& text) {
  world.waitFor([&] { return textOf(world, objectName) == text; },
                [&] { return QStringLiteral("%1 to say %2, not %3").arg(objectName, text, textOf(world, objectName)); });
}

// Whether no item named `objectName` is shown.
bool hidden(World& world, const QString& objectName) {
  QQuickItem* found = findNamed(pluginShell(world)->contentItem(), objectName);
  return found == nullptr || !found->isVisible();
}

void waitHidden(World& world, const QString& objectName) { world.waitFor([&] { return hidden(world, objectName); }, QStringLiteral("%1 to be hidden").arg(objectName)); }

// The Planner tab, on the view `name` when one is given.
QQuickItem* showPlanner(World& world, const QString& name = {}) {
  switchToTab(world, QStringLiteral("Planner"));
  // A page that cannot load says why instead.
  world.waitFor([&] { return !hidden(world, QStringLiteral("plannerPage")) || !hidden(world, QStringLiteral("pluginPageProblem")); }, QStringLiteral("the Planner page to load"));
  if (!hidden(world, QStringLiteral("pluginPageProblem"))) fail(textOf(world, QStringLiteral("pluginPageProblem")));
  QQuickItem* page = waitShownNamed(world, QStringLiteral("plannerPage"));
  const auto viewName = [&] { return page->property("working").toMap().value(QStringLiteral("name")).toString(); };
  if (!name.isEmpty() && viewName() != name) click(world, waitShownNamed(world, QStringLiteral("plannerView:") + name));
  if (!name.isEmpty()) world.waitFor([&] { return viewName() == name; }, [&] { return QStringLiteral("the view %1 to be shown, not %2").arg(name, viewName()); });
  return page;
}

qreal dayWidth(World& world) { return waitShownNamed(world, QStringLiteral("plannerGantt"))->property("dayWidth").toReal(); }

// The user presses `item` at its centre, moves the mouse by `by` in steps and lets go.
void drag(World& world, QQuickItem* item, QPointF by) {
  QQuickWindow* window = pluginShell(world);
  const QPoint from = item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
  QTest::mousePress(window, Qt::LeftButton, Qt::NoModifier, from);
  for (int i = 1; i <= 8; ++i) QTest::mouseMove(window, from + (by * i / 8).toPoint());
  QTest::mouseRelease(window, Qt::LeftButton, Qt::NoModifier, from + by.toPoint());
  world.sync();
}

QDate date(const QString& iso) { return QDate::fromString(iso, Qt::ISODate); }

QString iso(const QDate& day) { return day.toString(Qt::ISODate); }

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("an MC running the plugin %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kId, QStringLiteral("only %1 is faked").arg(kId));
    const QJsonObject read = manifest();
    QJsonObject settings;
    for (const QJsonValue& each : read.value(QLatin1String("settings")).toArray()) {
      settings.insert(each.toObject().value(QLatin1String("key")).toString(), each.toObject().value(QLatin1String("default")));
    }
    FakePlanner& fake = state(world);
    fake.defaultActions = settings.value(QLatin1String("actions")).toObject();
    // One prompt the user changed, for the settings to reset to the plugin's.
    QJsonObject actions = fake.defaultActions;
    QJsonObject feedback = actions.value(QLatin1String("feedback")).toObject();
    feedback.insert(QStringLiteral("prompt"), QStringLiteral("My own feedback prompt."));
    actions.insert(QStringLiteral("feedback"), feedback);
    settings.insert(QStringLiteral("actions"), actions);
    fake.settings = settings;
    fake.views = defaultViews();
    FakePluginPart part;
    part.package = package();
    part.call = [&world](const FakeMc::Rpc& rpc) { answer(world, rpc); };
    runFakePlugin(world, entry(read, settings), part);
    publish(world);
  });

  step(QStringLiteral("the plan has %1 from %1 to %1, %1 waiting for it, and the milestone %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString first = dated(world, c[0], c[1], c[2]).value(QLatin1String("id")).toString();
    const QDate after = date(c[2]).addDays(3);
    QJsonObject& waiting = dated(world, c[3], iso(after), iso(after.addDays(4)));
    waiting.insert(QStringLiteral("after"), QJsonArray{first});
    QJsonObject& milestone = item(world, c[4]);
    milestone.insert(QStringLiteral("kind"), QStringLiteral("milestone"));
    milestone.insert(QStringLiteral("due"), iso(after.addDays(14)));
    publish(world);
  });
  step(QStringLiteral("the user switches to the %1 tab with the view %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("Planner"), QStringLiteral("planner has no tab %1").arg(c[0]));
    showPlanner(world, c[1]);
  });
  step(QStringLiteral("%1 and %1 are bars on the timeline with an arrow from %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* first = waitShownNamed(world, QStringLiteral("plannerBar:") + c[0]);
    QQuickItem* second = waitShownNamed(world, QStringLiteral("plannerBar:") + c[1]);
    expect(second->mapToScene(QPointF()).x() > first->mapToScene(QPointF(first->width(), 0)).x(), QStringLiteral("%1 does not start after %2 ends").arg(c[1], c[0]));
    waitShownNamed(world, QStringLiteral("plannerArrow:%1->%2").arg(c[2], c[3]));
  });
  step(QStringLiteral("%1 is a milestone marker and today is marked").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShownNamed(world, QStringLiteral("plannerMilestone:") + c[0]);
    QQuickItem* today = waitShownNamed(world, QStringLiteral("plannerToday"));
    // Today is the second day of the first task's bar.
    const QJsonObject first = state(world).items.value(state(world).order.first());
    QQuickItem* bar = waitShownNamed(world, QStringLiteral("plannerBar:") + first.value(QLatin1String("title")).toString());
    const qreal at = today->mapToScene(QPointF(today->width() / 2, 0)).x();
    const qreal start = bar->mapToScene(QPointF()).x();
    const qreal day = dayWidth(world);
    expect(at > start + day && at < start + 2 * day, QStringLiteral("today is drawn at %1, not on the bar's second day from %2").arg(at).arg(start));
  });

  step(QStringLiteral("the plan has %1 from %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dated(world, c[0], c[1], c[2]);
    publish(world);
  });
  step(QStringLiteral("the user drags the bar of %1 one week later on the %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showPlanner(world, c[1]);
    drag(world, waitShownNamed(world, QStringLiteral("plannerBar:") + c[0]), QPointF(7 * dayWidth(world), 0));
  });
  step(QStringLiteral("%1 is moved to %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject moved{{QStringLiteral("id"), idOf(world, c[0])}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("start"), c[1]}, {QStringLiteral("due"), c[2]}}}};
    waitAsked(world, QStringLiteral("updateItem"), moved);
    // One change, when the bar is let go.
    expect(asked(world, QStringLiteral("updateItem")).size() == 1, QStringLiteral("the MC was asked %1").arg(showAsked(world, QStringLiteral("updateItem"))));
  });
  step(QStringLiteral("the user drags the end of the bar of %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showPlanner(world, QStringLiteral("Timeline"));
    const QDate due = date(item(world, c[0]).value(QLatin1String("due")).toString());
    drag(world, waitShownNamed(world, QStringLiteral("plannerBarEnd:") + c[0]), QPointF(due.daysTo(date(c[1])) * dayWidth(world), 0));
  });
  step(QStringLiteral("%1 ends on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject task = item(world, c[0]);
    const QJsonObject ended{{QStringLiteral("id"), task.value(QLatin1String("id"))},
                            {QStringLiteral("fields"), QJsonObject{{QStringLiteral("start"), task.value(QLatin1String("start"))}, {QStringLiteral("due"), c[1]}}}};
    waitAsked(world, QStringLiteral("updateItem"), ended);
    expect(asked(world, QStringLiteral("updateItem")).size() == 1, QStringLiteral("the MC was asked %1").arg(showAsked(world, QStringLiteral("updateItem"))));
  });

  step(QStringLiteral("the plan has %1 not started").arg(q), [](World& world, const Captures& c, const Table&) {
    item(world, c[0]).insert(QStringLiteral("status"), QStringLiteral("todo"));
    publish(world);
  });
  step(QStringLiteral("the user drags %1 to %1 on the %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showPlanner(world, c[2]);
    QQuickItem* card = waitShownNamed(world, QStringLiteral("plannerCard:") + c[0]);
    QQuickItem* column = waitShownNamed(world, QStringLiteral("plannerBoardColumn:") + c[1]);
    const QPointF to = column->mapToScene(QPointF(column->width() / 2, column->height() / 2));
    drag(world, card, to - card->mapToScene(QPointF(card->width() / 2, card->height() / 2)));
  });
  step(QStringLiteral("%1 is in progress").arg(q), [](World& world, const Captures& c, const Table&) {
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), idOf(world, c[0])}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("status"), QStringLiteral("doing")}}}});
    // The board shows it where the MC has it.
    world.waitFor([&] { return findNamed(waitShownNamed(world, QStringLiteral("plannerBoardColumn:In progress")), QStringLiteral("plannerCard:") + c[0]) != nullptr; },
                  QStringLiteral("%1 to be under In progress").arg(c[0]));
  });

  step(QStringLiteral("the plan has %1 dropped").arg(q), [](World& world, const Captures& c, const Table&) {
    item(world, c[0]).insert(QStringLiteral("status"), QStringLiteral("dropped"));
    publish(world);
  });
  step(QStringLiteral("%1 is under %1 on the board").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return findNamed(waitShownNamed(world, QStringLiteral("plannerBoardColumn:") + c[1]), QStringLiteral("plannerCard:") + c[0]) != nullptr; },
                  QStringLiteral("%1 to be under %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("the plan has %1 under %1 and %1 under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (int i = 0; i < 4; i += 2) {
      const QString parent = item(world, c[i + 1]).value(QLatin1String("id")).toString();
      item(world, c[i]).insert(QStringLiteral("parent"), parent);
    }
    publish(world);
  });
  step(QStringLiteral("the %1 is grouped by %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (QJsonValueRef each : state(world).views) {
      QJsonObject shown = each.toObject();
      if (shown.value(QLatin1String("name")) == c[0]) shown.insert(QStringLiteral("groupBy"), c[1]);
      each = shown;
    }
    publish(world);
  });
  step(QStringLiteral("%1 is moved under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), idOf(world, c[0])}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("parent"), idOf(world, c[1])}}}});
    world.waitFor([&] { return findNamed(waitShownNamed(world, QStringLiteral("plannerBoardColumn:") + c[1]), QStringLiteral("plannerCard:") + c[0]) != nullptr; },
                  QStringLiteral("%1 to be under %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("the milestones %1 and %1, with %1 waiting for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString task = item(world, c[3]).value(QLatin1String("id")).toString();
    for (const QString& name : {c[0], c[1]}) item(world, name).insert(QStringLiteral("kind"), QStringLiteral("milestone"));
    item(world, c[2]).insert(QStringLiteral("after"), QJsonArray{task});
    publish(world);
  });
  step(QStringLiteral("%1 waits for %1 and %1 no longer does").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString task = idOf(world, c[1]);
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), idOf(world, c[0])}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("after"), QJsonArray{task}}}}});
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), idOf(world, c[2])}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("after"), QJsonArray()}}}});
    world.waitFor([&] { return findNamed(waitShownNamed(world, QStringLiteral("plannerBoardColumn:") + c[0]), QStringLiteral("plannerCard:") + c[1]) != nullptr; },
                  QStringLiteral("%1 to be under %2").arg(c[1], c[0]));
  });

  step(QStringLiteral("the view %1 shows the owner and the due date").arg(q), [](World& world, const Captures& c, const Table&) {
    seedWhenEmpty(world);
    for (QJsonValueRef each : state(world).views) {
      QJsonObject shown = each.toObject();
      if (shown.value(QLatin1String("name")) != c[0]) continue;
      shown.insert(QStringLiteral("fields"), QJsonArray{QStringLiteral("status"), QStringLiteral("owner"), QStringLiteral("due")});
      each = shown;
    }
    publish(world);
  });
  step(QStringLiteral("each task's owner and due date are columns of the list"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = waitShownNamed(world, QStringLiteral("plannerList"));
    for (const QString& field : {QStringLiteral("owner"), QStringLiteral("due")}) waitShownNamed(world, QStringLiteral("plannerColumn:") + field);
    for (const QString& id : std::as_const(state(world).order)) {
      const QJsonObject task = state(world).items.value(id);
      const QString title = task.value(QLatin1String("title")).toString();
      QQuickItem* row = nullptr;
      world.waitFor([&] { return (row = findNamed(list, QStringLiteral("plannerRow:") + title)) != nullptr; }, QStringLiteral("%1 to be listed").arg(title));
      for (const QString& field : {QStringLiteral("owner"), QStringLiteral("due")}) {
        QQuickItem* cell = findNamed(row, QStringLiteral("plannerCell:") + field);
        expect(cell && cell->property("text") == task.value(field).toString(), QStringLiteral("%1's %2 is not shown").arg(title, field));
      }
    }
  });

  step(QStringLiteral("the user is on the view %1").arg(q), [](World& world, const Captures& c, const Table&) {
    seedWhenEmpty(world);
    publish(world);
    showPlanner(world, c[0]);
  });
  step(QStringLiteral("the user groups it by project, zooms to months and saves it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* groupBy = waitShownNamed(world, QStringLiteral("plannerGroupBy"));
    const int project = groupBy->property("values").toStringList().indexOf(QStringLiteral("project"));
    expect(project >= 0 && QMetaObject::invokeMethod(groupBy, "activated", Q_ARG(int, project)), QStringLiteral("the view cannot be grouped by project"));
    click(world, waitShownNamed(world, QStringLiteral("plannerZoom:month")));
    click(world, waitShownNamed(world, QStringLiteral("plannerViewSave")));
  });
  step(QStringLiteral("%1 is grouped by project at months on every client").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QJsonObject saved = asked(world, QStringLiteral("saveView")).value(0).value(QLatin1String("view")).toObject();
      return saved.value(QLatin1String("name")) == c[0] && saved.value(QLatin1String("id")) == QLatin1String("timeline") &&
             saved.value(QLatin1String("groupBy")) == QLatin1String("project") && saved.value(QLatin1String("zoom")) == QLatin1String("month");
    }, [&] { return QStringLiteral("the view to be saved grouped by project at months, not %1").arg(showAsked(world, QStringLiteral("saveView"))); });
    // Published back, the saved view is the one shown, unchanged.
    waitHidden(world, QStringLiteral("plannerViewChanged"));
    waitShownNamed(world, QStringLiteral("plannerGroup:api"));
    expect(waitShownNamed(world, QStringLiteral("plannerGantt"))->property("zoom") == QStringLiteral("month"), QStringLiteral("the chart is not at months"));
  });

  step(QStringLiteral("the user types %1 in the filter").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* filter = waitShownNamed(world, QStringLiteral("plannerFilter"));
    clickItem(world, filter);
    for (const QChar each : c[0]) QTest::keyClick(pluginShell(world), each.toLatin1());
    world.sync();
  });
  step(QStringLiteral("only tasks matching %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& id : std::as_const(state(world).order)) {
      const QString title = state(world).items.value(id).value(QLatin1String("title")).toString();
      const QString row = QStringLiteral("plannerRow:") + title;
      if (title.contains(c[0], Qt::CaseInsensitive)) waitShownNamed(world, row);
      else waitHidden(world, row);
    }
  });
  step(QStringLiteral("%1 is marked as changed until it is saved or reverted").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShownNamed(world, QStringLiteral("plannerViewChanged"));
    expect(drawsText(waitShownNamed(world, QStringLiteral("plannerView:") + c[0]), QStringLiteral("• ") + c[0]), QStringLiteral("the tab of %1 is not marked").arg(c[0]));
    click(world, waitShownNamed(world, QStringLiteral("plannerViewRevert")));
    waitHidden(world, QStringLiteral("plannerViewChanged"));
    waitText(world, QStringLiteral("plannerFilter"), QString());
    for (const QString& id : std::as_const(state(world).order)) waitShownNamed(world, QStringLiteral("plannerRow:") + state(world).items.value(id).value(QLatin1String("title")).toString());
    expect(asked(world, QStringLiteral("saveView")).isEmpty(), QStringLiteral("the filter was saved"));
  });

  step(QStringLiteral("the user tabs from the view %1 to %1 and presses Enter").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShownNamed(world, QStringLiteral("plannerView:") + c[0])->forceActiveFocus(Qt::TabFocusReason);
    QTest::keyClick(pluginShell(world), Qt::Key_Tab);
    QQuickItem* next = waitShownNamed(world, QStringLiteral("plannerView:") + c[1]);
    world.waitFor([&] { return next->hasActiveFocus(); }, QStringLiteral("the tab of %1 to have the keyboard").arg(c[1]));
    QTest::keyClick(pluginShell(world), Qt::Key_Return);
    world.sync();
  });
  step(QStringLiteral("the planner shows the view %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* page = waitShownNamed(world, QStringLiteral("plannerPage"));
    const auto viewName = [&] { return page->property("working").toMap().value(QStringLiteral("name")).toString(); };
    world.waitFor([&] { return viewName() == c[0]; }, [&] { return QStringLiteral("the view %1 to be shown, not %2").arg(c[0], viewName()); });
  });

  step(QStringLiteral("the plan has %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dated(world, c[0], QStringLiteral("2026-10-21"), QStringLiteral("2026-10-30"));
    publish(world);
  });
  step(QStringLiteral("the user opens %1 and sets its owner to %1 and its due date to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showPlanner(world);
    click(world, waitShownNamed(world, QStringLiteral("plannerTask:") + c[0]));
    waitText(world, QStringLiteral("plannerItemTitle"), c[0]);
    for (const auto& [field, value] : {std::pair{QStringLiteral("plannerItemOwner"), c[1]}, std::pair{QStringLiteral("plannerItemDue"), c[2]}}) {
      QQuickItem* edit = waitShownNamed(world, field);
      edit->setProperty("text", value);
      expect(QMetaObject::invokeMethod(edit, "editingFinished"), QStringLiteral("%1 cannot be edited").arg(field));
      world.sync();
    }
  });
  step(QStringLiteral("%1 is owned by %1 and due %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), id}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("owner"), c[1]}}}});
    waitAsked(world, QStringLiteral("updateItem"), {{QStringLiteral("id"), id}, {QStringLiteral("fields"), QJsonObject{{QStringLiteral("due"), c[2]}}}});
    waitText(world, QStringLiteral("plannerItemOwner"), c[1]);
    waitText(world, QStringLiteral("plannerItemDue"), c[2]);
  });

  step(QStringLiteral("the run of %1 proposes moving %1 to end on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    propose(world, c[0], c[1], c[2]);
    publish(world);
  });
  step(QStringLiteral("the user opens the run on the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("Planner"), QStringLiteral("planner has no tab %1").arg(c[0]));
    showPlanner(world);
    click(world, waitShownNamed(world, QStringLiteral("plannerRunsToggle")));
    click(world, waitShownNamed(world, QStringLiteral("plannerRun:") + state(world).runs.last().value(QLatin1String("label")).toString()));
    waitShownNamed(world, QStringLiteral("plannerRunDetail"));
  });
  step(QStringLiteral("the bar %1 would have is drawn beside its current one").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* ghost = waitShownNamed(world, QStringLiteral("plannerGhost:") + c[0]);
    QQuickItem* bar = waitShownNamed(world, QStringLiteral("plannerBar:") + c[0]);
    expect(ghost->parentItem() == bar->parentItem(), QStringLiteral("the proposed bar is not on %1's row").arg(c[0]));
    const qreal ends = bar->mapToScene(QPointF(bar->width(), 0)).x();
    const qreal proposed = ghost->mapToScene(QPointF(ghost->width(), 0)).x();
    expect(proposed > ends, QStringLiteral("the proposed bar ends at %1, not after %2").arg(proposed).arg(ends));
  });
  step(QStringLiteral("the user can dismiss the change, apply the run or discard it"), [](World& world, const Captures&, const Table&) {
    const QString run = state(world).runs.last().value(QLatin1String("id")).toString();
    // A changed run draws its changes again.
    const auto dismiss = [&] { return findNamed(waitShownNamed(world, QStringLiteral("plannerChange:c1")), QStringLiteral("plannerChangeDismiss")); };
    click(world, dismiss());
    world.waitFor([&] { return dismiss()->property("text") == QStringLiteral("Keep"); }, QStringLiteral("the change to be dismissed"));
    waitAsked(world, QStringLiteral("dismissChange"), {{QStringLiteral("runId"), run}, {QStringLiteral("changeId"), QStringLiteral("c1")}, {QStringLiteral("dismissed"), true}});
    click(world, dismiss());
    world.waitFor([&] { return dismiss()->property("text") == QStringLiteral("Dismiss"); }, QStringLiteral("the change to be kept"));
    expect(waitShownNamed(world, QStringLiteral("plannerDiscard"))->isEnabled(), QStringLiteral("the run cannot be discarded"));

    click(world, waitShownNamed(world, QStringLiteral("plannerApply")));
    waitAsked(world, QStringLiteral("apply"), {{QStringLiteral("runId"), run}});
    world.waitFor([&] { return textOf(world, QStringLiteral("plannerRunStatus")).startsWith(QLatin1String("Applied")); },
                  [&] { return textOf(world, QStringLiteral("plannerRunStatus")); });
    waitHidden(world, QStringLiteral("plannerApply"));
  });

  step(QStringLiteral("the run of %1 proposes moving %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject run = propose(world, c[0], c[1], QStringLiteral("2026-11-06"));
    listThread(world, run);
    publish(world);
  });
  step(QStringLiteral("the user opens the run's thread"), [](World& world, const Captures&, const Table&) {
    openPluginThread(world, state(world).runs.last().value(QLatin1String("threadId")).toString());
  });
  step(QStringLiteral("the action, the state of its run and the apply action are shown above the conversation"), [](World& world, const Captures&, const Table&) {
    QQuickItem* header = waitShownNamed(world, QStringLiteral("plannerHeader"));
    expect(findNamed(waitShownNamed(world, QStringLiteral("pluginThreadHeader")), QStringLiteral("plannerHeader")) == header, QStringLiteral("the header is not the thread's"));
    const QJsonObject run = state(world).runs.last();
    world.waitFor([&] { return findNamed(header, QStringLiteral("plannerHeaderTitle"))->property("text") == run.value(QLatin1String("label")).toString(); },
                  [&] { return findNamed(header, QStringLiteral("plannerHeaderTitle"))->property("text").toString(); });
    const QString status = findNamed(header, QStringLiteral("plannerHeaderStatus"))->property("text").toString();
    expect(status.contains(QLatin1String("Proposes 1 change")), QStringLiteral("the header says %1").arg(status));
    QQuickItem* apply = findNamed(header, QStringLiteral("plannerHeaderApply"));
    expect(apply->isVisible() && apply->isEnabled(), QStringLiteral("the run cannot be applied from its thread"));
  });

  step(QStringLiteral("the run of %1 proposes only that the plan is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject& run = addRun(world, c[0], {}, QStringLiteral("proposed"));
    run.insert(QStringLiteral("summary"), QStringLiteral("Schema slipped three days."));
    run.insert(QStringLiteral("health"), c[1]);
    listThread(world, run);
    publish(world);
  });
  step(QStringLiteral("the run can be applied from its thread and from the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* header = waitShownNamed(world, QStringLiteral("plannerHeader"));
    world.waitFor([&] { return findNamed(header, QStringLiteral("plannerHeaderStatus"))->property("text") == QStringLiteral("Proposes a status update"); },
                  [&] { return findNamed(header, QStringLiteral("plannerHeaderStatus"))->property("text").toString(); });
    QQuickItem* apply = findNamed(header, QStringLiteral("plannerHeaderApply"));
    expect(apply->isVisible() && apply->isEnabled(), QStringLiteral("the status update cannot be applied from its thread"));

    expect(c[0] == QLatin1String("Planner"), QStringLiteral("planner has no tab %1").arg(c[0]));
    showPlanner(world);
    click(world, waitShownNamed(world, QStringLiteral("plannerRunsToggle")));
    click(world, waitShownNamed(world, QStringLiteral("plannerRun:") + state(world).runs.last().value(QLatin1String("label")).toString()));
    expect(waitShownNamed(world, QStringLiteral("plannerApply"))->isEnabled(), QStringLiteral("the status update cannot be applied from the Planner tab"));
  });

  step(QStringLiteral("%1 shows its threads in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kId, QStringLiteral("only %1 is faked").arg(kId));
    state(world).settings.insert(QStringLiteral("display"), QStringLiteral("both"));
  });
  step(QStringLiteral("its thread is listed with the planner mark and the state of its run"), [](World& world, const Captures&, const Table&) {
    const auto marked = [&](const QString& text) {
      QQuickItem* mark = nullptr;
      world.waitFor([&] {
        QQuickItem* host = waitShownNamed(world, QStringLiteral("pluginRowMark"));
        return (mark = findNamed(host, QStringLiteral("plannerRowMark"))) && drawsText(mark, text);
      }, [&] { return QStringLiteral("the row mark to say %1").arg(text); });
    };
    marked(QStringLiteral("Running"));
    // The mark follows the run.
    QJsonObject& run = state(world).runs.last();
    run.insert(QStringLiteral("status"), QStringLiteral("proposed"));
    run.insert(QStringLiteral("changes"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("c1")}, {QStringLiteral("op"), QStringLiteral("update")}, {QStringLiteral("itemId"), QStringLiteral("t1")},
                                                                 {QStringLiteral("fields"), QJsonObject{{QStringLiteral("due"), QStringLiteral("2026-11-06")}}}, {QStringLiteral("dismissed"), false}}});
    publish(world);
    marked(QStringLiteral("1 change"));
  });

  step(QStringLiteral("the user changes the prompt of %1 and resets %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* settings = waitShownNamed(world, QStringLiteral("plannerSettings"));
    world.waitFor([&] { return settings->property("loaded").toBool(); }, QStringLiteral("the settings to be read"));
    waitShownNamed(world, QStringLiteral("plannerActionPrompt:") + actionId(world, c[0]))->setProperty("text", QStringLiteral("My own reschedule prompt."));
    // The buttons sit below the fold of the settings page, out of the mouse's reach.
    QQuickItem* reset = waitShownNamed(world, QStringLiteral("plannerActionReset:") + actionId(world, c[1]));
    world.waitFor([&] { return reset->isEnabled(); }, QStringLiteral("the reset to be enabled"));
    expect(QMetaObject::invokeMethod(reset, "clicked"), QStringLiteral("the reset cannot be pressed"));
    QQuickItem* save = waitShownNamed(world, QStringLiteral("plannerSave"));
    world.waitFor([&] { return save->isEnabled(); }, QStringLiteral("the settings to be saveable"));
    expect(QMetaObject::invokeMethod(save, "clicked"), QStringLiteral("the settings cannot be saved"));
  });
  step(QStringLiteral("the prompt of %1 is saved as changed and %1 as the plugin's").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto saved = [&] {
      QJsonArray found;
      for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
        if (rpc.method == QLatin1String("plugins.saveSettings")) found.append(rpc.payload.value(QLatin1String("settings")));
      }
      return found;
    };
    world.waitFor([&] { return !saved().isEmpty(); }, QStringLiteral("the settings to be saved"));
    const QJsonObject sent = saved().first().toObject();
    expect(sent.keys() == QStringList{QStringLiteral("actions")}, QStringLiteral("the MC was sent %1").arg(dump(sent)));
    const QJsonObject actions = sent.value(QLatin1String("actions")).toObject();
    const QString changed = actionId(world, c[0]);
    const QString reset = actionId(world, c[1]);
    expect(actions.value(changed).toObject().value(QLatin1String("prompt")) == QStringLiteral("My own reschedule prompt."), QStringLiteral("%1 was saved as %2").arg(c[0], dump(actions.value(changed))));
    expect(actions.value(reset).toObject().value(QLatin1String("prompt")) == state(world).defaultActions.value(reset).toObject().value(QLatin1String("prompt")),
           QStringLiteral("%1 was saved as %2").arg(c[1], dump(actions.value(reset))));
    // Read again after the save, nothing is left to save.
    QQuickItem* settings = waitShownNamed(world, QStringLiteral("plannerSettings"));
    world.waitFor([&] { return !settings->property("dirty").toBool(); }, QStringLiteral("the settings to be read again"));
  });

  step(QStringLiteral("the MC is connected to Slack as the bot %1").arg(q), [](World& world, const Captures&, const Table&) { state(world).slack = true; });
  step(QStringLiteral("%1 posts to the Slack channel %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kId, QStringLiteral("only %1 is faked").arg(kId));
    state(world).settings.insert(QStringLiteral("slackChannel"), c[1]);
  });
  step(QStringLiteral("the MC is connected to Slack"), [](World& world, const Captures&, const Table&) { state(world).slack = true; });
  step(QStringLiteral("the user opens the planner's settings"), [](World& world, const Captures&, const Table&) {
    pluginShell(world);
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/plugin/%1/%2").arg(world.mc.environmentId, kId)}});
    QQuickItem* settings = waitShownNamed(world, QStringLiteral("plannerSettings"));
    world.waitFor([&] { return settings->property("loaded").toBool(); }, QStringLiteral("the settings to be read"));
  });
  step(QStringLiteral("%1 has the board %1 %1 with the date fields %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePlanner& fake = state(world);
    fake.boards.append(QJsonObject{{QStringLiteral("id"), c[1]}, {QStringLiteral("owner"), c[0]}, {QStringLiteral("number"), c[1].section(QLatin1Char('/'), 1).toInt()}, {QStringLiteral("title"), c[2]}});
    fake.dateFields.insert(c[1], QJsonArray{c[3], c[4]});
  });
  step(QStringLiteral("the user picks the board %1 with %1 and %1 as its dates").arg(q), [](World& world, const Captures& c, const Table&) {
    // Picks entry `text` of the combo named `name` once it is offered.
    const auto pick = [&](const QString& name, const QString& text) {
      QQuickItem* combo = waitShownNamed(world, name);
      int index = -1;
      world.waitFor([&] {
        for (int i = 0; i < combo->property("count").toInt() && index < 0; ++i) {
          QString each;
          QMetaObject::invokeMethod(combo, "textAt", Q_RETURN_ARG(QString, each), Q_ARG(int, i));
          if (each.startsWith(text)) index = i;
        }
        return index >= 0;
      }, QStringLiteral("%1 to be offered").arg(text));
      expect(QMetaObject::invokeMethod(combo, "activated", Q_ARG(int, index)), QStringLiteral("%1 cannot be picked").arg(text));
    };
    pick(QStringLiteral("plannerBoard"), c[0]);
    pick(QStringLiteral("plannerDateField:startField"), c[1]);
    pick(QStringLiteral("plannerDateField:targetField"), c[2]);
    QQuickItem* save = waitShownNamed(world, QStringLiteral("plannerSave"));
    world.waitFor([&] { return save->isEnabled(); }, QStringLiteral("the settings to be saveable"));
    expect(QMetaObject::invokeMethod(save, "clicked"), QStringLiteral("the settings cannot be saved"));
  });
  step(QStringLiteral("%1 is saved following %1 with %1 and %1 as its dates").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kId, QStringLiteral("only %1 is faked").arg(kId));
    QJsonObject sent;
    world.waitFor([&] {
      for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
        if (rpc.method == QLatin1String("plugins.saveSettings")) sent = rpc.payload.value(QLatin1String("settings")).toObject();
      }
      return !sent.isEmpty();
    }, QStringLiteral("the settings to be saved"));
    const QJsonObject wanted{{QStringLiteral("board"), c[1]}, {QStringLiteral("startField"), c[2]}, {QStringLiteral("targetField"), c[3]}};
    expect(sent == wanted, QStringLiteral("the MC was sent %1").arg(dump(sent)));
  });
  step(QStringLiteral("the channels the bot is in are offered for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* channel = waitShownNamed(world, QStringLiteral("plannerSlackChannel"));
    QStringList offered;
    world.waitFor([&] {
      offered.clear();
      for (int i = 0; i < channel->property("count").toInt(); ++i) {
        QString text;
        QMetaObject::invokeMethod(channel, "textAt", Q_RETURN_ARG(QString, text), Q_ARG(int, i));
        offered.append(text);
      }
      return offered == QStringList{QStringLiteral("None"), QStringLiteral("#planning"), QStringLiteral("#releases")};
    }, [&] { return QStringLiteral("the channels to be offered, not %1").arg(offered.join(QStringLiteral(", "))); });
    expect(channel->property("currentText") == state(world).settings.value(QLatin1String("slackChannel")).toString(), QStringLiteral("the planner's channel is not picked"));
    // The field the channels are offered in is the one named.
    QQuickItem* field = channel->parentItem();
    while (field && !drawsText(field, c[0])) field = field->parentItem();
    expect(field && !drawsText(field, QStringLiteral("Announce proposals in Slack")), QStringLiteral("the channels are not offered for %1").arg(c[0]));
  });
});

}  // namespace

bool runPluginAction(World& world, const QString& label) {
  if (!isMcPlugin(world, kId)) return false;
  const QString id = actionId(world, label);
  const qsizetype runs = state(world).runs.size();
  showPlanner(world);
  click(world, waitShownNamed(world, QStringLiteral("plannerActions")));
  click(world, waitShownNamed(world, QStringLiteral("plannerAction:") + id));
  waitAsked(world, QStringLiteral("run"), {{QStringLiteral("action"), id}, {QStringLiteral("itemIds"), QJsonArray()}});
  world.waitFor([&] { return state(world).runs.size() > runs; }, QStringLiteral("the run of %1 to start").arg(label));
  // The MC part starts the run's thread as it starts the run.
  listThread(world, state(world).runs.last());
  return true;
}

bool openPlannerView(World& world, const QString& name) {
  if (!isMcPlugin(world, kId)) return false;
  const QJsonArray views = state(world).views;
  if (std::none_of(views.begin(), views.end(), [&](const QJsonValue& each) { return each.toObject().value(QLatin1String("name")) == name; })) return false;
  showPlanner(world, name);
  return true;
}
