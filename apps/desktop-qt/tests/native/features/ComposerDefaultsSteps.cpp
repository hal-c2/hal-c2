// What a turn starts from without the user choosing: the model last used,
// the default permissions, and an effort the prompt carries
// (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Launches.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QString effortValue(World& world) {
  for (const QVariant& option : composer(world).value(QStringLiteral("options")).toList()) {
    if (option.toMap().value(QStringLiteral("type")) == QLatin1String("select")) return option.toMap().value(QStringLiteral("value")).toString();
  }
  return {};
}

// What the effort control offered, and what it read before a send.
struct Offered {
  QStringList listed;
  QStringList stepped;
  QString shown;
};

QJsonArray providers(World& world) {
  return fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
}

void changeProvider(World& world, const QString& instanceId, const std::function<void(QJsonObject&)>& change) {
  QJsonArray list = providers(world);
  for (qsizetype i = 0; i < list.size(); ++i) {
    QJsonObject entry = list.at(i).toObject();
    if (entry.value(QLatin1String("instanceId")) != instanceId) continue;
    change(entry);
    list.replace(i, entry);
  }
  publishProviders(world.mc, list);
  world.sync();
}

void updateThread(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(kThread, row);
  world.sync();
}

QJsonObject lastMessage(World& world) {
  world.sync();
  for (auto it = world.mc.commands.crbegin(); it != world.mc.commands.crend(); ++it) {
    if (it->value(QLatin1String("type")) == QLatin1String("message.dispatch")) return *it;
  }
  return {};
}

void newThread(World& world) {
  world.openDraft(kProject);
  world.waitFor([&] { return composer(world).value(QStringLiteral("target")) == world.draftId; },
                [&] { return QStringLiteral("the composer on the new thread; it shows %1").arg(show(composer(world))); });
}

QString labelOf(World& world, const QString& mode) {
  for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
    if (entry.toMap().value(QStringLiteral("value")) == mode) return entry.toMap().value(QStringLiteral("label")).toString();
  }
  return mode;
}

