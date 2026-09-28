#pragma once

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>

#include "SidebarModel.h"

class NodeClient;

// The node's `shell` shape folded into rows: every node of the cluster, its
// environment descriptor, its live threads and its projects. The sidebar's
// project groups stay with the page, which groups them by its own settings;
// project rows are kept for what a thread needs from its project (its root
// and scripts).
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(NodeClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
  // Whether a node of the cluster serves this environment.
  bool servesEnvironment(const QString& environmentId) const;
  // The name of the node serving this environment, for shapes addressed by node.
  QString nodeOf(const QString& environmentId) const;
  // Raw OrchestrationV2ThreadShell / OrchestrationProjectShell rows; empty when unknown.
  QJsonObject threadRow(const QString& key) const;
  QJsonObject projectRow(const QString& environmentId, const QString& projectId) const;
  bool synchronized() const { return m_synchronized; }

signals:
  void changed();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& node, const QJsonObject& environment);

  struct Node {
    QString environmentId;
    QJsonObject capabilities;
    bool online = false;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };

  QHash<QString, Node> m_nodes;
  bool m_synchronized = false;
};
