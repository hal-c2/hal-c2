#include "EnvironmentCatalog.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#include "SecretStore.h"

namespace {

constexpr int kVersion = 1;

// The records the file holds, or nothing when it is not a record file of this
// version: not JSON, not an object, another version, or no list.
std::optional<QList<SavedEnvironment>> parse(const QByteArray& bytes) {
  QJsonParseError error;
  const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
  if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
  const QJsonObject root = document.object();
  if (root.value(QLatin1String("version")).toInt() != kVersion || !root.value(QLatin1String("environments")).isArray()) return std::nullopt;
  QList<SavedEnvironment> environments;
  for (const QJsonValue& value : root.value(QLatin1String("environments")).toArray()) {
    const QJsonObject record = value.toObject();
    const QString id = record.value(QLatin1String("id")).toString();
    // Without an id nothing can name it, not even to say it is broken.
    if (id.isEmpty()) continue;
    SavedEnvironment environment{id, record.value(QLatin1String("label")).toString(), QUrl(record.value(QLatin1String("origin")).toString()),
                                 QDateTime::fromString(record.value(QLatin1String("expiresAt")).toString(), Qt::ISODateWithMs)};
    environments.append(environment);
  }
  return environments;
}

}  // namespace

EnvironmentCatalog::EnvironmentCatalog(const QString& path, SecretStore* secrets) : m_path(path), m_secrets(secrets) {}

void EnvironmentCatalog::load() {
  m_environments.clear();
  QFile file(m_path);
  if (!file.exists()) return;
  if (file.open(QIODevice::ReadOnly)) {
    if (auto parsed = parse(file.readAll())) {
      m_environments = *parsed;
      return;
    }
    file.close();
  }
  // Kept apart as it was, and an empty catalog in its place.
  // Never over one set aside before, even within the same millisecond.
  const QString stamped = m_path + QStringLiteral(".damaged-") +
                          QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd'T'HHmmsszzz'Z'"));
  QString aside = stamped;
  for (int n = 2; QFile::exists(aside); ++n) aside = stamped + QLatin1Char('-') + QString::number(n);
  if (QFile::rename(m_path, aside)) {
    m_damaged = aside;
  } else {
    qWarning("[catalog] the damaged %s could not be moved aside", qPrintable(m_path));
  }
  write();
}

std::optional<SavedEnvironment> EnvironmentCatalog::find(const QString& id) const {
  for (const SavedEnvironment& environment : m_environments) {
    if (environment.id == id) return environment;
  }
  return std::nullopt;
}

std::optional<QString> EnvironmentCatalog::save(const SavedEnvironment& environment, const QString& credential) {
  QString why;
  // What the keyring had: one not saved leaves it as it was. Nothing is also
  // what a keyring that cannot be read gives.
  const std::optional<QString> previous = m_secrets->read(environment.id);
  if (!m_secrets->write(environment.id, credential, &why)) {
    return QStringLiteral("%1 could not be saved: %2").arg(environment.label.isEmpty() ? environment.id : environment.label, why);
  }
  const QList<SavedEnvironment> before = m_environments;
  m_environments.removeIf([&](const SavedEnvironment& kept) { return kept.id == environment.id; });
  m_environments.append(environment);
  if (!write()) {
    m_environments = before;
    if (previous) {
      m_secrets->write(environment.id, *previous, &why);
    } else if (!find(environment.id)) {
      // A credential no record names is not left behind; one a record names
      // stays, since what it replaced could not be read.
      m_secrets->remove(environment.id);
    }
    return QStringLiteral("%1 could not be saved: the record of saved environments could not be written.")
        .arg(environment.label.isEmpty() ? environment.id : environment.label);
  }
  return std::nullopt;
}

void EnvironmentCatalog::forget(const QString& id) {
  m_secrets->remove(id);
  if (m_environments.removeIf([&](const SavedEnvironment& kept) { return kept.id == id; }) > 0) write();
}

void EnvironmentCatalog::setExpiry(const QString& id, const QDateTime& expiresAt) {
  for (SavedEnvironment& environment : m_environments) {
    if (environment.id != id || environment.expiresAt == expiresAt) continue;
    environment.expiresAt = expiresAt;
    write();
  }
}

EnvironmentCatalog::Connection EnvironmentCatalog::connect(const QString& id) const {
  const std::optional<SavedEnvironment> environment = find(id);
  if (!environment || !environment->complete()) return {environment.value_or(SavedEnvironment{id, {}, {}, {}}), {}, profileMissing(id)};
  const std::optional<QString> credential = m_secrets->read(id);
  if (!credential || credential->isEmpty()) return {*environment, {}, credentialMissing(id)};
  return {*environment, *credential, {}};
}

bool EnvironmentCatalog::write() {
  QJsonArray records;
  for (const SavedEnvironment& environment : std::as_const(m_environments)) {
    QJsonObject record{{QStringLiteral("id"), environment.id}, {QStringLiteral("label"), environment.label}};
    if (!environment.origin.isEmpty()) record.insert(QStringLiteral("origin"), environment.origin.toString());
    if (environment.expiresAt.isValid()) record.insert(QStringLiteral("expiresAt"), environment.expiresAt.toUTC().toString(Qt::ISODateWithMs));
    records.append(record);
  }
  QDir().mkpath(QFileInfo(m_path).absolutePath());
  QSaveFile file(m_path);
  if (!file.open(QIODevice::WriteOnly)) return false;
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("version"), kVersion}, {QStringLiteral("environments"), records}}).toJson());
  return file.commit();
}
