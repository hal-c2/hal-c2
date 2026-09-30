// The model, effort and permissions a turn runs with: the node's providers
// (`config.providers`), the model picker ComposerController publishes
// (`modelPicker`), and the message a send makes of the choice
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

// The providers the node offers, and the model last made a favourite.
struct Catalogue {
  QJsonArray providers;
  QString favourite;
};

QJsonObject effort() {
  QJsonArray choices;
  for (const char* level : {"low", "medium", "high"}) {
    choices.append(QJsonObject{{QStringLiteral("id"), QString::fromLatin1(level)}, {QStringLiteral("label"), QString::fromLatin1(level)}});
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

// The node offers `providers` and the picker lists them.
void offer(World& world, const QJsonArray& providers) {
  world.node.part<Catalogue>().providers = providers;
  publishProviders(world.node, providers);
  world.waitFor([&] { return instances(world).size() == std::count_if(providers.begin(), providers.end(), [](const QJsonValue& entry) {
                               return entry.toObject().value(QLatin1String("enabled")).toBool();
                             }); },
                [&] { return QStringLiteral("the picker to list the providers; it lists %1").arg(show(instances(world))); });
}

void add(World& world, const QJsonObject& entry) {
  QJsonArray providers = world.node.part<Catalogue>().providers;
  for (qsizetype i = 0; i < providers.size(); ++i) {
    if (providers.at(i).toObject().value(QLatin1String("instanceId")) == entry.value(QLatin1String("instanceId"))) {
      providers.removeAt(i);
      break;
    }
  }
  providers.append(entry);
  offer(world, providers);
}

// Codex and Claude, as a node with both signed in.
QJsonArray codexAndClaude() {
  return {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"),
                   {QStringLiteral("gpt-5"), QStringLiteral("gpt-5-codex")}),
          provider(QStringLiteral("claudeAgent"), QStringLiteral("claudeAgent"), QStringLiteral("Claude"),
                   {QStringLiteral("claude-opus"), QStringLiteral("claude-sonnet")})};
}

void updateThread(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.node.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.node.sendRow(kThread, row);
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
  const qsizetype before = world.node.commands.size();
  world.bridge().dispatch(QStringLiteral("composer.submit"),
                          QVariantMap{{QStringLiteral("text"), QStringLiteral("next turn")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  world.waitFor([&] {
    return world.node.commands.size() > before &&
           world.node.commands.last().value(QLatin1String("type")) == QLatin1String("message.dispatch");
  }, [&] { return QStringLiteral("the message; the node has %1").arg(world.describeCommands()); });
  return world.node.commands.mid(before);
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

  // The node's providers.
  step(QStringLiteral("a project with an open thread on Codex"), [](World& world, const Captures&, const Table&) {
    world.node.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                          {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                          {QStringLiteral("scripts"), QJsonArray()}});
    world.node.part<Catalogue>().providers = codexAndClaude();
    publishProviders(world.node, codexAndClaude());
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
    world.waitFor([&] { return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("locked")).toBool(); },
                  QStringLiteral("the picker to lock the provider"));
  });

  // What the user does.
  step(QStringLiteral("the user looks through the models"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the user chooses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceOf(world, c[0])}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user sets the effort to (low|medium|high)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.option.set"),
                            QVariantMap{{QStringLiteral("id"), QStringLiteral("reasoningEffort")}, {QStringLiteral("value"), c[0]}});
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
    world.node.part<Catalogue>().favourite = c[0];
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceOf(world, c[0])}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user removes it from the favourites"), [](World& world, const Captures&, const Table&) {
    const QString slug = world.node.part<Catalogue>().favourite;
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
    const QString slug = world.node.part<Catalogue>().favourite;
    world.waitFor([&] { return !favourite(world, slug); }, [&] { return QStringLiteral("no favourite; the picker lists %1").arg(show(instances(world))); });
  });
  step(QStringLiteral("only Codex models can be chosen"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& entry : instances(world)) {
      const QVariantMap listed = entry.toMap();
      const bool codex = listed.value(QStringLiteral("driverKind")) == QLatin1String("codex");
      expect(codex == listed.value(QStringLiteral("isAvailable")).toBool() && codex == !slugs(listed).isEmpty(),
             QStringLiteral("the picker lists %1").arg(show(instances(world))));
    }
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("claude-opus")}});
    expect(composer(world).value(QStringLiteral("selectedInstanceId")) == QLatin1String("codex"),
           QStringLiteral("the composer chose %1").arg(show(composer(world))));
  });

  // What the next turn runs with.
  step(QStringLiteral("the next turn runs on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject selection = sendTurn(world).last().value(QLatin1String("modelSelection")).toObject();
    expect(selection.value(QLatin1String("model")) == c[0], QStringLiteral("the message runs on %1").arg(show(selection.toVariantMap())));
  });
  step(QStringLiteral("the next turn runs with (low|medium|high) effort"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject selection = sendTurn(world).last().value(QLatin1String("modelSelection")).toObject();
    const QJsonArray options = selection.value(QLatin1String("options")).toArray();
    const bool found = std::any_of(options.begin(), options.end(), [&](const QJsonValue& option) {
      return option.toObject().value(QLatin1String("id")) == QLatin1String("reasoningEffort") && option.toObject().value(QLatin1String("value")) == c[0];
    });
    expect(found, QStringLiteral("the message runs with %1").arg(show(selection.toVariantMap())));
  });
  step(QStringLiteral("the next turn runs in (.+)"), [](World& world, const Captures& c, const Table&) {
    QString mode;
    for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
      if (entry.toMap().value(QStringLiteral("label")) == c[0]) mode = entry.toMap().value(QStringLiteral("value")).toString();
    }
    const QString before = world.node.threads.value(kThread).value(QLatin1String("runtimeMode")).toString();
    // The mode is set before the message, unless the thread already runs in it.
    QString runs = before;
    for (const QJsonObject& command : sendTurn(world)) {
      if (command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set")) runs = command.value(QLatin1String("runtimeMode")).toString();
    }
    expect(!mode.isEmpty() && runs == mode, QStringLiteral("the turn runs in %1, not %2").arg(runs, mode));
  });

  // Plan mode, a beta setting, on a provider that offers it.
  step(QStringLiteral("plan mode is turned on"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true),
           world.native().controller<SettingsController>()->deviceError());
    world.node.part<Catalogue>().providers = codexAndClaude();
    publishProviders(world.node, codexAndClaude());
    world.sync();
  });
});

}  // namespace
