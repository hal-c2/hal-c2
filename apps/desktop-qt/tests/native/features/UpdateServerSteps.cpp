// Bringing a server up to this app's version (ServerUpdateController): the
// offer in the window's ConnectionNotice, Update all and each machine's action
// in Connections settings (ServerUpdatesList, ServerUpdateAction), against
// the fake MC's descriptors (features/settings/updates.feature, Rule
// "Updating a server"). "server" is the MC's own environment; any other
// machine is a member of its cluster.

#include <QJsonObject>
#include <QQuickItem>

#include "Brick.h"
#include "ConnectionHealthController.h"
#include "Harness.h"
#include "World.h"

namespace {

const QString kOwn = QStringLiteral("server");
const QString kBehind = QStringLiteral("1.3.0");
const QString kMethod = QStringLiteral("server.updateServer");

// What the scenario said of the app and the server's answers.
struct Updates {
  QString appVersion = QStringLiteral("1.4.0");
  QString machine;  // the machine the scenario is about
  // How `server.updateServer` answers, by environment id: the version it
  // reconnected on, or "!" and why it failed. None: held.
  QHash<QString, QString> answers;
  QList<FakeMc::Rpc> held;
};

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(kMethod, [&mc](const FakeMc::Rpc& rpc) {
    const QString environment = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
    Updates& updates = mc.part<Updates>();
    if (!updates.answers.contains(environment)) {
      updates.held.append(rpc);
      return;
    }
    const QString answer = updates.answers.value(environment);
    if (answer.startsWith(u'!')) {
      mc.refuse(rpc, answer.mid(1));
    } else {
      mc.reply(rpc, QJsonObject{{QStringLiteral("targetVersion"), answer}, {QStringLiteral("method"), QStringLiteral("hot-upgrade")}});
    }
  });
});

Updates& updates(World& world) {
  return world.mc.part<Updates>();
}

QString idOf(World& world, const QString& name) {
  return name == kOwn ? world.mc.environmentId : name;
}

void setAppVersion(World& world) {
  auto* health = world.native().shared<ConnectionHealthController>();
  if (!health) fail(QStringLiteral("the shell has no connection health"));
  health->setClientVersion(updates(world).appVersion);
}

QVariantMap serverUpdates(World& world) {
  return world.state(QStringLiteral("serverUpdates")).toMap();
}

std::optional<QVariantMap> machine(World& world, const QString& name) {
  for (const QVariant& value : serverUpdates(world).value(QStringLiteral("machines")).toList()) {
    if (value.toMap().value(QStringLiteral("environmentId")) == idOf(world, name)) return value.toMap();
  }
  return std::nullopt;
}

QString describe(World& world) {
  return QStringLiteral("serverUpdates is %1; confirmation %2; toasts %3")
      .arg(show(serverUpdates(world)), show(world.state(QStringLiteral("confirmation"))), show(world.state(QStringLiteral("toasts"))));
}

// Says what `name`'s descriptor offers, the shell connected and hearing it.
// selfUpdate: the `serverSelfUpdate` capability, empty for a checkout.
void describeMachine(World& world, const QString& name, const QString& version, const QString& selfUpdate, bool desktopAppUpdate = true) {
  QJsonObject capabilities{{QStringLiteral("desktopAppUpdate"), desktopAppUpdate}};
  if (!selfUpdate.isEmpty()) capabilities.insert(QStringLiteral("serverSelfUpdate"), selfUpdate);
  world.mc.descriptorFields.insert(idOf(world, name), {{QStringLiteral("serverVersion"), version}, {QStringLiteral("capabilities"), capabilities}});
  updates(world).machine = name;
  if (name == kOwn && world.mc.label.isEmpty()) world.mc.label = kOwn;
  if (world.shellSubscriptions() < 1) {
    world.connect();
  } else if (name == kOwn) {
    world.mc.announceEnvironment();
  } else {
    world.mc.peerLabels.insert(name, name);
    world.mc.join(QStringLiteral("mc-") + name, name);
  }
  if (name != kOwn && !world.mc.members.contains(name)) world.mc.join(name);
  world.sync();
  setAppVersion(world);
  world.waitFor([&] { return machine(world, name).has_value() && machine(world, name)->value(QStringLiteral("version")) == version; },
                [&] { return QStringLiteral("%1 on %2; %3").arg(name, version, describe(world)); });
}

