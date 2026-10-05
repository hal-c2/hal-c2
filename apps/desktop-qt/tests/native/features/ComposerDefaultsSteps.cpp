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
    // Claude's effort offers Ultrathink, which rides in the prompt.
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
  step(QStringLiteral("the user turns on Ultrathink and sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = composerBrick(world);
    typeInComposer(world, c[0]);
    // From the effort picker's list, with the keyboard.
    QQuickItem* picker = composerPart(world, QStringLiteral("effortPicker"));
    expect(picker && picker->isVisible(), QStringLiteral("the composer shows no effort picker"));
    QObject* popup = picker->property("popup").value<QObject*>();
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(picker));
    world.waitFor([&] { return popup->property("opened").toBool(); }, QStringLiteral("the effort picker to open"));
    const int last = picker->property("count").toInt() - 1;
    for (int guard = 0; picker->property("highlightedIndex").toInt() != last && guard < 8; ++guard) QTest::keyClick(&brick.window(), Qt::Key_Down);
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    world.waitFor([&] { return picker->property("displayText") == QLatin1String("Ultrathink"); },
                  [&] { return QStringLiteral("the effort to read Ultrathink; it reads %1").arg(picker->property("displayText").toString()); });
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    pressInComposer(world, QStringLiteral("Enter"));
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
  step(QStringLiteral("the default permissions for new threads are (.+)"), [](World& world, const Captures& c, const Table&) {
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
  // "Ultrathink:" leads the prompt on a line of its own.
  const QString sent = message.value(QLatin1String("text")).toString();
  expect(sent.simplified() == text && sent.startsWith(QLatin1String("Ultrathink:\n")), QStringLiteral("the agent received \"%1\"").arg(sent));
  return true;
}
