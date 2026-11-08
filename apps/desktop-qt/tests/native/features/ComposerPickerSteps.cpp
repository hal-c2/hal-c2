// The composer's toolbar on screen (ComposerBrick.h): the model picker's
// popup, the plan toggle, the pickers the toolbar shortcuts open and the
// send/stop button (features/composer/model-and-mode.feature,
// qt-scenarios.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QJSValue>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "DevicePanelSteps.h"
#include "FakeConfig.h"
#include "FakeGit.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

// The model the scenario expects the next choice to be.
struct Expected {
  QString instanceId;
  QString slug;
};

// The picker's height before a scenario opens a provider's older models.
struct PickerHeight {
  qreal height = 0;
};

QVariant plain(const QVariant& value) {
  return value.userType() == qMetaTypeId<QJSValue>() ? value.value<QJSValue>().toVariant() : value;
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QVariantList instances(World& world) {
  return world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList();
}

QQuickItem* picker(World& world) {
  QQuickItem* item = composerPart(world, QStringLiteral("modelPicker"));
  expect(item != nullptr, QStringLiteral("the composer has no model picker"));
  return item;
}

QObject* popupOf(QQuickItem* control) {
  QObject* popup = control->property("popup").value<QObject*>();
  expect(popup != nullptr, QStringLiteral("%1 has no popup").arg(control->objectName()));
  return popup;
}

bool pickerOpen(World& world) {
  return popupOf(picker(world))->property("opened").toBool();
}

QVariantList rows(World& world) {
  return plain(picker(world)->property("rows")).toList();
}

QString rowName(const QVariant& row) {
  return row.toMap().value(QStringLiteral("model")).toMap().value(QStringLiteral("name")).toString();
}

QStringList listed(World& world) {
  QStringList names;
  for (const QVariant& row : rows(world)) names.append(rowName(row));
  return names;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = composerBrick(world);
  expect(item->isVisible(), QStringLiteral("%1 is not on screen").arg(item->objectName()));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  expect(item != nullptr, QStringLiteral("the composer shows no %1").arg(objectName));
  return item;
}

// The picker has opened: the second model it lists is the one "the second
// model" steps mean.
void opened(World& world) {
  world.waitFor([&] { return pickerOpen(world); }, QStringLiteral("the model picker to open"));
  const QVariant second = rows(world).value(1);
  world.mc.part<Expected>() = {second.toMap().value(QStringLiteral("instance")).toMap().value(QStringLiteral("instanceId")).toString(),
                               second.toMap().value(QStringLiteral("model")).toMap().value(QStringLiteral("slug")).toString()};
}

void openPicker(World& world) {
  if (!popupOf(picker(world))->property("visible").toBool()) click(world, picker(world));
  opened(world);
}

void toggleByShell(World& world) {
  composerBrick(world);
  const bool open = pickerOpen(world);
  expect(world.native().controller<KeybindingController>()->commands()->run(QStringLiteral("modelPicker.toggle")),
         QStringLiteral("modelPicker.toggle is not a command"));
  if (open) {
    world.waitFor([&] { return !popupOf(picker(world))->property("visible").toBool(); }, QStringLiteral("the model picker to close"));
  } else {
    opened(world);
  }
}

// The row of the model named `name`, in whichever provider's list.
QQuickItem* rowOf(World& world, const QString& name) {
  for (const QVariant& entry : instances(world)) {
    const QVariantMap instance = entry.toMap();
    for (const QVariant& model : instance.value(QStringLiteral("models")).toList()) {
      if (model.toMap().value(QStringLiteral("name")) != name && model.toMap().value(QStringLiteral("slug")) != name) continue;
      const QString instanceId = instance.value(QStringLiteral("instanceId")).toString();
      const QString row = QStringLiteral("modelPickerRow:%1:%2").arg(instanceId, model.toMap().value(QStringLiteral("slug")).toString());
      // Its provider's list, from the rail.
      if (!composerPart(world, row)) click(world, part(world, QStringLiteral("modelPickerProvider:") + instanceId));
      world.waitFor([&] { return composerPart(world, row) != nullptr; }, [&] { return QStringLiteral("%1 to be listed; the picker lists %2").arg(name, listed(world).join(u", ")); });
      return part(world, row);
    }
  }
  fail(QStringLiteral("no provider offers %1; the picker offers %2").arg(name, show(instances(world))));
}

QJsonObject model(const QString& slug, const QString& name) {
  return {{QStringLiteral("slug"), slug},
          {QStringLiteral("name"), name},
          {QStringLiteral("capabilities"),
           QJsonObject{{QStringLiteral("optionDescriptors"),
                        QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("reasoningEffort")},
                                               {QStringLiteral("label"), QStringLiteral("Reasoning")},
                                               {QStringLiteral("type"), QStringLiteral("select")},
                                               {QStringLiteral("options"),
                                                QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("low")}, {QStringLiteral("label"), QStringLiteral("Low")}},
                                                           QJsonObject{{QStringLiteral("id"), QStringLiteral("high")}, {QStringLiteral("label"), QStringLiteral("High")}}}},
                                               {QStringLiteral("currentValue"), QStringLiteral("low")}}}}}}};
}

QJsonObject provider(const QString& id, const QString& name, const QJsonArray& models) {
  return {{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name}, {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("models"), models}};
}

QJsonArray providers(World& world) {
  return fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
}

// The MC's providers change and the picker follows.
void offer(World& world, const QJsonArray& list) {
  publishProviders(world.mc, list);
  world.sync();
  const qsizetype enabled = std::count_if(list.begin(), list.end(), [](const QJsonValue& entry) { return entry.toObject().value(QLatin1String("enabled")).toBool(); });
  world.waitFor([&] { return instances(world).size() == enabled; }, [&] { return QStringLiteral("the picker to list the providers; it lists %1").arg(show(instances(world))); });
}

void changeProvider(World& world, const QString& instanceId, const std::function<void(QJsonObject&)>& change) {
  QJsonArray list = providers(world);
  for (qsizetype i = 0; i < list.size(); ++i) {
    QJsonObject entry = list.at(i).toObject();
    if (entry.value(QLatin1String("instanceId")) != instanceId) continue;
    change(entry);
    list.replace(i, entry);
  }
  offer(world, list);
}

void updateThread(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(kThread, row);
  world.sync();
}

