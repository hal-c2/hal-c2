#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>

#include "SidebarModel.h"

class NodeClient;

// The node's `shell` shape folded into rows: every node of the cluster, its
// environment descriptor, its live projects and threads, plus the environments
// the node reaches through links (HalC2.Links). The node sends linked
// environments' rows only to a `{"type":"shell","links":true}` subscription
// (shell.linkRows, shell.linkEnvironment, shell.linkNode), and the shell does
// not ask yet; when it does they fold in here as more projects and threads
// keyed by their environment, and the sidebar groups them like any other.
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(NodeClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  QList<sidebar::Project> projects() const;
  std::optional<sidebar::Project> project(const QString& key) const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
  // Whether a node of the cluster serves this environment.
  bool servesEnvironment(const QString& environmentId) const;
  // Whether the node reaches this environment: served by the cluster or linked.
  bool reaches(const QString& environmentId) const;
  // The environment `node` serves, empty until its descriptor arrives.
  QString environmentOf(const QString& node) const { return m_nodes.value(node).environmentId; }
  // The node of the cluster whose row this thread ("environmentId:threadId")
  // is, empty while none lists it.
  QString nodeOf(const QString& threadKey) const;
  bool online(const QString& node) const { return m_nodes.value(node).online; }
  bool synchronized() const { return m_synchronized; }
  // The node's links as `shell.links` carries them: {environment, origin,
  // online, problem?}, where problem is "unreachable" or "refused".
  const QJsonArray& links() const { return m_links; }

signals:
  void changed();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& node, const QJsonObject& environment);
  void setLinks(const QJsonArray& links);

  struct Node {
    QString environmentId;
    QJsonObject capabilities;
    bool online = false;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };

  QHash<QString, Node> m_nodes;
  // Environments outside the cluster the node is linked to. Their threads stay
  // with the page; the node only forwards their RPCs and shapes.
  QSet<QString> m_linked;
  QJsonArray m_links;
  bool m_synchronized = false;
};
