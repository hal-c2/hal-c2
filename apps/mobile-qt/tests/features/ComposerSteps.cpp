// A thread's own screen on the phone (features/mobile/composer.feature): the
// composer under a conversation, typed into and tapped as the user does, and
// what the MC receives from it.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "World.h"

namespace {

const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

QList<int> followers(FakeMc& mc, const QString& thread) {
  QList<int> ids;
  for (const int id : mc.subscribers(QStringLiteral("stream"))) {
    if (mc.shapeOf(id).value(QLatin1String("stream")).toString() == thread) ids.append(id);
  }
  return ids;
}

const FakeMc::Extension streams([](FakeMc& mc) {
  mc.onShape(QStringLiteral("stream"), [&mc](int id, const QJsonObject& shape) {
    FakeStreams& fake = mc.part<FakeStreams>();
    QJsonArray rows;
    const QMap<QString, QJsonObject> entities = fake.threads.value(shape.value(QLatin1String("stream")).toString());
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      const QStringList key = it.key().split(QLatin1Char('\n'));
      rows.append(QJsonArray{key.at(0), key.at(1), *it});
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), fake.seq},
             {QStringLiteral("at"), kNow}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}});
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), fake.seq}});
  });
});

// The MC's settings and what it can run turns on.
struct FakeConfig {
  QJsonArray providers;
  QJsonObject settings;
  int version = 0;
};

const FakeMc::Extension config([](FakeMc& mc) {
  mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject& shape) {
    if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
    const FakeConfig& fake = mc.part<FakeConfig>();
    mc.send({{QStringLiteral("t"), QStringLiteral("config")},
             {QStringLiteral("id"), id},
             {QStringLiteral("mc"), mc.name},
             {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), fake.providers}, {QStringLiteral("settings"), fake.settings}}}});
    mc.send({{QStringLiteral("t"), QStringLiteral("config.themes")}, {QStringLiteral("id"), id}, {QStringLiteral("themes"), QJsonArray()}});
  });
  mc.onRpc(QStringLiteral("hal-c2.readSettings"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeConfig& fake = mc.part<FakeConfig>();
    mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), fake.settings}, {QStringLiteral("version"), fake.version}});
  });
  mc.onRpc(QStringLiteral("hal-c2.writeSettings"), [&mc](const FakeMc::Rpc& rpc) {
    FakeConfig& fake = mc.part<FakeConfig>();
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
  FakeStreams& fake = mc.part<FakeStreams>();
  QJsonObject& entity = fake.threads[thread][kind + QLatin1Char('\n') + id];
  for (auto it = fields.begin(); it != fields.end(); ++it) entity.insert(it.key(), it.value());
  const int seq = ++fake.seq;
  // QJsonValue keeps the event nested: Apple clang before 20 reads
  // QJsonArray{QJsonArray{...}} as a copy of the inner array.
  for (const int follower : followers(mc, thread)) {
    mc.send({{QStringLiteral("t"), QStringLiteral("events")},
             {QStringLiteral("id"), follower},
             {QStringLiteral("offset"), seq},
             {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, QJsonObject{{QStringLiteral("s"), fields}}, kNow})}}});
  }
}

void updateRow(FakeMc& mc, const QString& thread, const QJsonObject& fields) {
  QJsonObject& row = mc.threads[thread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  mc.sendRow(thread, row);
}

void offerProviders(FakeMc& mc, const QJsonArray& providers) {
  mc.part<FakeConfig>().providers = providers;
  for (const int id : mc.subscribers(QStringLiteral("config"))) {
    mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers}});
  }
}

namespace {

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
  step(S("the agent is working on a turn"), [](World& world, const Captures&, const Table&) {
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
  });

  // A queued run behind the running turn and its message; `fields` are what
  // the message carries beyond its text.
  const auto queue = [](World& world, const QString& text, const QJsonObject& fields) {
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
    world.tap(S("effortPicker"));
    QQuickItem* level = nullptr;
    world.waitFor(
        [&] {
          level = world.findWhere([&](QQuickItem* candidate) {
            const auto* label = candidate->inherits("QQuickItemDelegate") ? candidate->property("contentItem").value<QQuickItem*>() : nullptr;
            return label && label->property("text").toString().compare(c[1], Qt::CaseInsensitive) == 0;
          });
          return level != nullptr;
        },
        [&] { return S("the %1 level to be offered; the screen says: %2").arg(c[1], screenTexts(world)); });
    world.tap(level);
    // The list closes and the picker shows the level chosen.
    QQuickItem* picker = world.item(S("effortPicker"));
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
    world.tap(S("optionPicker:contextWindow"));
    QQuickItem* choice = nullptr;
    world.waitFor(
        [&] {
          choice = world.findWhere([&](QQuickItem* candidate) {
            const auto* label = candidate->inherits("QQuickItemDelegate") ? candidate->property("contentItem").value<QQuickItem*>() : nullptr;
            return label && label->property("text").toString() == QLatin1String("1M");
          });
          return choice != nullptr;
        },
        [&] { return S("the 1M context window to be offered; the screen says: %1").arg(screenTexts(world)); });
    world.tap(choice);
    QQuickItem* picker = world.item(S("optionPicker:contextWindow"));
    world.waitFor([&] { return picker->property("displayText").toString() == QLatin1String("1M"); },
                  [&] { return S("the composer to show the 1M context window; it shows %1").arg(picker->property("displayText").toString()); });

    world.tap(S("optionToggle:fastMode"));
    world.waitFor([&] { return world.item(S("optionToggle:fastMode"))->property("checked").toBool(); }, S("fast mode to be on"));
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
