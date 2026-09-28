// The node's settings document and this device's preferences, as the shell's
// settings store keeps them (features/desktop/native-settings.feature).

#include <QDir>
#include <QFile>
#include <QJsonDocument>

#include <optional>

#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsController.h"
#include "World.h"

namespace {

// How the shell's last change went.
struct Outcome {
  bool done = false;
  std::optional<QString> error;
};

QList<int> configSubscribers(FakeNode& node, const QString& environment) {
  QList<int> result;
  for (const int id : node.subscribers(QStringLiteral("config"))) {
    if (node.shapeOf(id).value(QLatin1String("environment")) == environment) result.append(id);
  }
  return result;
}

void sendConfig(FakeNode& node, const QString& environment, const QJsonObject& frame) {
  for (const int id : configSubscribers(node, environment)) {
    QJsonObject withId = frame;
    withId.insert(QStringLiteral("id"), id);
    node.send(withId);
  }
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onShape(QStringLiteral("config"), [&node](int id, const QJsonObject& shape) {
    const QString environment = shape.value(QLatin1String("environment")).toString();
    FakeConfig& fake = fakeConfig(node);
    // As the node answers: the snapshot, then what it publishes.
    if (environment == node.environmentId) {
      QJsonObject config = fake.config;
      config.insert(QStringLiteral("settings"), fake.settings);
      node.send({{QStringLiteral("t"), QStringLiteral("config")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("node"), node.name},
                 {QStringLiteral("config"), config}});
    }
    node.send({{QStringLiteral("t"), QStringLiteral("config.themes")},
               {QStringLiteral("id"), id},
               {QStringLiteral("themes"), fake.themes.value(environment)}});
  });
  node.onRpc(QStringLiteral("hal-c2.readSettings"), [&node](const FakeNode::Rpc& rpc) {
    FakeConfig& fake = fakeConfig(node);
    if (fake.holdReads) return;
    node.reply(rpc, QJsonObject{{QStringLiteral("settings"), fake.settings}, {QStringLiteral("version"), fake.version}});
    if (fake.editOnRead) {
      saveElsewhere(node, QStringLiteral("otherEdits"), fake.settings.value(QLatin1String("otherEdits")).toInt() + 1, true);
    }
  });
  node.onRpc(QStringLiteral("hal-c2.writeSettings"), [&node](const FakeNode::Rpc& rpc) {
    FakeConfig& fake = fakeConfig(node);
    fake.writes.append(rpc.payload);
    if (!fake.refuseWrites.isEmpty()) {
      fake.saved.append(false);
      node.refuse(rpc, fake.refuseWrites);
      return;
    }
    if (rpc.payload.value(QLatin1String("version")).toInt(-1) != fake.version) {
      fake.saved.append(false);
      node.refuse(rpc, QStringLiteral("settings changed"),
                  {{QStringLiteral("_tag"), QStringLiteral("StaleSettings")},
                   {QStringLiteral("message"), QStringLiteral("settings changed")}});
      return;
    }
    fake.saved.append(true);
    fake.settings = rpc.payload.value(QLatin1String("settings")).toObject();
    fake.version++;
    node.reply(rpc, QJsonObject{{QStringLiteral("version"), fake.version}});
    sendConfig(node, node.environmentId,
               {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), fake.settings}});
  });
});

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

bool isOn(const QString& state) {
  return state == QLatin1String("on");
}

void turn(World& world, const QString& key, bool on) {
  // Connected, the shell reads the settings next; unless the node holds them back.
  if (!fakeConfig(world.node).holdReads) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
  }
  Outcome& outcome = world.node.part<Outcome>();
  outcome = {};
  settings(world)->change(
      [key, on](QJsonObject document) {
        document.insert(key, on);
        return document;
      },
      [&outcome](const std::optional<QString>& error) {
        outcome.done = true;
        outcome.error = error;
      });
  world.waitFor([&outcome] { return outcome.done; }, QStringLiteral("the change to be saved or given up"));
}

