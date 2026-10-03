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
  step(QStringLiteral("the model picker is (open|closed)"), [](World& world, const Captures& c, const Table&) {
    const bool open = c[0] == QLatin1String("open");
    world.waitFor([&] { return open ? pickerOpen(world) : !popupOf(picker(world))->property("visible").toBool(); },
                  [&] { return QStringLiteral("the model picker to be %1").arg(c[0]); });
    // Open, it has the keyboard for the search.
    if (open) expect(part(world, QStringLiteral("modelPickerSearch"))->hasActiveFocus(), QStringLiteral("the search does not have the keyboard"));
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
    shellThread(world);
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
      {QStringLiteral("access mode picker"), {QStringLiteral("composer.mode"), QStringLiteral("runtimeModePicker")}},
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
