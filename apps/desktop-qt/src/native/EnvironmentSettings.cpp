#include "EnvironmentSettings.h"

#include <QJsonArray>
#include <QPointer>

#include <memory>

#include "NodeClient.h"

namespace {

// How often a write refused as stale is edited again before giving up.
constexpr int kStaleRetries = 3;

}  // namespace

EnvironmentSettings::EnvironmentSettings(NodeClient* client, QObject* parent) : QObject(parent), m_client(client) {}

EnvironmentSettings::~EnvironmentSettings() {
  for (const Target& target : std::as_const(m_followed)) {
    if (target.subscription >= 0) m_client->unsubscribe(target.subscription);
  }
}

void EnvironmentSettings::setTargets(const QStringList& environmentIds) {
  QStringList targets = environmentIds;
  targets.removeAll(QString());
  targets.removeDuplicates();
  if (targets == m_targets) return;
  m_targets = targets;
  for (auto it = m_followed.begin(); it != m_followed.end();) {
    if (m_targets.contains(it.key())) {
      ++it;
      continue;
    }
    if (it->subscription >= 0) m_client->unsubscribe(it->subscription);
    it = m_followed.erase(it);
  }
  for (const QString& environmentId : std::as_const(m_targets)) {
    if (m_followed.contains(environmentId)) continue;
    m_followed.insert(environmentId, Target{});
    const int id = m_client->subscribe(this, 
        {{QStringLiteral("type"), QStringLiteral("config")}, {QStringLiteral("environment"), environmentId}},
        [this, environmentId](const QJsonObject& message) {
          auto found = m_followed.find(environmentId);
          if (found == m_followed.end()) return;
          const QString type = message.value(QLatin1String("t")).toString();
          std::optional<QJsonObject> settings;
          if (type == QLatin1String("config")) {
            const QJsonValue value = message.value(QLatin1String("config")).toObject().value(QLatin1String("settings"));
            if (value.isObject()) settings = value.toObject();
          } else if (type == QLatin1String("config.settings")) {
            settings = message.value(QLatin1String("settings")).toObject();
          }
          const bool settingsChanged = settings && found->settings != settings;
          if (settingsChanged) found->settings = settings;
          emit frame(environmentId, message);
          if (settingsChanged) emit changed();
        });
    m_followed[environmentId].subscription = id;
  }
  emit changed();
}

bool EnvironmentSettings::ready() const {
  for (const QString& environmentId : m_targets) {
    if (!m_followed.value(environmentId).settings) return false;
  }
  return true;
}

std::optional<QJsonObject> EnvironmentSettings::settings(const QString& environmentId) const {
  return m_followed.value(environmentId).settings;
}

EnvironmentSettings::Reading EnvironmentSettings::read(const Pick& pick) const {
  Reading reading;
  for (const QString& environmentId : m_targets) {
    const std::optional<QJsonObject> settings = m_followed.value(environmentId).settings;
    if (!settings) continue;
    const QJsonValue value = pick(*settings, environmentId);
    if (reading.known++ == 0) {
      reading.value = value;
    } else if (value != reading.value) {
      reading.mixed = true;
    }
  }
  return reading;
}

EnvironmentSettings::Reading EnvironmentSettings::read(const QString& path) const {
  return read([path](const QJsonObject& settings, const QString&) { return at(settings, path); });
}

QJsonValue EnvironmentSettings::at(const QJsonObject& settings, const QString& path) {
  QJsonValue value = settings;
  for (const QString& part : path.split(QLatin1Char('.'))) {
    if (!value.isObject() || !value.toObject().contains(part)) return QJsonValue(QJsonValue::Undefined);
    value = value.toObject().value(part);
  }
  return value;
}

QJsonObject EnvironmentSettings::with(QJsonObject settings, const QString& path, const QJsonValue& value) {
  const qsizetype dot = path.indexOf(QLatin1Char('.'));
  if (dot < 0) {
    if (value.isUndefined() || value.isNull()) settings.remove(path);
    else settings.insert(path, value);
    return settings;
  }
  const QString head = path.left(dot);
  const QJsonObject inner = with(settings.value(head).toObject(), path.mid(dot + 1), value);
  settings.insert(head, inner);
  return settings;
}

void EnvironmentSettings::change(const Edit& edit, const Done& done) {
  struct Outcome {
    int pending = 0;
    int saved = 0;
    QHash<QString, QString> failed;
    Done done;
  };
  auto outcome = std::make_shared<Outcome>();
  outcome->done = done;
  QStringList reachable;
  for (const QString& environmentId : std::as_const(m_targets)) {
    if (m_followed.value(environmentId).settings) reachable.append(environmentId);
    else outcome->failed.insert(environmentId, tr("Not connected."));
  }
  outcome->pending = int(reachable.size());
  if (reachable.isEmpty()) {
    if (done) done(outcome->failed, 0);
    return;
  }
  for (const QString& environmentId : std::as_const(reachable)) {
    attempt(environmentId, edit, kStaleRetries, [outcome, environmentId](const std::optional<QString>& error) {
      if (error) outcome->failed.insert(environmentId, *error);
      else ++outcome->saved;
      if (--outcome->pending == 0 && outcome->done) outcome->done(outcome->failed, outcome->saved);
    });
  }
}

void EnvironmentSettings::attempt(const QString& environmentId, const Edit& edit, int retries,
                                  std::function<void(std::optional<QString>)> done) {
  const QPointer<EnvironmentSettings> self(this);
  m_client->call(this, environmentId, QStringLiteral("hal-c2.readSettings"), QJsonObject{},
                 [self, environmentId, edit, retries, done](const QJsonValue& result, const std::optional<QString>& error) {
                   if (!self) return;
                   if (error) {
                     done(error);
                     return;
                   }
                   const QJsonObject read = result.toObject();
                   const QJsonObject settings = read.value(QLatin1String("settings")).toObject();
                   const QJsonObject next = edit(settings, environmentId);
                   if (next == settings) {
                     done(std::nullopt);
                     return;
                   }
                   self->m_client->call(self, 
                       environmentId, QStringLiteral("hal-c2.writeSettings"),
                       QJsonObject{{QStringLiteral("settings"), next}, {QStringLiteral("version"), read.value(QLatin1String("version"))}},
                       [self, environmentId, edit, retries, done](const QJsonValue& answer, const std::optional<QString>& error) {
                         if (!self) return;
                         if (!error) {
                           done(std::nullopt);
                         } else if (answer.toObject().value(QLatin1String("_tag")) == QLatin1String("StaleSettings") && retries > 0) {
                           self->attempt(environmentId, edit, retries - 1, done);
                         } else {
                           done(error);
                         }
                       });
                 });
}
