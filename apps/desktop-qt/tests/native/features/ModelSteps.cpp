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
    world.waitFor([&] { return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("locked")).toBool(); },
                  QStringLiteral("the picker to lock the provider"));
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
