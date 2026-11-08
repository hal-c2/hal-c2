// The model, effort and permissions a turn runs with: the MC's providers
// (`config.providers`), the model picker ComposerController publishes
// (`modelPicker`), and the message a send makes of the choice
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "ComposerBrick.h"
#include "FakeConfig.h"
#include <QTest>

#include "Brick.h"
#include "Keymap.h"
#include "Turn.h"
#include "NavigationController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

// The providers the MC offers, and the model last made a favourite.
struct Catalogue {
  QJsonArray providers;
  QString favourite;
};

QJsonObject effort() {
  QJsonArray choices;
  for (const char* level : {"low", "medium", "high"}) {
    choices.append(QJsonObject{{QStringLiteral("id"), QString::fromLatin1(level)},
                               {QStringLiteral("label"), QString::fromLatin1(level)},
                               {QStringLiteral("isDefault"), QLatin1String(level) == QLatin1String("medium")}});
  }
  return {{QStringLiteral("id"), QStringLiteral("reasoningEffort")},
          {QStringLiteral("label"), QStringLiteral("Reasoning")},
          {QStringLiteral("type"), QStringLiteral("select")},
          {QStringLiteral("options"), choices},
          {QStringLiteral("currentValue"), QStringLiteral("medium")}};
}

QJsonObject provider(const QString& instanceId, const QString& driver, const QString& displayName, const QStringList& models,
                     const QJsonObject& fields = {}) {
  QJsonArray list;
  for (const QString& slug : models) {
    list.append(QJsonObject{{QStringLiteral("slug"), slug},
                            {QStringLiteral("name"), slug},
                            {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{effort()}}}}});
  }
  QJsonObject entry{{QStringLiteral("instanceId"), instanceId},
                    {QStringLiteral("driver"), driver},
                    {QStringLiteral("displayName"), displayName},
                    {QStringLiteral("enabled"), true},
                    {QStringLiteral("installed"), true},
                    {QStringLiteral("status"), QStringLiteral("ready")},
                    {QStringLiteral("models"), list}};
  for (auto it = fields.begin(); it != fields.end(); ++it) entry.insert(it.key(), it.value());
  return entry;
}

// The id of the thread's effort: the composer's first choice option.
QString effortId(World& world) {
  for (const QVariant& option : world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("options")).toList()) {
    if (option.toMap().value(QStringLiteral("type")) == QLatin1String("select")) return option.toMap().value(QStringLiteral("id")).toString();
  }
  return QStringLiteral("reasoningEffort");
}

QVariantList instances(World& world) {
  return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList();
}

QVariantMap instance(World& world, const QString& instanceId) {
  for (const QVariant& entry : instances(world)) {
    if (entry.toMap().value(QStringLiteral("instanceId")) == instanceId) return entry.toMap();
  }
  return {};
}

QStringList slugs(const QVariantMap& instance) {
  QStringList result;
  for (const QVariant& model : instance.value(QStringLiteral("models")).toList()) {
    result.append(model.toMap().value(QStringLiteral("slug")).toString());
  }
  return result;
}

// The MC offers `providers` and the picker lists them.
void offer(World& world, const QJsonArray& providers) {
  world.mc.part<Catalogue>().providers = providers;
  publishProviders(world.mc, providers);
  world.waitFor([&] { return instances(world).size() == std::count_if(providers.begin(), providers.end(), [](const QJsonValue& entry) {
                               return entry.toObject().value(QLatin1String("enabled")).toBool();
                             }); },
                [&] { return QStringLiteral("the picker to list the providers; it lists %1").arg(show(instances(world))); });
}

void add(World& world, const QJsonObject& entry) {
  QJsonArray providers = world.mc.part<Catalogue>().providers;
  for (qsizetype i = 0; i < providers.size(); ++i) {
    if (providers.at(i).toObject().value(QLatin1String("instanceId")) == entry.value(QLatin1String("instanceId"))) {
      providers.removeAt(i);
      break;
    }
  }
  providers.append(entry);
  offer(world, providers);
}

