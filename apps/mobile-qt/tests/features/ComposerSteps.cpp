// A thread's own screen on the phone (features/mobile/composer.feature): the
// composer under a conversation, typed into and tapped as the user does, and
// what the MC receives from it.

#include <QJsonArray>
#include <QJsonObject>
#include <QGuiApplication>
#include <QInputMethod>
#include <QQuickItem>
#include <QRegularExpression>

#include <algorithm>
#include <functional>
#include <utility>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ThreadStore.h"
#include "Phone.h"
#include "World.h"

namespace {

const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

// The queued message a scenario is about, for its "it".
QString lastQueued;
// What the user made of it in the composer.
QString editedText;
// The thread's draft as it stood when an edit began.
QString priorDraft;
// The command the scenario's When step sent, which its Then must find.
QString expectedCommand;

QList<int> followers(FakeMc& mc, const QString& thread) {
  QList<int> ids;
  for (const int id : mc.subscribers(QStringLiteral("stream"))) {
    if (mc.shapeOf(id).value(QLatin1String("stream")).toString() == thread) ids.append(id);
  }
  return ids;
}

// A frame for a follower of a stream, counted in what the MC sent.
void deliver(FakeMc& mc, const QJsonObject& frame) {
  mc.part<FakeStreams>().sent.append(frame);
  mc.send(frame);
}

// Answers a `sub` to a thread's stream as the MC does
// (lib/hal_c2/streams/server.ex): the changes since its offset when it comes
// back with the MC's handle, else a snapshot of what its view holds — the
// newest turns only for a windowed `sub`; then `live`.
void answer(FakeMc& mc, int id, const QJsonObject& shape, const QJsonObject& sub) {
  FakeStreams& fake = mc.part<FakeStreams>();
  const QString thread = shape.value(QLatin1String("stream")).toString();
  fake.asked.append({thread, sub, fake.sent.size(), fake.unfollowed.take(thread)});
  const QMap<QString, QJsonObject> entities = fake.threads.value(thread);
  const QJsonObject window = sub.value(QLatin1String("window")).toObject();
  const bool opens = window.value(QLatin1String("items")).isDouble();
  StreamView view{shape.value(QLatin1String("kinds")).toObject()};
  if (opens) {
    view.windowed = true;
    view.floor = streamTakeRuns(entities, QJsonValue::Null, window.value(QLatin1String("items")).toInt()).second;
  } else if (window.contains(QLatin1String("floor"))) {
    view.windowed = true;
    view.floor = window.value(QLatin1String("floor"));
  }
  fake.views.insert(id, view);
  const QJsonValue offset = sub.value(QLatin1String("offset"));
  const bool resumes = !opens && !fake.handle.isEmpty() && sub.value(QLatin1String("handle")) == fake.handle && offset.isDouble() && offset.toInt() <= fake.seq;
  if (resumes) {
    QJsonArray events;
    for (const FakeStreams::Change& change : fake.log.value(thread)) {
      if (change.seq <= offset.toInt()) continue;
      if (!streamHolds(view, entities, change.kind, entities.value(change.kind + QLatin1Char('\n') + change.id))) continue;
      events.append(QJsonArray{change.seq, change.kind, change.id, change.patch, kNow});
    }
    if (std::exchange(fake.cutCatchUp, false) && events.size() > 1) {
      // The first part of two carries the offset the client is at; the
      // connection goes before the second.
      deliver(mc, {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), offset},
                   {QStringLiteral("events"), QJsonArray{events.first()}}});
      mc.drop();
      return;
    }
    if (!events.isEmpty()) {
      deliver(mc, {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), id},
                   {QStringLiteral("offset"), events.last().toArray().at(0)}, {QStringLiteral("events"), events}});
    }
  } else {
    QJsonArray rows;
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      const QStringList key = it.key().split(QLatin1Char('\n'));
      if (streamHolds(view, entities, key.at(0), *it)) rows.append(QJsonArray{key.at(0), key.at(1), *it});
    }
    QJsonObject snapshot{{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), fake.seq},
                         {QStringLiteral("at"), kNow}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}};
    if (!fake.handle.isEmpty()) snapshot.insert(QStringLiteral("handle"), fake.handle);
    if (view.windowed) snapshot.insert(QStringLiteral("floor"), view.floor);
    deliver(mc, snapshot);
  }
  QJsonObject live{{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), fake.seq}};
  if (!fake.handle.isEmpty()) live.insert(QStringLiteral("handle"), fake.handle);
  deliver(mc, live);
}

// Answers `more`: the runs before the follower's window, as a page that
// moves its floor down. Held while the scenario holds `pages`.
void sendPage(FakeMc& mc, int id, int items) {
  FakeStreams& fake = mc.part<FakeStreams>();
  if (!fake.views.contains(id)) return;
  StreamView& view = fake.views[id];
  const QMap<QString, QJsonObject> entities = fake.threads.value(mc.shapeOf(id).value(QLatin1String("stream")).toString());
  QJsonArray rows;
  QJsonValue floor = QJsonValue::Null;
  if (view.windowed && !view.floor.isNull()) {
    const auto [runs, lower] = streamTakeRuns(entities, view.floor, items);
    floor = lower;
    StreamView page{view.kinds};
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      const QStringList key = it.key().split(QLatin1Char('\n'));
      if (key.at(0) != QLatin1String("turn-item") && key.at(0) != QLatin1String("message") && key.at(0) != QLatin1String("node")) continue;
      if (runs.contains(it->value(QLatin1String("runId")).toString()) && streamHolds(page, entities, key.at(0), *it)) rows.append(QJsonArray{key.at(0), key.at(1), *it});
    }
    view.floor = floor;
  }
  deliver(mc, {{QStringLiteral("t"), QStringLiteral("page")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), fake.seq},
               {QStringLiteral("rows"), rows}, {QStringLiteral("floor"), floor}, {QStringLiteral("done"), true}});
}

const FakeMc::Extension streams([](FakeMc& mc) {
  mc.onShape(QStringLiteral("stream"), [&mc](int id, const QJsonObject& shape) {
    if (mc.part<FakeStreams>().offline.contains(shape.value(QLatin1String("environment")).toString())) {
      mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unknown environment")}});
      mc.forget(id);
      return;
    }
    const QJsonObject sub = mc.subscriptions.last();
    FakeStreams& fake = mc.part<FakeStreams>();
    if (fake.slow) {
      fake.waiting.append([&mc, id, shape, sub] {
        if (mc.subscribers(QStringLiteral("stream")).contains(id)) answer(mc, id, shape, sub);
      });
      return;
    }
    if (const int ms = fake.loadMs; ms > 0) {
      mc.busy(ms, [&mc, id, shape, sub] {
        if (mc.subscribers(QStringLiteral("stream")).contains(id)) answer(mc, id, shape, sub);
      });
      return;
    }
    answer(mc, id, shape, sub);
  });
  mc.onFrame(QStringLiteral("more"), [&mc](const QJsonObject& frame) {
    const int id = frame.value(QLatin1String("id")).toInt();
    const int items = frame.value(QLatin1String("items")).toInt();
    mc.part<FakeStreams>().sent.append(frame);
    if (mc.holding(QStringLiteral("pages"))) {
      mc.defer([&mc, id, items] { sendPage(mc, id, items); });
    } else {
      sendPage(mc, id, items);
    }
  });
});

// The MC's settings and what it can run turns on, and the settings documents
// of the cluster's other members (SettingsDocument).
struct FakeConfig {
  QJsonArray providers;
  QJsonObject settings;
  int version = 0;
  QHash<QString, SettingsDocument> elsewhere;
};