QString modeOf(World& world, const QString& label) {
  for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
    if (entry.toMap().value(QStringLiteral("label")) == label) return entry.toMap().value(QStringLiteral("value")).toString();
  }
  fail(QStringLiteral("the composer offers %1").arg(show(composer(world).value(QStringLiteral("runtimeModes")))));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Ultrathink.
  step(QStringLiteral("the thread runs on Claude"), [](World& world, const Captures&, const Table&) {
    // Claude lists Ultrathink among its efforts, though only the prompt carries it.
    changeProvider(world, QStringLiteral("claudeAgent"), [](QJsonObject& entry) {
      QJsonArray models = entry.value(QLatin1String("models")).toArray();
      for (qsizetype i = 0; i < models.size(); ++i) {
        QJsonObject model = models.at(i).toObject();
        model.insert(QStringLiteral("capabilities"),
                     QJsonObject{{QStringLiteral("optionDescriptors"),
                                  QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("effort")},
                                                         {QStringLiteral("label"), QStringLiteral("Effort")},
                                                         {QStringLiteral("type"), QStringLiteral("select")},
                                                         {QStringLiteral("options"),
                                                          QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("medium")}, {QStringLiteral("label"), QStringLiteral("Medium")}, {QStringLiteral("isDefault"), true}},
                                                                     QJsonObject{{QStringLiteral("id"), QStringLiteral("high")}, {QStringLiteral("label"), QStringLiteral("High")}},
                                                                     QJsonObject{{QStringLiteral("id"), QStringLiteral("ultrathink")}, {QStringLiteral("label"), QStringLiteral("Ultrathink")}}}},
                                                         {QStringLiteral("promptInjectedValues"), QJsonArray{QStringLiteral("ultrathink")}},
                                                         {QStringLiteral("currentValue"), QStringLiteral("medium")}}}}});
        models.replace(i, model);
      }
      entry.insert(QStringLiteral("models"), models);
    });
    updateThread(world, {{QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("claude-opus")}}}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedInstanceId")) == QLatin1String("claudeAgent"); },
                  [&] { return QStringLiteral("the composer on Claude; it shows %1").arg(show(composer(world))); });
  });
  // Ultrathink is typed, not picked: what the picker lists and the steps reach.
  step(QStringLiteral("the user opens the effort choices or steps the effort"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    QQuickItem* picker = composerPart(world, QStringLiteral("effortPicker"));
    expect(picker && picker->isVisible(), QStringLiteral("the composer shows no effort picker"));
    QObject* popup = picker->property("popup").value<QObject*>();
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(picker));
    world.waitFor([&] { return popup->property("opened").toBool(); }, QStringLiteral("the effort picker to open"));
    Offered& offered = world.mc.part<Offered>();
    offered.listed = picker->property("model").toStringList();
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.waitFor([&] { return !popup->property("opened").toBool(); }, QStringLiteral("the effort picker to close"));
    // Once round the levels and one more, so a level the step reaches is seen.
    for (int i = 0; i <= offered.listed.size(); ++i) {
      const QString before = effortValue(world);
      world.bridge().dispatch(QStringLiteral("composer.effort.step"), QVariantMap{{QStringLiteral("direction"), 1}});
      world.waitFor([&] { return effortValue(world) != before; },
                    [&] { return QStringLiteral("a step from %1 to change the effort").arg(before); });
      offered.stepped.append(effortValue(world));
    }
  });
  step(QStringLiteral("Ultrathink is not offered"), [](World& world, const Captures&, const Table&) {
    const Offered& offered = world.mc.part<Offered>();
    expect(!offered.listed.isEmpty() && !offered.listed.join(u'\n').contains(QLatin1String("Ultrathink"), Qt::CaseInsensitive),
           QStringLiteral("the effort choices list %1").arg(offered.listed.join(QStringLiteral(", "))));
    expect(!offered.stepped.contains(QStringLiteral("ultrathink")), QStringLiteral("the steps reach %1").arg(offered.stepped.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user types %1 and sends it").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    typeInComposer(world, c[0]);
    settleComposer(world);
    QQuickItem* picker = composerPart(world, QStringLiteral("effortPicker"));
    expect(picker != nullptr, QStringLiteral("the composer shows no effort picker"));
    // The effort follows the typed prompt once the composer publishes it.
    const QString typed = c[0];
    world.waitFor([&] { return effortValue(world) == QLatin1String("ultrathink") || !typed.startsWith(QLatin1String("Ultrathink:")); },
                  [&] { return QStringLiteral("the effort to follow the typed prompt; it is %1 under \"%2\"").arg(effortValue(world), composer(world).value(QStringLiteral("text")).toString()); });
    world.sync();
    world.mc.part<Offered>().shown = picker->property("displayText").toString();
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    pressInComposer(world, QStringLiteral("Enter"));
  });
  step(QStringLiteral("the effort reads %1 and the turn runs at Ultrathink").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString shown = world.mc.part<Offered>().shown;
    expect(shown == c[0], QStringLiteral("the effort read %1 before the send").arg(shown));
    expect(composerMessageReceived(world, QStringLiteral("Ultrathink: design the cache")), QStringLiteral("the agent did not receive the typed Ultrathink"));
  });

  // The model last used.
  step(QStringLiteral("the user last used %1 with Codex").arg(q), [](World& world, const Captures& c, const Table&) {
    // Codex would start a thread on another model.
    changeProvider(world, QStringLiteral("codex"), [&](QJsonObject& entry) {
      QJsonArray models;
      for (const QJsonValue& model : entry.value(QLatin1String("models")).toArray()) {
        if (model.toObject().value(QLatin1String("slug")) != c[0]) models.prepend(model); else models.append(model);
      }
      entry.insert(QStringLiteral("models"), models);
    });
    world.bridge().dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), c[0]}});
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("use it")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    expect(lastMessage(world).value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")) == c[0], QStringLiteral("the turn did not run on %1").arg(c[0]));
  });
  step(QStringLiteral("the user starts a new thread on Codex"), [](World& world, const Captures&, const Table&) { newThread(world); });
  step(QStringLiteral("%1 is chosen").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(composer(world).value(QStringLiteral("selectedInstanceId")) == QLatin1String("codex") && composer(world).value(QStringLiteral("selectedModel")) == c[0],
           QStringLiteral("the composer is on %1 of %2").arg(composer(world).value(QStringLiteral("selectedModel")).toString(), composer(world).value(QStringLiteral("selectedInstanceId")).toString()));
  });
  step(QStringLiteral("a model set for the project takes precedence"), [](World& world, const Captures&, const Table&) {
    QJsonObject row = world.mc.projects.value(kProject);
    row.insert(QStringLiteral("defaultModelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("claude-sonnet")}});
    world.mc.projects.insert(kProject, row);
    world.mc.sendRows(world.mc.name, {QJsonValue(QJsonArray{kProject, QStringLiteral("project"), row})});
    world.sync();
    world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("claude-sonnet"); },
                  [&] { return QStringLiteral("the project's model; the composer is on %1").arg(composer(world).value(QStringLiteral("selectedModel")).toString()); });
  });

  // Default permissions (Settings → Project defaults; the MC keeps them).
  step(QStringLiteral("the default permissions (?:for new threads )?are (.+)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().controller<SettingsController>()->ready(); }, QStringLiteral("the shell to read the settings"));
    const QString mode = modeOf(world, c[0]);
    saveElsewhere(world.mc, QStringLiteral("defaultRuntimeMode"), mode);
    world.waitFor([&] { return world.native().controller<SettingsController>()->value(QStringLiteral("defaultRuntimeMode")) == mode; },
                  QStringLiteral("the shell to read the default permissions"));
  });
  step(QStringLiteral("the thread runs in (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(world, c[0]);
    expect(composer(world).value(QStringLiteral("target")) == world.draftId && composer(world).value(QStringLiteral("runtimeMode")) == mode,
           QStringLiteral("the composer shows %1; the MC's default is %2, the draft %3 of %4")
               .arg(labelOf(world, composer(world).value(QStringLiteral("runtimeMode")).toString()),
                    show(world.native().controller<SettingsController>()->value(QStringLiteral("defaultRuntimeMode"))), world.draftId, composer(world).value(QStringLiteral("target")).toString()));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("Add caching")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.waitFor([&] { return !launchCalls(world).isEmpty(); }, QStringLiteral("the thread to launch"));
    expect(launchCalls(world).constLast().value(QLatin1String("runtimeMode")) == mode, QStringLiteral("the launch is %1").arg(show(launchCalls(world).constLast().toVariantMap())));
    world.sync();
  });
  // A provider account that cannot run falls back to another of its driver.
  const auto effortChoices = [] {
    return QJsonObject{{QStringLiteral("id"), QStringLiteral("reasoningEffort")},
                       {QStringLiteral("label"), QStringLiteral("Effort")},
                       {QStringLiteral("type"), QStringLiteral("select")},
                       {QStringLiteral("options"),
                        QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("low")}, {QStringLiteral("label"), QStringLiteral("Low")}, {QStringLiteral("isDefault"), true}},
                                   QJsonObject{{QStringLiteral("id"), QStringLiteral("high")}, {QStringLiteral("label"), QStringLiteral("High")}},
                                   QJsonObject{{QStringLiteral("id"), QStringLiteral("xhigh")}, {QStringLiteral("label"), QStringLiteral("Extra High")}}}},
                       {QStringLiteral("currentValue"), QStringLiteral("low")}};
  };
  const auto accountModel = [&effortChoices](const QString& slug, const QString& name, const QJsonObject& extra = {}) {
    QJsonObject model{{QStringLiteral("slug"), slug},
                      {QStringLiteral("name"), name},
                      {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{effortChoices()}}}}};
    for (auto it = extra.begin(); it != extra.end(); ++it) model.insert(it.key(), it.value());
    return model;
  };
  const auto account = [](const QString& id, const QString& driver, const QString& name, const QJsonArray& models) {
    return QJsonObject{{QStringLiteral("instanceId"), id},
                       {QStringLiteral("driver"), driver},
                       {QStringLiteral("displayName"), name},
                       {QStringLiteral("enabled"), true},
                       {QStringLiteral("installed"), true},
                       {QStringLiteral("status"), QStringLiteral("ready")},
                       {QStringLiteral("models"), models}};
  };
  const auto accountId = [](const QString& name) { return name.toLower().replace(u' ', u'_'); };
  const auto addAccount = [](World& world, const QJsonObject& entry) {
    QJsonArray list = providers(world);
    list.append(entry);
    publishProviders(world.mc, list);
    world.sync();
  };
  const auto effortOf = [](World& world) {
    for (const QVariant& option : composer(world).value(QStringLiteral("options")).toList()) {
      if (option.toMap().value(QStringLiteral("id")) == QLatin1String("reasoningEffort")) {
        return option.toMap().value(QStringLiteral("value")).toString();
      }
    }
    return QString();
  };
  const auto turnOff = [&accountId](World& world, const QString& name) {
    changeProvider(world, accountId(name), [](QJsonObject& entry) { entry.insert(QStringLiteral("enabled"), false); });
  };
  step(QStringLiteral("new threads default to Claude Opus at extra high effort on the account %1").arg(q), [&](World& world, const Captures& c, const Table&) {
    addAccount(world, account(accountId(c[0]), QStringLiteral("claudeAgent"), c[0], QJsonArray{accountModel(QStringLiteral("opus"), QStringLiteral("Claude Opus"))}));
    addAccount(world, account(QStringLiteral("claude_team"), QStringLiteral("claudeAgent"), QStringLiteral("Claude Team"),
                              QJsonArray{accountModel(QStringLiteral("opus"), QStringLiteral("Claude Opus"))}));
    // The project's default for new threads (a carried model gives way to it).
    QJsonObject row = world.mc.projects.value(kProject);
    row.insert(QStringLiteral("defaultModelSelection"),
               QJsonObject{{QStringLiteral("instanceId"), accountId(c[0])},
                           {QStringLiteral("model"), QStringLiteral("opus")},
                           {QStringLiteral("options"),
                            QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("reasoningEffort")}, {QStringLiteral("value"), QStringLiteral("xhigh")}}}}});
    world.mc.projects.insert(kProject, row);
    world.mc.sendRows(world.mc.name, {QJsonValue(QJsonArray{kProject, QStringLiteral("project"), row})});
    world.sync();
  });
  step(QStringLiteral("%1 is turned off and the account %1 is ready").arg(q), [&](World& world, const Captures& c, const Table&) { turnOff(world, c[0]); });
  step(QStringLiteral("%1 is turned off and %1, with high effort of its own is ready").arg(q), [&](World& world, const Captures& c, const Table&) {
    // The fallback account's own effort for the model, from when it was used.
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), accountId(c[1])}, {QStringLiteral("model"), QStringLiteral("opus")}});
    world.bridge().dispatch(QStringLiteral("composer.option.set"),
                            QVariantMap{{QStringLiteral("id"), QStringLiteral("reasoningEffort")}, {QStringLiteral("value"), QStringLiteral("high")}});
    world.waitFor([&] { return effortOf(world) == QLatin1String("high"); }, QStringLiteral("the fallback account's own effort to be set"));
    turnOff(world, c[0]);
  });
  step(QStringLiteral("%1 is turned off and only a Codex account is ready").arg(q), [&](World& world, const Captures& c, const Table&) {
    turnOff(world, c[0]);
    turnOff(world, QStringLiteral("Claude Team"));
    changeProvider(world, QStringLiteral("claudeAgent"), [](QJsonObject& entry) { entry.insert(QStringLiteral("enabled"), false); });
  });
  step(QStringLiteral("the composer shows Claude Opus at extra high effort on %1").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return composer(world).value(QStringLiteral("target")) == world.draftId &&
             composer(world).value(QStringLiteral("selectedInstanceId")) == accountId(c[0]) &&
             composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("opus") && effortOf(world) == QLatin1String("xhigh");
    }, [&] { return QStringLiteral("Opus at extra high on %1; the composer shows %2").arg(c[0], show(composer(world))); });
  });
  step(QStringLiteral("the first turn is sent at extra high effort"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("text"), QStringLiteral("first turn")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.waitFor([&] { return !launchCalls(world).isEmpty(); }, QStringLiteral("the thread to launch"));
    bool sent = false;
    const QJsonObject selection = launchCalls(world).constLast().value(QLatin1String("modelSelection")).toObject();
    for (const QJsonValue& option : selection.value(QLatin1String("options")).toArray()) {
      sent = sent || (option.toObject().value(QLatin1String("id")) == QLatin1String("reasoningEffort") &&
                      option.toObject().value(QLatin1String("value")) == QLatin1String("xhigh"));
    }
    expect(sent, QStringLiteral("the launch is %1").arg(show(launchCalls(world).constLast().toVariantMap())));
  });
  step(QStringLiteral("the composer shows %1 at its own high effort").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return composer(world).value(QStringLiteral("target")) == world.draftId &&
             composer(world).value(QStringLiteral("selectedInstanceId")) == accountId(c[0]) && effortOf(world) == QLatin1String("high");
    }, [&] { return QStringLiteral("%1 at high; the composer shows %2").arg(c[0], show(composer(world))); });
  });
  step(QStringLiteral("the composer shows the Codex model at its default effort"), [&](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return composer(world).value(QStringLiteral("target")) == world.draftId &&
             composer(world).value(QStringLiteral("selectedInstanceId")) == QLatin1String("codex") &&
             composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("gpt-5");
    }, [&] { return QStringLiteral("the Codex model; the composer shows %1").arg(show(composer(world))); });
    // Codex's effort defaults to medium in this catalogue.
    expect(effortOf(world) == QLatin1String("medium"), QStringLiteral("the effort is %1").arg(effortOf(world)));
  });

  // A thread saved under a model's alias, on an account that is now off.
  step(QStringLiteral("a thread saved on the account %1 with the model %1 at high effort").arg(q), [&](World& world, const Captures& c, const Table&) {
    const QJsonObject builtin = accountModel(QStringLiteral("gpt-5.4"), QStringLiteral("GPT-5.4"),
                                             {{QStringLiteral("aliases"), QJsonArray{QStringLiteral("5.4")}}});
    const QJsonObject custom = accountModel(QStringLiteral("my-5.4"), QStringLiteral("5.4"), {{QStringLiteral("isCustom"), true}});
    addAccount(world, account(accountId(c[0]), QStringLiteral("codex"), c[0], QJsonArray{builtin, custom}));
    addAccount(world, account(QStringLiteral("codex_work"), QStringLiteral("codex"), QStringLiteral("Codex Work"), QJsonArray{builtin}));
    updateThread(world, {{QStringLiteral("modelSelection"),
                          QJsonObject{{QStringLiteral("instanceId"), accountId(c[0])},
                                      {QStringLiteral("model"), c[1]},
                                      {QStringLiteral("options"),
                                       QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("reasoningEffort")}, {QStringLiteral("value"), QStringLiteral("high")}}}}}}});
  });
  step(QStringLiteral("the composer shows %1 on %1 at high effort").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return composer(world).value(QStringLiteral("selectedInstanceId")) == accountId(c[1]) &&
             composer(world).value(QStringLiteral("selectedModel")) == c[0] && effortOf(world) == QLatin1String("high");
    }, [&] { return QStringLiteral("%1 on %2 at high; the composer shows %3").arg(c[0], c[1], show(composer(world))); });
  });
  step(QStringLiteral("a custom model named %1 on %1 is not taken for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(composer(world).value(QStringLiteral("selectedModel")) == c[2] &&
               composer(world).value(QStringLiteral("selectedModel")) != QLatin1String("my-5.4"),
           QStringLiteral("the composer is on %1").arg(composer(world).value(QStringLiteral("selectedModel")).toString()));
  });

  // A draft switched to an instance whose catalogue has not got its model.
  step(QStringLiteral("the draft picked %1 on the default OpenCode instance").arg(q), [&](World& world, const Captures& c, const Table&) {
    addAccount(world, account(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"),
                              QJsonArray{accountModel(QStringLiteral("kimi-k3.1-pro"), c[0])}));
    QJsonObject kimiDefault = accountModel(QStringLiteral("kimi-default"), QStringLiteral("Kimi Default"));
    kimiDefault.insert(QStringLiteral("isDefault"), true);
    addAccount(world, account(QStringLiteral("kimi"), QStringLiteral("opencode"), QStringLiteral("Kimi"), QJsonArray{kimiDefault}));
    saveElsewhere(world.mc, QStringLiteral("defaultModelSelection"),
                  QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("opencode")}, {QStringLiteral("model"), QStringLiteral("kimi-k3.1-pro")}});
    world.sync();
  });
  step(QStringLiteral("the user switches the draft to a second OpenCode instance %1 without picking a model").arg(q), [&](World& world, const Captures& c, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("defaultModelSelection"),
                  QJsonObject{{QStringLiteral("instanceId"), accountId(c[0])}, {QStringLiteral("model"), QStringLiteral("kimi-k3.1-pro")}});
    newThread(world);
  });
  step(QStringLiteral("the composer shows %1's own default model with its effort choices").arg(q), [&](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return composer(world).value(QStringLiteral("selectedInstanceId")) == QLatin1String("kimi") &&
             composer(world).value(QStringLiteral("selectedModel")) == QLatin1String("kimi-default") && !effortOf(world).isEmpty();
    }, [&] { return QStringLiteral("%1's default; the composer shows %2").arg(c[0], show(composer(world))); });
  });
  step(QStringLiteral("sending asks %1 only for a model in its own catalog").arg(q), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("text"), QStringLiteral("hello")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.waitFor([&] { return !launchCalls(world).isEmpty(); }, QStringLiteral("the thread to launch"));
    const QJsonObject selection = launchCalls(world).constLast().value(QLatin1String("modelSelection")).toObject();
    expect(selection.value(QLatin1String("instanceId")) == QLatin1String("kimi") &&
               selection.value(QLatin1String("model")) == QLatin1String("kimi-default"),
           QStringLiteral("the launch asks for %1").arg(show(selection.toVariantMap())));
  });

  step(QStringLiteral("a project that overrides the default uses its own permissions"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("projectSettingsOverrides"),
                  QJsonObject{{kProject, QJsonObject{{QStringLiteral("defaultRuntimeMode"), QStringLiteral("auto-accept-edits")}}}});
    world.sync();
    newThread(world);
    world.waitFor([&] { return composer(world).value(QStringLiteral("runtimeMode")) == QLatin1String("auto-accept-edits"); },
                  [&] { return QStringLiteral("the project's permissions; the composer shows %1").arg(composer(world).value(QStringLiteral("runtimeMode")).toString()); });
  });
});

}  // namespace

bool composerMessageReceived(World& world, const QString& text) {
  if (!composerBrickShown(world)) return false;
  const QJsonObject message = lastMessage(world);
  if (message.isEmpty()) return false;
  const QString sent = message.value(QLatin1String("text")).toString();
  expect(sent.simplified() == text, QStringLiteral("the agent received \"%1\"").arg(sent));
  return true;
}
