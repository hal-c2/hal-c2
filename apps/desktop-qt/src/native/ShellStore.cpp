#include "ShellStore.h"

#include <QJsonArray>

#include <algorithm>

#include "McClient.h"

namespace {

// The MC's rows of `kind`, or nothing for kinds the shell does not fold.
QHash<QString, QJsonObject>* rowsOf(auto& mc, const QString& kind) {
  if (kind == QLatin1String("thread")) return &mc.threads;
  if (kind == QLatin1String("project")) return &mc.projects;
  return nullptr;
}

bool removed(const QJsonObject& row) {
  const QJsonValue deletedAt = row.value(QLatin1String("deletedAt"));
  return row.isEmpty() || (!deletedAt.isUndefined() && !deletedAt.isNull());
}

QString threadKey(const QString& environmentId, const QString& threadId) {
  return environmentId + QLatin1Char(':') + threadId;
}

}  // namespace

ShellStore::ShellStore(McClient* client, QObject* parent) : QObject(parent) {
  client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("shell")}}, [this](const QJsonObject& frame) { onFrame(frame); });
}

QList<sidebar::Thread> ShellStore::threads() const {
  QList<sidebar::Thread> result;
  for (const Mc& mc : m_mcs) {
    // An MC whose environment is not known yet has no key for its threads.
    if (mc.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : mc.threads) {
      if (lives(row)) result.append(sidebar::threadFromRow(mc.environmentId, row));
    }
  }
  return result;
}

bool ShellStore::lives(const QJsonObject& row) const {
  if (row.value(QLatin1String("movedTo")).isObject()) return false;
  const QJsonObject moving = row.value(QLatin1String("moving")).toObject();
  if (moving.isEmpty()) return true;
  const QString destination = moving.value(QLatin1String("environmentId")).toString();
  const QString id = row.value(QLatin1String("id")).toString();
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != destination) continue;
    const auto arrived = mc.threads.constFind(id);
    return arrived == mc.threads.constEnd() || arrived->value(QLatin1String("movedTo")).isObject();
  }
  return true;
}

QString ShellStore::located(const QString& key) const {
  const QJsonObject row = threadRow(key);
  if (row.isEmpty() || lives(row)) return key;
  const QString id = key.mid(key.indexOf(QLatin1Char(':')) + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId.isEmpty()) continue;
    const auto found = mc.threads.constFind(id);
    if (found != mc.threads.constEnd() && lives(*found)) return threadKey(mc.environmentId, id);
  }
  // Its new machine's rows have not arrived yet: where the record points.
  const QString environmentId = row.value(QLatin1String("movedTo")).toObject().value(QLatin1String("environmentId")).toString();
  return environmentId.isEmpty() ? key : threadKey(environmentId, id);
}

QList<sidebar::Project> ShellStore::projects() const {
  QList<sidebar::Project> result;
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : mc.projects) result.append(sidebar::projectFromRow(mc.environmentId, row));
  }
  // Row hashes have no order; the web app lists projects by creation.
  std::stable_sort(result.begin(), result.end(), [](const sidebar::Project& left, const sidebar::Project& right) {
    if (left.createdAt != right.createdAt) return left.createdAt < right.createdAt;
    return left.key() < right.key();
  });
  return result;
}

std::optional<sidebar::Project> ShellStore::project(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return std::nullopt;
  const QString environmentId = key.left(colon);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    const auto row = mc.projects.constFind(key.mid(colon + 1));
    if (row != mc.projects.constEnd()) return sidebar::projectFromRow(environmentId, *row);
  }
  return std::nullopt;
}

bool ShellStore::servesEnvironment(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return true;
  }
  return false;
}

// Rows as `shell.rows` carries them: each [id, kind, fields].
void ShellStore::putRows(const QString& mc, const QJsonArray& rows) {
  for (const QJsonValue& value : rows) {
    const QJsonArray row = value.toArray();
    putRow(mc, row.at(0).toString(), row.at(1).toString(), row.at(2).toObject());
  }
}

void ShellStore::putRow(const QString& mc, const QString& id, const QString& kind, const QJsonObject& fields) {
  auto* kept = rowsOf(m_mcs[mc], kind);
  if (!kept) return;
  if (removed(fields)) {
    kept->remove(id);
  } else {
    kept->insert(id, fields);
  }
}

