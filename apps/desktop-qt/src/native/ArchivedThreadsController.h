#pragma once

#include <QHash>
#include <QJsonArray>
#include <QObject>
#include <QSet>
#include <QStringList>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The Archive settings section ("/settings/archived"), which the shell owns:
// every archived thread the connected environments hold, grouped by project,
// with a way back (unarchive) and a way out (delete) for each (the web's
// ArchivedThreadsPanel).
//
// The list is fetched, not streamed (features/parity/rpc.feature): opening
// the section, refreshing, an action landing, or the online environments
// changing asks each reachable online environment for its
// `orchestration.getArchivedShellSnapshot`.
//
// Publishes `archivedThreads`: {open, status: loading | error | empty |
// ready, title, description (why nothing is listed), groups [{key, title,
// threads [{key, environmentId, threadId, title, description, busy}]}]}.
//
// Actions: `archivedThreads.refresh`, `.unarchive {environmentId, threadId}`,
// `.delete {environmentId, threadId}` (asks first when the user wants
// deletes confirmed).
class ArchivedThreadsController : public QObject, public NativeController {
  Q_OBJECT

public:
  ArchivedThreadsController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  void setOpen(bool open);
  void load();
  QStringList online() const;
  void act(const QString& environmentId, const QString& threadId, const QString& type, const QString& failure);
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  // The environments last asked, and which have not answered.
  QStringList m_asked;
  QSet<QString> m_pending;
  // Bumped per load, so an answer to an older one is dropped.
  int m_generation = 0;
  QString m_error;
  // Each environment's answer: its projects and archived threads.
  QHash<QString, QJsonArray> m_projects;
  QHash<QString, QJsonArray> m_threads;
  // Threads with an action in flight, by key.
  QSet<QString> m_busy;
};
