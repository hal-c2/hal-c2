#include "ShellStore.h"

#include <QJsonArray>

#include "NodeClient.h"

namespace {

// The node's threads or projects table, for a row of that kind.
QHash<QString, QJsonObject>* tableFor(const QString& kind, QHash<QString, QJsonObject>& threads,
                                      QHash<QString, QJsonObject>& projects) {
  if (kind == QLatin1String("thread")) return &threads;
  if (kind == QLatin1String("project")) return &projects;
  return nullptr;
}

bool removed(const QJsonObject& row) {
  const QJsonValue deletedAt = row.value(QLatin1String("deletedAt"));
  return row.isEmpty() || (!deletedAt.isUndefined() && !deletedAt.isNull());
}

}  // namespace

ShellStore::ShellStore(NodeClient* client, QObject* parent) : QObject(parent) {
  client->subscribe({{QStringLiteral("type"), QStringLiteral("shell")}},
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

bool ShellStore::servesEnvironment(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) return true;
  }
  return false;
}

QString ShellStore::nodeOf(const QString& environmentId) const {
  for (auto it = m_nodes.cbegin(); it != m_nodes.cend(); ++it) {
    if (it->environmentId == environmentId) return it.key();
  }
  return {};
}

QJsonObject ShellStore::threadRow(const QString& key) const {
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return {};
  const QString environmentId = key.left(colon);
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) {
      const QJsonObject row = node.threads.value(key.mid(colon + 1));
      if (!row.isEmpty()) return row;
    }
  }
  return {};
}

QJsonObject ShellStore::projectRow(const QString& environmentId, const QString& projectId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId == environmentId) {
      const QJsonObject row = node.projects.value(projectId);
      if (!row.isEmpty()) return row;
    }
  }
  return {};
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

sidebar::Capabilities ShellStore::capabilities(const QString& environmentId) const {
  for (const Node& node : m_nodes) {
    if (node.environmentId != environmentId) continue;
    return {node.capabilities.value(QLatin1String("threadSettlement")).toBool(),
            node.capabilities.value(QLatin1String("threadSnooze")).toBool(),
            node.capabilities.value(QLatin1String("threadVisitedTracking")).toBool()};
  }
  return {};
}

void ShellStore::setEnvironment(const QString& node, const QJsonObject& environment) {
  Node& entry = m_nodes[node];
  entry.environmentId = environment.value(QLatin1String("environmentId")).toString();
  entry.capabilities = environment.value(QLatin1String("capabilities")).toObject();
}

void ShellStore::onFrame(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("shell")) {
    // The whole cluster, sent on every (re)subscription.
    m_nodes.clear();
    for (const QJsonValue& value : frame.value(QLatin1String("nodes")).toArray()) {
      const QJsonObject node = value.toObject();
      const QString name = node.value(QLatin1String("node")).toString();
      setEnvironment(name, node.value(QLatin1String("environment")).toObject());
      m_nodes[name].online = node.value(QLatin1String("online")).toBool();
    }
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      const QJsonObject fields = row.at(3).toObject();
      Node& node = m_nodes[row.at(0).toString()];
      auto* table = tableFor(row.at(2).toString(), node.threads, node.projects);
      if (!table || removed(fields)) continue;
      table->insert(row.at(1).toString(), fields);
    }
    m_synchronized = true;
  } else if (type == QLatin1String("shell.environment")) {
    setEnvironment(frame.value(QLatin1String("node")).toString(),
                   frame.value(QLatin1String("environment")).toObject());
  } else if (type == QLatin1String("shell.node")) {
    m_nodes[frame.value(QLatin1String("node")).toString()].online =
        frame.value(QLatin1String("online")).toBool();
  } else if (type == QLatin1String("shell.rows")) {
    Node& node = m_nodes[frame.value(QLatin1String("node")).toString()];
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      auto* table = tableFor(row.at(1).toString(), node.threads, node.projects);
      if (!table) continue;
      const QJsonObject fields = row.at(2).toObject();
      if (removed(fields)) {
        table->remove(row.at(0).toString());
      } else {
        table->insert(row.at(0).toString(), fields);
      }
    }
  } else {
    return;
  }
  emit changed();
}