// Sends `frame` to the subscribers of the environment's `config`.
void sendConfig(FakeMc& mc, const QString& environment, QJsonObject frame) {
  for (const int id : mc.subscribers(QStringLiteral("config"))) {
    if (mc.shapeOf(id).value(QLatin1String("environment")).toString() != environment) continue;
    frame.insert(QStringLiteral("id"), id);
    mc.send(frame);
  }
}

const FakeMc::Extension config([](FakeMc& mc) {
  mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject& shape) {
    const QString environment = shape.value(QLatin1String("environment")).toString();
    const FakeConfig& fake = mc.part<FakeConfig>();
    if (environment == mc.environmentId) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), fake.providers},
                                                      {QStringLiteral("settings"), fake.settings},
                                                      {QStringLiteral("environment"), QJsonObject{{QStringLiteral("capabilities"), mc.capabilities}}}}}});
    } else if (fake.elsewhere.contains(environment)) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), QJsonArray()},
                                                      {QStringLiteral("settings"), fake.elsewhere.value(environment).settings},
                                                      {QStringLiteral("environment"),
                                                       QJsonObject{{QStringLiteral("capabilities"), fake.elsewhere.value(environment).capabilities}}}}}});
    } else {
      return;
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("config.themes")}, {QStringLiteral("id"), id}, {QStringLiteral("themes"), QJsonArray()}});
  });
  mc.onRpc(QStringLiteral("hal-c2.readSettings"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeConfig& fake = mc.part<FakeConfig>();
    const bool other = fake.elsewhere.contains(rpc.environment);
    const SettingsDocument document = other ? fake.elsewhere.value(rpc.environment) : SettingsDocument{fake.settings, fake.version};
    mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), document.settings}, {QStringLiteral("version"), document.version}});
  });
  mc.onRpc(QStringLiteral("hal-c2.writeSettings"), [&mc](const FakeMc::Rpc& rpc) {
    FakeConfig& fake = mc.part<FakeConfig>();
    if (fake.elsewhere.contains(rpc.environment)) {
      // Another member refuses a write over a version it has moved past, as the MC does.
      SettingsDocument& document = fake.elsewhere[rpc.environment];
      if (rpc.payload.value(QLatin1String("version")).toInt(-1) != document.version) {
        mc.refuse(rpc, QStringLiteral("settings changed"), {{QStringLiteral("_tag"), QStringLiteral("StaleSettings")}});
        return;
      }
      document.settings = rpc.payload.value(QLatin1String("settings")).toObject();
      mc.reply(rpc, QJsonObject{{QStringLiteral("version"), ++document.version}});
      sendConfig(mc, rpc.environment, {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), document.settings}});
      return;
    }
    fake.settings = rpc.payload.value(QLatin1String("settings")).toObject();
    mc.reply(rpc, QJsonObject{{QStringLiteral("version"), ++fake.version}});
    for (const int id : mc.subscribers(QStringLiteral("config"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("id"), id}, {QStringLiteral("settings"), fake.settings}});
    }
  });
});

// A model at three reasoning levels; Opus, as Claude lists it, also offers fast
// mode and a 200k or 1M context window.
QJsonObject model(const QString& slug, const QString& name) {
  QJsonArray levels;
  for (const char* level : {"Low", "Medium", "High"}) {
    levels.append(QJsonObject{{QStringLiteral("id"), QString::fromLatin1(level).toLower()}, {QStringLiteral("label"), QString::fromLatin1(level)}});
  }
  QJsonArray descriptors{QJsonObject{{QStringLiteral("id"), QStringLiteral("reasoningEffort")},
                                     {QStringLiteral("label"), QStringLiteral("Reasoning")},
                                     {QStringLiteral("type"), QStringLiteral("select")},
                                     {QStringLiteral("options"), levels},
                                     {QStringLiteral("currentValue"), QStringLiteral("low")}}};
  if (slug == QLatin1String("claude-opus")) {
    descriptors.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("fastMode")},
                                   {QStringLiteral("label"), QStringLiteral("Fast Mode")},
                                   {QStringLiteral("type"), QStringLiteral("boolean")}});
    descriptors.append(QJsonObject{
        {QStringLiteral("id"), QStringLiteral("contextWindow")},
        {QStringLiteral("label"), QStringLiteral("Context Window")},
        {QStringLiteral("type"), QStringLiteral("select")},
        {QStringLiteral("options"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("200k")}, {QStringLiteral("label"), QStringLiteral("200k")}},
                                               QJsonObject{{QStringLiteral("id"), QStringLiteral("1m")}, {QStringLiteral("label"), QStringLiteral("1M")}}}},
        {QStringLiteral("currentValue"), QStringLiteral("200k")}});
  }
  return {{QStringLiteral("slug"), slug},
          {QStringLiteral("name"), name},
          {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), descriptors}}}};
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

// The composer's editor, once the thread's composer is ready for it.
QQuickItem* editor(World& world) {
  QQuickItem* input = world.item(QStringLiteral("input"));
  world.waitFor([&] { return input->isEnabled(); }, [&] { return QStringLiteral("the composer to take text; it is %1").arg(show(composer(world))); });
  return input;
}

// The user taps into the composer and types.
void typeMessage(World& world, const QString& text) {
  QQuickItem* input = editor(world);
  world.tap(input);
  expect(input->hasActiveFocus(), QStringLiteral("the composer did not take the keyboard"));
  world.type(text);
  expect(input->property("text").toString() == text, QStringLiteral("the composer reads %1").arg(input->property("text").toString()));
}

// The commands of a type the MC received, oldest first.
QList<QJsonObject> commandsOf(World& world, const QString& type) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == type) found.append(command);
  }
  return found;
}

QString describeCommands(World& world) {
  QStringList lines;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) lines.append(show(command.toVariantMap()));
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

// The model the picker lists under `name`: its provider instance and slug.
std::pair<QString, QString> listedModel(World& world, const QString& name) {
  const QVariantList instances = world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList();
  for (const QVariant& instance : instances) {
    for (const QVariant& entry : instance.toMap().value(QStringLiteral("models")).toList()) {
      if (entry.toMap().value(QStringLiteral("name")).toString() == name) {
        return {instance.toMap().value(QStringLiteral("instanceId")).toString(), entry.toMap().value(QStringLiteral("slug")).toString()};
      }
    }
  }
  fail(QStringLiteral("no provider offers %1; the picker offers %2").arg(name, show(instances)));
}

}  // namespace

void setEntity(FakeMc& mc, const QString& thread, const QString& kind, const QString& id, const QJsonObject& fields) {
  changeEntity(mc, thread, kind, id, {{QStringLiteral("s"), fields}});
}

void changeEntity(FakeMc& mc, const QString& thread, const QString& kind, const QString& id, const QJsonObject& patch, bool quiet) {
  FakeStreams& fake = mc.part<FakeStreams>();
  QJsonObject& entity = fake.threads[thread][kind + QLatin1Char('\n') + id];
  const QJsonObject set = patch.value(QLatin1String("s")).toObject();
  for (auto it = set.begin(); it != set.end(); ++it) entity.insert(it.key(), it.value());
  const QJsonObject append = patch.value(QLatin1String("a")).toObject();
  for (auto it = append.begin(); it != append.end(); ++it) entity.insert(it.key(), entity.value(it.key()).toString() + it.value().toString());
  const int seq = ++fake.seq;
  fake.log[thread].append({seq, kind, id, patch});
  const QList<int> following = quiet || !mc.connected() ? QList<int>() : followers(mc, thread);
  if (following.isEmpty()) ++fake.unfollowed[thread];
  // QJsonValue keeps the event nested: Apple clang before 20 reads
  // QJsonArray{QJsonArray{...}} as a copy of the inner array.
  for (const int follower : following) {
    // A follower is only sent changes to what it holds.
    if (!streamHolds(fake.views.value(follower), fake.threads.value(thread), kind, entity)) continue;
    deliver(mc, {{QStringLiteral("t"), QStringLiteral("events")},
                 {QStringLiteral("id"), follower},
                 {QStringLiteral("offset"), seq},
                 {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, kNow})}}});
  }
}

