#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QVariantMap>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The pull requests page, which the shell owns (the route `pullRequests`):
// every reachable environment is asked for its pull requests
// (`pullRequests.list`, apps/server-ex HalC2.PullRequests) under the chosen
// filters, and the answers are merged, newest first, into the groups
// Authored, Review requested, Others. While the page shows, each
// environment's `pullRequestRefreshes` shape re-reads the list when a pull
// request changes from HAL-C2.
//
// Publishes `pullRequestList`: {open, loading, filters {state, involvement,
// draft, review, checks, query, environmentId, projectKey}, filtered, groups
// [{id, label, rows}], count, environments [{id, label, status: loading |
// ready | failed | offline, message}], problems [text], empty {title, body} |
// null, error {title, message} | null, projects [{key, label}], notice}.
//
// Actions: `pullRequestList.filter {name, value}` (kept on this device for next
// time), `pullRequestList.refresh` (the hosts are asked afresh:
// `pullRequests.invalidate`), `pullRequestList.open {key}` (the thread working
// on it, `pullRequests.linkedThreads`) and `pullRequestList.openOnHost {key}`.
class PullRequestListController : public QObject, public NativeController {
  Q_OBJECT

public:
  PullRequestListController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  struct Answer {
    QString status;  // loading, ready, failed, offline
    QString message;
    QJsonObject result;
  };

  void setOpen(bool open);
  void load();
  void refresh();
  void subscribe();
  void unsubscribe();
  void open(const QString& key);
  QStringList targets() const;
  QJsonObject input(const QString& environmentId) const;
  QVariantMap row(const QString& key) const;
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QVariantMap m_filters;
  QHash<QString, Answer> m_answers;
  // Each environment's live `pullRequestRefreshes`, and the revision it last said.
  QHash<QString, int> m_subscriptions;
  QHash<QString, int> m_revisions;
  QVariantMap m_notice;
  // Bumped by every read; an answer lands only if nothing was asked since.
  quint64 m_generation = 0;
};
