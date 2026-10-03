// The MC's settings document and this device's preferences, as the desktop's
// settings store keeps them (features/settings/saving-settings.feature).

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QSet>

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

QList<int> configSubscribers(FakeMc& mc, const QString& environment) {
  QList<int> result;
  for (const int id : mc.subscribers(QStringLiteral("config"))) {
    if (mc.shapeOf(id).value(QLatin1String("environment")) == environment) result.append(id);
  }
  return result;
}

void sendConfig(FakeMc& mc, const QString& environment, const QJsonObject& frame) {
  for (const int id : configSubscribers(mc, environment)) {
    QJsonObject withId = frame;
    withId.insert(QStringLiteral("id"), id);
    mc.send(withId);
  }
}

// Another machine of the cluster keeps its own settings document.
bool ownsDocument(const FakeConfig& fake, const QString& environment) {
  return fake.documents.contains(environment) || fake.elsewhere.contains(environment);
}

// The document as HalC2.ProviderSecrets.seal keeps it: each sensitive
// provider variable's value moved to the secret store, a redacted one kept
// when a secret is stored under its name, and the secrets of variables gone.
QJsonObject sealed(FakeConfig& fake, QJsonObject settings) {
  QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
  for (auto it = instances.begin(); it != instances.end(); ++it) {
    QJsonObject instance = it.value().toObject();
    QJsonArray environment = instance.value(QLatin1String("environment")).toArray();
    QSet<QString> kept;
    for (qsizetype i = 0; i < environment.size(); ++i) {
      QJsonObject variable = environment.at(i).toObject();
      if (!variable.value(QLatin1String("sensitive")).toBool()) continue;
      const QString key = it.key() + QLatin1Char('/') + variable.value(QLatin1String("name")).toString();
      const QString value = variable.value(QLatin1String("value")).toString();
      kept.insert(key);
      if (variable.value(QLatin1String("valueRedacted")).toBool() && fake.secrets.contains(key)) {
        variable.insert(QStringLiteral("value"), QString());
      } else if (!value.isEmpty()) {
        fake.secrets.insert(key, value);
        variable.insert(QStringLiteral("value"), QString());
        variable.insert(QStringLiteral("valueRedacted"), true);
      } else {
        fake.secrets.remove(key);
        variable.remove(QStringLiteral("valueRedacted"));
      }
      environment.replace(i, variable);
    }
    for (const QString& secret : fake.secrets.keys()) {
      if (secret.startsWith(it.key() + QLatin1Char('/')) && !kept.contains(secret)) fake.secrets.remove(secret);
    }
    if (!environment.isEmpty()) instance.insert(QStringLiteral("environment"), environment);
    it.value() = instance;
  }
  if (settings.contains(QLatin1String("providerInstances"))) settings.insert(QStringLiteral("providerInstances"), instances);
  // As HalC2.UsageLimitSources.seal_keys: a hub's management key moves to the
  // secret store, the marker stays, and a dropped hub's key is deleted.
  QJsonObject hubs = settings.value(QLatin1String("usageLimitSources")).toObject();
  const QString marker = QStringLiteral("••••••");
  for (auto it = hubs.begin(); it != hubs.end(); ++it) {
    QJsonObject hub = it.value().toObject();
    const QString key = hub.value(QLatin1String("managementKey")).toString();
    if (key.isEmpty() || key == marker) continue;
    fake.secrets.insert(QStringLiteral("hub/") + it.key(), key);
    hub.insert(QStringLiteral("managementKey"), marker);
    it.value() = hub;
  }
  for (const QString& secret : fake.secrets.keys()) {
    if (secret.startsWith(QLatin1String("hub/")) && !hubs.contains(secret.mid(4))) fake.secrets.remove(secret);
  }
  if (settings.contains(QLatin1String("usageLimitSources"))) settings.insert(QStringLiteral("usageLimitSources"), hubs);
  return settings;
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject& shape) {
    const QString environment = shape.value(QLatin1String("environment")).toString();
    FakeConfig& fake = fakeConfig(mc);
    // As the MC answers: the snapshot, then what it publishes.
    if (environment == mc.environmentId) {
      QJsonObject config = fake.config;
      config.insert(QStringLiteral("settings"), fake.settings);
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("mc"), mc.name},
                 {QStringLiteral("config"), config}});
    } else if (fake.elsewhere.contains(environment) || fake.documents.contains(environment)) {
      QJsonObject config = fake.elsewhere.value(environment);
      config.insert(QStringLiteral("settings"), fake.documents.value(environment).settings);
      mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("config.themes")},
               {QStringLiteral("id"), id},
               {QStringLiteral("themes"), fake.themes.value(environment)}});
    if (fake.sources.contains(environment)) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config.usageLimitSources")},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("sources"), fake.sources.value(environment)}});
    }
  });
  mc.onRpc(QStringLiteral("hal-c2.readSettings"), [&mc](const FakeMc::Rpc& rpc) {
    FakeConfig& fake = fakeConfig(mc);
    if (ownsDocument(fake, rpc.environment)) {
      const FakeConfig::Document& document = fake.documents.value(rpc.environment);
      mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), document.settings}, {QStringLiteral("version"), document.version}});
      return;
    }
    if (fake.holdReads) return;
    mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), fake.settings}, {QStringLiteral("version"), fake.version}});
    if (fake.editOnRead) {
      saveElsewhere(mc, QStringLiteral("otherEdits"), fake.settings.value(QLatin1String("otherEdits")).toInt() + 1, true);
    }
  });
  mc.onRpc(QStringLiteral("hal-c2.writeSettings"), [&mc](const FakeMc::Rpc& rpc) {
    FakeConfig& fake = fakeConfig(mc);
    if (ownsDocument(fake, rpc.environment)) {
      FakeConfig::Document& document = fake.documents[rpc.environment];
      if (!document.refuseWrites.isEmpty()) {
        mc.refuse(rpc, document.refuseWrites);
      } else if (rpc.payload.value(QLatin1String("version")).toInt(-1) != document.version) {
        mc.refuse(rpc, QStringLiteral("settings changed"), {{QStringLiteral("_tag"), QStringLiteral("StaleSettings")}});
      } else {
        document.settings = rpc.payload.value(QLatin1String("settings")).toObject();
        document.version++;
        mc.reply(rpc, QJsonObject{{QStringLiteral("version"), document.version}});
        sendConfig(mc, rpc.environment, {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), document.settings}});
      }
      return;
    }
    fake.writes.append(rpc.payload);
    if (!fake.refuseWrites.isEmpty()) {
      fake.saved.append(false);
      mc.refuse(rpc, fake.refuseWrites);
      return;
    }
    if (rpc.payload.value(QLatin1String("version")).toInt(-1) != fake.version) {
      fake.saved.append(false);
      mc.refuse(rpc, QStringLiteral("settings changed"),
                  {{QStringLiteral("_tag"), QStringLiteral("StaleSettings")},
                   {QStringLiteral("message"), QStringLiteral("settings changed")}});
      return;
    }
    fake.saved.append(true);
    const QJsonObject before = fake.settings.value(QLatin1String("providerInstances")).toObject();
    fake.settings = sealed(fake, rpc.payload.value(QLatin1String("settings")).toObject());
    fake.version++;
    mc.reply(rpc, QJsonObject{{QStringLiteral("version"), fake.version}});
    sendConfig(mc, mc.environmentId,
               {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), fake.settings}});
    // A dropped hub's accounts leave what the MC publishes.
    if (fake.sources.contains(mc.environmentId)) {
      const QJsonObject hubs = fake.settings.value(QLatin1String("usageLimitSources")).toObject();
      QJsonArray kept;
      for (const QJsonValue& source : fake.sources.value(mc.environmentId)) {
        if (hubs.contains(source.toObject().value(QLatin1String("id")).toString())) kept.append(source);
      }
      if (kept.size() != fake.sources.value(mc.environmentId).size()) {
        fake.sources.insert(mc.environmentId, kept);
        sendConfig(mc, mc.environmentId, {{QStringLiteral("t"), QStringLiteral("config.usageLimitSources")}, {QStringLiteral("sources"), kept}});
      }
    }
    // As HalC2.Settings provider_enabled? reads it: an instance's own entry
    // first, then its driver's; an added instance that was removed is no
    // longer listed, and one's name and colour show as HalC2.Environment
    // lists them.
    QJsonArray providers = fake.config.value(QLatin1String("providers")).toArray();
    const QJsonObject instances = fake.settings.value(QLatin1String("providerInstances")).toObject();
    bool changed = false;
    for (qsizetype i = providers.size() - 1; i >= 0; --i) {
      const QString id = providers.at(i).toObject().value(QLatin1String("instanceId")).toString();
      if (before.contains(id) && !instances.contains(id) && id != providers.at(i).toObject().value(QLatin1String("driver")).toString()) {
        providers.removeAt(i);
        changed = true;
      }
    }
    for (qsizetype i = 0; i < providers.size(); ++i) {
      QJsonObject entry = providers.at(i).toObject();
      const QString id = entry.value(QLatin1String("instanceId")).toString();
      const QJsonObject instance = instances.value(id).toObject();
      for (const QString key : {QStringLiteral("displayName"), QStringLiteral("accentColor")}) {
        const QString value = instance.value(key).toString().trimmed();
        // No provider lists an accent of its own, so a cleared one goes.
        if (value.isEmpty() && key == QLatin1String("accentColor") && !instance.isEmpty() && entry.contains(key)) {
          entry.remove(key);
          providers.replace(i, entry);
          changed = true;
        }
        if (value.isEmpty() || entry.value(key) == value) continue;
        entry.insert(key, value);
        providers.replace(i, entry);
        changed = true;
      }
      const QJsonValue enabled = instance.contains(QLatin1String("enabled"))
                                     ? instance.value(QLatin1String("enabled"))
                                     : fake.settings.value(QLatin1String("providers")).toObject().value(id).toObject().value(QLatin1String("enabled"));
      if (!enabled.isBool() || enabled == entry.value(QLatin1String("enabled"))) continue;
      entry.insert(QStringLiteral("enabled"), enabled);
      providers.replace(i, entry);
      changed = true;
    }
    if (changed) publishProviders(mc, providers);
  });
});

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