// Codex and Claude, as an MC with both signed in.
QJsonArray codexAndClaude() {
  return {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"),
                   {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")}),
          provider(QStringLiteral("claudeAgent"), QStringLiteral("claudeAgent"), QStringLiteral("Claude"),
                   {QStringLiteral("claude-opus"), QStringLiteral("claude-sonnet")})};
}

void updateThread(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(kThread, row);
  world.sync();
}

// The instance whose models include `slug`.
QString instanceOf(World& world, const QString& slug) {
  for (const QVariant& entry : instances(world)) {
    if (slugs(entry.toMap()).contains(slug)) return entry.toMap().value(QStringLiteral("instanceId")).toString();
  }
  fail(QStringLiteral("no provider lists %1; the picker lists %2").arg(slug, show(instances(world))));
  return {};
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

// Sends a turn and returns the commands it made, the message last.
QList<QJsonObject> sendTurn(World& world) {
  const qsizetype before = world.mc.commands.size();
  world.bridge().dispatch(QStringLiteral("composer.submit"),
                          QVariantMap{{QStringLiteral("text"), QStringLiteral("next turn")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  world.waitFor([&] {
    return world.mc.commands.size() > before &&
           world.mc.commands.last().value(QLatin1String("type")) == QLatin1String("message.dispatch");
  }, [&] { return QStringLiteral("the message; the MC has %1").arg(world.describeCommands()); });
  return world.mc.commands.mid(before);
}

bool favourite(World& world, const QString& slug) {
  for (const QVariant& entry : instances(world)) {
    const QVariantList models = entry.toMap().value(QStringLiteral("models")).toList();
    for (qsizetype i = 0; i < models.size(); ++i) {
      const QVariantMap model = models.at(i).toMap();
      // Favourites lead their provider's list.
      if (model.value(QStringLiteral("slug")) == slug) {
        return model.value(QStringLiteral("isFavorite")).toBool() &&
               std::all_of(models.cbegin(), models.cbegin() + i,
                           [](const QVariant& earlier) { return earlier.toMap().value(QStringLiteral("isFavorite")).toBool(); });
      }
    }
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The MC's providers.
  step(QStringLiteral("a project with an open thread on Codex"), [](World& world, const Captures&, const Table&) {
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                          {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                          {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.part<Catalogue>().providers = codexAndClaude();
    publishProviders(world.mc, codexAndClaude());
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
                         {QStringLiteral("runtimeMode"), QStringLiteral("full-access")}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5"); },
                  [&] { return QStringLiteral("the composer on gpt-5; it shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("the Cursor provider is not installed"), [](World& world, const Captures&, const Table&) {
    add(world, provider(QStringLiteral("cursor"), QStringLiteral("cursor"), QStringLiteral("Cursor"), {QStringLiteral("cursor-auto")},
                        {{QStringLiteral("installed"), false},
                         {QStringLiteral("status"), QStringLiteral("error")},
                         {QStringLiteral("message"), QStringLiteral("Cursor CLI is not installed.")}}));
  });
  step(QStringLiteral("Claude and a second Codex instance %1 are enabled").arg(q), [](World& world, const Captures& c, const Table&) {
    add(world, provider(QStringLiteral("codex_work"), QStringLiteral("codex"), c[0], {QStringLiteral("gpt-5-work")}));
    // And one the user turned off in settings.
    add(world, provider(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"), {QStringLiteral("big-pickle")},
                        {{QStringLiteral("enabled"), false}}));
  });
  step(QStringLiteral("the thread has already run a turn on Codex"), [](World& world, const Captures&, const Table&) {
    updateThread(world, {{QStringLiteral("latestRunId"), QStringLiteral("run-0")}});
    world.sync();
  });

  // providers/permission-modes.feature: the composer's own permission picker.
  step(QStringLiteral("a supervised thread"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Catalogue>().providers = codexAndClaude();
    publishProviders(world.mc, codexAndClaude());
    lookAtThread(world, kProject);
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
                         {QStringLiteral("runtimeMode"), QStringLiteral("approval-required")}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("runtimeMode")) == QLatin1String("approval-required"); },
                  [&] { return QStringLiteral("a supervised composer; it shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("the user switches the thread to auto-accept edits on desktop or mobile"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& mode : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (mode.toMap().value(QStringLiteral("value")) == QLatin1String("auto-accept-edits")) {
        world.bridge().dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("auto-accept-edits")}});
        return;
      }
    }
    fail(QStringLiteral("the composer does not offer auto-accept edits: %1").arg(show(composer(world).value(QStringLiteral("runtimeModes")))));
  });

  // The MC is told before any message, and the picker keeps the mode once the
  // thread's row carries it.
  step(QStringLiteral("the thread is in (.+) at once"), [](World& world, const Captures& c, const Table&) {
    QString mode;
    for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (entry.toMap().value(QStringLiteral("label")).toString().compare(c[0], Qt::CaseInsensitive) == 0) mode = entry.toMap().value(QStringLiteral("value")).toString();
    }
    world.waitFor([&] {
      return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
        return command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set") && command.value(QLatin1String("runtimeMode")) == mode;
      });
    }, [&] { return QStringLiteral("the access change for %1; the MC has %2").arg(mode, world.describeCommands()); });
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("type")) != QLatin1String("message.dispatch"), QStringLiteral("a message was sent with the access change"));
    }
    updateThread(world, {{QStringLiteral("runtimeMode"), mode}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("runtimeMode")) == mode; },
                  [&] { return QStringLiteral("the composer in %1; it shows %2").arg(mode, show(composer(world))); });
  });

  // What the user does.
  step(QStringLiteral("the user looks through the models"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the user chooses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceOf(world, c[0])}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user sets the effort to (low|medium|high)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.option.set"), QVariantMap{{QStringLiteral("id"), effortId(world)}, {QStringLiteral("value"), c[0]}});
  });
  step(QStringLiteral("the user sets the permissions to (.+)"), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& mode : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (mode.toMap().value(QStringLiteral("label")) == c[0]) {
        world.bridge().dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), mode.toMap().value(QStringLiteral("value"))}});
        return;
      }
    }
    fail(QStringLiteral("the composer offers %1").arg(show(composer(world).value(QStringLiteral("runtimeModes")))));
  });
  step(QStringLiteral("the user marks %1 as a favourite").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<Catalogue>().favourite = c[0];
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceOf(world, c[0])}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user removes it from the favourites"), [](World& world, const Captures&, const Table&) {
    const QString slug = world.mc.part<Catalogue>().favourite;
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceOf(world, slug)}, {QStringLiteral("model"), slug}});
  });

  // What the picker and the composer show.
  step(QStringLiteral("Cursor's models cannot be chosen"), [](World& world, const Captures&, const Table&) {
    const QVariantMap cursor = instance(world, QStringLiteral("cursor"));
    expect(!cursor.isEmpty() && !cursor.value(QStringLiteral("isAvailable")).toBool() && slugs(cursor).isEmpty(),
           QStringLiteral("the picker lists Cursor as %1").arg(show(cursor)));
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("cursor")}, {QStringLiteral("model"), QStringLiteral("cursor-auto")}});
    expect(composer(world).value(QStringLiteral("selectedInstanceId")) != QLatin1String("cursor"),
           QStringLiteral("the composer chose %1").arg(show(composer(world))));
  });
  step(QStringLiteral("Cursor is listed with the reason it is unavailable"), [](World& world, const Captures&, const Table&) {
    const QString reason = instance(world, QStringLiteral("cursor")).value(QStringLiteral("unavailableReason")).toString();
    expect(reason.contains(QLatin1String("Cursor CLI is not installed.")), QStringLiteral("the picker lists %1").arg(show(instances(world))));
  });
  step(QStringLiteral("Codex, %1 and Claude each list only their own models").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap work = instance(world, QStringLiteral("codex_work"));
    expect(slugs(instance(world, QStringLiteral("codex"))) == QStringList{QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")} &&
               work.value(QStringLiteral("displayName")) == c[0] && slugs(work) == QStringList{QStringLiteral("gpt-5-work")} &&
               slugs(instance(world, QStringLiteral("claudeAgent"))) == QStringList{QStringLiteral("claude-opus"), QStringLiteral("claude-sonnet")},
           QStringLiteral("the picker lists %1").arg(show(instances(world))));
  });
  step(QStringLiteral("a provider that is turned off in settings is not listed"), [](World& world, const Captures&, const Table&) {
    expect(instance(world, QStringLiteral("opencode")).isEmpty(), QStringLiteral("the picker lists %1").arg(show(instances(world))));
  });
  step(QStringLiteral("the composer shows %1 marked as a (\\w+) model").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap shown = composer(world);
    const QVariantMap chosen = instance(world, shown.value(QStringLiteral("selectedInstanceId")).toString());
    expect(shown.value(QStringLiteral("selectedModel")) == c[0] && chosen.value(QStringLiteral("displayName")) == c[1],
           QStringLiteral("the composer shows %1 of %2").arg(show(shown.value(QStringLiteral("selectedModel"))), show(chosen)));
  });
  step(QStringLiteral("%1 is listed among the favourites").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return favourite(world, c[0]); }, [&] { return QStringLiteral("a favourite; the picker lists %1").arg(show(instances(world))); });
  });
  step(QStringLiteral("it is no longer listed among the favourites"), [](World& world, const Captures&, const Table&) {
    const QString slug = world.mc.part<Catalogue>().favourite;
    world.waitFor([&] { return !favourite(world, slug); }, [&] { return QStringLiteral("no favourite; the picker lists %1").arg(show(instances(world))); });
  });

  // What the next turn runs with.
  step(QStringLiteral("the next turn runs on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject selection = sendTurn(world).last().value(QLatin1String("modelSelection")).toObject();
    expect(selection.value(QLatin1String("model")) == c[0], QStringLiteral("the message runs on %1").arg(show(selection.toVariantMap())));
  });
  step(QStringLiteral("the next turn moves the thread to Claude before it runs on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> commands = sendTurn(world);
    QVariantList made;
    for (const QJsonObject& command : commands) made.append(command.toVariantMap());
    const QJsonObject before = commands.size() > 1 ? commands.at(commands.size() - 2) : QJsonObject();
    expect(before.value(QLatin1String("type")) == QLatin1String("provider.switch") &&
               before.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")) == QLatin1String("claudeAgent") &&
               commands.last().value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")) == c[0],
           QStringLiteral("the send made %1").arg(show(made)));
  });
  step(QStringLiteral("the next turn runs with (low|medium|high) effort"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject selection = sendTurn(world).last().value(QLatin1String("modelSelection")).toObject();
    const QJsonArray options = selection.value(QLatin1String("options")).toArray();
    const bool found = std::any_of(options.begin(), options.end(), [&](const QJsonValue& option) {
      return option.toObject().value(QLatin1String("id")) == effortId(world) && option.toObject().value(QLatin1String("value")) == c[0];
    });
    expect(found, QStringLiteral("the message runs with %1").arg(show(selection.toVariantMap())));
  });
  step(QStringLiteral("the next turn runs in (.+)"), [](World& world, const Captures& c, const Table&) {
    QString mode;
    for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (entry.toMap().value(QStringLiteral("label")).toString().compare(c[0], Qt::CaseInsensitive) == 0) mode = entry.toMap().value(QStringLiteral("value")).toString();
    }
    const QString before = world.mc.threads.value(kThread).value(QLatin1String("runtimeMode")).toString();
    // The mode is set before the message, unless the thread already runs in it.
    QString runs = before;
    for (const QJsonObject& command : sendTurn(world)) {
      if (command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set")) runs = command.value(QLatin1String("runtimeMode")).toString();
    }
    expect(!mode.isEmpty() && runs == mode, QStringLiteral("the turn runs in %1, not %2").arg(runs, mode));
  });

  // Why a provider instance cannot be used, in its rail tooltip.
  step(QStringLiteral("the provider instance %1 (.+)").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject fields;
    if (c[1] == QLatin1String("is turned off in settings")) {
      fields = {{QStringLiteral("status"), QStringLiteral("disabled")}};
    } else if (c[1].startsWith(QLatin1String("failed its check with"))) {
      fields = {{QStringLiteral("status"), QStringLiteral("error")},
                {QStringLiteral("message"), c[1].mid(QStringLiteral("failed its check with \"").size()).chopped(1)}};
    } else if (c[1].startsWith(QLatin1String("reports the warning"))) {
      fields = {{QStringLiteral("status"), QStringLiteral("warning")},
                {QStringLiteral("message"), c[1].mid(QStringLiteral("reports the warning \"").size()).chopped(1)}};
    } else if (c[1] == QLatin1String("has not finished its check")) {
      fields = {{QStringLiteral("status"), QStringLiteral("checking")}};
    } else {
      fail(QStringLiteral("the steps do not know the state %1").arg(c[1]));
    }
    add(world, provider(QStringLiteral("codex_work"), QStringLiteral("codex"), c[0], {QStringLiteral("gpt-5-work")}, fields));
  });
  step(QStringLiteral("the user rests on %1 in the model picker").arg(q), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the user reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString reason = instance(world, QStringLiteral("codex_work")).value(QStringLiteral("unavailableReason")).toString();
    expect(reason == c[0], QStringLiteral("the picker says \"%1\", not \"%2\"").arg(reason, c[0]));
  });

  // Only the permissions the provider supports.
  const auto onlySupervisedAndFull = [](World& world) {
    add(world, provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"),
                        {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")},
                        {{QStringLiteral("supportedRuntimeModes"), QJsonArray{QStringLiteral("approval-required"), QStringLiteral("full-access")}}}));
  };
  step(QStringLiteral("the thread's provider supports only Supervised and Full access"), [onlySupervisedAndFull](World& world, const Captures&, const Table&) {
    onlySupervisedAndFull(world);
  });
  step(QStringLiteral("its provider now supports only Supervised and Full access"), [onlySupervisedAndFull](World& world, const Captures&, const Table&) {
    onlySupervisedAndFull(world);
  });
  step(QStringLiteral("the user opens the permissions"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("only Supervised and Full access are offered, each with a line saying what it allows"), [](World& world, const Captures&, const Table&) {
    QStringList labels;
    bool described = true;
    for (const QVariant& mode : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      labels.append(mode.toMap().value(QStringLiteral("label")).toString());
      described = described && !mode.toMap().value(QStringLiteral("description")).toString().isEmpty();
    }
    expect(labels == QStringList{QStringLiteral("Supervised"), QStringLiteral("Full access")} && described,
           QStringLiteral("the composer offers %1").arg(show(composer(world).value(QStringLiteral("runtimeModes")))));
  });
  step(QStringLiteral("the thread was saved with Auto-accept edits"), [](World& world, const Captures&, const Table&) {
    updateThread(world, {{QStringLiteral("runtimeMode"), QStringLiteral("auto-accept-edits")}});
  });
  step(QStringLiteral("the user looks at the composer"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the permissions read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString shown = composer(world).value(QStringLiteral("runtimeMode")).toString();
    QString label;
    for (const QVariant& mode : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (mode.toMap().value(QStringLiteral("value")) == shown) label = mode.toMap().value(QStringLiteral("label")).toString();
    }
    expect(label == c[0], QStringLiteral("the permissions read \"%1\" (%2)").arg(label, shown));
  });
  step(QStringLiteral("the thread's saved permissions are unchanged until the user chooses"), [](World& world, const Captures&, const Table&) {
    expect(world.mc.threads.value(kThread).value(QLatin1String("runtimeMode")) == QLatin1String("auto-accept-edits") &&
               std::none_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [](const QJsonObject& command) {
                 return command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set");
               }),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // Build and Plan only while the plan mode setting is on.
  step(QStringLiteral("the plan mode setting is on"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true),
           world.native().controller<SettingsController>()->deviceError());
    world.sync();
  });
  step(QStringLiteral("the composer offers to switch between \"Build\" and \"Plan\""), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composer(world).value(QStringLiteral("showInteractionModeToggle")).toBool(); },
                  [&] { return QStringLiteral("the Build/Plan switch; the composer shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("the user turns the plan mode setting off"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), false),
           world.native().controller<SettingsController>()->deviceError());
    world.sync();
  });
  step(QStringLiteral("the composer offers no such switch"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !composer(world).value(QStringLiteral("showInteractionModeToggle")).toBool(); },
                  [&] { return QStringLiteral("no Build/Plan switch; the composer shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("the next turn builds"), [](World& world, const Captures&, const Table&) {
    expect(composer(world).value(QStringLiteral("interactionMode")) == QLatin1String("default"),
           QStringLiteral("the composer is in %1").arg(composer(world).value(QStringLiteral("interactionMode")).toString()));
    for (const QJsonObject& command : sendTurn(world)) {
      expect(command.value(QLatin1String("interactionMode")) != QLatin1String("plan"), QStringLiteral("the send made %1").arg(show(command.toVariantMap())));
    }
  });

  // A saved model its provider no longer lists.
  step(QStringLiteral("the thread runs on OpenCode with the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    add(world, provider(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"), {c[0], QStringLiteral("big-pickle")}));
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("opencode")}, {QStringLiteral("model"), c[0]}}}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == c[0]; },
                  [&] { return QStringLiteral("the composer on %1; it shows %2").arg(c[0], show(composer(world))); });
  });
  step(QStringLiteral("OpenCode no longer lists %1").arg(q), [](World& world, const Captures&, const Table&) {
    add(world, provider(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"), {QStringLiteral("big-pickle")}));
  });
  step(QStringLiteral("the model reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The trigger reads "<model> (Unavailable)" from the kept model's flag.
    const QString slug = c[0].chopped(QStringLiteral(" (Unavailable)").size());
    bool kept = false;
    for (const QVariant& model : instance(world, QStringLiteral("opencode")).value(QStringLiteral("models")).toList()) {
      if (model.toMap().value(QStringLiteral("slug")) == slug) kept = model.toMap().value(QStringLiteral("isUnavailable")).toBool();
    }
    expect(kept && composer(world).value(QStringLiteral("selectedModel")) == slug,
           QStringLiteral("the picker lists %1").arg(show(instances(world))));
  });
  step(QStringLiteral("the thread's model is not changed to another one"), [](World& world, const Captures&, const Table&) {
    expect(world.mc.threads.value(kThread).value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")) ==
               composer(world).value(QStringLiteral("selectedModel")).toString(),
           QStringLiteral("the thread is on %1").arg(show(world.mc.threads.value(kThread).toVariantMap())));
  });

  // A composer with no usable provider. The thread runs on OpenCode, a
  // keep-unlisted driver, so its dropped model still resolves in the picker:
  // the stand-in has to win over the model name on the trigger itself.
  step(QStringLiteral("no provider can run a turn"), [](World& world, const Captures&, const Table&) {
    offer(world, {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"), {QStringLiteral("gpt-5")},
                           {{QStringLiteral("installed"), false},
                            {QStringLiteral("status"), QStringLiteral("error")},
                            {QStringLiteral("message"), QStringLiteral("codex not found")}}),
                  provider(QStringLiteral("claudeAgent"), QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {QStringLiteral("claude-opus")},
                           {{QStringLiteral("installed"), false}, {QStringLiteral("status"), QStringLiteral("error")}}),
                  provider(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"), {QStringLiteral("big-pickle")},
                           {{QStringLiteral("installed"), false}, {QStringLiteral("status"), QStringLiteral("error")}})});
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("opencode")}, {QStringLiteral("model"), QStringLiteral("kimi-k2")}}}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("kimi-k2"); },
                  [&] { return QStringLiteral("the composer on kimi-k2; it shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("one of the providers can be set up"), [](World& world, const Captures&, const Table&) {
    add(world, provider(QStringLiteral("cursor"), QStringLiteral("cursor"), QStringLiteral("Cursor"), {QStringLiteral("cursor-auto")},
                        {{QStringLiteral("installed"), false},
                         {QStringLiteral("status"), QStringLiteral("error")},
                         {QStringLiteral("setup"), QJsonObject{{QStringLiteral("canInstall"), true}, {QStringLiteral("canAuthenticate"), false}}}}));
  });
  step(QStringLiteral("none of the providers can be set up"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the composer shows %1 where the model would be").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    QQuickItem* picker = composerPart(world, QStringLiteral("modelPicker"));
    expect(picker != nullptr, QStringLiteral("the composer has no model picker"));
    world.waitFor([&] { return picker->property("triggerTitle") == c[0]; },
                  [&] { return QStringLiteral("the trigger to read \"%1\"; it reads \"%2\"").arg(c[0], picker->property("triggerTitle").toString()); });
  });
  step(QStringLiteral("no message can be sent"), [](World& world, const Captures&, const Table&) {
    expect(!composer(world).value(QStringLiteral("canSend")).toBool() &&
               composer(world).value(QStringLiteral("sendDisabledReason")) == QLatin1String("No provider available"),
           QStringLiteral("the composer shows %1").arg(show(composer(world))));
  });

  // The model cannot change while a message is on its way.
  step(QStringLiteral("the user has sent a message the MC has not taken yet"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    world.mc.hold(QStringLiteral("answers"));
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("text"), QStringLiteral("next turn")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("isSendBusy")).toBool(); }, QStringLiteral("the send to be on its way"));
  });
  step(QStringLiteral("the model picker cannot be opened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* picker = composerPart(world, QStringLiteral("modelPicker"));
    expect(picker != nullptr, QStringLiteral("the composer has no model picker"));
    expect(!picker->property("enabled").toBool(), QStringLiteral("the model picker can be opened while a message is on its way"));
    QMetaObject::invokeMethod(picker, "open");
    world.sync();
    expect(!picker->property("popup").value<QObject*>()->property("opened").toBool(), QStringLiteral("the model picker opened"));
  });
  step(QStringLiteral("it can be opened again once the MC takes the message"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    QQuickItem* picker = composerPart(world, QStringLiteral("modelPicker"));
    world.waitFor([&] { return !composer(world).value(QStringLiteral("isSendBusy")).toBool() && picker->property("enabled").toBool(); },
                  QStringLiteral("the model picker to open again"));
    QMetaObject::invokeMethod(picker, "open");
    world.waitFor([&] { return picker->property("popup").value<QObject*>()->property("opened").toBool(); }, QStringLiteral("the model picker to open"));
  });

  // The picker waits for the provider list.
  step(QStringLiteral("the environment has not yet reported its providers"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    offer(world, {});
  });
  step(QStringLiteral("the composer shows the thread's model and the model picker cannot be opened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* picker = composerPart(world, QStringLiteral("modelPicker"));
    expect(picker != nullptr, QStringLiteral("the composer has no model picker"));
    world.waitFor([&] { return !picker->property("enabled").toBool(); }, QStringLiteral("the model picker to wait"));
    expect(picker->property("triggerTitle") == composer(world).value(QStringLiteral("selectedModel")),
           QStringLiteral("the picker reads \"%1\"").arg(picker->property("triggerTitle").toString()));
    QMetaObject::invokeMethod(picker, "open");
    world.sync();
    expect(!picker->property("popup").value<QObject*>()->property("opened").toBool(), QStringLiteral("the model picker opened"));
  });
  step(QStringLiteral("the providers arrive"), [](World& world, const Captures&, const Table&) { offer(world, codexAndClaude()); });
  step(QStringLiteral("the model picker can be opened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* picker = composerPart(world, QStringLiteral("modelPicker"));
    world.waitFor([&] { return picker->property("enabled").toBool(); }, QStringLiteral("the model picker to open"));
    QMetaObject::invokeMethod(picker, "open");
    world.waitFor([&] { return picker->property("popup").value<QObject*>()->property("opened").toBool(); }, QStringLiteral("the model picker to open"));
  });

  // A favourite older model, kept for the removal step above.
  step(QStringLiteral("Codex lists the legacy model %1 and the user marked it as a favourite").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject legacy{{QStringLiteral("slug"), c[0]},
                       {QStringLiteral("name"), c[0]},
                       {QStringLiteral("isLegacy"), true},
                       {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{effort()}}}}};
    QJsonObject codex = provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"), {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")});
    QJsonArray models = codex.value(QLatin1String("models")).toArray();
    models.append(legacy);
    codex.insert(QStringLiteral("models"), models);
    add(world, codex);
    world.mc.part<Catalogue>().favourite = c[0];
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"),
                            QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), c[0]}});
    world.waitFor([&] { return favourite(world, c[0]); }, QStringLiteral("the favourite to be marked"));
  });

  // Plan mode, a beta setting, on a provider that offers it.
  step(QStringLiteral("plan mode is turned on"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true),
           world.native().controller<SettingsController>()->deviceError());
    world.mc.part<Catalogue>().providers = codexAndClaude();
    publishProviders(world.mc, codexAndClaude());
    world.sync();
  });
});