void updateRow(FakeMc& mc, const QString& thread, const QJsonObject& fields) {
  QJsonObject& row = mc.threads[thread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  mc.sendRow(thread, row);
}

SettingsDocument& settingsOf(FakeMc& mc, const QString& environment) {
  return mc.part<FakeConfig>().elsewhere[environment];
}

QJsonObject ownSettings(FakeMc& mc) {
  return mc.part<FakeConfig>().settings;
}

void saveOwnSetting(FakeMc& mc, const QString& key, const QJsonValue& value) {
  FakeConfig& fake = mc.part<FakeConfig>();
  fake.settings.insert(key, value);
  fake.version++;
  sendConfig(mc, mc.environmentId, {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), fake.settings}});
}

void offerProviders(FakeMc& mc, const QJsonArray& providers) {
  mc.part<FakeConfig>().providers = providers;
  for (const int id : mc.subscribers(QStringLiteral("config"))) {
    mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers}});
  }
}

namespace {

// The composer's control `name`, shown or folded away into its menu.
QQuickItem* composerControl(World& world, const QString& name) {
  const std::function<QQuickItem*(QQuickItem*)> within = [&](QQuickItem* item) -> QQuickItem* {
    if (item->objectName() == name) return item;
    for (QQuickItem* child : item->childItems())
      if (QQuickItem* found = within(child)) return found;
    return nullptr;
  };
  QQuickItem* found = nullptr;
  world.waitFor([&] { return (found = within(world.item(QStringLiteral("composer")))) != nullptr; },
                [&] { return QStringLiteral("the composer to hold %1").arg(name); });
  return found;
}

// Opens the composer's chip `name`, or, on a toolbar too narrow for it,
// the row standing for it in the composer's menu of further controls.
void openChip(World& world, const QString& name) {
  using S = QString;
  QQuickItem* chip = composerControl(world, name);
  if (chip->isVisible()) {
    world.tap(chip);
    return;
  }
  QObject* composerView = world.item(S("composer"));
  world.tap(S("composerOverflow"));
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        QObject* menu = composerView->property("overflowMenu").value<QObject*>();
        if (!menu || !menu->property("opened").toBool()) return false;
        for (int i = 0; i < menu->property("count").toInt(); ++i) {
          QQuickItem* candidate = nullptr;
          QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, candidate), Q_ARG(int, i));
          QObject* sub = candidate ? candidate->property("subMenu").value<QObject*>() : nullptr;
          if (candidate && (sub ? sub->objectName() : candidate->objectName()) == S("composerOverflow:") + name) row = candidate;
        }
        return row != nullptr;
      },
      [&] { return S("%1 in the composer's menu; the screen says: %2").arg(name, screenTexts(world)); });
  world.tap(row);
}

// A choice an open picker lists, as a list row or, folded, a menu row.
bool offers(QQuickItem* candidate, const QString& label) {
  if (candidate->inherits("QQuickMenuItem")) return candidate->isVisible() && candidate->property("text").toString().compare(label, Qt::CaseInsensitive) == 0;
  // A picker's row lays its label out beside marks: the row's own text names it.
  return candidate->inherits("QQuickItemDelegate") && candidate->isVisible() &&
         candidate->property("text").toString().compare(label, Qt::CaseInsensitive) == 0;
}

// Claude offers Sonnet and Opus, and the thread runs on Sonnet: the user picks
// `name` from the model picker.
void pickModel(World& world, const QString& name) {
  using S = QString;
  offerProviders(world.mc, {QJsonObject{{S("instanceId"), S("claudeAgent")},
                                        {S("driver"), S("claudeAgent")},
                                        {S("displayName"), S("Claude")},
                                        {S("enabled"), true},
                                        {S("installed"), true},
                                        {S("status"), S("ready")},
                                        {S("models"), QJsonArray{model(S("claude-sonnet"), S("Sonnet")), model(S("claude-opus"), S("Opus"))}}}});
  world.sync();
  world.waitFor([&] { return world.item(S("modelPicker"))->isEnabled(); }, [&] { return S("the model picker; the composer is %1").arg(show(composer(world))); });
  const auto [instance, slug] = listedModel(world, name);
  expect(composer(world).value(S("selectedModel")).toString() != slug, S("the thread already runs on %1").arg(name));

  world.tap(S("modelPicker"));
  const QString row = S("modelPickerRow:%1:%2").arg(instance, slug);
  world.waitFor([&] { return world.find(row) != nullptr || world.find(S("modelPickerProvider:") + instance) != nullptr; },
                [&] { return S("the picker; the screen says: %1").arg(screenTexts(world)); });
  if (world.find(row) == nullptr) world.tap(S("modelPickerProvider:") + instance);
  world.tap(row);
  world.waitFor([&] { return composer(world).value(S("selectedModel")).toString() == slug; },
                [&] { return S("the composer to choose %1; it is %2").arg(name, show(composer(world))); });
  // The picker closes as the user sees it, once its fade is done.
  world.waitFor(
      [&] {
        return world.findWhere([](QQuickItem* item) {
                 const QObject* owner = item->parent() ? item->parent()->parent() : nullptr;
                 return item->inherits("QQuickPopupItem") && item->isVisible() && owner && owner->objectName() == QLatin1String("modelPicker");
               }) == nullptr;
      },
      S("the model picker to close"));
}