// The scenario's machine, behind and updating itself, unless a step described it already.
void ensureMachine(World& world, const QString& name, const QString& selfUpdate = QStringLiteral("boot-service")) {
  if (!world.mc.descriptorFields.contains(idOf(world, name))) describeMachine(world, name, kBehind, selfUpdate);
}

// One machine's offer as Connections settings shows it.
Brick& action(World& world, const QString& name) {
  world.brick = std::make_unique<Brick>(
      world, QStringLiteral("import QtQuick\nimport HalC2.Bricks\nItem { ServerUpdateAction { environmentId: \"%1\" } }\n").arg(idOf(world, name)).toUtf8(),
      QSize(600, 120));
  return *world.brick;
}

Brick& notice(World& world) {
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n", QSize(900, 600));
  return *world.brick;
}

bool visible(Brick& brick, const QString& objectName) {
  QQuickItem* item = brick.item(objectName);
  return item && item->isVisible();
}

void clickUpdate(World& world, const QString& name) {
  Brick& shown = action(world, name);
  expect(visible(shown, QStringLiteral("serverUpdateButton")), QStringLiteral("no update is offered for %1; %2").arg(name, describe(world)));
  shown.click(QStringLiteral("serverUpdateButton"));
}

QList<FakeMc::Rpc> updateCalls(World& world) {
  QList<FakeMc::Rpc> found;
  for (const FakeMc::Rpc& rpc : world.mc.calls) {
    if (rpc.method == kMethod) found.append(rpc);
  }
  return found;
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QVariantMap waitForToast(World& world, const QString& title) {
  QVariantMap found;
  world.waitFor(
      [&] {
        for (const QVariant& item : toasts(world)) {
          if (item.toMap().value(QStringLiteral("title")) == title) found = item.toMap();
        }
        return !found.isEmpty();
      },
      [&] { return QStringLiteral("the toast \"%1\"; %2").arg(title, describe(world)); });
  return found;
}

QVariantMap question(World& world) {
  world.waitFor([&] { return world.state(QStringLiteral("confirmation")).typeId() == QMetaType::QVariantMap; },
                [&] { return QStringLiteral("a question; %1").arg(describe(world)); });
  return world.state(QStringLiteral("confirmation")).toMap();
}

void answer(World& world, bool accepted) {
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), question(world).value(QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

const Steps steps([] {
  const QString q = kQuoted;

  // The offer in the conversation.
  step(QStringLiteral("the app is newer than the server on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    describeMachine(world, c[0], kBehind, QStringLiteral("boot-service"));
  });
  step(QStringLiteral("the user opens a thread on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kOwn, QStringLiteral("threads here are on the MC's own environment"));
    // The notice stands over every view of the window, the thread's included.
    notice(world);
  });
  step(QStringLiteral("the user is offered to update %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& shown = *world.brick;
    world.waitFor([&] { return visible(shown, QStringLiteral("serverUpdateButton")); }, [&] { return describe(world); });
    const QVariantMap warning = world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("versionWarning")).toMap();
    expect(shown.shows(warning.value(QStringLiteral("text")).toString()) && warning.value(QStringLiteral("text")).toString().contains(c[0]) &&
               shown.item(QStringLiteral("serverUpdateButton"))->property("text") == QLatin1String("Update server"),
           QStringLiteral("the notice is %1; %2").arg(show(warning), describe(world)));
  });

  // Updating one.
  step(QStringLiteral("%1 is behind the app").arg(q), [](World& world, const Captures& c, const Table&) {
    describeMachine(world, c[0], kBehind, QStringLiteral("boot-service"));
  });
  step(QStringLiteral("the user updates %1 and it reconnects on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updates(world).appVersion = c[1];
    ensureMachine(world, c[0]);
    setAppVersion(world);
    updates(world).answers.insert(idOf(world, c[0]), c[1]);
    clickUpdate(world, c[0]);
  });
  step(QStringLiteral("the user is told %1 was updated and reconnected on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, QStringLiteral("%1 updated").arg(c[0]));
    expect(toast.value(QStringLiteral("type")) == QLatin1String("success") &&
               toast.value(QStringLiteral("description")) == QStringLiteral("Reconnected on hal-c2@%1.").arg(c[1]),
           QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user updates %1 and the update fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureMachine(world, c[0]);
    updates(world).answers.insert(idOf(world, c[0]), u'!' + c[1]);
    clickUpdate(world, c[0]);
  });
  step(QStringLiteral("%1 keeps running on its current version").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto now = machine(world, c[0]);
    // Still behind, offered again, and not stuck updating.
    expect(now && now->value(QStringLiteral("version")) == kBehind && now->value(QStringLiteral("behind")).toBool() &&
               !now->value(QStringLiteral("updating")).toBool() && visible(action(world, c[0]), QStringLiteral("serverUpdateButton")),
           describe(world));
  });

  // A desktop app's server.
  step(QStringLiteral("%1 is served by the desktop app on that machine(?: and is behind)?").arg(q), [](World& world, const Captures& c, const Table&) {
    describeMachine(world, c[0], kBehind, QStringLiteral("desktop-managed"), true);
  });
  step(QStringLiteral("this client cannot update that desktop app"), [](World& world, const Captures&, const Table&) {
    describeMachine(world, updates(world).machine, kBehind, QStringLiteral("desktop-managed"), false);
  });
  step(QStringLiteral("the user updates the server on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureMachine(world, c[0]);
    clickUpdate(world, c[0]);
  });
  step(QStringLiteral("the user is asked to confirm the desktop app on %1 will close and relaunch").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QVariantMap asked = question(world);
         expect(asked.value(QStringLiteral("title")).toString().contains(c[0]) &&
                    asked.value(QStringLiteral("description")) == QLatin1String("It will close and relaunch on that machine.") &&
                    updateCalls(world).isEmpty(),
                describe(world));
       });
  step(QStringLiteral("nothing is updated"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const auto now = machine(world, updates(world).machine);
    expect(updateCalls(world).isEmpty() && now && !now->value(QStringLiteral("updating")).toBool(), describe(world));
  });
  step(QStringLiteral("the user looks at the update offer for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    action(world, c[0]);
  });
  step(QStringLiteral("the user is told to update the desktop app on that machine to update the server"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->shows(QStringLiteral("Update the desktop app on that machine to update this server.")), describe(world));
  });
  step(QStringLiteral("no update button is offered"), [](World& world, const Captures&, const Table&) {
    expect(!visible(*world.brick, QStringLiteral("serverUpdateButton")), describe(world));
  });
  step(QStringLiteral("the user updates %1 and its desktop app relaunches on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updates(world).appVersion = c[1];
    ensureMachine(world, c[0], QStringLiteral("desktop-managed"));
    setAppVersion(world);
    updates(world).answers.insert(idOf(world, c[0]), c[1]);
    clickUpdate(world, c[0]);
    answer(world, true);
  });
  step(QStringLiteral("the user is told %1 was updated and the desktop app relaunched on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, QStringLiteral("%1 updated").arg(c[0]));
    expect(toast.value(QStringLiteral("type")) == QLatin1String("success") &&
               toast.value(QStringLiteral("description")) == QStringLiteral("Desktop app relaunched on %1.").arg(c[1]),
           QStringLiteral("the toast is %1").arg(show(toast)));
  });

  // Update all.
  step(QStringLiteral("%1 is hosted by the desktop app and %1 is a service").arg(q), [](World& world, const Captures& c, const Table&) {
    describeMachine(world, c[1], kBehind, QStringLiteral("boot-service"));
    describeMachine(world, c[0], kBehind, QStringLiteral("desktop-managed"), true);
  });
  step(QStringLiteral("the user updates all machines"), [](World& world, const Captures&, const Table&) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ServerUpdatesList { width: 600 } }\n", QSize(600, 300));
    expect(visible(*world.brick, QStringLiteral("serverUpdatesAll")), describe(world));
    world.brick->click(QStringLiteral("serverUpdatesAll"));
  });
  step(QStringLiteral("the user is asked to confirm that the desktop app on %1 will relaunch").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap asked = question(world);
    expect(asked.value(QStringLiteral("title")).toString().contains(c[0]) &&
               asked.value(QStringLiteral("description")) == QLatin1String("They will close and relaunch on those machines.") &&
               updateCalls(world).isEmpty(),
           describe(world));
  });
  step(QStringLiteral("%1 updates independently of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    answer(world, true);
    world.waitFor([&] { return updates(world).held.size() == 2; }, [&] { return QStringLiteral("both updates to start; %1").arg(describe(world)); });
    // The service answers while the desktop app is still on its way.
    const QString own = idOf(world, c[0]);
    for (const FakeMc::Rpc& rpc : std::as_const(updates(world).held)) {
      const QString environment = rpc.environment.isEmpty() ? world.mc.environmentId : rpc.environment;
      if (environment == own) world.mc.reply(rpc, QJsonObject{{QStringLiteral("targetVersion"), updates(world).appVersion}});
    }
    waitForToast(world, QStringLiteral("%1 updated").arg(c[0]));
    const auto other = machine(world, c[1]);
    expect(other && other->value(QStringLiteral("updating")).toBool() && !machine(world, c[0])->value(QStringLiteral("updating")).toBool(),
           describe(world));
  });

  // The command for a server started by hand.
  step(QStringLiteral("the user copies the update command for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureMachine(world, c[0], QString());
    Brick& shown = action(world, c[0]);
    expect(visible(shown, QStringLiteral("serverUpdateButton")) &&
               shown.item(QStringLiteral("serverUpdateButton"))->property("text") == QLatin1String("Copy update command"),
           describe(world));
    shown.click(QStringLiteral("serverUpdateButton"));
  });
  step(QStringLiteral("the command for the matching version is on the clipboard"), [](World& world, const Captures&, const Table&) {
    expect(world.clipboard == QStringLiteral("npx hal-c2@") + updates(world).appVersion, QStringLiteral("the clipboard holds %1").arg(world.clipboard));
  });
  step(QStringLiteral("the user sees an? %1 toast %1 saying to run the command on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    expect(toast.value(QStringLiteral("type")) == c[0] &&
               toast.value(QStringLiteral("description")) ==
                   QStringLiteral("Run `npx hal-c2@%1` on %2 to update it.").arg(updates(world).appVersion, c[2]),
           QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user sees an? %1 toast %1 with the reason").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    expect(toast.value(QStringLiteral("type")) == c[0] &&
               toast.value(QStringLiteral("description")).toString().startsWith(QLatin1String("The clipboard could not be written.")),
           QStringLiteral("the toast is %1").arg(show(toast)));
  });

  // Dismissing the notice.
  step(QStringLiteral("the user dismissed the update notice for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updates(world).appVersion = c[0];
    describeMachine(world, kOwn, kBehind, QStringLiteral("boot-service"));
    Brick& shown = notice(world);
    world.waitFor([&] { return visible(shown, QStringLiteral("connectionDismissWarning")); }, [&] { return describe(world); });
    shown.click(QStringLiteral("connectionDismissWarning"));
  });
  step(QStringLiteral("the user reconnects to the same server"), [](World& world, const Captures&, const Table&) {
    world.restart();
    world.connect();
    world.sync();
    setAppVersion(world);
    world.waitFor([&] { return world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("phase")) == QLatin1String("connected"); },
                  [&] { return show(world.state(QStringLiteral("connection"))); });
  });
  step(QStringLiteral("the notice for %1 does not return").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariant warning = world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("versionWarning"));
    expect(updates(world).appVersion == c[0] && warning.isNull() && !visible(notice(world), QStringLiteral("connectionNotice")),
           QStringLiteral("the notice is %1").arg(show(warning)));
  });
  step(QStringLiteral("a notice for %1 does appear").arg(q), [](World& world, const Captures& c, const Table&) {
    updates(world).appVersion = c[0];
    setAppVersion(world);
    Brick& shown = notice(world);
    world.waitFor([&] { return visible(shown, QStringLiteral("connectionNotice")) && visible(shown, QStringLiteral("serverUpdateButton")); },
                  [&] { return describe(world); });
    expect(world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("versionWarning")).toMap().value(QStringLiteral("clientVersion")) == c[0],
           describe(world));
  });
});

}  // namespace
