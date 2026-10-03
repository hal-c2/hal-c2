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

// A forwarding record: the thread moved to another machine, which lists it now.
bool forwarded(const QJsonObject& row) {
  return row.value(QLatin1String("movedTo")).isObject();
}

bool removed(const QJsonObject& row) {
  const QJsonValue deletedAt = row.value(QLatin1String("deletedAt"));
  return row.isEmpty() || (!deletedAt.isUndefined() && !deletedAt.isNull());
}

}  // namespace

ShellStore::ShellStore(McClient* client, QObject* parent) : QObject(parent) {
  client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("shell")}, {QStringLiteral("links"), true}},
                    [this](const QJsonObject& frame) { onFrame(frame); });
}

QList<sidebar::Thread> ShellStore::threads() const {
  QList<sidebar::Thread> result;
  for (const Mc& mc : m_mcs) {
    // An MC whose environment is not known yet has no key for its threads.
    if (mc.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : mc.threads) {
      if (!forwarded(row)) result.append(sidebar::threadFromRow(mc.environmentId, row));
    }
  }
  return result;
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
    if (mc.link.isEmpty() && mc.environmentId == environmentId) return true;
  }
  return false;
}

bool ShellStore::reaches(const QString& environmentId) const {
  return m_linked.contains(environmentId) || servesEnvironment(environmentId);
}

bool ShellStore::mayOperate(const QString& environmentId) const {
  if (servesEnvironment(environmentId)) return true;
  // The link to it, or to the cluster it is a member of.
  QString via = m_linked.contains(environmentId) ? environmentId : QString();
  for (const Mc& mc : m_mcs) {
    if (via.isEmpty() && mc.environmentId == environmentId) via = mc.link;
  }
  for (const QJsonValue& value : m_links) {
    const QJsonObject link = value.toObject();
    if (link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString() != via) continue;
    // A link paired before the MC kept scopes lists none; the other side still checks.
    const QJsonValue scopes = link.value(QLatin1String("scopes"));
    return !scopes.isArray() || scopes.toArray().contains(QStringLiteral("orchestration:operate"));
  }
  return true;
}

// The whole list of links: a link that left takes its MCs and rows with it.
// A snapshot's links carry their MCs and rows; `shell.links` does not, and
// leaves the rows of the links it keeps as they are.
void ShellStore::setLinks(const QJsonArray& links) {
  m_links = links;
  m_linked.clear();
  for (const QJsonValue& value : links) {
    const QJsonObject link = value.toObject();
    const QString id = link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString();
    m_linked.insert(id);
    for (const QJsonValue& entry : link.value(QLatin1String("mcs")).toArray()) {
      const QJsonObject mc = entry.toObject();
      const QString key = linkedKey(id, mc.value(QLatin1String("mc")).toString());
      setEnvironment(key, mc.value(QLatin1String("environment")).toObject());
      m_mcs[key].link = id;
      m_mcs[key].online = mc.value(QLatin1String("online")).toBool();
    }
    for (const QJsonValue& entry : link.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = entry.toArray();
      const QString key = linkedKey(id, row.at(0).toString());
      m_mcs[key].link = id;
      putRow(key, row.at(1).toString(), row.at(2).toString(), row.at(3).toObject());
    }
  }
  m_mcs.removeIf(
      [this](QHash<QString, Mc>::iterator mc) { return !mc->link.isEmpty() && !m_linked.contains(mc->link); });
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
    if (row != mc.threads.constEnd() && !forwarded(*row)) return sidebar::threadFromRow(environmentId, *row);
  }
  return std::nullopt;
}

std::optional<QString> ShellStore::movedTo(const QString& key) const {
  const QJsonObject moved = threadRow(key).value(QLatin1String("movedTo")).toObject();
  const QString environmentId = moved.value(QLatin1String("environmentId")).toString();
  if (environmentId.isEmpty()) return std::nullopt;
  return environmentId + key.mid(key.indexOf(QLatin1Char(':')));
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
    if (it->link.isEmpty() && it->environmentId == environmentId) return it.key();
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
  // A linked environment's change names its MC as that environment does.
  const auto linked = [&frame] {
    return linkedKey(frame.value(QLatin1String("link")).toString(), frame.value(QLatin1String("mc")).toString());
  };
  if (type == QLatin1String("shell")) {
    // The whole cluster and its links, sent on every (re)subscription.
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
    setLinks(frame.value(QLatin1String("links")).toArray());
    m_synchronized = true;
  } else if (type == QLatin1String("shell.environment")) {
    setEnvironment(frame.value(QLatin1String("mc")).toString(),
                   frame.value(QLatin1String("environment")).toObject());
  } else if (type == QLatin1String("shell.mc")) {
    m_mcs[frame.value(QLatin1String("mc")).toString()].online =
        frame.value(QLatin1String("online")).toBool();
  } else if (type == QLatin1String("shell.links")) {
    setLinks(frame.value(QLatin1String("links")).toArray());
  } else if (type == QLatin1String("shell.rows")) {
    putRows(frame.value(QLatin1String("mc")).toString(), frame.value(QLatin1String("rows")).toArray());
  } else if (type == QLatin1String("shell.linkEnvironment")) {
    // An MC that appears is offline until shell.linkMc says otherwise.
    const QString key = linked();
    setEnvironment(key, frame.value(QLatin1String("environment")).toObject());
    m_mcs[key].link = frame.value(QLatin1String("link")).toString();
  } else if (type == QLatin1String("shell.linkMc")) {
    Mc& mc = m_mcs[linked()];
    mc.link = frame.value(QLatin1String("link")).toString();
    mc.online = frame.value(QLatin1String("online")).toBool();
  } else if (type == QLatin1String("shell.linkRows")) {
    const QString key = linked();
    m_mcs[key].link = frame.value(QLatin1String("link")).toString();
    putRows(key, frame.value(QLatin1String("rows")).toArray());
  } else {
    return;
  }
  emit changed();
}
