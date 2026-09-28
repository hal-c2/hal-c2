#pragma once

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>

#include "SidebarModel.h"

class NodeClient;

// The node's `shell` shape folded into thread rows: every node of the cluster,
// its environment descriptor, and its live threads. Projects stay with the
// page, which groups them by its own settings.
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(NodeClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
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
  };

  QHash<QString, Node> m_nodes;
  bool m_synchronized = false;
};
