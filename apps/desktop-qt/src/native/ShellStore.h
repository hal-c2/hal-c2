#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QUrl>

#include "LocalCache.h"
#include "SidebarModel.h"

class McClient;

// The MC's `shell` shape folded into rows: every MC of the cluster, its
// environment descriptor, and its live projects and threads. Each change
// (shell.rows, shell.environment, shell.mc) is applied as it comes; a member
// that goes offline keeps its rows, and one removed from the cluster takes
// them with it. A thread that moved to
// another machine leaves a forwarding record (`movedTo`) on the one it left:
// the thread is listed where it lives, and located() follows the record.
//
// The rows are kept in the LocalCache with the version the MC gave each MC's
// (`epoch`, `rev`), so the next subscription, after a reconnect or a restart,
// says what it holds (`have`) and is sent only the rows changed since. Rows
// read from the cache show at once but are not the MC's word yet: every MC
// reads as offline and synchronized() stays false until its `shell` frame.
class ShellStore : public QObject {
  Q_OBJECT

public:
  // How long row changes wait for more before they go to the cache.
  static constexpr int flushDelayMs = 500;

  explicit ShellStore(McClient* client, QObject* parent = nullptr);
  ~ShellStore() override;

  // Where the rows are kept between runs; without one nothing is.
  void setCache(LocalCache* cache) { m_cache = cache; }
  // Before the client knows where its MC is (the desktop's host is still
  // starting it): holds the rows kept for the MC it was last opened at.
  void showKept();
  // The client is being opened at `origin`: the rows last kept for it are
  // held until its MC answers (previewing()). Another origin's rows go.
  void open(const QUrl& origin);
  // Whether the rows held came from the cache and no MC has confirmed them.
  bool previewing() const { return m_previewing; }
  // What a `shell` subscription carries as `have`: each MC's version as held.
  QJsonObject have() const;
  // Hands the cache the row changes it has not been given.
  void flush();

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
  // Whether the MC has said what the cluster holds: only then is a row that
  // is missing a row that is gone.
  bool synchronized() const { return m_synchronized; }
  // How many `shell` frames have landed: one per (re)subscription the MC answered.
  quint64 snapshots() const { return m_snapshots; }
  // Why the MC turned the shell subscription down (its `error` frame); empty
  // once a snapshot lands. The rows it had stay as they were.
  QString problem() const { return m_problem; }
  // The shell left its MC (NativeShell::close): every machine and row goes,
  // here and in the cache. It reads as synchronized, an empty cluster, so what
  // was kept for a machine that is no longer listed is let go as when one is
  // removed.
  // False when what the cache kept could not be deleted (LocalCache::clear).
  bool clear();

signals:
  void changed();
  // The client was opened at another MC than the one whose rows it held:
  // nothing kept of the first is this one's to show.
  void originChanged();

private:
  void onFrame(const QJsonObject& frame);
  void setEnvironment(const QString& mc, const QJsonObject& environment);
  void putRows(const QString& mc, const QJsonArray& rows);
  void putRow(const QString& mc, const QString& id, const QString& kind, const QJsonObject& fields);
  // The MC's rows as of `epoch` and `rev` (a frame's); none when it gave no version.
  void setVersion(const QString& mc, const QJsonValue& epoch, const QJsonValue& rev);
  // Drops the MC's rows, which the frame being applied replaces; the keys of
  // its threads go to `threads`.
  void resetRows(const QString& mc, QSet<QString>& threads);
  void removeMc(const QString& mc);
  // Forgets the cached copies of `threads` (keys) that are no longer listed.
  void forgetThreads(const QSet<QString>& threads);
  // Whether `row` is the thread itself: not the forwarding record of a move,
  // nor the copy its old machine still holds once the new one has it.
  bool lives(const QJsonObject& row) const;

  struct Mc {
    QString environmentId;
    QJsonObject capabilities;
    QJsonObject environment;
    bool online = false;
    // The version of its rows; no epoch when the MC gave none.
    QString epoch;
    qint64 rev = 0;
    QHash<QString, QJsonObject> threads;
    QHash<QString, QJsonObject> projects;
  };
  // What the cache has not been told of one MC.
  struct Unsaved {
    bool reset = false;
    QHash<QString, cache::ShellRow> put;
    QSet<QString> gone;
  };
  Unsaved& unsaved(const QString& mc);
  // Takes the rows the cache kept for `origin` in place of the ones held.
  void hold(const cache::Shell& kept, const QString& origin);

  QHash<QString, Mc> m_mcs;
  LocalCache* m_cache = nullptr;
  QString m_origin;
  QHash<QString, Unsaved> m_unsaved;
  QTimer m_flushTimer;
  bool m_previewing = false;
  bool m_synchronized = false;
  quint64 m_snapshots = 0;
  QString m_problem;
};