// A thread on Codex's GPT-5.4 with Codex and Claude offered, unless the
// scenario already has its thread.
void shellThread(World& world) {
  if (!world.mc.part<FakeStreams>().thread.isEmpty()) return;
  publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"),
                                       {model(QStringLiteral("gpt-5.4"), QStringLiteral("GPT-5.4")), model(QStringLiteral("gpt-5.5"), QStringLiteral("GPT-5.5"))}),
                              provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"),
                                       {model(QStringLiteral("opus"), QStringLiteral("Claude Opus")), model(QStringLiteral("sonnet"), QStringLiteral("Claude Sonnet"))})});
  openTurnThread(world);
  updateThread(world, {{QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5.4")}}}});
  world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5.4"); },
                [&] { return QStringLiteral("the composer on GPT-5.4; it shows %1").arg(show(composer(world))); });
}

// The thread's session has started on a provider that keeps its model.
void lockModel(World& world) {
  changeProvider(world, QStringLiteral("codex"), [](QJsonObject& entry) { entry.insert(QStringLiteral("requiresNewThreadForModelChange"), true); });
  updateThread(world, {{QStringLiteral("latestRunId"), QStringLiteral("run-0")},
                       {QStringLiteral("runtime"), QJsonObject{{QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")}}}});
}

QString driverOf(const QString& name) {
  return name == QLatin1String("Claude") ? QStringLiteral("claudeAgent") : name.toLower();
}

bool onlyListed(World& world, const QString& driver) {
  const QVariantList shown = rows(world);
  return !shown.isEmpty() && std::all_of(shown.cbegin(), shown.cend(), [&](const QVariant& row) {
    return row.toMap().value(QStringLiteral("instance")).toMap().value(QStringLiteral("driverKind")) == driver;
  });
}

QJsonObject nextMessage(World& world) {
  const qsizetype before = world.mc.commands.size();
  world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("next turn")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  world.waitFor([&] { return world.mc.commands.size() > before && world.mc.commands.last().value(QLatin1String("type")) == QLatin1String("message.dispatch"); },
                [&] { return QStringLiteral("the message; the MC has %1").arg(world.describeCommands()); });
  return world.mc.commands.last();
}

void expectSwitched(World& world, const QString& instanceId, const QString& slug) {
  world.waitFor([&] { return composer(world).value(QStringLiteral("selectedInstanceId")) == instanceId && composer(world).value(QStringLiteral("selectedModel")) == slug; },
                [&] { return QStringLiteral("the composer on %1 of %2; it is on %3 of %4").arg(slug, instanceId, composer(world).value(QStringLiteral("selectedModel")).toString(),
                                                                                                 composer(world).value(QStringLiteral("selectedInstanceId")).toString()); });
}

// A new thread's draft in a git project two environments have, on a model
// with an effort: every toolbar control has something to offer.
void toolbarDraft(World& world) {
  if (composerBrickShown(world)) return;
  const QString project = QStringLiteral("shop");
  const QJsonObject identity{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}};
  world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                       {QStringLiteral("scripts"), QJsonArray()}, {QStringLiteral("repositoryIdentity"), identity}});
  fakeGitRepo(world, QStringLiteral("/work/shop"), {QStringLiteral("main"), QStringLiteral("feature/tax")}, QStringLiteral("main"), QStringLiteral("main"));
  publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"), {model(QStringLiteral("gpt-5.4"), QStringLiteral("GPT-5.4"))})});
  world.connect();
  world.sync();
  world.mc.join(QStringLiteral("mc-b"), QStringLiteral("env-b"));
  world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("shell")).value(0)},
                 {QStringLiteral("mc"), QStringLiteral("mc-b")}, {QStringLiteral("online"), true}});
  world.mc.sendRows(QStringLiteral("mc-b"), {QJsonValue(QJsonArray{QStringLiteral("shop-copy"), QStringLiteral("project"),
                                                                    QJsonObject{{QStringLiteral("id"), QStringLiteral("shop-copy")}, {QStringLiteral("title"), project},
                                                                                {QStringLiteral("workspaceRoot"), QStringLiteral("/srv/shop")}, {QStringLiteral("scripts"), QJsonArray()},
                                                                                {QStringLiteral("repositoryIdentity"), identity}}})});
  world.sync();
  world.openDraft(project);
  world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("isDraft")).toBool(); }, QStringLiteral("the draft to open"));
  composerBrick(world);
}