bool isOn(const QString& state) {
  return state == QLatin1String("on");
}

void turn(World& world, const QString& key, bool on) {
  // Connected, the shell reads the settings next; unless the MC holds them back.
  if (!fakeConfig(world.mc).holdReads) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
  }
  Outcome& outcome = world.mc.part<Outcome>();
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

  // The MC's document.
  step(QStringLiteral("the MC's settings are at version (\\d+) with %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& fake = fakeConfig(world.mc);
    fake.version = c[0].toInt();
    fake.settings.insert(c[1], true);
  });
  step(QStringLiteral("the MC holds back its settings"), [](World& world, const Captures&, const Table&) {
    fakeConfig(world.mc).holdReads = true;
  });
  step(QStringLiteral("another client saved %1 on without the desktop hearing of it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    saveElsewhere(world.mc, c[0], true, true);
  });
  step(QStringLiteral("another client saves %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    saveElsewhere(world.mc, c[0], true);
  });
  step(QStringLiteral("another client saves the settings each time the desktop reads them"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the settings"));
    fakeConfig(world.mc).editOnRead = true;
    saveElsewhere(world.mc, QStringLiteral("otherEdits"), 1, true);
  });
  step(QStringLiteral("the MC refuses to save settings with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.mc).refuseWrites = c[0];
  });
  step(QStringLiteral("the MC restarts with %1 on").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& fake = fakeConfig(world.mc);
    fake.settings = {{c[0], true}};
    fake.version = 0;
    world.mc.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the MC's configuration lists the provider %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.mc).config.insert(QStringLiteral("providers"), QJsonArray{QJsonObject{{QStringLiteral("provider"), c[0]}}});
  });
  step(QStringLiteral("the MC's providers become %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonArray providers{QJsonObject{{QStringLiteral("provider"), c[0]}}};
    fakeConfig(world.mc).config.insert(QStringLiteral("providers"), providers);
    sendConfig(world.mc, world.mc.environmentId,
               {{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("providers"), providers}});
  });

  // The shell's side.
  step(QStringLiteral("the desktop (?:turns|turned) %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    turn(world, c[0], isOn(c[1]));
  });
  step(QStringLiteral("the desktop holds the MC's settings at version (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return settings(world)->ready() && settings(world)->version() == c[0].toInt(); }, [&] {
      return QStringLiteral("version %1; the shell holds version %2 (%3)")
          .arg(c[0])
          .arg(settings(world)->version())
          .arg(settings(world)->ready() ? QStringLiteral("read") : QStringLiteral("not read"));
    });
  });
  step(QStringLiteral("the desktop holds %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return settings(world)->ready() && settings(world)->value(c[0]) == QVariant(isOn(c[1])); }, [&] {
      return QStringLiteral("%1 %2; the shell holds %3").arg(c[0], c[1], show(settings(world)->settings().toVariantMap()));
    });
  });
  step(QStringLiteral("the desktop reports %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const Outcome& outcome = world.mc.part<Outcome>();
    expect(outcome.error == c[0], QStringLiteral("the change ended with %1").arg(outcome.error.value_or(QStringLiteral("no error"))));
    expect(settings(world)->error() == c[0], QStringLiteral("the store reports \"%1\"").arg(settings(world)->error()));
  });
  step(QStringLiteral("the desktop's configuration lists the provider %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return at(settings(world)->config().toVariantMap(), QStringLiteral("providers")).toList().value(0).toMap().value(QStringLiteral("provider")) == c[0];
    }, [&] { return QStringLiteral("the provider %1 in %2").arg(c[0], show(settings(world)->config().toVariantMap())); });
  });

  // What the MC was sent.
  step(QStringLiteral("the MC saved the change at version (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const FakeConfig& fake = fakeConfig(world.mc);
    expect(!fake.writes.isEmpty() && fake.saved.last(), QStringLiteral("the MC saved nothing"));
    const int version = fake.writes.last().value(QLatin1String("version")).toInt();
    expect(version == c[0].toInt(), QStringLiteral("saved at version %1").arg(version));
  });
  step(QStringLiteral("the MC holds %1 (on|off)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonValue value = fakeConfig(world.mc).settings.value(c[0]);
    expect(value == QJsonValue(isOn(c[1])), QStringLiteral("the MC holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())));
  });
  step(QStringLiteral("the MC does not hold %1 off").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fakeConfig(world.mc).settings.value(c[0]) != QJsonValue(false),
           QStringLiteral("the MC holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())));
  });
  step(QStringLiteral("the MC refused the desktop's first save as stale"), [](World& world, const Captures&, const Table&) {
    const FakeConfig& fake = fakeConfig(world.mc);
    QStringList answers;
    for (const bool saved : fake.saved) answers.append(saved ? QStringLiteral("saved") : QStringLiteral("refused"));
    expect(fake.saved.size() >= 2 && !fake.saved.first() && fake.saved.last(),
           QStringLiteral("the MC's answers to the saves were [%1]").arg(answers.join(u", ")));
  });
  step(QStringLiteral("the MC's settings were not written"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fakeConfig(world.mc).writes.isEmpty(), QStringLiteral("the MC was sent %1 write(s)").arg(fakeConfig(world.mc).writes.size()));
  });

  // This device's preferences.
  step(QStringLiteral("this device's preferences say %1 is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QFile file(preferencesPath(world));
    if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(file.fileName()));
    file.write(QJsonDocument(QJsonObject{{c[0], c[1]}}).toJson());
  });
  step(QStringLiteral("this device's %1 is set to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject device = settings(world)->deviceSettings();
    device.insert(c[0], c[1]);
    expect(settings(world)->setDeviceSettings(device), QStringLiteral("the preferences were not saved"));
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
    world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
  });
  step(QStringLiteral("the desktop saves the device preference %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settings(world)->writeDevice(c[0], c[1]);
  });
  step(QStringLiteral("this device's preferences file holds %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QFile file(preferencesPath(world));
    if (!file.open(QIODevice::ReadOnly)) fail(QStringLiteral("there is no %1").arg(file.fileName()));
    const QJsonObject saved = QJsonDocument::fromJson(file.readAll()).object();
    expect(saved.value(c[0]) == c[1], QStringLiteral("the file holds %1").arg(show(saved.toVariantMap())));
  });
  step(QStringLiteral("the desktop reports this device's preferences could not be saved"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->deviceError().startsWith(QLatin1String("Cannot save")),
           QStringLiteral("the store reports \"%1\"").arg(settings(world)->deviceError()));
  });
  step(QStringLiteral("the device preference %1 is not set").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!settings(world)->deviceSettings().contains(c[0]),
           QStringLiteral("this device holds %1").arg(show(settings(world)->deviceSettings().toVariantMap())));
  });
});

}  // namespace