QString preferencesPath(World& world) {
  return QDir(world.configDir()).filePath(QStringLiteral("preferences.json"));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The node's document.
  step(QStringLiteral("the node's settings are at version (\\d+) with %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& fake = fakeConfig(world.node);
    fake.version = c[0].toInt();
    fake.settings.insert(c[1], true);
  });
  step(QStringLiteral("the node holds back its settings"), [](World& world, const Captures&, const Table&) {
    fakeConfig(world.node).holdReads = true;
  });
  step(QStringLiteral("another client saved %1 on without the shell hearing of it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    saveElsewhere(world.node, c[0], true, true);
  });
  step(QStringLiteral("another client saves %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    saveElsewhere(world.node, c[0], true);
  });
  step(QStringLiteral("another client saves the settings each time the shell reads them"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    fakeConfig(world.node).editOnRead = true;
    saveElsewhere(world.node, QStringLiteral("otherEdits"), 1, true);
  });
  step(QStringLiteral("the node refuses to save settings with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.node).refuseWrites = c[0];
  });
  step(QStringLiteral("the node restarts with %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& fake = fakeConfig(world.node);
    fake.settings = {{c[0], true}};
    fake.version = 0;
    world.node.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the node's configuration lists the provider %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.node).config.insert(QStringLiteral("providers"), QJsonArray{QJsonObject{{QStringLiteral("provider"), c[0]}}});
  });
  step(QStringLiteral("the node's providers become %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonArray providers{QJsonObject{{QStringLiteral("provider"), c[0]}}};
    fakeConfig(world.node).config.insert(QStringLiteral("providers"), providers);
    sendConfig(world.node, world.node.environmentId,
               {{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("providers"), providers}});
  });

  // The shell's side.
  step(QStringLiteral("the shell (?:turns|turned) %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    turn(world, c[0], isOn(c[1]));
  });
  step(QStringLiteral("the shell holds the node's settings at version (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return settings(world)->ready() && settings(world)->version() == c[0].toInt(); }, [&] {
      return QStringLiteral("version %1; the shell holds version %2 (%3)")
          .arg(c[0])
          .arg(settings(world)->version())
          .arg(settings(world)->ready() ? QStringLiteral("read") : QStringLiteral("not read"));
    });
  });
  step(QStringLiteral("the shell holds %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return settings(world)->ready() && settings(world)->value(c[0]) == QVariant(isOn(c[1])); }, [&] {
      return QStringLiteral("%1 %2; the shell holds %3").arg(c[0], c[1], show(settings(world)->settings().toVariantMap()));
    });
  });
  step(QStringLiteral("the shell reports %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const Outcome& outcome = world.node.part<Outcome>();
    expect(outcome.error == c[0], QStringLiteral("the change ended with %1").arg(outcome.error.value_or(QStringLiteral("no error"))));
    expect(settings(world)->error() == c[0], QStringLiteral("the store reports \"%1\"").arg(settings(world)->error()));
  });
  step(QStringLiteral("the shell's configuration lists the provider %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return at(settings(world)->config().toVariantMap(), QStringLiteral("providers")).toList().value(0).toMap().value(QStringLiteral("provider")) == c[0];
    }, [&] { return QStringLiteral("the provider %1 in %2").arg(c[0], show(settings(world)->config().toVariantMap())); });
  });

  // What the node was sent.
  step(QStringLiteral("the node saved the change at version (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const FakeConfig& fake = fakeConfig(world.node);
    expect(!fake.writes.isEmpty() && fake.saved.last(), QStringLiteral("the node saved nothing"));
    const int version = fake.writes.last().value(QLatin1String("version")).toInt();
    expect(version == c[0].toInt(), QStringLiteral("saved at version %1").arg(version));
  });
  step(QStringLiteral("the node holds %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonValue value = fakeConfig(world.node).settings.value(c[0]);
    expect(value == QJsonValue(isOn(c[1])), QStringLiteral("the node holds %1").arg(show(fakeConfig(world.node).settings.toVariantMap())));
  });
  step(QStringLiteral("the node does not hold %1 off").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fakeConfig(world.node).settings.value(c[0]) != QJsonValue(false),
           QStringLiteral("the node holds %1").arg(show(fakeConfig(world.node).settings.toVariantMap())));
  });
  step(QStringLiteral("the node refused the shell's first save as stale"), [](World& world, const Captures&, const Table&) {
    const FakeConfig& fake = fakeConfig(world.node);
    QStringList answers;
    for (const bool saved : fake.saved) answers.append(saved ? QStringLiteral("saved") : QStringLiteral("refused"));
    expect(fake.saved.size() >= 2 && !fake.saved.first() && fake.saved.last(),
           QStringLiteral("the node's answers to the saves were [%1]").arg(answers.join(u", ")));
  });
  step(QStringLiteral("the node's settings were not written"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fakeConfig(world.node).writes.isEmpty(), QStringLiteral("the node was sent %1 write(s)").arg(fakeConfig(world.node).writes.size()));
  });

  // This device's preferences.
  step(QStringLiteral("this device's preferences say %1 is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QFile file(preferencesPath(world));
    if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(file.fileName()));
    file.write(QJsonDocument(QJsonObject{{c[0], c[1]}}).toJson());
  });
  step(QStringLiteral("this device's preferences cannot be saved"), [](World& world, const Captures&, const Table&) {
    // A file where the preferences' directory would be.
    const QString blocker = QDir(world.configDir()).filePath(QStringLiteral("blocked"));
    QFile file(blocker);
    if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(blocker));
    settings(world)->setDevicePath(QDir(blocker).filePath(QStringLiteral("preferences.json")));
  });
  step(QStringLiteral("the desktop shell starts"), [](World& world, const Captures&, const Table&) {
    // main.cpp reads this device's preferences before anything else.
    settings(world)->setDevicePath(preferencesPath(world));
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
  });
  step(QStringLiteral("the shell saves the device preference %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settings(world)->writeDevice(c[0], c[1]);
  });
  step(QStringLiteral("this device's preferences file holds %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QFile file(preferencesPath(world));
    if (!file.open(QIODevice::ReadOnly)) fail(QStringLiteral("there is no %1").arg(file.fileName()));
    const QJsonObject saved = QJsonDocument::fromJson(file.readAll()).object();
    expect(saved.value(c[0]) == c[1], QStringLiteral("the file holds %1").arg(show(saved.toVariantMap())));
  });
  step(QStringLiteral("the shell reports this device's preferences could not be saved"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->deviceError().startsWith(QLatin1String("Cannot save")),
           QStringLiteral("the store reports \"%1\"").arg(settings(world)->deviceError()));
  });
  step(QStringLiteral("the device preference %1 is not set").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!settings(world)->deviceSettings().contains(c[0]),
           QStringLiteral("this device holds %1").arg(show(settings(world)->deviceSettings().toVariantMap())));
  });
});

}  // namespace

FakeConfig& fakeConfig(FakeNode& node) {
  return node.part<FakeConfig>();
}

void publishThemes(FakeNode& node, const QString& environment, const QJsonArray& themes) {
  fakeConfig(node).themes.insert(environment, themes);
  sendConfig(node, environment, {{QStringLiteral("t"), QStringLiteral("config.themes")}, {QStringLiteral("themes"), themes}});
}

void saveElsewhere(FakeNode& node, const QString& key, const QJsonValue& value, bool quietly) {
  FakeConfig& fake = fakeConfig(node);
  fake.settings.insert(key, value);
  fake.version++;
  if (quietly) return;
  sendConfig(node, node.environmentId,
             {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), fake.settings}});
}
