#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

#include <functional>

class McClient;
class ShellStore;

// The threads working on one pull request and linking it to or unlinking it
// from one (apps/web PullRequestThreadLinks.tsx): `pullRequests.linkedThreads`
// counts them, `thread.pull-request.link` / `unlink` change one. The thread
// the pull request is shown in, when there is one, is "this thread"; any
// other active thread of the environment is chosen from the picker.
//
// Hidden (`available` false) in an environment without several linked pull
// requests per thread. Shared by the desktop and the phone: it knows nothing
// of where it is drawn.
class PullRequestThreadLinks : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool available READ available NOTIFY changed)
  // How many threads link it, once the MC said; -1 until then.
  Q_PROPERTY(int count READ count NOTIFY changed)
  // "Linked from 2 threads", or "Linked threads" while none are known.
  Q_PROPERTY(QString label READ label NOTIFY changed)
  Q_PROPERTY(bool linkedHere READ linkedHere NOTIFY changed)
  // "Unlink from this thread", "Link to this thread", or "Link to thread"
  // when it is shown outside a thread (which opens the picker).
  Q_PROPERTY(QString menuLabel READ menuLabel NOTIFY changed)
  // A link or unlink is on its way.
  Q_PROPERTY(bool pending READ pending NOTIFY changed)
  Q_PROPERTY(bool pickerOpen READ pickerOpen WRITE setPickerOpen NOTIFY changed)
  // Narrows the picker by thread title and project title.
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY changed)
  // The picker's threads, newest first, archived ones left out:
  // [{id, title, project, linked}]. A linked one cannot be chosen.
  Q_PROPERTY(QVariantList candidates READ candidates NOTIFY changed)

public:
  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  // Searches the threads (the command palette) for `query`.
  using Search = std::function<void(const QString& query)>;

  PullRequestThreadLinks(McClient* client, ShellStore* store, Notify notify, Search search, QObject* parent = nullptr);

  // The pull request, in `environmentId`, shown in `threadId` (empty outside a thread).
  void setTarget(const QString& environmentId, const QString& threadId, const QString& host, const QString& repository, int number,
                 const QString& url);
  void clear();

  bool available() const;
  int count() const { return m_count; }
  QString label() const;
  bool linkedHere() const;
  QString menuLabel() const;
  bool pending() const { return m_pending; }
  bool pickerOpen() const { return m_pickerOpen; }
  void setPickerOpen(bool open);
  QString query() const { return m_query; }
  void setQuery(const QString& query);
  QVariantList candidates() const;
  // Whether the thread `threadId` of the environment links the pull request.
  bool links(const QString& threadId) const;

  // Asks the MC again how many threads link it.
  Q_INVOKABLE void refresh();
  // The threads that link it, in the command palette.
  Q_INVOKABLE void search();
  // This thread links it, or no longer does; outside a thread, the picker opens.
  Q_INVOKABLE void toggleHere();
  // Links it to `threadId`, unless that thread already does.
  Q_INVOKABLE void choose(const QString& threadId);

signals:
  void changed();

private:
  void change(const QString& threadId, bool link);

  McClient* m_client;
  ShellStore* m_store;
  Notify m_notify;
  Search m_search;
  QString m_environment;
  QString m_thread;
  QString m_host;
  QString m_repository;
  int m_number = 0;
  QString m_url;
  int m_count = -1;
  bool m_pending = false;
  bool m_pickerOpen = false;
  QString m_query;
  // Bumped by every new target; an answer lands only for the one it asked about.
  quint64 m_generation = 0;
};
