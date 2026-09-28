#include "SettingsController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>

#include "NodeClient.h"

namespace {

const NativeControllerRegistrar<SettingsController> registrar(QStringLiteral("settings"), {}, "Settings");

// Saves over a stale copy before giving up: each retry is another editor
// saving in between, which is rare, and never endless.
constexpr int kStaleRetries = 3;

QJsonObject withPath(QJsonObject object, const QStringList& path, const QJsonValue& value) {
  const QString& key = path.first();
  if (path.size() == 1) {
    if (value.isNull() || value.isUndefined()) object.remove(key);
    else object.insert(key, value);
    return object;
  }
  object.insert(key, withPath(object.value(key).toObject(), path.mid(1), value));
  return object;
}

}  // namespace

SettingsController::SettingsController(ShellBridge*, NodeClient* client, QObject* parent)
    : QObject(parent), m_client(client) {
  // A reconnect may reach a restarted node, whose versions start again; the
  // config snapshot that follows the re-sent subscription reads them afresh.
  connect(m_client, &NodeClient::readyChanged, this, [this](bool ready) {
    if (ready || !m_ready) return;
    m_ready = false;
    ++m_generation;
    emit settingsChanged();
  });
}

void SettingsController::activate() {
  if (m_active) return;
  m_active = true;
  m_client->subscribe({{QStringLiteral("type"), QStringLiteral("config")},
                       {QStringLiteral("environment"), m_client->environment()}},
                      [this](const QJsonObject& frame) { onConfig(frame); });
}

void SettingsController::onConfig(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("config")) {
    const QJsonObject config = frame.value(QLatin1String("config")).toObject();
    if (config != m_config) {
      m_config = config;
      emit configChanged();
    }
    // The snapshot after every (re)subscription: the document may have moved on.
    read();
  } else if (type == QLatin1String("config.settings")) {
    m_config.insert(QStringLiteral("settings"), frame.value(QLatin1String("settings")));
    emit configChanged();
    // The frame has no version to save against; the read brings one.
    read();
  } else if (type == QLatin1String("config.providers")) {
    m_config.insert(QStringLiteral("providers"), frame.value(QLatin1String("providers")));
    emit configChanged();
  } else if (type == QLatin1String("config.keybindings")) {
    m_config.insert(QStringLiteral("keybindings"), frame.value(QLatin1String("rules")));
    emit configChanged();
  } else if (type == QLatin1String("config.themes")) {
    setThemes(frame.value(QLatin1String("themes")).toArray());
  }
}

void SettingsController::setThemes(const QJsonArray& themes) {
  if (themes == m_themes) return;
  m_themes = themes;
  emit themesChanged();
}

void SettingsController::read(std::function<void()> then) {
  const quint64 generation = ++m_generation;
  m_client->call(m_client->environment(), QStringLiteral("hal-c2.readSettings"), QJsonObject{},
                 [this, generation, then = std::move(then)](const QJsonValue& result, const std::optional<QString>& error) {
                   // Answers land out of order: a read asked before a save may arrive
                   // after it. What waits on it goes on with what is newer.
                   if (generation != m_generation) {
                     if (then) then();
                     return;
                   }
                   if (error) {
                     fail(*error);
                     if (then) then();
                     return;
                   }
                   const QJsonObject answer = result.toObject();
                   const QJsonObject settings = answer.value(QLatin1String("settings")).toObject();
                   const int version = answer.value(QLatin1String("version")).toInt();
                   const bool changed = !m_ready || settings != m_settings || version != m_version || !m_error.isEmpty();
                   m_settings = settings;
                   m_version = version;
                   m_ready = true;
                   m_error.clear();
                   if (changed) emit settingsChanged();
                   if (then) then();
                 });
}

void SettingsController::change(Edit edit, Done done) {
  attempt(std::move(edit), std::move(done), kStaleRetries);
}

void SettingsController::attempt(Edit edit, Done done, int retries) {
  const auto finish = [done](const std::optional<QString>& error) {
    if (done) done(error);
  };
  if (!m_ready) {
    const QString message = QStringLiteral("The node's settings are not loaded.");
    fail(message);
    finish(message);
    return;
  }
  const QJsonObject next = edit(m_settings);
  if (next == m_settings) {
    finish(std::nullopt);
    return;
  }
  const quint64 generation = ++m_generation;
  const QJsonObject payload{{QStringLiteral("settings"), next}, {QStringLiteral("version"), m_version}};
  m_client->call(m_client->environment(), QStringLiteral("hal-c2.writeSettings"), payload,
                 [this, edit, done, retries, next, generation, finish](const QJsonValue& result,
                                                                       const std::optional<QString>& error) {
                   if (error) {
                     const bool stale = result.toObject().value(QLatin1String("_tag")) == QLatin1String("StaleSettings");
                     if (stale && retries > 0) {
                       // Another client saved first: apply the edit to what it saved.
                       read([this, edit, done, retries] { attempt(edit, done, retries - 1); });
                       return;
                     }
                     const QString message = stale ? QStringLiteral("Settings kept changing elsewhere; not saved.") : *error;
                     fail(message);
                     finish(message);
                     return;
                   }
                   // A read overtaken by this save is dropped; this is newer.
                   if (generation == m_generation) {
                     m_settings = next;
                     m_version = result.toObject().value(QLatin1String("version")).toInt(m_version + 1);
                     m_error.clear();
                     emit settingsChanged();
                   }
                   finish(std::nullopt);
                 });
}

void SettingsController::fail(const QString& error) {
  m_error = error;
  emit settingsChanged();
}

QVariant SettingsController::value(const QString& path) const {
  QJsonValue current = m_settings;
  for (const QString& key : path.split(QLatin1Char('.'))) current = current.toObject().value(key);
  return current.toVariant();
}

void SettingsController::write(const QString& path, const QVariant& value) {
  const QStringList keys = path.split(QLatin1Char('.'), Qt::SkipEmptyParts);
  if (keys.isEmpty()) return;
  const QJsonValue json = QJsonValue::fromVariant(value);
  change([keys, json](const QJsonObject& settings) { return withPath(settings, keys, json); });
}

void SettingsController::setDevicePath(const QString& path) {
  m_devicePath = path;
  QJsonObject device;
  QString error;
  QFile file(path);
  if (file.exists()) {
    QJsonParseError parse;
    const QJsonDocument doc =
        file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll(), &parse) : QJsonDocument();
    if (doc.isObject()) device = doc.object();
    else error = QStringLiteral("Cannot read %1").arg(path);
  }
  m_device = device;
  m_deviceError = error;
  emit deviceChanged();
}

bool SettingsController::setDeviceSettings(const QJsonObject& device) {
  if (device == m_device) return true;
  QString error;
  if (m_devicePath.isEmpty()) {
    error = QStringLiteral("This device has nowhere to keep its preferences.");
  } else {
    QDir().mkpath(QFileInfo(m_devicePath).absolutePath());
    QSaveFile file(m_devicePath);
    if (!file.open(QIODevice::WriteOnly) || file.write(QJsonDocument(device).toJson()) < 0 || !file.commit()) {
      error = QStringLiteral("Cannot save %1").arg(m_devicePath);
    }
  }
  if (!error.isEmpty()) {
    m_deviceError = error;
    emit deviceChanged();
    return false;
  }
  m_device = device;
  m_deviceError.clear();
  emit deviceChanged();
  return true;
}

bool SettingsController::writeDevice(const QString& key, const QVariant& value) {
  return setDeviceSettings(withPath(m_device, {key}, QJsonValue::fromVariant(value)));
}
