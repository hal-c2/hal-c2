#include "ShellStore.h"

#include <QJsonArray>

#include <algorithm>

#include "NodeClient.h"

namespace {

// The node's rows of `kind`, or nothing for kinds the shell does not fold.
QHash<QString, QJsonObject>* rowsOf(auto& node, const QString& kind) {
  if (kind == QLatin1String("thread")) return &node.threads;
  if (kind == QLatin1String("project")) return &node.projects;
  return nullptr;
}

bool removed(const QJsonObject& row) {
  const QJsonValue deletedAt = row.value(QLatin1String("deletedAt"));
  return row.isEmpty() || (!deletedAt.isUndefined() && !deletedAt.isNull());
}

}  // namespace

ShellStore::ShellStore(NodeClient* client, QObject* parent) : QObject(parent) {
  client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("shell")}, {QStringLiteral("links"), true}},
                    [this](const QJsonObject& frame) { onFrame(frame); });
}

QList<sidebar::Thread> ShellStore::threads() const {
  QList<sidebar::Thread> result;
  for (const Node& node : m_nodes) {
    // A node whose environment is not known yet has no key for its threads.
    if (node.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : node.threads) result.append(sidebar::threadFromRow(node.environmentId, row));
  }
  return result;
}

QList<sidebar::Project> ShellStore::projects() const {
  QList<sidebar::Project> result;
  for (const Node& node : m_nodes) {
    if (node.environmentId.isEmpty()) continue;
    for (const QJsonObject& row : node.projects) result.append(sidebar::projectFromRow(node.environmentId, row));
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
  for (const Node& node : m_nodes) {
    if (node.environmentId != environmentId) continue;
    const auto row = node.projects.constFind(key.mid(colon + 1));
    if (row != node.projects.constEnd()) return sidebar::projectFromRow(environmentId, *row);
  }
  return std::nullopt;
}

bool ShellStore::servesEnvironment(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.link.isEmpty() && node.environmentId == environmentId) return true;
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
  for (const Node& node : m_nodes) {
    if (via.isEmpty() && node.environmentId == environmentId) via = node.link;
  }
  for (const QJsonValue& value : m_links) {
    const QJsonObject link = value.toObject();
    if (link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString() != via) continue;
    // A link paired before the node kept scopes lists none; the other side still checks.
    const QJsonValue scopes = link.value(QLatin1String("scopes"));
    return !scopes.isArray() || scopes.toArray().contains(QStringLiteral("orchestration:operate"));
  }
  return true;
}

// The whole list of links: a link that left takes its nodes and rows with it.
// A snapshot's links carry their nodes and rows; `shell.links` does not, and
// leaves the rows of the links it keeps as they are.
void ShellStore::setLinks(const QJsonArray& links) {
  m_links = links;
  m_linked.clear();
  for (const QJsonValue& value : links) {
    const QJsonObject link = value.toObject();
    const QString id = link.value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString();
    m_linked.insert(id);
    for (const QJsonValue& entry : link.value(QLatin1String("nodes")).toArray()) {
      const QJsonObject node = entry.toObject();
      const QString key = linkedKey(id, node.value(QLatin1String("node")).toString());
      setEnvironment(key, node.value(QLatin1String("environment")).toObject());
      m_nodes[key].link = id;
      m_nodes[key].online = node.value(QLatin1String("online")).toBool();
    }
    for (const QJsonValue& entry : link.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = entry.toArray();
      const QString key = linkedKey(id, row.at(0).toString());
      m_nodes[key].link = id;
      putRow(key, row.at(1).toString(), row.at(2).toString(), row.at(3).toObject());
    }
  }
  m_nodes.removeIf(
      [this](QHash<QString, Node>::iterator node) { return !node->link.isEmpty() && !m_linked.contains(node->link); });
}

// Rows as `shell.rows` carries them: each [id, kind, fields].
void ShellStore::putRows(const QString& node, const QJsonArray& rows) {
  for (const QJsonValue& value : rows) {
    const QJsonArray row = value.toArray();
    putRow(node, row.at(0).toString(), row.at(1).toString(), row.at(2).toObject());
  }
}

void ShellStore::putRow(const QString& node, const QString& id, const QString& kind, const QJsonObject& fields) {
  auto* kept = rowsOf(m_nodes[node], kind);
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
  for (const Node& node : m_nodes) {
    if (node.environmentId != environmentId) continue;
    const auto row = node.threads.constFind(threadId);
    if (row != node.threads.constEnd()) return sidebar::threadFromRow(environmentId, *row);
  }
  return std::nullopt;
}

