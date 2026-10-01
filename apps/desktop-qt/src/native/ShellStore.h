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

class McClient;

// The MC's `shell` shape folded into rows: every MC of the cluster, its
// environment descriptor, its live projects and threads, plus the MCs and
// rows of the environments the MC is linked to (HalC2.Links), which it sends
// to a `{"type":"shell","links":true}` subscription under each link. Linked
// rows are more projects and threads keyed by their environment, so the
// sidebar groups them like any other; each change (shell.linkRows,
// shell.linkEnvironment, shell.linkMc) is applied as it comes, and a link
// that leaves `links` takes its MCs and rows with it. A dropped link keeps
// its rows with its MCs offline, as a cluster member that leaves does.
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(McClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  QList<sidebar::Project> projects() const;
  std::optional<sidebar::Project> project(const QString& key) const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  // The raw rows, empty when the cluster has none by that key.
  QJsonObject threadRow(const QString& key) const;
  QJsonObject projectRow(const QString& environmentId, const QString& projectId) const;
  QList<QJsonObject> projectRows(const QString& environmentId) const;
  // The environments the cluster serves or the MC is linked to, and each
  // one's descriptor.
  QStringList environments() const;
  QJsonObject environment(const QString& environmentId) const;
  // The cluster MC serving `environmentId`, for MC-addressed shapes; empty
  // when none does (a linked environment's MCs are not the cluster's).
  QString mcServing(const QString& environmentId) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
  // Whether the environment's descriptor turns `capability` on (pullRequests,
  // threadPullRequests, threadPullRequestLinking, ...).
  bool supports(const QString& environmentId, const QString& capability) const;
  // Whether an MC of the cluster serves this environment.
  bool servesEnvironment(const QString& environmentId) const;
  // Whether the MC reaches this environment: served by the cluster or linked.
  bool reaches(const QString& environmentId) const;
  // The environment the cluster's `mc` serves, empty until its descriptor arrives.
  QString environmentOf(const QString& mc) const { return m_mcs.value(mc).environmentId; }
  // Whether the MC (cluster member or linked) whose row lists this thread
  // ("environmentId:threadId") is online; false while none lists it.
  bool threadOnline(const QString& threadKey) const;
  // Whether an MC serving `environmentId` is online.
  bool environmentOnline(const QString& environmentId) const;
  bool synchronized() const { return m_synchronized; }
  // Whether this MC's clients may change `environmentId`: false only when it
  // is reached through a link whose pairing did not grant orchestration:operate
  // (the MC checks its own clients; the linked environment checks the link).
  bool mayOperate(const QString& environmentId) const;
  // The MC's links as `shell.links` carries them: {environment, origin,
  // online, scopes?, problem?}, where problem is "unreachable" or "refused".
  const QJsonArray& links() const { return m_links; }

signals:
  void changed();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& mc, const QJsonObject& environment);
  void setLinks(const QJsonArray& links);
  void putRows(const QString& mc, const QJsonArray& rows);
  void putRow(const QString& mc, const QString& id, const QString& kind, const QJsonObject& fields);

  // Cluster MCs are keyed by name; a linked environment's by linkedKey(),
  // since its MC names are its own and may be the cluster's too.
  static QString linkedKey(const QString& link, const QString& mc) { return link + QLatin1Char('\n') + mc; }

  struct Mc {
    QString link;  // the linked environment it is reached through; empty in the cluster
    QString environmentId;
    QJsonObject capabilities;
    QJsonObject environment;
    bool online = false;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };

  QHash<QString, Mc> m_mcs;
  // Environments outside the cluster the MC is linked to; the MC forwards
  // their RPCs and environment-addressed shapes.
  QSet<QString> m_linked;
  QJsonArray m_links;
  bool m_synchronized = false;
};