const Steps steps([] {
  const QString q = kQuoted;

  // The catalogue (model-and-mode.feature's background has its own).
  step(QStringLiteral("Claude is enabled"), [](World& world, const Captures&, const Table&) {
    changeProvider(world, QStringLiteral("claudeAgent"), [](QJsonObject& entry) { entry.insert(QStringLiteral("enabled"), true); });
  });
  step(QStringLiteral("the shell lists models from Codex and Claude"), [](World& world, const Captures&, const Table&) { shellThread(world); });
  step(QStringLiteral("the shell has chosen %1 on (\\w+)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), driverOf(c[1])}, {QStringLiteral("model"), c[0]}});
    world.sync();
  });
  step(QStringLiteral("the shell lists %1 as a favourite").arg(q), [](World& world, const Captures& c, const Table&) {
    shellThread(world);
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("opus")}});
    world.sync();
    expect(c[0] == QLatin1String("Claude Opus"), QStringLiteral("the steps know Claude Opus only"));
  });
  const auto cannotUse = [](World& world, bool own) {
    if (own) {
      shellThread(world);
    } else {
      changeProvider(world, QStringLiteral("codex"), [](QJsonObject& entry) {
        QJsonArray models = entry.value(QLatin1String("models")).toArray();
        models.append(model(QStringLiteral("gpt-5.5"), QStringLiteral("gpt-5.5")));
        entry.insert(QStringLiteral("models"), models);
      });
    }
    lockModel(world);
  };
  step(QStringLiteral("the model %1 cannot be used because %1").arg(q), [cannotUse](World& world, const Captures&, const Table&) { cannotUse(world, false); });
  step(QStringLiteral("the shell says %1 cannot be used because %1").arg(q), [cannotUse](World& world, const Captures&, const Table&) { cannotUse(world, true); });
  step(QStringLiteral("the shell lists Cursor as unavailable because %1").arg(q), [](World& world, const Captures&, const Table&) {
    shellThread(world);
    QJsonArray list = providers(world);
    QJsonObject cursor = provider(QStringLiteral("cursor"), QStringLiteral("Cursor"), {model(QStringLiteral("cursor-auto"), QStringLiteral("Auto"))});
    cursor.insert(QStringLiteral("installed"), false);
    cursor.insert(QStringLiteral("status"), QStringLiteral("error"));
    cursor.insert(QStringLiteral("message"), QStringLiteral("Not installed."));
    list.append(cursor);
    offer(world, list);
  });

  // Opening and closing.
  step(QStringLiteral("the user opens the model picker"), [](World& world, const Captures&, const Table&) { openPicker(world); });
  step(QStringLiteral("the shell asks to toggle the model picker(?: again)?"), [](World& world, const Captures&, const Table&) {
    shellThread(world);
    toggleByShell(world);
  });
  step(QStringLiteral("the user presses the model picker shortcut(?: again)?"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    const bool open = popupOf(picker(world))->property("visible").toBool();
    expect(pressInComposer(world, QStringLiteral("mod+shift+m")), QStringLiteral("the composer's window did not take the key"));
    if (!open) opened(world);
  });
  step(QStringLiteral("the model picker is closed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !popupOf(picker(world))->property("visible").toBool(); }, QStringLiteral("the model picker to be closed"));
  });

  // Looking through the models.
  const auto search = [](World& world, const QString& query) {
    openPicker(world);
    typeInComposer(world, query);
    expect(picker(world)->property("query") == query, QStringLiteral("the search reads \"%1\"").arg(picker(world)->property("query").toString()));
  };
  step(QStringLiteral("the user searches the models for %1").arg(q), [search](World& world, const Captures& c, const Table&) { search(world, c[0]); });
  step(QStringLiteral("the user searches for %1").arg(q), [search](World& world, const Captures& c, const Table&) { search(world, c[0]); });
  step(QStringLiteral("only Claude's models are listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return onlyListed(world, QStringLiteral("claudeAgent")); }, [&] { return QStringLiteral("Claude's models; the picker lists %1").arg(listed(world).join(u", ")); });
  });
  step(QStringLiteral("Claude's models are listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return onlyListed(world, QStringLiteral("claudeAgent")) && rows(world).size() == 2; },
                  [&] { return QStringLiteral("Claude's models; the picker lists %1").arg(listed(world).join(u", ")); });
  });
  step(QStringLiteral("the model picker offers a Codex section and a Claude section"), [](World& world, const Captures&, const Table&) {
    expect(part(world, QStringLiteral("modelPickerProvider:codex"))->isVisible() && part(world, QStringLiteral("modelPickerProvider:claudeAgent"))->isVisible(),
           QStringLiteral("the rail does not show both"));
  });
  step(QStringLiteral("the Codex section lists only Codex's models"), [](World& world, const Captures&, const Table&) {
    click(world, part(world, QStringLiteral("modelPickerProvider:codex")));
    expect(listed(world) == QStringList{QStringLiteral("GPT-5.4"), QStringLiteral("GPT-5.5")}, QStringLiteral("the picker lists %1").arg(listed(world).join(u", ")));
  });
  step(QStringLiteral("the model picker shows %1 marked as a (\\w+) model").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    QQuickItem* title = part(world, QStringLiteral("modelPickerTitle"));
    QQuickItem* icon = part(world, QStringLiteral("modelPickerIcon"));
    world.waitFor([&] { return title->property("text") == c[0] && icon->isVisible() && icon->property("driverKind") == driverOf(c[1]); },
                  [&] { return QStringLiteral("the picker to name %1; it names %2 of %3").arg(c[0], title->property("text").toString(), icon->property("driverKind").toString()); });
  });
  step(QStringLiteral("%1 cannot be chosen").arg(q), [](World& world, const Captures& c, const Table&) {
    // The Device tab's push Send is unchoosable in the same words (DeviceSteps).
    if (checkDeviceCannotChoose(world, c[0])) return;
    const QVariantMap before = composer(world);
    click(world, rowOf(world, c[0]));
    expect(pickerOpen(world) && composer(world).value(QStringLiteral("selectedModel")) == before.value(QStringLiteral("selectedModel")),
           QStringLiteral("the composer is on %1").arg(composer(world).value(QStringLiteral("selectedModel")).toString()));
  });
  step(QStringLiteral("Cursor is listed with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* cursor = part(world, QStringLiteral("modelPickerProvider:cursor"));
    expect(cursor->isVisible() && cursor->property("tooltip") == c[0], QStringLiteral("Cursor says \"%1\"").arg(cursor->property("tooltip").toString()));
  });
  step(QStringLiteral("Cursor cannot be chosen"), [](World& world, const Captures&, const Table&) {
    const QString view = picker(world)->property("view").toString();
    click(world, part(world, QStringLiteral("modelPickerProvider:cursor")));
    expect(picker(world)->property("view") == view && onlyListed(world, QStringLiteral("codex")), QStringLiteral("the picker shows %1").arg(picker(world)->property("view").toString()));
  });

  // Choosing.
  step(QStringLiteral("the shell is asked to switch to %1 on (\\w+)").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSwitched(world, driverOf(c[1]), c[0]);
  });
  step(QStringLiteral("the shell is not asked to switch models"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5.4") && pickerOpen(world),
           QStringLiteral("the composer is on %1").arg(composer(world).value(QStringLiteral("selectedModel")).toString()));
  });
  const auto downAndEnter = [](World& world, const Captures&, const Table&) {
    pressInComposer(world, QStringLiteral("Down"));
    pressInComposer(world, QStringLiteral("Enter"));
  };
  step(QStringLiteral("the user presses Down and then Enter"), downAndEnter);
  step(QStringLiteral("the user moves to the next model and confirms it"), downAndEnter);
  step(QStringLiteral("the user presses the shortcut for the second model"), [](World& world, const Captures&, const Table&) {
    pressInComposer(world, QStringLiteral("mod+2"));
  });
  step(QStringLiteral("the shell is asked to switch to the second model listed"), [](World& world, const Captures&, const Table&) {
    const Expected& second = world.mc.part<Expected>();
    expect(!second.slug.isEmpty(), QStringLiteral("the picker listed one model"));
    expectSwitched(world, second.instanceId, second.slug);
    expect(!popupOf(picker(world))->property("opened").toBool(), QStringLiteral("the picker stayed open"));
  });
  step(QStringLiteral("the next turn runs on (?:that model|the second model listed)"), [](World& world, const Captures&, const Table&) {
    const Expected& second = world.mc.part<Expected>();
    expect(!second.slug.isEmpty(), QStringLiteral("the picker listed one model"));
    const QJsonObject selection = nextMessage(world).value(QLatin1String("modelSelection")).toObject();
    expect(selection.value(QLatin1String("model")) == second.slug && selection.value(QLatin1String("instanceId")) == second.instanceId,
           QStringLiteral("the message runs on %1, not %2").arg(show(selection.toVariantMap()), second.slug));
  });
  const auto nextProvider = [](World& world, const Captures&, const Table&) { pressInComposer(world, QStringLiteral("mod+shift+Down")); };
  step(QStringLiteral("the user moves to the next provider"), nextProvider);
  step(QStringLiteral("the user presses the next provider shortcut"), nextProvider);

  // Favourites.
  step(QStringLiteral("the favourites list %1 first").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(picker(world)->property("view") == QLatin1String("favorites") && rowName(rows(world).value(0)) == c[0],
           QStringLiteral("the %1 view lists %2").arg(picker(world)->property("view").toString(), listed(world).join(u", ")));
  });
  step(QStringLiteral("the user removes %1 from the favourites").arg(q), [](World& world, const Captures&, const Table&) {
    click(world, part(world, QStringLiteral("modelPickerFavorite:claudeAgent:opus")));
  });
  step(QStringLiteral("the shell is asked to toggle %1 on (\\w+) as a favourite").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto starred = [&] {
      for (const QVariant& entry : instances(world)) {
        if (entry.toMap().value(QStringLiteral("instanceId")) != driverOf(c[1])) continue;
        for (const QVariant& listed : entry.toMap().value(QStringLiteral("models")).toList()) {
          if (listed.toMap().value(QStringLiteral("slug")) == c[0]) return listed.toMap().value(QStringLiteral("isFavorite")).toBool();
        }
      }
      return true;
    };
    world.waitFor([&] { return !starred(); }, [&] { return QStringLiteral("%1 to leave the favourites; the picker lists %2").arg(c[0], show(instances(world))); });
    expect(world.native().controller<SettingsController>()->deviceValue(QStringLiteral("favorites")).toList().isEmpty(), QStringLiteral("this device still keeps a favourite"));
  });

  // Build and plan.
  const auto buildMode = [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"), {model(QStringLiteral("gpt-5.4"), QStringLiteral("GPT-5.4"))})});
    updateThread(world, {{QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5.4")}}}});
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true), QStringLiteral("plan mode could not be turned on"));
    composerBrick(world);
    world.waitFor([&] { return composer(world).value(QStringLiteral("showInteractionModeToggle")).toBool() && part(world, QStringLiteral("planToggle"))->isVisible(); },
                  QStringLiteral("the composer to offer Build and Plan"));
    expect(composer(world).value(QStringLiteral("interactionMode")) == QLatin1String("default"), QStringLiteral("the composer is not in build mode"));
  };
  step(QStringLiteral("the composer is in build mode"), buildMode);
  step(QStringLiteral("the composer is in build mode with keyboard focus"), buildMode);
  step(QStringLiteral("the user switches the composer's mode"), [](World& world, const Captures&, const Table&) { click(world, part(world, QStringLiteral("planToggle"))); });
  step(QStringLiteral("plan mode is requested"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return composer(world).value(QStringLiteral("interactionMode")) == QLatin1String("plan"); },
                  [&] { return QStringLiteral("plan mode; the composer shows %1").arg(show(composer(world))); });
    expect(part(world, QStringLiteral("planToggle"))->property("checked").toBool(), QStringLiteral("the toggle does not show Plan"));
  });
  step(QStringLiteral("the composer keeps the keyboard"), [](World& world, const Captures&, const Table&) {
    expect(composerEditor(world)->hasActiveFocus(), QStringLiteral("the editor lost the keyboard"));
  });

  // Send and stop.
  step(QStringLiteral("a turn is running"), [](World& world, const Captures&, const Table&) {
    shellThread(world);
    const QString run = startRun(world);
    updateThread(world, {{QStringLiteral("activeRunId"), run}, {QStringLiteral("latestRunId"), run}});
  });
  step(QStringLiteral("the user uses the composer's primary action"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    QQuickItem* action = part(world, QStringLiteral("primaryAction"));
    world.waitFor([&] { return action->property("stopMode").toBool(); }, QStringLiteral("the primary action to offer Stop"));
    click(world, action);
  });
  step(QStringLiteral("the turn is interrupted"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const auto interrupt = std::find_if(world.mc.commands.cbegin(), world.mc.commands.cend(), [](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("run.interrupt");
    });
    expect(interrupt != world.mc.commands.cend() && interrupt->value(QLatin1String("runId")) == world.mc.part<FakeStreams>().run,
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // The toolbar shortcuts (composer.effort, .mode, .host, .workspace, .branch).
  const QHash<QString, std::pair<QString, QString>> controls{
      {QStringLiteral("effort picker"), {QStringLiteral("composer.effort"), QStringLiteral("effortPicker")}},
      // A new thread names its permissions in the context strip.
      {QStringLiteral("access mode picker"), {QStringLiteral("composer.mode"), QStringLiteral("contextPermissions")}},
      {QStringLiteral("host picker"), {QStringLiteral("composer.host"), QStringLiteral("hostPicker")}},
      {QStringLiteral("workspace picker"), {QStringLiteral("composer.workspace"), QStringLiteral("envModePicker")}},
      {QStringLiteral("branch picker"), {QStringLiteral("composer.branch"), QStringLiteral("branchPicker")}}};
  const auto popup = [](World& world, const QString& name) -> QObject* {
    if (name == QLatin1String("branchPicker")) return composerItem(world)->findChild<QObject*>(name);
    return popupOf(part(world, name));
  };
  step(QStringLiteral("the shell asks to open the (.+ picker)"), [controls, popup](World& world, const Captures& c, const Table&) {
    toolbarDraft(world);
    expect(controls.contains(c[0]), QStringLiteral("the toolbar has no %1").arg(c[0]));
    QObject* control = popup(world, controls.value(c[0]).second);
    expect(control && !control->property("visible").toBool(), QStringLiteral("the %1 is open already").arg(c[0]));
    expect(world.native().controller<KeybindingController>()->commands()->run(controls.value(c[0]).first), QStringLiteral("%1 is not a command").arg(controls.value(c[0]).first));
  });
  step(QStringLiteral("the native (.+ picker) opens"), [controls, popup](World& world, const Captures& c, const Table&) {
    QObject* control = popup(world, controls.value(c[0]).second);
    world.waitFor([&] { return control->property("opened").toBool(); }, [&] { return QStringLiteral("the %1 to open").arg(c[0]); });
  });

  // A narrow composer: the chips that do not fit fold into its overflow
  // chip's menu (composerOverflow) instead of wrapping the toolbar.
  const auto shownChips = [](World& world) {
    QList<QQuickItem*> shown;
    for (QQuickItem* chip : part(world, QStringLiteral("toolbarChips"))->childItems()) {
      if (chip->isVisible() && !chip->objectName().isEmpty()) shown.append(chip);
    }
    return shown;
  };
  const auto overflowRows = [](World& world) {
    QObject* menu = composerItem(world)->property("overflowMenu").value<QObject*>();
    QStringList rows;
    if (!menu) return rows;
    for (int i = 0; i < menu->property("count").toInt(); ++i) {
      QQuickItem* row = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, row), Q_ARG(int, i));
      QObject* sub = row ? row->property("subMenu").value<QObject*>() : nullptr;
      rows.append(sub ? sub->objectName() : row ? row->objectName() : QString());
    }
    return rows;
  };
  step(QStringLiteral("the composer offers its reasoning effort, plan and access controls"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    publishProviders(world.mc, {provider(QStringLiteral("codex"), QStringLiteral("Codex"), {model(QStringLiteral("gpt-5.4"), QStringLiteral("GPT-5.4"))})});
    // Permissions other than the default, which the toolbar names.
    updateThread(world, {{QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5.4")}}},
                         {QStringLiteral("runtimeMode"), QStringLiteral("approval-required")}});
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true), QStringLiteral("plan mode could not be turned on"));
    composerBrick(world);
    world.waitFor([&] {
      return part(world, QStringLiteral("effortPicker"))->isVisible() && part(world, QStringLiteral("planToggle"))->isVisible() &&
             part(world, QStringLiteral("runtimeModePicker"))->isVisible();
    }, [&] { return QStringLiteral("the effort, plan and access on the toolbar; the composer shows %1").arg(show(composer(world))); });
  });
  step(QStringLiteral("the composer is too narrow to show all its controls"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    const QSize narrow(380, brick.window().height());
    brick.window().resize(narrow);
    brick.root()->setSize(narrow);
    world.waitFor([&] { return part(world, QStringLiteral("composerOverflow"))->isVisible(); }, QStringLiteral("the composer to fold a control"));
  });
  step(QStringLiteral("its toolbar is still one line"), [shownChips](World& world, const Captures&, const Table&) {
    QQuickItem* toolbar = part(world, QStringLiteral("toolbar"));
    QList<QQuickItem*> line = shownChips(world);
    line << part(world, QStringLiteral("modelPicker")) << part(world, QStringLiteral("primaryAction"));
    const qreal right = part(world, QStringLiteral("primaryAction"))->mapToItem(toolbar, QPointF()).x();
    for (QQuickItem* item : line) {
      const QPointF middle = item->mapToItem(toolbar, QPointF(item->width(), item->height() / 2));
      expect(qAbs(middle.y() - toolbar->height() / 2) < 1, QStringLiteral("%1 is off the toolbar's line").arg(item->objectName()));
      if (item->objectName() != QLatin1String("primaryAction")) expect(middle.x() <= right, QStringLiteral("%1 runs under Send").arg(item->objectName()));
    }
  });
  step(QStringLiteral("the reasoning effort is offered in its menu of further controls"), [shownChips, overflowRows](World& world, const Captures&, const Table&) {
    expect(!shownChips(world).contains(part(world, QStringLiteral("effortPicker"))), QStringLiteral("the effort is still on the toolbar"));
    click(world, part(world, QStringLiteral("composerOverflow")));
    world.waitFor([&] { return overflowRows(world).contains(QStringLiteral("composerOverflow:effortPicker")); },
                  [&] { return QStringLiteral("the effort in the menu; it offers %1").arg(overflowRows(world).join(u", ")); });
  });
  step(QStringLiteral("the model can still be chosen beside it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* picker = part(world, QStringLiteral("modelPicker"));
    expect(picker->isVisible() && picker->isEnabled(), QStringLiteral("the model picker is not on the toolbar"));
  });
  step(QStringLiteral("the user chooses %1 in that menu").arg(q), [overflowRows](World& world, const Captures& c, const Table&) {
    const QString row = QStringLiteral("composerOverflow:planToggle");
    expect(c[0] == QLatin1String("Plan"), QStringLiteral("the menu has no %1 for this step").arg(c[0]));
    world.waitFor([&] { return overflowRows(world).contains(row); }, [&] { return QStringLiteral("Plan in the menu; it offers %1").arg(overflowRows(world).join(u", ")); });
    QQuickItem* item = part(world, row);
    expect(item->property("text") == c[0], QStringLiteral("the row reads %1").arg(item->property("text").toString()));
    click(world, item);
  });

  // Send stands out only with something to send, and is Stop while a turn
  // runs with nothing to send.
  const auto primary = [](World& world) {
    composerBrick(world);
    return part(world, QStringLiteral("primaryAction"));
  };
  step(QStringLiteral("the send control cannot be used"), [primary](World& world, const Captures&, const Table&) {
    QQuickItem* action = primary(world);
    world.waitFor([&] { return !action->isEnabled() && !action->property("sendable").toBool(); }, QStringLiteral("Send to be off"));
  });
  step(QStringLiteral("the send control can be used and is the composer's accent"), [primary](World& world, const Captures&, const Table&) {
    QQuickItem* action = primary(world);
    world.waitFor([&] { return action->isEnabled() && action->property("sendable").toBool(); }, QStringLiteral("Send to be on"));
    const QColor fill = action->property("background").value<QObject*>()->property("color").value<QColor>();
    expect(fill == action->property("accent").value<QColor>(), QStringLiteral("Send is filled %1").arg(fill.name()));
  });
  step(QStringLiteral("the send control is replaced by a control that stops the turn"), [primary](World& world, const Captures&, const Table&) {
    QQuickItem* action = primary(world);
    world.waitFor([&] { return action->property("stopMode").toBool() && action->isEnabled(); }, QStringLiteral("the composer to offer Stop"));
    expect(part(world, QStringLiteral("stopGlyph"))->isVisible(), QStringLiteral("Stop does not show its square"));
  });
  step(QStringLiteral("the send control is back"), [primary](World& world, const Captures&, const Table&) {
    QQuickItem* action = primary(world);
    world.waitFor([&] { return !action->property("stopMode").toBool() && action->property("sendable").toBool(); }, QStringLiteral("the composer to offer Send again"));
  });

  // Search order, older models, new marks and the setup offer.
  const auto quotedList = [](const QString& text) {
    QStringList names;
    const QRegularExpression quoted(QStringLiteral("\"([^\"]*)\""));
    for (auto match = quoted.globalMatch(text); match.hasNext();) names.append(match.next().captured(1));
    return names;
  };
  step(QStringLiteral("Claude lists (.+) in that order"), [quotedList](World& world, const Captures& c, const Table&) {
    QJsonArray models;
    for (const QString& name : quotedList(c[0])) models.append(model(name.toLower().replace(u' ', u'-'), name));
    changeProvider(world, QStringLiteral("claudeAgent"), [&models](QJsonObject& entry) { entry.insert(QStringLiteral("models"), models); });
  });
  step(QStringLiteral("the models are listed as (.+)"), [quotedList](World& world, const Captures& c, const Table&) {
    const QStringList expected = quotedList(c[0]);
    world.waitFor([&] { return listed(world) == expected; }, [&] { return QStringLiteral("%1; the picker lists %2").arg(expected.join(u", "), listed(world).join(u", ")); });
  });
  step(QStringLiteral("a shorter name is not listed ahead of a newer model"), [](World& world, const Captures&, const Table&) {
    const QStringList names = listed(world);
    expect(names.indexOf(QStringLiteral("Opus 5")) > names.indexOf(QStringLiteral("Opus 5.5")) && names.indexOf(QStringLiteral("Opus 5.5")) >= 0,
           QStringLiteral("the picker lists %1").arg(names.join(u", ")));
  });
  step(QStringLiteral("the user looks through (\\w+)'s models"), [](World& world, const Captures& c, const Table&) {
    openPicker(world);
    click(world, part(world, QStringLiteral("modelPickerProvider:") + driverOf(c[0])));
  });
  step(QStringLiteral("Codex lists the legacy model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    changeProvider(world, QStringLiteral("codex"), [&c](QJsonObject& entry) {
      QJsonArray models = entry.value(QLatin1String("models")).toArray();
      QJsonObject legacy = model(c[0], c[0]);
      legacy.insert(QStringLiteral("isLegacy"), true);
      models.append(legacy);
      entry.insert(QStringLiteral("models"), models);
    });
  });
  // Codex's own list, two current models then three older ones, with the
  // picker's height and the "Show more" row it ends on.
  step(QStringLiteral("Codex lists two current models and three it calls legacy"), [](World& world, const Captures&, const Table&) {
    // The thread's own model stays current, so the picker opens with the
    // older models folded.
    const QVariantMap chosen = composer(world);
    const QString first = chosen.value(QStringLiteral("selectedInstanceId")) == QLatin1String("codex") ? chosen.value(QStringLiteral("selectedModel")).toString() : QStringLiteral("gpt-6");
    changeProvider(world, QStringLiteral("codex"), [&first](QJsonObject& entry) {
      QJsonArray models{model(first, QStringLiteral("GPT-6")), model(QStringLiteral("gpt-6-mini"), QStringLiteral("GPT-6 Mini"))};
      for (const QString& slug : {QStringLiteral("gpt-4.1"), QStringLiteral("gpt-4o"), QStringLiteral("o3")}) {
        QJsonObject legacy = model(slug, slug.toUpper());
        legacy.insert(QStringLiteral("isLegacy"), true);
        models.append(legacy);
      }
      entry.insert(QStringLiteral("models"), models);
    });
  });
  step(QStringLiteral("the user chooses %1 at the end of Codex's models").arg(q), [](World& world, const Captures& c, const Table&) {
    openPicker(world);
    click(world, part(world, QStringLiteral("modelPickerProvider:codex")));
    world.waitFor([&] { return listed(world) == QStringList{QStringLiteral("GPT-6"), QStringLiteral("GPT-6 Mini"), QString()}; },
                  [&] { return QStringLiteral("Codex's two current models and then a row; the picker lists %1").arg(show(rows(world))); });
    expect(rows(world).last().toMap().value(QStringLiteral("kind")) == QLatin1String("legacy"), QStringLiteral("Codex's list ends on %1").arg(show(rows(world).last())));
    QQuickItem* more = part(world, QStringLiteral("modelPickerLegacy:codex"));
    expect(more->property("text") == c[0], QStringLiteral("the row reads %1, not %2").arg(more->property("text").toString(), c[0]));
    world.mc.part<PickerHeight>().height = popupOf(picker(world))->property("height").toReal();
    click(world, more);
  });
  step(QStringLiteral("the three older models are listed in place and the row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList expected{QStringLiteral("GPT-6"), QStringLiteral("GPT-6 Mini"), QStringLiteral("GPT-4.1"), QStringLiteral("GPT-4O"), QStringLiteral("O3"), QString()};
    world.waitFor([&] { return listed(world) == expected; }, [&] { return QStringLiteral("the older models above the row; the picker lists %1").arg(show(rows(world))); });
    QQuickItem* less = part(world, QStringLiteral("modelPickerLegacy:codex"));
    expect(less->property("text") == c[0], QStringLiteral("the row reads %1, not %2").arg(less->property("text").toString(), c[0]));
    expect(pickerOpen(world), QStringLiteral("the picker closed"));
  });
  step(QStringLiteral("the list scrolls inside the picker"), [](World& world, const Captures&, const Table&) {
    const qreal before = world.mc.part<PickerHeight>().height;
    const qreal after = popupOf(picker(world))->property("height").toReal();
    expect(before > 0 && qFuzzyCompare(before, after), QStringLiteral("the picker was %1 tall and is %2").arg(before).arg(after));
    QQuickItem* row = part(world, QStringLiteral("modelPickerLegacy:codex"));
    QQuickItem* list = row->parentItem();
    while (list && !list->inherits("QQuickListView")) list = list->parentItem();
    expect(list != nullptr, QStringLiteral("the rows are not in a list"));
    expect(list->clip() && list->property("interactive").toBool(), QStringLiteral("the list does not scroll in place"));
  });
  step(QStringLiteral("%1 is listed without choosing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listed(world).contains(c[0]); }, [&] { return QStringLiteral("%1 to be listed; the picker lists %2").arg(c[0], listed(world).join(u", ")); });
  });
  step(QStringLiteral("%1 is listed above Codex's current models without choosing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList names = listed(world);
    expect(names.value(0) == c[0], QStringLiteral("the picker lists %1").arg(names.join(u", ")));
  });
  step(QStringLiteral("%1 is back among the older models behind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      bool folded = false;
      for (const QVariant& row : rows(world)) folded = folded || row.toMap().value(QStringLiteral("kind")) == QLatin1String("legacy");
      return folded && !listed(world).contains(c[0]);
    }, [&] { return QStringLiteral("%1 behind the older models; the picker lists %2").arg(c[0], listed(world).join(u", ")); });
  });
  step(QStringLiteral("Codex reports %1 as a new model").arg(q), [](World& world, const Captures& c, const Table&) {
    changeProvider(world, QStringLiteral("codex"), [&c](QJsonObject& entry) {
      QJsonArray models = entry.value(QLatin1String("models")).toArray();
      QJsonObject fresh = model(c[0], c[0]);
      fresh.insert(QStringLiteral("badge"), QStringLiteral("new"));
      models.append(fresh);
      entry.insert(QStringLiteral("models"), models);
    });
  });
  step(QStringLiteral("%1 is marked as new").arg(q), [](World& world, const Captures& c, const Table&) {
    bool marked = false;
    for (const QVariant& row : rows(world)) {
      const QVariantMap listedModel = row.toMap().value(QStringLiteral("model")).toMap();
      if (listedModel.value(QStringLiteral("slug")) == c[0]) marked = listedModel.value(QStringLiteral("isNew")).toBool();
    }
    expect(marked && part(world, QStringLiteral("modelPickerRow:codex:") + c[0])->isVisible(), QStringLiteral("%1 is not marked as new").arg(c[0]));
  });

  // The picker opens on the favourites, or on a started thread's provider.
  step(QStringLiteral("the user has marked %1 as a favourite").arg(q), [](World& world, const Captures& c, const Table&) {
    QString instanceId;
    for (const QVariant& entry : instances(world)) {
      for (const QVariant& listed : entry.toMap().value(QStringLiteral("models")).toList()) {
        if (listed.toMap().value(QStringLiteral("slug")) == c[0]) instanceId = entry.toMap().value(QStringLiteral("instanceId")).toString();
      }
    }
    expect(!instanceId.isEmpty(), QStringLiteral("no provider lists %1").arg(c[0]));
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"), QVariantMap{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), c[0]}});
    world.sync();
  });
  step(QStringLiteral("the favourites are listed first, each under its own provider's name"), [](World& world, const Captures&, const Table&) {
    expect(picker(world)->property("view") == QLatin1String("favorites"), QStringLiteral("the picker opens on %1").arg(picker(world)->property("view").toString()));
    const QVariantList shown = rows(world);
    expect(!shown.isEmpty() && std::all_of(shown.cbegin(), shown.cend(), [](const QVariant& row) {
             return row.toMap().value(QStringLiteral("model")).toMap().value(QStringLiteral("isFavorite")).toBool() &&
                    !row.toMap().value(QStringLiteral("instance")).toMap().value(QStringLiteral("displayName")).toString().isEmpty();
           }),
           QStringLiteral("the favourites list %1").arg(listed(world).join(u", ")));
  });
  step(QStringLiteral("in a thread that has already run a turn the picker opens on the thread's provider"), [](World& world, const Captures&, const Table&) {
    QMetaObject::invokeMethod(picker(world), "close");
    updateThread(world, {{QStringLiteral("latestRunId"), QStringLiteral("run-0")},
                         {QStringLiteral("runtime"), QJsonObject{{QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")}}}});
    openPicker(world);
    expect(picker(world)->property("view") == composer(world).value(QStringLiteral("selectedInstanceId")),
           QStringLiteral("the picker opens on %1").arg(picker(world)->property("view").toString()));
  });

  // Each model keeps the options it was last given.
  const auto effortNow = [](World& world) {
    for (const QVariant& option : composer(world).value(QStringLiteral("options")).toList()) {
      if (option.toMap().value(QStringLiteral("id")) == QLatin1String("reasoningEffort")) {
        return option.toMap().value(QStringLiteral("value")).toString();
      }
    }
    return QString();
  };
  const auto pickAt = [](World& world, const QString& instanceId, const QString& model, const QString& effort) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}});
    world.bridge().dispatch(QStringLiteral("composer.option.set"), QVariantMap{{QStringLiteral("id"), QStringLiteral("reasoningEffort")}, {QStringLiteral("value"), effort}});
  };
  struct Offered {
    QString sonnet;
    QString proxyMessage;
  };
  step(QStringLiteral("the user set %1 to high effort and %1 to low effort").arg(q), [&](World& world, const Captures& c, const Table&) {
    changeProvider(world, QStringLiteral("claudeAgent"), [&](QJsonObject& entry) {
      entry.insert(QStringLiteral("models"), QJsonArray{model(c[0], c[0]), model(c[1], c[1])});
    });
    pickAt(world, QStringLiteral("claudeAgent"), c[0], QStringLiteral("high"));
    world.waitFor([&] { return effortNow(world) == QLatin1String("high"); }, QStringLiteral("high to be set"));
    pickAt(world, QStringLiteral("claudeAgent"), c[1], QStringLiteral("low"));
    world.waitFor([&] { return effortNow(world) == QLatin1String("low"); }, QStringLiteral("low to be set"));
  });
  step(QStringLiteral("the user switches from %1 to %1 and back").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), c[0]}});
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), c[1]}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == c[1]; }, QStringLiteral("the switch"));
    world.mc.part<Offered>().sonnet = effortNow(world);
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), c[0]}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == c[0]; }, QStringLiteral("the switch back"));
  });
  step(QStringLiteral("%1 was offered with low effort and %1 is back at high effort").arg(q), [&](World& world, const Captures&, const Table&) {
    expect(world.mc.part<Offered>().sonnet == QLatin1String("low"), QStringLiteral("sonnet was offered %1").arg(world.mc.part<Offered>().sonnet));
    expect(effortNow(world) == QLatin1String("high"), QStringLiteral("opus is back at %1").arg(effortNow(world)));
  });

  // A custom model whose slug is also a built-in's alias stays itself.
  step(QStringLiteral("the Codex account %1 has the custom model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    shellThread(world);
    QJsonObject custom = model(c[1], c[1]);
    custom.insert(QStringLiteral("isCustom"), true);
    QJsonArray list = providers(world);
    list.append(provider(QStringLiteral("codex_proxy"), c[0], {custom}));
    offer(world, list);
  });
  step(QStringLiteral("the user picks %1 on %1 at high effort and sends a message").arg(q), [&](World& world, const Captures& c, const Table&) {
    pickAt(world, QStringLiteral("codex_proxy"), c[0], QStringLiteral("high"));
    world.waitFor([&] { return effortNow(world) == QLatin1String("high"); }, QStringLiteral("high to be set"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("through the proxy")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.mc.part<Offered>().proxyMessage = QStringLiteral("through the proxy");
    world.sync();
  });
  step(QStringLiteral("the turn runs on the custom model %1, not on a built-in model it is an alias of").arg(q), [&](World& world, const Captures& c, const Table&) {
    // The thread's turn runs on what its switch (or its message) named.
    QJsonObject selection;
    for (auto it = world.mc.commands.crbegin(); it != world.mc.commands.crend() && selection.isEmpty(); ++it) {
      const QString type = it->value(QLatin1String("type")).toString();
      if ((type == QLatin1String("provider.switch") || type == QLatin1String("message.dispatch")) &&
          it->contains(QLatin1String("modelSelection"))) {
        selection = it->value(QLatin1String("modelSelection")).toObject();
      }
    }
    expect(selection.value(QLatin1String("instanceId")) == QLatin1String("codex_proxy") && selection.value(QLatin1String("model")) == c[0],
           QStringLiteral("the turn ran on %1; the MC has %2").arg(show(selection.toVariantMap()), world.describeCommands()));
  });
  step(QStringLiteral("picking %1 again offers high effort").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}});
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex_proxy")}, {QStringLiteral("model"), c[0]}});
    world.waitFor([&] { return effortNow(world) == QLatin1String("high"); },
                  [&] { return QStringLiteral("high again; the composer offers %1").arg(effortNow(world)); });
  });

  // The name the model button says.
  step(QStringLiteral("the model manifest names %1 %1 for short").arg(q), [](World& world, const Captures& c, const Table&) {
    changeProvider(world, QStringLiteral("claudeAgent"), [&c](QJsonObject& entry) {
      QJsonObject named = model(QStringLiteral("claude-opus-5.5"), c[0]);
      named.insert(QStringLiteral("shortName"), c[1]);
      entry.insert(QStringLiteral("models"), QJsonArray{named});
    });
    openPicker(world);
  });
  step(QStringLiteral("the user chooses the (\\w+) model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString instanceId = driverOf(c[0]);
    QString slug = c[1].toLower();
    slug.replace(QRegularExpression(QStringLiteral("[^a-z0-9]+")), QStringLiteral("-"));
    bool offered = false;
    for (const QJsonValue& entry : providers(world)) offered = offered || entry.toObject().value(QLatin1String("instanceId")) == instanceId;
    if (offered) {
      changeProvider(world, instanceId, [&](QJsonObject& entry) { entry.insert(QStringLiteral("models"), QJsonArray{model(slug, c[1])}); });
    } else {
      QJsonArray list = providers(world);
      list.append(provider(instanceId, c[0], {model(slug, c[1])}));
      offer(world, list);
    }
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), slug}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == slug; },
                  [&] { return QStringLiteral("the composer on %1; it shows %2").arg(slug, show(composer(world))); });
    composerBrick(world);
  });
  step(QStringLiteral("the full name %1 is shown in its tooltip and in the model picker").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(picker(world)->property("triggerFullTitle") == c[0],
           QStringLiteral("the tooltip names \"%1\"").arg(picker(world)->property("triggerFullTitle").toString()));
    openPicker(world);
    expect(listed(world).contains(c[0]), QStringLiteral("the picker lists %1").arg(listed(world).join(u", ")));
  });
  step(QStringLiteral("the model button reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return picker(world)->property("triggerTitle") == c[0]; },
                  [&] { return QStringLiteral("the button to read \"%1\"; it reads \"%2\"").arg(c[0], picker(world)->property("triggerTitle").toString()); });
    expect(part(world, QStringLiteral("modelPickerTitle"))->property("text") == c[0],
           QStringLiteral("the button reads \"%1\"").arg(part(world, QStringLiteral("modelPickerTitle"))->property("text").toString()));
  });

  // A provider that needs setting up.
  step(QStringLiteral("Cursor is not installed and HAL-C2 can install it"), [](World& world, const Captures&, const Table&) {
    QJsonArray list = providers(world);
    QJsonObject cursor = provider(QStringLiteral("cursor"), QStringLiteral("Cursor"), {model(QStringLiteral("cursor-auto"), QStringLiteral("Auto"))});
    cursor.insert(QStringLiteral("installed"), false);
    cursor.insert(QStringLiteral("status"), QStringLiteral("error"));
    cursor.insert(QStringLiteral("message"), QStringLiteral("Cursor CLI is not installed."));
    cursor.insert(QStringLiteral("setup"), QJsonObject{{QStringLiteral("canInstall"), true}, {QStringLiteral("canAuthenticate"), false}});
    list.append(cursor);
    offer(world, list);
  });
  step(QStringLiteral("the picker says why Cursor cannot be used and offers %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* reason = part(world, QStringLiteral("modelPickerSetupReason"));
    QQuickItem* setup = part(world, QStringLiteral("modelPickerSetup"));
    world.waitFor([&] { return reason->isVisible() && setup->isVisible() && setup->property("text") == c[0]; },
                  [&] { return QStringLiteral("the setup offer; the picker says \"%1\"").arg(reason->property("text").toString()); });
    expect(reason->property("text").toString().contains(QLatin1String("Cursor CLI is not installed.")), QStringLiteral("the picker says \"%1\"").arg(reason->property("text").toString()));
  });
  step(QStringLiteral("the picker closes and the setup for Cursor opens"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !popupOf(picker(world))->property("visible").toBool(); }, QStringLiteral("the picker to close"));
    auto* navigation = world.native().controller<NavigationController>();
    world.waitFor([&] { return navigation->route() == NavigationController::Route::settings(NavigationController::kProvidersSection); },
                  [&] { return QStringLiteral("the Providers settings to open; the window shows %1").arg(show(world.state(QStringLiteral("route")))); });
  });
});

}  // namespace