QJsonObject ShellStore::threadRow(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return {};
  const QString environmentId = key.left(colon);
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.threads.value(key.mid(colon + 1));
  }
  return {};
}

QJsonObject ShellStore::projectRow(const QString& environmentId, const QString& projectId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.projects.value(projectId);
  }
  return {};
}

QList<QJsonObject> ShellStore::projectRows(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.projects.values();
  }
  return {};
}

QStringList ShellStore::environments() const {
  QStringList result;
  for (const Node& node : m_nodes) {
    if (!node.environmentId.isEmpty()) result.append(node.environmentId);
  }
  return result;
}

QJsonObject ShellStore::environment(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.environment;
  }
  return {};
}

QString ShellStore::nodeServing(const QString& environmentId) const {
  for (auto it = m_nodes.cbegin(); it != m_nodes.cend(); ++it) {
    if (it->link.isEmpty() && it->environmentId == environmentId) return it.key();
  }
  return {};
}

bool ShellStore::threadOnline(const QString& threadKey) const {
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  if (colon <= 0) return false;
  const QString environmentId = threadKey.left(colon);
  const QString threadId = threadKey.mid(colon + 1);
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId && node.threads.contains(threadId)) return node.online;
  }
  return false;
}

bool ShellStore::environmentOnline(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.online;
  }
  return false;
}

sidebar::Capabilities ShellStore::capabilities(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId != environmentId) continue;
    return {node.capabilities.value(QLatin1String("threadSettlement")).toBool(),
            node.capabilities.value(QLatin1String("threadSnooze")).toBool(),
            node.capabilities.value(QLatin1String("threadVisitedTracking")).toBool(),
            node.capabilities.value(QLatin1String("threadPinning")).toBool(),
            node.capabilities.value(QLatin1String("threadTitleRegeneration")).toBool()};
  }
  return {};
}

bool ShellStore::supports(const QString& environmentId, const QString& capability) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return node.capabilities.value(capability).toBool();
  }
  return false;
}

void ShellStore::setEnvironment(const QString& node, const QJsonObject& environment) {
  Node& entry = m_nodes[node];
  entry.environmentId = environment.value(QLatin1String("environmentId")).toString();
  entry.capabilities = environment.value(QLatin1String("capabilities")).toObject();
  entry.environment = environment;
}

void ShellStore::onFrame(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  // A linked environment's change names its node as that environment does.
  const auto linked = [&frame] {
    return linkedKey(frame.value(QLatin1String("link")).toString(), frame.value(QLatin1String("node")).toString());
  };
  if (type == QLatin1String("shell")) {
    // The whole cluster and its links, sent on every (re)subscription.
    m_nodes.clear();
    for (const QJsonValue& value : frame.value(QLatin1String("nodes")).toArray()) {
      const QJsonObject node = value.toObject();
      const QString name = node.value(QLatin1String("node")).toString();
      setEnvironment(name, node.value(QLatin1String("environment")).toObject());
      m_nodes[name].online = node.value(QLatin1String("online")).toBool();
    }
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      putRow(row.at(0).toString(), row.at(1).toString(), row.at(2).toString(), row.at(3).toObject());
    }
    setLinks(frame.value(QLatin1String("links")).toArray());
    m_synchronized = true;
  } else if (type == QLatin1String("shell.environment")) {
    setEnvironment(frame.value(QLatin1String("node")).toString(),
                   frame.value(QLatin1String("environment")).toObject());
  } else if (type == QLatin1String("shell.node")) {
    m_nodes[frame.value(QLatin1String("node")).toString()].online =
        frame.value(QLatin1String("online")).toBool();
  } else if (type == QLatin1String("shell.links")) {
    setLinks(frame.value(QLatin1String("links")).toArray());
  } else if (type == QLatin1String("shell.rows")) {
    putRows(frame.value(QLatin1String("node")).toString(), frame.value(QLatin1String("rows")).toArray());
  } else if (type == QLatin1String("shell.linkEnvironment")) {
    // A node that appears is offline until shell.linkNode says otherwise.
    const QString key = linked();
    setEnvironment(key, frame.value(QLatin1String("environment")).toObject());
    m_nodes[key].link = frame.value(QLatin1String("link")).toString();
  } else if (type == QLatin1String("shell.linkNode")) {
    Node& node = m_nodes[linked()];
    node.link = frame.value(QLatin1String("link")).toString();
    node.online = frame.value(QLatin1String("online")).toBool();
  } else if (type == QLatin1String("shell.linkRows")) {
    const QString key = linked();
    m_nodes[key].link = frame.value(QLatin1String("link")).toString();
    putRows(key, frame.value(QLatin1String("rows")).toArray());
  } else {
    return;
  }
  emit changed();
}