// The picker itself (qml/HalC2/Bricks/ModelPicker.qml) open over the thread:
// its numbered keys and the keymap's modelPickerOpen
// (navigation/focus.feature, keybinding-customisation.feature).
struct OpenPicker {
  QString second;
  QString thread;
};

QObject* pickerPopup(World& world) {
  return world.brick->item(QStringLiteral("picker"))->property("popup").value<QObject*>();
}

const Steps pickerSteps([] {
  Brick::registerSingletons();

  step(QStringLiteral("the model picker is open"), [](World& world, const Captures&, const Table&) {
    if (modelPickerShownOpen(world)) return;
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                          {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                          {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.part<Catalogue>().providers = codexAndClaude();
    if (world.shellSubscriptions() == 0) {
      world.connect();
    } else {
      world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
    }
    world.sync();
    publishProviders(world.mc, codexAndClaude());
    // A second thread, which mod+2 would jump to.
    world.mc.threads.insert(QStringLiteral("thread-other"), {{QStringLiteral("id"), QStringLiteral("thread-other")}, {QStringLiteral("title"), QStringLiteral("Other")},
                                                               {QStringLiteral("projectId"), kProject},
                                                               {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")},
                                                               {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
    world.mc.sendRow(QStringLiteral("thread-other"), world.mc.threads.value(QStringLiteral("thread-other")));
    lookAtThread(world, kProject);
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
                         {QStringLiteral("runtimeMode"), QStringLiteral("full-access")}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5"); },
                  [&] { return QStringLiteral("the composer on gpt-5; it shows %1").arg(show(composer(world))); });
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                          "Item { ModelPicker { objectName: \"picker\"; y: 500; width: 220\n"
                                          "  selectedInstanceId: Shell.state.composer ? Shell.state.composer.selectedInstanceId : null\n"
                                          "  selectedModel: Shell.state.composer ? Shell.state.composer.selectedModel : null } }\n",
                                          QSize(800, 700));
    world.brick->takesKeys = true;
    expect(QTest::qWaitForWindowActive(&world.brick->window()), QStringLiteral("the window did not become active"));
    QQuickItem* picker = world.brick->item(QStringLiteral("picker"));
    QMetaObject::invokeMethod(picker, "open");
    world.waitFor([&] { return pickerPopup(world)->property("opened").toBool(); }, QStringLiteral("the model picker to open"));
    OpenPicker& state = world.mc.part<OpenPicker>();
    state.thread = world.native().controller<NavigationController>()->threadKey();
    for (const QVariant& row : picker->property("rows").toList()) {
      if (row.toMap().value(QStringLiteral("jumpIndex")).toInt() == 1 && row.toMap().value(QStringLiteral("kind")) == QLatin1String("model")) {
        state.second = at(row, QStringLiteral("model.slug")).toString();
      }
    }
    expect(!state.second.isEmpty() && state.second != QLatin1String("gpt-5"), QStringLiteral("the picker lists %1").arg(show(picker->property("rows"))));
    // The keyboard is in the picker's search field.
    setKeyFocus(world, {{QStringLiteral("editable"), true}});
  });
  step(QStringLiteral("the second model is chosen"), [](World& world, const Captures&, const Table&) {
    const OpenPicker& state = world.mc.part<OpenPicker>();
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == state.second; },
                  [&] { return QStringLiteral("%1 to be chosen; the composer shows %2").arg(state.second, composer(world).value(QStringLiteral("selectedModel")).toString()); });
    expect(!pickerPopup(world)->property("opened").toBool(), QStringLiteral("the picker is still open"));
  });
  step(QStringLiteral("no thread jump happens"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.native().controller<NavigationController>()->threadKey() == world.mc.part<OpenPicker>().thread && !keyRan(world, QStringLiteral("thread.jump.2")),
           QStringLiteral("%1; the route is %2").arg(describeKeyPress(world), show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the composer has focus and a draft"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    const QString target = world.native().controller<NavigationController>()->threadKey();
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), target}, {QStringLiteral("text"), QStringLiteral("Add tax")}, {QStringLiteral("cursor"), 7}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("text")) == QLatin1String("Add tax"); }, QStringLiteral("the draft"));
    setKeyFocus(world, {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}});
  });
});

}  // namespace
