#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>

#include "SidebarModel.h"

class McClient;

// The MC's `shell` shape folded into rows: every MC of the cluster, its
// environment descriptor, and its live projects and threads. Each change
// (shell.rows, shell.environment, shell.mc) is applied as it comes; a member
// that goes offline keeps its rows, and one removed from the cluster takes
// them with it. A thread that moved to
// another machine leaves a forwarding record (`movedTo`) on the one it left:
// the thread is listed where it lives, and located() follows the record.
class ShellStore : public QObject {
  Q_OBJECT

public:
  explicit ShellStore(McClient* client, QObject* parent = nullptr);

  QList<sidebar::Thread> threads() const;
  QList<sidebar::Project> projects() const;
  std::optional<sidebar::Project> project(const QString& key) const;
  std::optional<sidebar::Thread> thread(const QString& key) const;
  // The raw rows, empty when the cluster has none by that key. A thread's row
  // may be the forwarding record of a move.
  QJsonObject threadRow(const QString& key) const;
  // The key the thread at `key` lives under now: another machine's once it
  // moved there, `key` itself otherwise. Keys kept from before a move (a saved
  // route, a notification, a draft) resolve through this.
  QString located(const QString& key) const;
  QJsonObject projectRow(const QString& environmentId, const QString& projectId) const;
  QList<QJsonObject> projectRows(const QString& environmentId) const;
  // The environments the cluster serves, and each one's descriptor.
  QStringList environments() const;
  QJsonObject environment(const QString& environmentId) const;
  // The cluster MC serving `environmentId`, for MC-addressed shapes; empty
  // when none does.
  QString mcServing(const QString& environmentId) const;
  sidebar::Capabilities capabilities(const QString& environmentId) const;
  // Whether the environment's descriptor turns `capability` on (pullRequests,
  // threadPullRequests, threadPullRequestLinking, ...).
  bool supports(const QString& environmentId, const QString& capability) const;
  // Whether an MC of the cluster serves this environment.
  bool servesEnvironment(const QString& environmentId) const;
  // The environment the cluster's `mc` serves, empty until its descriptor arrives.
  QString environmentOf(const QString& mc) const { return m_mcs.value(mc).environmentId; }
  // Whether the MC whose row lists this thread ("environmentId:threadId") is
  // online; false while none lists it.
  bool threadOnline(const QString& threadKey) const;
  // Whether an MC serving `environmentId` is online.
  bool environmentOnline(const QString& environmentId) const;
  bool synchronized() const { return m_synchronized; }

signals:
  void changed();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& mc, const QJsonObject& environment);
  void putRows(const QString& mc, const QJsonArray& rows);
  void putRow(const QString& mc, const QString& id, const QString& kind, const QJsonObject& fields);
  // Whether `row` is the thread itself: not the forwarding record of a move,
  // nor the copy its old machine still holds once the new one has it.
  bool lives(const QJsonObject& row) const;

  struct Mc {
    QString environmentId;
    QJsonObject capabilities;
    QJsonObject environment;
    bool online = false;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };

  QHash<QString, Mc> m_mcs;
  bool m_synchronized = false;
};