FakeConfig& fakeConfig(FakeMc& mc) {
  return mc.part<FakeConfig>();
}

void publishThemes(FakeMc& mc, const QString& environment, const QJsonArray& themes) {
  fakeConfig(mc).themes.insert(environment, themes);
  sendConfig(mc, environment, {{QStringLiteral("t"), QStringLiteral("config.themes")}, {QStringLiteral("themes"), themes}});
}

void saveElsewhere(FakeMc& mc, const QString& key, const QJsonValue& value, bool quietly) {
  FakeConfig& fake = fakeConfig(mc);
  fake.settings.insert(key, value);
  fake.version++;
  if (quietly) return;
  sendConfig(mc, mc.environmentId,
             {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), fake.settings}});
}

void saveOn(FakeMc& mc, const QString& environment, const QString& key, const QJsonValue& value) {
  if (environment.isEmpty() || environment == mc.environmentId) {
    saveElsewhere(mc, key, value);
    return;
  }
  FakeConfig::Document& document = documentOf(mc, environment);
  document.settings.insert(key, value);
  document.version++;
  sendConfig(mc, environment, {{QStringLiteral("t"), QStringLiteral("config.settings")}, {QStringLiteral("settings"), document.settings}});
}

FakeConfig::Document& documentOf(FakeMc& mc, const QString& environment) {
  return fakeConfig(mc).documents[environment];
}

void publishProviders(FakeMc& mc, const QJsonArray& providers) {
  fakeConfig(mc).config.insert(QStringLiteral("providers"), providers);
  sendConfig(mc, mc.environmentId, {{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("providers"), providers}});
}