const Steps steps([] {
  using S = QString;

  step(S("the user is in the thread %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.thread = haveThread(world, c[0]);
    openThread(world, c[0]);
    editor(world);
  });

  // A run of the thread, running, with the message that asked for it; the MC
  // ends it when it is told to, as its projection does.
  const auto working = [](World& world) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.run = S("run-%1").arg(fake.ordinal + 1);
    setEntity(world.mc, world.thread, S("run"), world.run,
              {{S("id"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}});
    const QString message = S("message:") + world.run;
    setEntity(world.mc, world.thread, S("turn-item"), message,
              {{S("id"), message}, {S("type"), S("user_message")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("completed")}, {S("text"), S("Add a tax line to the cart")}, {S("updatedAt"), kNow}});
    updateRow(world.mc, world.thread, {{S("activeRunId"), world.run}, {S("latestRunId"), world.run}});
    world.mc.effects.append([&world](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("run.interrupt") || command.value(QLatin1String("runId")) != world.run) return;
      setEntity(world.mc, world.thread, S("run"), world.run, {{S("status"), S("interrupted")}, {S("completedAt"), kNow}});
      updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
    });
    world.sync();
    world.waitFor([&] { return world.item(S("primaryAction"))->property("stopMode").toBool(); },
                  [&] { return S("the composer to offer Stop; it is %1").arg(show(composer(world))); });
  };
  step(S("the agent is working on a turn"), [working](World& world, const Captures&, const Table&) { working(world); });

  // A queued run behind the running turn and its message; `fields` are what
  // the message carries beyond its text.
  const auto queue = [](World& world, const QString& text, const QJsonObject& fields) {
    // Every scenario queues first: start each from a clean slate.
    lastQueued.clear();
    editedText.clear();
    priorDraft.clear();
    expectedCommand.clear();
    FakeStreams& fake = world.mc.part<FakeStreams>();
    const int ordinal = ++fake.ordinal;
    const QString run = S("run-%1").arg(ordinal);
    QJsonObject message{{S("id"), S("message:") + run}, {S("role"), S("user")}, {S("text"), text}};
    for (auto it = fields.begin(); it != fields.end(); ++it) message.insert(it.key(), it.value());
    setEntity(world.mc, world.thread, S("message"), S("message:") + run, message);
    setEntity(world.mc, world.thread, S("run"), run,
              {{S("id"), run}, {S("ordinal"), ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ordinal},
               {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}});
    world.sync();
  };
  step(S("the message %1 is waiting for the current turn").arg(kQuoted), [queue](World& world, const Captures& c, const Table&) {
    queue(world, c[0], {});
    lastQueued = c[0];
  });
  // As apps/server-ex/lib/hal_c2/orchestration/delegation.ex queues it.
  step(S("the result of the delegated task %1 is waiting for the current turn").arg(kQuoted), [queue](World& world, const Captures& c, const Table&) {
    queue(world, S("<delegated_task_result taskId=\"task:1\" title=\"%1\" status=\"completed\" childThreadId=\"thread-9\">\ndone\n</delegated_task_result>").arg(c[0]),
          {{S("createdBy"), S("system")},
           {S("delegatedCompletion"), QJsonObject{{S("taskId"), S("task:1")}, {S("status"), S("completed")}}},
           {S("notification"), QJsonObject{{S("summary"), c[0] + S(" finished")}, {S("outcome"), S("completed")}}}});
  });
  step(S("the composer lists %1 with %1 waiting behind it").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const auto texts = [&world](const QString& prefix) {
      // Every visible match: a Repeater's delegates are only in the item tree.
      QStringList found;
      world.findWhere([&](QQuickItem* item) {
        if (item->objectName().startsWith(prefix)) found.append(item->property("text").toString());
        return false;
      });
      return found;
    };
    world.waitFor([&] { return texts(S("queueText-")) == QStringList{c[0]} && texts(S("queueWaiting-")) == QStringList{c[1]}; },
                  [&] { return S("the queue to list %1 then %2; it lists %3, then %4, of the turn %5")
                                 .arg(c[0], c[1], texts(S("queueText-")).join(S(" | ")), texts(S("queueWaiting-")).join(S(" | ")),
                                      show(world.state(S("turn")).toMap())); });
  });


  // ---- The queue, edited and cancelled from its card, and the send control.

  // The queued run showing `text`, from what the composer lists.
  const auto queuedRun = [](World& world, const QString& text) {
    for (const QVariant& entry : world.state(S("turn")).toMap().value(S("queue")).toList()) {
      if (entry.toMap().value(S("text")) == text) return entry.toMap().value(S("runId")).toString();
    }
    fail(S("\"%1\" is not queued; the turn is %2").arg(text, show(world.state(S("turn")).toMap())));
  };
  // The card's button for a queued message, tapped as a finger does.
  const auto tapQueued = [queuedRun](World& world, const QString& button, const QString& text) {
    const QString runId = queuedRun(world, text);
    const QString name = button + S("-") + runId;
    // A folded queue is opened from its header first.
    if (world.find(name) == nullptr && world.find(S("queueToggle")) != nullptr) world.tap(S("queueToggle"));
    world.tap(world.item(name));
    world.sync();
  };

  step(S("the user edits it to %1").arg(kQuoted), [tapQueued](World& world, const Captures& c, const Table&) {
    expectedCommand = S("queued-run.edit");
    tapQueued(world, S("queueEdit"), lastQueued);
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == lastQueued; },
                  [&] { return S("the composer to hold the queued message; it reads %1").arg(input->property("text").toString()); });
    world.tap(input);
    world.press(S("ctrl+a"));
    world.type(c[0]);
    expect(input->property("text").toString() == c[0], S("the composer reads %1").arg(input->property("text").toString()));
    world.tap(S("primaryAction"));
    world.sync();
  });
  step(S("%1 runs after the current turn").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(!expectedCommand.isEmpty(), S("no step sent the edit or the resume"));
    const QList<QJsonObject> sent = commandsOf(world, expectedCommand);
    expect(!sent.isEmpty(), S("the MC to get %1; it has %2").arg(expectedCommand, describeCommands(world)));
    if (expectedCommand == QLatin1String("queued-run.edit")) {
      expect(sent.last().value(QLatin1String("text")) == c[0] && sent.last().value(QLatin1String("threadId")) == world.thread,
             S("the edit to carry %1; the MC has %2").arg(c[0], describeCommands(world)));
    }
  });
  step(S("the user cancels it"), [tapQueued](World& world, const Captures&, const Table&) { tapQueued(world, S("queueRemove"), lastQueued); });
  step(S("it does not run"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> cancels = commandsOf(world, S("queued-run.cancel"));
    expect(cancels.size() == 1 && cancels.first().value(QLatin1String("threadId")) == world.thread,
           S("the MC has %1").arg(describeCommands(world)));
  });

  // Editing from the card: the message goes into the composer.
  const auto startEdit = [queue, tapQueued](World& world, const QString& text) {
    queue(world, text, {});
    lastQueued = text;
    priorDraft = composer(world).value(S("text")).toString();
    tapQueued(world, S("queueEdit"), text);
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == text; },
                  [&] { return S("the composer to hold %1; it reads %2").arg(text, input->property("text").toString()); });
  };
  step(S("the user is editing the queued message %1").arg(kQuoted), [startEdit](World& world, const Captures& c, const Table&) { startEdit(world, c[0]); });
  step(S("the user is editing the queued message %1 and has changed its text").arg(kQuoted), [startEdit](World& world, const Captures& c, const Table&) {
    startEdit(world, c[0]);
    world.tap(editor(world));
    world.type(S(" and more"));
    editedText = editor(world)->property("text").toString();
    // The controller has the text once the composer's debounce is through.
    world.waitFor([&] { return composer(world).value(S("text")).toString() == editedText; },
                  [&] { return S("the draft to reach the controller; the composer is %1").arg(show(composer(world))); });
  });
  step(S("the user clears the text and saves"), [](World& world, const Captures&, const Table&) {
    QQuickItem* input = editor(world);
    world.tap(input);
    world.press(S("ctrl+a"));
    world.press(S("Backspace"));
    expect(input->property("text").toString().isEmpty(), S("the composer reads %1").arg(input->property("text").toString()));
    world.tap(S("primaryAction"));
    world.sync();
  });
  step(S("the user is told a queued message cannot be left empty"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("A queued message cannot be left empty"), false); },
                  [&] { return S("the notice; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the message is not changed"), [](World& world, const Captures&, const Table&) {
    expect(commandsOf(world, S("queued-run.edit")).isEmpty(), S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("the composer's own draft is empty"), [](World&, const Captures&, const Table&) {
    expect(priorDraft.isEmpty(), S("the thread's draft before the edit read %1").arg(priorDraft));
  });
  step(S("the message starts running on another device"), [](World& world, const Captures&, const Table&) {
    setEntity(world.mc, world.thread, S("run"), S("run-%1").arg(world.mc.part<FakeStreams>().ordinal), {{S("status"), S("running")}});
    world.sync();
  });
  step(S("the edit mode ends"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return (composer(world).value(S("editingQueuedRunId"))).isNull(); },
                  [&] { return S("the edit to end; the composer is %1").arg(show(composer(world))); });
  });
  step(S("the edited text is in the composer"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composer(world).value(S("text")).toString() == editedText; },
                  [&] { return S("the edit; the composer is %1").arg(show(composer(world))); });
  });
  step(S("the user is told the message already started and the edit is back in the composer"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Your unsaved edit was kept in the composer."), false); },
                  [&] { return S("the notice; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the app restarts"), [](World& world, const Captures&, const Table&) {
    world.background();
    world.close();
    world.open();
  });
  step(S("the composer is not in edit mode"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected"); },
                  [&] { return S("the reopened app to connect; it is %1").arg(show(world.state(S("connection")))); });
    world.waitFor([&] { return world.find(S("threadScreen")) != nullptr || world.find(S("homeScreen")) != nullptr; }, S("a screen"));
    if (world.find(S("threadScreen")) == nullptr) openThread(world, S("Fix checkout"));
    world.waitFor([&] { return world.find(S("input")) != nullptr; }, S("the composer"));
    world.waitFor([&] { return composer(world).value(S("editingQueuedRunId")).isNull(); },
                  [&] { return S("no edit; the composer is %1").arg(show(composer(world))); });
  });
  step(S("the composer holds the draft the user had before the edit"), [](World& world, const Captures&, const Table&) {
    expect(composer(world).value(S("text")).toString() == priorDraft, S("the composer is %1; the draft before the edit read %2").arg(show(composer(world)), priorDraft));
  });

  // A queue the MC holds after its restart.
  step(S("%1 was queued when %1 restarted").arg(kQuoted), [queue](World& world, const Captures& c, const Table&) {
    queue(world, c[0], {});
    for (const QVariant& entry : world.state(S("turn")).toMap().value(S("queue")).toList()) {
      setEntity(world.mc, world.thread, S("run"), entry.toMap().value(S("runId")).toString(), {{S("queueHeld"), true}});
    }
    world.sync();
  });
  step(S("the user opens the queued messages"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("queueCard")) != nullptr; }, [&] { return S("the queue; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the user is told the queue is held"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("queueHeld")) != nullptr; }, [&] { return S("the held queue; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the user resumes the queue"), [](World& world, const Captures&, const Table&) {
    expectedCommand = S("queue.resume");
    world.tap(S("queueResume"));
    world.sync();
  });

  step(S("the user dismisses the keyboard"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::inputMethod()->hide();
    world.sync();
  });
  step(S("the draft still reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(editor(world)->property("text").toString() == c[0], S("the composer reads %1").arg(editor(world)->property("text").toString()));
  });

  // The send control.
  step(S("the agent is idle and the message leaves at once"), [](World&, const Captures&, const Table&) {});
  step(S("the agent is working and the follow-up setting is (queue|steer)"), [working](World& world, const Captures& c, const Table&) {
    saveOwnSetting(world.mc, S("followUpBehavior"), c[0]);
    world.native().controller<SettingsController>()->writeDevice(S("followUpBehavior"), c[0]);
    working(world);
  });
  step(S("the user is editing a queued message"), [startEdit](World& world, const Captures&, const Table&) { startEdit(world, S("also update docs")); });
  step(S("the send control reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* input = editor(world);
    if (input->property("text").toString().isEmpty()) typeMessage(world, S("tweak"));
    QQuickItem* action = world.item(S("primaryAction"));
    world.waitFor([&] { return action->property("label").toString() == c[0]; },
                  [&] { return S("the send control to read %1; it reads %2").arg(c[0], action->property("label").toString()); });
  });

  // ---- composer/queue-and-steer.feature: its Background, and the queue's rows.
  step(S("a thread whose agent is working on a turn"), [working](World& world, const Captures&, const Table&) {
    world.mc.label = S("My MacBook");
    pairWithEnvironment(world);
    world.thread = haveThread(world, S("Fix checkout"));
    openThread(world, S("Fix checkout"));
    editor(world);
    working(world);
  });
  step(S("the follow-up behaviour setting is %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    saveOwnSetting(world.mc, S("followUpBehavior"), c[0]);
    world.native().controller<SettingsController>()->writeDevice(S("followUpBehavior"), c[0]);
    world.sync();
  });
  step(S("the user sends %1 the opposite way from the phone").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    typeMessage(world, c[0]);
    // A long press on the send control offers the other way.
    QQuickItem* action = world.item(S("primaryAction"));
    world.hold(action,
               [&] {
                 QQuickItem* steer = world.find(S("sendModeSteer"));
                 return steer != nullptr && steer->isVisible();
               },
               S("the steer way to send"));
    world.tap(S("sendModeSteer"));
    world.sync();
  });
  step(S("%1 steers the running turn").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); }, [&] { return S("the message; the MC has %1").arg(describeCommands(world)); });
    const QJsonObject message = commandsOf(world, S("message.dispatch")).last();
    expect(message.value(QLatin1String("text")) == c[0] && message.value(QLatin1String("deliveryIntent")) == QLatin1String("steer") &&
               message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("start_immediately"),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
  });
  step(S("the user removes a queued message on the phone"), [queue, tapQueued](World& world, const Captures&, const Table&) {
    queue(world, S("later"), {});
    lastQueued = S("later");
    tapQueued(world, S("queueRemove"), lastQueued);
  });
  step(S("the queued message is cancelled"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !commandsOf(world, S("queued-run.cancel")).isEmpty(); }, [&] { return S("the cancel; the MC has %1").arg(describeCommands(world)); });
    const QList<QJsonObject> cancels = commandsOf(world, S("queued-run.cancel"));
    expect(cancels.size() == 1 && cancels.first().value(QLatin1String("threadId")) == world.thread &&
               cancels.first().value(QLatin1String("runId")).toString().startsWith(S("run-")),
           S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("%1 is queued").arg(kQuoted), [queue](World& world, const Captures& c, const Table&) {
    queue(world, c[0], {});
    lastQueued = c[0];
  });
  step(S("%1 and %1 are queued").arg(kQuoted), [queue](World& world, const Captures& c, const Table&) {
    queue(world, c[0], {});
    // `queue` starts each scenario afresh; the second one only adds.
    FakeStreams& fake = world.mc.part<FakeStreams>();
    const int ordinal = ++fake.ordinal;
    const QString run = S("run-%1").arg(ordinal);
    setEntity(world.mc, world.thread, S("message"), S("message:") + run, {{S("id"), S("message:") + run}, {S("role"), S("user")}, {S("text"), c[1]}});
    setEntity(world.mc, world.thread, S("run"), run,
              {{S("id"), run}, {S("ordinal"), ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ordinal},
               {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}});
    world.sync();
  });
  // A queued row's control, unfolding the queue first.
  const auto rowPart = [queuedRun](World& world, const QString& part, const QString& text) -> QQuickItem* {
    const QString name = part + S("-") + queuedRun(world, text);
    if (world.find(name) == nullptr && world.find(S("queueToggle")) != nullptr) world.tap(S("queueToggle"));
    world.waitFor([&] { return world.find(name) != nullptr && world.find(name)->isVisible(); },
                  [&] { return S("%1; the screen says: %2").arg(name, screenTexts(world)); });
    return world.item(name);
  };
  step(S("the user looks at %1 in the queue").arg(kQuoted), [rowPart](World& world, const Captures& c, const Table&) {
    rowPart(world, S("queueText"), c[0]);
  });
  step(S("the user is offered to send %1 now, to edit it and to remove it").arg(kQuoted), [rowPart](World& world, const Captures& c, const Table&) {
    QStringList offered;
    for (const QString& part : {S("queueSendNow"), S("queueEdit"), S("queueRemove")}) {
      if (rowPart(world, part, c[0])->isEnabled()) offered.append(part);
    }
    expect(offered.size() == 3 && rowPart(world, S("queueSendNow"), c[0])->property("text") == QLatin1String("Send now"),
           S("the row offers %1").arg(offered.join(u", ")));
  });
  step(S("the user is not offered to move %1 in the queue").arg(kQuoted), [queuedRun](World& world, const Captures& c, const Table&) {
    QStringList moves;
    const std::function<void(QQuickItem*)> walk = [&](QQuickItem* item) {
      // Remove is not a move.
      static const QRegularExpression move(S("(?<![Rr]e)[Mm]ove|[Hh]andle|[Dd]rag|[Rr]eorder|[Pp]osition"));
      if (item->isVisible() && move.match(item->objectName()).hasMatch()) moves.append(item->objectName());
      for (QQuickItem* child : item->childItems()) walk(child);
    };
    walk(world.item(S("queueRow-") + queuedRun(world, c[0])));
    expect(moves.isEmpty(), S("the row offers %1").arg(moves.join(u", ")));
  });
  const auto queuedAndHeld = [queue](World& world, const QStringList& texts) {
    queue(world, texts.first(), {});
    FakeStreams& fake = world.mc.part<FakeStreams>();
    for (const QString& text : texts.mid(1)) {
      const int ordinal = ++fake.ordinal;
      const QString run = S("run-%1").arg(ordinal);
      setEntity(world.mc, world.thread, S("message"), S("message:") + run, {{S("id"), S("message:") + run}, {S("role"), S("user")}, {S("text"), text}});
      setEntity(world.mc, world.thread, S("run"), run,
                {{S("id"), run}, {S("ordinal"), ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ordinal},
                 {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}});
    }
    for (const QVariant& entry : world.state(S("turn")).toMap().value(S("queue")).toList()) {
      setEntity(world.mc, world.thread, S("run"), entry.toMap().value(S("runId")).toString(), {{S("queueHeld"), true}});
    }
    setEntity(world.mc, world.thread, S("run"), world.run, {{S("status"), S("completed")}, {S("completedAt"), kNow}});
    updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
    world.sync();
  };
  step(S("%1, %1 and %1 are queued and held, and the turn is no longer running").arg(kQuoted),
       [queuedAndHeld](World& world, const Captures& c, const Table&) { queuedAndHeld(world, {c[0], c[1], c[2]}); });
  step(S("the user is offered to send %1 now instead of steering it").arg(kQuoted), [rowPart, queuedRun](World& world, const Captures& c, const Table&) {
    QQuickItem* send = rowPart(world, S("queueSendNow"), c[0]);
    world.waitFor([&] { return send->isEnabled(); }, S("Send now to be usable"));
    expect(send->property("text") == QLatin1String("Send now"), S("the row offers %1").arg(send->property("text").toString()));
    world.tap(send);
    world.waitFor([&] { return !commandsOf(world, S("queued-run.start")).isEmpty(); }, [&] { return S("the MC has %1").arg(describeCommands(world)); });
    expect(commandsOf(world, S("queued-run.start")).last().value(QLatin1String("runId")) == queuedRun(world, c[0]) &&
               commandsOf(world, S("queued-message.promote-to-steer")).isEmpty(),
           S("the MC has %1").arg(describeCommands(world)));
  });
  // The agent's question takes the composer from the queue. The MC closes it
  // once it is answered.
  const auto askQuestion = [](World& world) {
    world.mc.effects.append([&world](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("runtime-request.respond") ||
          command.value(QLatin1String("requestId")) != QLatin1String("request-queue"))
        return;
      setEntity(world.mc, world.thread, S("runtime-request"), S("request-queue"), {{S("status"), S("resolved")}});
      setEntity(world.mc, world.thread, S("turn-item"), S("question-queue"), {{S("status"), S("completed")}});
    });
    FakeStreams& fake = world.mc.part<FakeStreams>();
    setEntity(world.mc, world.thread, S("runtime-request"), S("request-queue"),
              {{S("id"), S("request-queue")}, {S("status"), S("pending")}, {S("responseCapability"), QJsonObject{{S("type"), S("live")}}}});
    setEntity(world.mc, world.thread, S("turn-item"), S("question-queue"),
              {{S("id"), S("question-queue")}, {S("type"), S("user_input_request")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("waiting")}, {S("requestId"), S("request-queue")}, {S("updatedAt"), kNow},
               {S("questions"), QJsonArray{QJsonObject{{S("id"), S("database")}, {S("header"), S("Database")}, {S("question"), S("Which database?")},
                                                       {S("options"), QJsonArray{QJsonObject{{S("label"), S("Postgres")}, {S("description"), QString()}}}},
                                                       {S("multiSelect"), false}, {S("allowCustomAnswer"), true}}}}});
    world.sync();
    world.waitFor([&] { return !world.state(S("turn")).toMap().value(S("questions")).toList().isEmpty(); },
                  [&] { return S("the question; the turn is %1").arg(show(world.state(S("turn")))); });
  };
  step(S("the agent has asked the user a question"), [askQuestion](World& world, const Captures&, const Table&) { askQuestion(world); });
  step(S("the agent asks which database to use"), [askQuestion](World& world, const Captures&, const Table&) { askQuestion(world); });
  step(S("editing %1 is unavailable, saying %1").arg(kQuoted), [rowPart](World& world, const Captures& c, const Table&) {
    QQuickItem* edit = rowPart(world, S("queueEdit"), c[0]);
    world.waitFor([&] { return !edit->isEnabled(); }, S("Edit to be unavailable"));
    expect(edit->property("toolTip") == c[1], S("Edit says \"%1\"").arg(edit->property("toolTip").toString()));
    // A disabled button takes no tap; what it would ask is refused too.
    world.bridge().dispatch(S("composer.queue.edit"), QVariantMap{{S("runId"), edit->objectName().mid(int(qstrlen("queueEdit-")))}});
    world.sync();
    expect(composer(world).value(S("editingQueuedRunId")).isNull(), S("an edit opened"));
  });
  step(S("the edit-latest shortcut does nothing"), [](World& world, const Captures&, const Table&) {
    const QString before = composer(world).value(S("text")).toString();
    world.bridge().dispatch(S("composer.queue.edit"), QVariantMap());
    world.sync();
    expect(composer(world).value(S("editingQueuedRunId")).isNull() && composer(world).value(S("text")).toString() == before,
           S("the composer is %1").arg(show(composer(world))));
  });
  // ---- A queued edit belongs to its thread.

  // The composer's text replaced as the user types it, through to the controller.
  const auto retype = [](World& world, const QString& text) {
    QQuickItem* input = editor(world);
    world.tap(input);
    world.press(S("ctrl+a"));
    world.type(text);
    world.waitFor([&] { return composer(world).value(S("text")).toString() == text; },
                  [&] { return S("the draft to reach the controller; the composer is %1").arg(show(composer(world))); });
  };
  // Home, then the thread `title` on its own screen.
  const auto go = [](World& world, const QString& title) {
    for (int tries = 0; tries < 6 && world.find(S("homeScreen")) == nullptr; ++tries) {
      world.back();
      world.sync();
    }
    openThread(world, title);
    world.sync();
  };
  const auto otherThread = [go](World& world) {
    haveThread(world, S("Other"));
    go(world, S("Other"));
  };
  const auto editing = [](World& world, const QString& text) {
    QQuickItem* input = editor(world);
    world.waitFor([&] { return !composer(world).value(S("editingQueuedRunId")).isNull() && input->property("text").toString() == text; },
                  [&] { return S("the edit of %1; the composer is %2 and reads %3").arg(text, show(composer(world)), input->property("text").toString()); });
  };
  // The phone has no edit key: the last queued message is edited from its card.
  step(S("the user starts editing the last queued message from the start of the composer"), [tapQueued](World& world, const Captures&, const Table&) {
    priorDraft = composer(world).value(S("text")).toString();
    tapQueued(world, S("queueEdit"), lastQueued);
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == lastQueued; },
                  [&] { return S("the composer to hold %1; it reads %2").arg(lastQueued, input->property("text").toString()); });
  });
  step(S("the user changes the edit to %1").arg(kQuoted), [retype](World& world, const Captures& c, const Table&) { retype(world, c[0]); });
  step(S("the user edits the queued message again to %1").arg(kQuoted), [retype](World& world, const Captures& c, const Table&) { retype(world, c[0]); });
  step(S("the user (?:switches|switched) to thread B and back to thread A"), [go, otherThread](World& world, const Captures&, const Table&) {
    otherThread(world);
    go(world, S("Fix checkout"));
  });
  step(S("the user has gone to another thread"), [otherThread](World& world, const Captures&, const Table&) { otherThread(world); });
  step(S("the user is still editing the queued message, reading %1").arg(kQuoted), [editing](World& world, const Captures& c, const Table&) { editing(world, c[0]); });
  step(S("the user is editing the queued %1").arg(kQuoted), [startEdit](World& world, const Captures& c, const Table&) { startEdit(world, c[0]); });
  step(S("the user is editing the queued %1 again").arg(kQuoted), [editing](World& world, const Captures& c, const Table&) { editing(world, c[0]); });
  step(S("the user is editing a queued message in thread A"), [startEdit](World& world, const Captures&, const Table&) { startEdit(world, S("fix typo")); });
  step(S("the user is editing the queued %1 with a change").arg(kQuoted), [startEdit, retype](World& world, const Captures& c, const Table&) {
    startEdit(world, c[0]);
    retype(world, c[0] + S(" and the docs"));
  });
  step(S("the user saved %1 over the queued %1 and the MC has not answered yet").arg(kQuoted), [startEdit, retype](World& world, const Captures& c, const Table&) {
    startEdit(world, c[1]);
    world.mc.hold(S("answers:") + world.thread);
    retype(world, c[0]);
    world.tap(S("primaryAction"));
    world.sync();
    expect(commandsOf(world, S("queued-run.edit")).size() == 1, S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("the first save finishes"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    world.sync();
    expect(commandsOf(world, S("queued-run.edit")).size() == 1, S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("the queued run of %1 starts").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // Its run, by its message: the edit may have left the thread's screen.
    QString run;
    const QMap<QString, QJsonObject> entities = world.mc.part<FakeStreams>().threads.value(world.thread);
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      if (it.key().startsWith(S("message\n")) && it->value(QLatin1String("text")) == c[0])
        run = it->value(QLatin1String("id")).toString().mid(int(qstrlen("message:")));
    }
    expect(!run.isEmpty(), S("no queued message reads %1").arg(c[0]));
    setEntity(world.mc, world.thread, S("run"), run, {{S("status"), S("running")}});
    world.sync();
  });
  step(S("the edit has ended"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composer(world).value(S("editingQueuedRunId")).isNull(); },
                  [&] { return S("the edit to end; the composer is %1").arg(show(composer(world))); });
  });
  const auto toastsTitled = [](World& world, const QString& title) {
    QVariantList found;
    for (const QVariant& toast : world.state(S("toasts")).toMap().value(S("items")).toList()) {
      if (toast.toMap().value(S("title")) == title) found.append(toast);
    }
    return found;
  };
  step(S("no message about the edit is shown"), [toastsTitled](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantList shown = toastsTitled(world, S("Queued message is no longer queued"));
    expect(shown.isEmpty(), S("the phone says %1").arg(show(shown)));
  });
  step(S("the changed edit waits in the thread's composer if it was empty, with a message naming the thread"),
       [go, toastsTitled](World& world, const Captures&, const Table&) {
         world.waitFor([&] {
           const QVariantList shown = toastsTitled(world, S("Queued message is no longer queued"));
           return std::any_of(shown.cbegin(), shown.cend(), [](const QVariant& toast) {
             return toast.toMap().value(S("description")).toString().contains(S("Fix checkout"));
           });
         }, [&] { return S("a toast naming \"Fix checkout\"; the toasts are %1").arg(show(world.state(S("toasts")))); });
         // Back in the thread, the change is its draft, no longer an edit.
         go(world, S("Fix checkout"));
         QQuickItem* input = editor(world);
         world.waitFor([&] { return composer(world).value(S("editingQueuedRunId")).isNull() && input->property("text").toString() == S("fix typo and the docs"); },
                       [&] { return S("the draft; the composer is %1 and reads %2").arg(show(composer(world)), input->property("text").toString()); });
       });
  step(S("thread A is deleted"), [](World& world, const Captures&, const Table&) {
    QJsonObject row = world.mc.threads.take(world.thread);
    row.insert(S("deletedAt"), kNow);
    world.mc.sendRow(world.thread, row);
    const QString key = world.mc.environmentId + QLatin1Char(':') + world.thread;
    world.waitFor([&] { return !world.native().store()->thread(key).has_value(); }, S("the thread to go"));
  });

  // Saves of a queued edit, one at a time.
  step(S("the user saved %1 over it and the MC has not answered yet").arg(kQuoted), [tapQueued](World& world, const Captures& c, const Table&) {
    tapQueued(world, S("queueEdit"), lastQueued);
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == lastQueued; },
                  [&] { return S("the composer to hold the queued message; it reads %1").arg(input->property("text").toString()); });
    world.mc.hold(S("answers"));
    world.tap(input);
    world.press(S("ctrl+a"));
    world.type(c[0]);
    world.tap(S("primaryAction"));
    world.sync();
    expect(commandsOf(world, S("queued-run.edit")).size() == 1, S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("the user edits it again and saves %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* input = editor(world);
    world.tap(input);
    world.press(S("ctrl+a"));
    world.type(c[0]);
    world.tap(S("primaryAction"));
    world.sync();
  });
  step(S("%1 is sent only after the MC answered the first save").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(commandsOf(world, S("queued-run.edit")).size() == 1, S("the MC has %1").arg(describeCommands(world)));
    world.mc.answerHeld();
    world.waitFor([&] { return commandsOf(world, S("queued-run.edit")).size() == 2; }, [&] { return S("the MC has %1").arg(describeCommands(world)); });
    expect(commandsOf(world, S("queued-run.edit")).last().value(QLatin1String("text")) == c[0], S("the MC has %1").arg(describeCommands(world)));
  });
  step(S("the queued message ends as %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return composer(world).value(S("editingQueuedRunId")).isNull(); }, S("the edit to end"));
    const QList<QJsonObject> saves = commandsOf(world, S("queued-run.edit"));
    expect(saves.size() == 2 && saves.last().value(QLatin1String("text")) == c[0], S("the MC has %1").arg(describeCommands(world)));
  });

  // A follow-up sent during a turn.
  step(S("the user sends %1 to (run after the current turn|steer now)").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.native().controller<SettingsController>()->writeDevice(S("followUpBehavior"), c[1] == S("steer now") ? S("steer") : S("queue"));
    typeMessage(world, c[0]);
    world.tap(S("primaryAction"));
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); }, [&] { return S("the message; the MC has %1").arg(describeCommands(world)); });
  });
  step(S("the message waits until the current turn ends"), [](World& world, const Captures&, const Table&) {
    const QJsonObject message = commandsOf(world, S("message.dispatch")).last();
    expect(message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("queue_after_active") &&
               !message.contains(QLatin1String("deliveryIntent")),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
  });
  step(S("the agent receives the message during the turn"), [](World& world, const Captures&, const Table&) {
    const QJsonObject message = commandsOf(world, S("message.dispatch")).last();
    expect(message.value(QLatin1String("deliveryIntent")) == QLatin1String("steer") &&
               message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("start_immediately"),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
  });

  step(S("the user stops the agent"), [](World& world, const Captures&, const Table&) {
    QQuickItem* action = world.item(S("primaryAction"));
    expect(action->property("stopMode").toBool(), S("the composer does not offer Stop"));
    world.tap(action);
  });

  step(S("the turn ends"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> interrupts = commandsOf(world, S("run.interrupt"));
    expect(interrupts.size() == 1 && interrupts.first().value(QLatin1String("runId")) == world.run &&
               interrupts.first().value(QLatin1String("threadId")) == world.thread,
           S("the MC has %1").arg(describeCommands(world)));
    // The composer is back to sending once the MC says the run is over.
    world.waitFor([&] { return !composer(world).value(S("isRunning")).toBool() && !world.item(S("primaryAction"))->property("stopMode").toBool(); },
                  [&] { return S("the turn to end; the composer is %1").arg(show(composer(world))); });
  });

  step(S("the user has typed %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { typeMessage(world, c[0]); });

  step(S("the app is closed and reopened"), [](World& world, const Captures&, const Table&) {
    // Right after the last key, inside Composer.qml's debounce: a phone stops
    // the app as it leaves the front, and what is typed has to be kept by then.
    const QString typed = world.item(S("input"))->property("text").toString();
    world.background();
    expect(composer(world).value(S("text")).toString() == typed,
           S("the app left the front without keeping the draft; the composer is %1").arg(show(composer(world))));
    world.close();
    world.open();
  });

  step(S("the draft in %1 still reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected"); },
                  [&] { return S("the reopened app to connect; it is %1").arg(show(world.state(S("connection")))); });
    // The app opens where it was closed, or at home: the thread is a tap away.
    world.waitFor([&] { return world.find(S("threadScreen")) != nullptr || world.find(S("homeScreen")) != nullptr; },
                  [&] { return S("a screen; the app says: %1").arg(screenTexts(world)); });
    if (world.find(S("threadScreen")) == nullptr) openThread(world, c[0]);
    world.waitFor([&] { return world.item(S("title"))->property("text").toString() == c[0]; },
                  [&] { return S("%1; the screen says: %2").arg(c[0], screenTexts(world)); });
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == c[1]; },
                  [&] { return S("the draft; the composer reads: %1").arg(input->property("text").toString()); });
  });

  // Each model has three reasoning levels and the thread runs at low: picking
  // Opus and high changes both.
  step(S("the user picks the model %1 with (low|medium|high) reasoning").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    pickModel(world, c[0]);
    // The level, among the ones the reasoning picker lists once it is open.
    openChip(world, S("effortPicker"));
    QQuickItem* level = nullptr;
    world.waitFor(
        [&] {
          level = world.findWhere([&](QQuickItem* candidate) { return offers(candidate, c[1]); });
          return level != nullptr;
        },
        [&] { return S("the %1 level to be offered; the screen says: %2").arg(c[1], screenTexts(world)); });
    world.tap(level);
    // The list closes and the picker shows the level chosen.
    QQuickItem* picker = composerControl(world, S("effortPicker"));
    world.waitFor(
        [&] {
          return !picker->property("popup").value<QObject*>()->property("visible").toBool() &&
                 picker->property("displayText").toString().compare(c[1], Qt::CaseInsensitive) == 0;
        },
        [&] { return S("the composer to show %1 reasoning; it shows %2").arg(c[1], picker->property("displayText").toString()); });
  });

  step(S("the next message is sent to %1 with (low|medium|high) reasoning").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const auto [instance, slug] = listedModel(world, c[0]);
    typeMessage(world, S("next turn"));
    world.tap(S("primaryAction"));
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); }, [&] { return S("the message; the MC has %1").arg(describeCommands(world)); });
    const QJsonObject message = commandsOf(world, S("message.dispatch")).last();
    const QJsonObject selection = message.value(QLatin1String("modelSelection")).toObject();
    const QJsonArray options = selection.value(QLatin1String("options")).toArray();
    const bool effort = std::any_of(options.begin(), options.end(), [&](const QJsonValue& option) {
      return option.toObject().value(QLatin1String("id")) == QLatin1String("reasoningEffort") && option.toObject().value(QLatin1String("value")) == c[1];
    });
    expect(message.value(QLatin1String("threadId")) == world.thread && selection.value(QLatin1String("instanceId")) == instance &&
               selection.value(QLatin1String("model")) == slug && effort,
           S("the message was %1").arg(show(message.toVariantMap())));
  });

  // Opus's other options, from the toolbar beside its reasoning picker.
  step(S("the user picks the model %1 with the 1M context window and fast mode on").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    pickModel(world, c[0]);
    openChip(world, S("optionPicker:contextWindow"));
    QQuickItem* choice = nullptr;
    world.waitFor(
        [&] {
          choice = world.findWhere([&](QQuickItem* candidate) { return offers(candidate, S("1M")); });
          return choice != nullptr;
        },
        [&] { return S("the 1M context window to be offered; the screen says: %1").arg(screenTexts(world)); });
    world.tap(choice);
    QQuickItem* picker = composerControl(world, S("optionPicker:contextWindow"));
    world.waitFor([&] { return picker->property("displayText").toString() == QLatin1String("1M"); },
                  [&] { return S("the composer to show the 1M context window; it shows %1").arg(picker->property("displayText").toString()); });

    openChip(world, S("optionToggle:fastMode"));
    world.waitFor([&] { return composerControl(world, S("optionToggle:fastMode"))->property("checked").toBool(); }, S("fast mode to be on"));
  });

  step(S("the next message is sent to %1 with the 1M context window and fast mode on").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const auto [instance, slug] = listedModel(world, c[0]);
    typeMessage(world, S("next turn"));
    world.tap(S("primaryAction"));
    world.waitFor([&] { return !commandsOf(world, S("message.dispatch")).isEmpty(); }, [&] { return S("the message; the MC has %1").arg(describeCommands(world)); });
    const QJsonObject selection = commandsOf(world, S("message.dispatch")).last().value(QLatin1String("modelSelection")).toObject();
    const QJsonArray options = selection.value(QLatin1String("options")).toArray();
    const auto has = [&](const char* id, const QJsonValue& value) {
      return std::any_of(options.begin(), options.end(), [&](const QJsonValue& option) {
        return option.toObject().value(QLatin1String("id")) == QLatin1String(id) && option.toObject().value(QLatin1String("value")) == value;
      });
    };
    expect(selection.value(QLatin1String("model")) == slug && has("contextWindow", S("1m")) && has("fastMode", true),
           S("the message runs with %1").arg(show(selection.toVariantMap())));
  });
});

}  // namespace