bool modelPickerLists(World& world, const QString& name, bool expected) {
  if (!composerBrickShown(world)) return false;
  const QStringList names = listed(world);
  const bool found = std::any_of(names.cbegin(), names.cend(), [&](const QString& entry) { return entry.contains(name); });
  expect(pickerOpen(world) && found == expected, QStringLiteral("the picker lists %1").arg(names.join(QStringLiteral(", "))));
  return true;
}

bool modelPickerShows(World& world, const QString& name, const QString& reason) {
  // The picker's own scenarios: a thread of Stream.h's with providers listed.
  if (world.mc.part<FakeStreams>().thread.isEmpty() || instances(world).isEmpty()) return false;
  if (!composerBrickShown(world) || !pickerOpen(world)) openPicker(world);
  const QString shown = rowOf(world, name)->property("disabledReason").toString();
  expect(shown.endsWith(reason), QStringLiteral("%1 shows \"%2\"").arg(name, shown));
  return true;
}

bool modelPickerChooses(World& world, const QString& name) {
  if (!composerBrickShown(world) || !pickerOpen(world)) return false;
  click(world, rowOf(world, name));
  return true;
}

bool modelPickerChoosesSetup(World& world) {
  if (!composerBrickShown(world)) return false;
  QQuickItem* setup = composerPart(world, QStringLiteral("modelPickerSetup"));
  if (!setup || !setup->isVisible()) return false;
  click(world, setup);
  return true;
}

bool modelPickerShownOpen(World& world) {
  // As an outcome with the composer on screen; as a precondition it is ModelSteps'.
  if (!world.checking || !composerBrickShown(world)) return false;
  world.waitFor([&] { return pickerOpen(world); }, QStringLiteral("the model picker to be open"));
  // Open, it has the keyboard for the search.
  expect(part(world, QStringLiteral("modelPickerSearch"))->hasActiveFocus(), QStringLiteral("the search does not have the keyboard"));
  return true;
}
