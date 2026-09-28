#include "ShellStore.h"

#include <QJsonArray>

#include "NodeClient.h"

namespace {

bool isThreadRow(const QString& kind) {
  return kind == QLatin1String("thread");
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

bool ShellStore::reaches(const QString& environmentId) const {
  return m_linked.contains(environmentId) || servesEnvironment(environmentId);
}

void ShellStore::setLinks(const QJsonArray& links) {
  m_links = links;
  m_linked.clear();
  for (const QJsonValue& link : links) {
    m_linked.insert(
        link.toObject().value(QLatin1String("environment")).toObject().value(QLatin1String("environmentId")).toString());
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

QString ShellStore::nodeOf(const QString& threadKey) const {
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  if (colon <= 0) return {};
  const QString environmentId = threadKey.left(colon);
  const QString threadId = threadKey.mid(colon + 1);
  for (auto it = m_nodes.cbegin(); it != m_nodes.cend(); ++it) {
    if (it->environmentId == environmentId && it->threads.contains(threadId)) return it.key();
  }
  return {};
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
      if (!isThreadRow(row.at(2).toString()) || removed(fields)) continue;
      m_nodes[row.at(0).toString()].threads.insert(row.at(1).toString(), fields);
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
    Node& node = m_nodes[frame.value(QLatin1String("node")).toString()];
    for (const QJsonValue& value : frame.value(QLatin1String("rows")).toArray()) {
      const QJsonArray row = value.toArray();
      if (!isThreadRow(row.at(1).toString())) continue;
      const QJsonObject fields = row.at(2).toObject();
      if (removed(fields)) {
        node.threads.remove(row.at(0).toString());
      } else {
        node.threads.insert(row.at(0).toString(), fields);
      }
    }
  } else {
    return;
  }
  emit changed();
}