std::optional<sidebar::Thread> ShellStore::thread(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return std::nullopt;
  const QString environmentId = key.left(colon);
  const QString threadId = key.mid(colon + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    const auto row = mc.threads.constFind(threadId);
    if (row != mc.threads.constEnd() && lives(*row)) return sidebar::threadFromRow(environmentId, *row);
  }
  return std::nullopt;
}

QJsonObject ShellStore::threadRow(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return {};
  const QString environmentId = key.left(colon);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.threads.value(key.mid(colon + 1));
  }
  return {};
}

QJsonObject ShellStore::projectRow(const QString& environmentId, const QString& projectId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.projects.value(projectId);
  }
  return {};
}

QList<QJsonObject> ShellStore::projectRows(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.projects.values();
  }
  return {};
}

QStringList ShellStore::environments() const {
  QStringList result;
  for (const Mc& mc : m_mcs) {
    if (!mc.environmentId.isEmpty()) result.append(mc.environmentId);
  }
  return result;
}

QJsonObject ShellStore::environment(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.environment;
  }
  return {};
}

QString ShellStore::mcServing(const QString& environmentId) const {
  for (auto it = m_mcs.cbegin(); it != m_mcs.cend(); ++it) {
    if (it->environmentId == environmentId) return it.key();
  }
  return {};
}

bool ShellStore::threadOnline(const QString& threadKey) const {
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  if (colon <= 0) return false;
  const QString environmentId = threadKey.left(colon);
  const QString threadId = threadKey.mid(colon + 1);
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId && mc.threads.contains(threadId)) return mc.online;
  }
  return false;
}

bool ShellStore::environmentOnline(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.online;
  }
  return false;
}

sidebar::Capabilities ShellStore::capabilities(const QString& environmentId) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId != environmentId) continue;
    return {mc.capabilities.value(QLatin1String("threadSettlement")).toBool(),
            mc.capabilities.value(QLatin1String("threadSnooze")).toBool(),
            mc.capabilities.value(QLatin1String("threadVisitedTracking")).toBool(),
            mc.capabilities.value(QLatin1String("threadPinning")).toBool(),
            mc.capabilities.value(QLatin1String("threadTitleRegeneration")).toBool()};
  }
  return {};
}

bool ShellStore::supports(const QString& environmentId, const QString& capability) const {
  for (const Mc& mc : m_mcs) {
    if (mc.environmentId == environmentId) return mc.capabilities.value(capability).toBool();
  }
  return false;
}

void ShellStore::setEnvironment(const QString& mc, const QJsonObject& environment) {
  Mc& entry = m_mcs[mc];
  entry.environmentId = environment.value(QLatin1String("environmentId")).toString();
  entry.capabilities = environment.value(QLatin1String("capabilities")).toObject();
  entry.environment = environment;
}

void ShellStore::onFrame(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("shell")) {
    // The whole cluster, sent on every (re)subscription.
    m_mcs.clear();
    for (const QJsonValue& value : frame.value(QLatin1String("mcs")).toArray()) {
      const QJsonObject mc = value.toObject();
      const QString name = mc.value(QLatin1String("mc")).toString();
      setEnvironment(name, mc.value(QLatin1String("environment")).toObject());
      m_mcs[name].online = mc.value(QLatin1String("online")).toBool();
    }
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      putRow(row.at(0).toString(), row.at(1).toString(), row.at(2).toString(), row.at(3).toObject());
    }
    m_synchronized = true;
  } else if (type == QLatin1String("shell.environment")) {
    setEnvironment(frame.value(QLatin1String("mc")).toString(),
                   frame.value(QLatin1String("environment")).toObject());
  } else if (type == QLatin1String("shell.mc")) {
    const QString mc = frame.value(QLatin1String("mc")).toString();
    // A machine removed from the cluster takes its rows with it; an offline one keeps them.
    if (frame.value(QLatin1String("removed")).toBool()) {
      m_mcs.remove(mc);
    } else {
      m_mcs[mc].online = frame.value(QLatin1String("online")).toBool();
    }
  } else if (type == QLatin1String("shell.rows")) {
    putRows(frame.value(QLatin1String("mc")).toString(), frame.value(QLatin1String("rows")).toArray());
  } else {
    return;
  }
  emit changed();
}
