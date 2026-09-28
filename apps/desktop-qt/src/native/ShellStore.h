#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>

#include "SidebarModel.h"

class NodeClient;

// The node's `shell` shape folded into rows: every node of the cluster, its
// environment descriptor, its live projects and threads, plus the environments
// the node reaches through links (HalC2.Links). Grouping projects stays with
// the page, which groups them by its own settings.
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(NodeClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  // The raw rows, empty when the cluster has none by that key.
  QJsonObject threadRow(const QString& key) const;
  QJsonObject projectRow(const QString& environmentId, const QString& projectId) const;
  QList<QJsonObject> projectRows(const QString& environmentId) const;
  // The environments the cluster serves, and each one's descriptor.
  QStringList environments() const;
  QJsonObject environment(const QString& environmentId) const;
  // The node serving `environmentId`, empty when none does.
  QString nodeServing(const QString& environmentId) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
  // Whether a node of the cluster serves this environment.
  bool servesEnvironment(const QString& environmentId) const;
  // Whether the node reaches this environment: served by the cluster or linked.
  bool reaches(const QString& environmentId) const;
  // The environment `node` serves, empty until its descriptor arrives.
  QString environmentOf(const QString& node) const { return m_nodes.value(node).environmentId; }
  bool synchronized() const { return m_synchronized; }

signals:
  void changed();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& node, const QJsonObject& environment);
  void setLinks(const QJsonArray& links);

  struct Node {
    QString environmentId;
    QJsonObject capabilities;
    QJsonObject environment;
    bool online = false;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };

  QHash<QString, Node> m_nodes;
  // Environments outside the cluster the node is linked to. Their threads stay
  // with the page; the node only forwards their RPCs and shapes.
  QSet<QString> m_linked;
  bool m_synchronized = false;
};
