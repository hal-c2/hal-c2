#pragma once

#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

#include "DiffModel.h"

class McClient;

// The Pull request review tab (`pull-request:<host>/<repository>#<number>`):
// one pull request of the thread, read from its host through the thread's
// environment (apps/server-ex HalC2.PullRequests): `pullRequests.detail` (the
// description, branches, labels, reviewers and checks), `pullRequests.activity`
// (the conversation and review threads), `pullRequests.filesViewed`, and its
// code over HTTP (`POST /api/pull-requests/diff`, a slice at a time until
// `nextCursor` is null), which lands in `model` as DiffPanel draws it.
//
// Changes go to the same environment and read the pull request again once
// they land: comment(body) (`pullRequests.comment`), submitReview(verdict,
// body) (`pullRequests.submitReview`: comment, approve or request-changes),
// merge(method) (`pullRequests.runAction`; no method is the default one),
// setThreadResolved(id, resolved) (`pullRequests.setThreadResolution`), and
// setViewed(path, viewed) (`pullRequests.setFilesViewed`; a viewed file
// collapses, and the mark is taken back when the host refuses it). While the
// environment is offline what was read stays and nothing is sent.
class PullRequestReview : public QObject {
  Q_OBJECT
  Q_PROPERTY(DiffModel* model READ model CONSTANT)
  // "host/repository#number", empty when no pull request is shown.
  Q_PROPERTY(QString key READ key NOTIFY targetChanged)
  Q_PROPERTY(int number READ number NOTIFY targetChanged)
  Q_PROPERTY(bool online READ online NOTIFY stateChanged)
  // idle, loading, ready or error (`message` is the MC's reason).
  Q_PROPERTY(QString status READ status NOTIFY stateChanged)
  Q_PROPERTY(QString message READ message NOTIFY stateChanged)
  // {title, body, url, author, state, stateLabel, branches, labels [name],
  //  reviewers [login], mergeability, behindBy, checks [{name, status,
  //  description, url}], canMerge, mergeMethods [merge|squash|rebase]}, empty
  //  until read. `canMerge` is an open, ready pull request on a host that
  //  merges, for a viewer who may; `mergeMethods` are the ones the host and
  //  the repository both allow, the default first.
  Q_PROPERTY(QVariantMap detail READ detail NOTIFY detailChanged)
  // [{id, kind, author, body, createdAt, reviewState, path}], oldest first.
  Q_PROPERTY(QVariantList conversation READ conversation NOTIFY detailChanged)
  // [{id, path, line, resolved, outdated, comments [{author, body}]}].
  Q_PROPERTY(QVariantList reviewThreads READ reviewThreads NOTIFY detailChanged)
  // The host's stack the pull request is a layer of (`pullRequests.stack`),
  // empty outside one: {number, base, position, size, layers [{number, title,
  // state, current}], mergeCount (this layer and the unmerged ones below),
  // canMerge, canRebase, stale, notice}. A read that fails keeps what was
  // read before, `stale` with a `notice`; retryStack() reads it again.
  Q_PROPERTY(QVariantMap stack READ stack NOTIFY stackChanged)
  // The stack action waiting to be confirmed, or empty: {action ("merge" or
  // "rebase"), title, description, confirmLabel}.
  Q_PROPERTY(QVariantMap stackConfirmation READ stackConfirmation NOTIFY stackChanged)
  // The code: idle, loading, ready or error (`codeMessage`).
  Q_PROPERTY(QString codeStatus READ codeStatus NOTIFY codeChanged)
  Q_PROPERTY(QString codeMessage READ codeMessage NOTIFY codeChanged)
  Q_PROPERTY(QStringList viewedPaths READ viewedPaths NOTIFY viewedChanged)
  Q_PROPERTY(int viewedCount READ viewedCount NOTIFY viewedChanged)
  // A comment, review or resolution is on its way.
  Q_PROPERTY(bool busy READ busy NOTIFY stateChanged)
  // Why the last comment or review was not sent.
  Q_PROPERTY(QString problem READ problem NOTIFY stateChanged)

public:
  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  using Open = std::function<void(const QString& url)>;
  using Copy = std::function<bool(const QString& text)>;

  PullRequestReview(McClient* client, Notify notify, Open open, QObject* parent = nullptr);

  // The pull request shown: its environment, the thread's project (whose
  // checkout reads it), and the link's host, repository and number.
  void setPullRequest(const QString& environmentId, const QString& projectId, const QString& host, const QString& repository,
                      int number);
  void clear();
  void setOnline(bool online);
  // Only a shown tab reads; one shown again reads what changed since.
  void setActive(bool active);
  void setClipboardWriter(Copy copy) { m_copy = std::move(copy); }

  DiffModel* model() { return &m_model; }
  QString key() const;
  int number() const { return m_number; }
  bool online() const { return m_online; }
  QString status() const { return m_status; }
  QString message() const { return m_message; }
  QVariantMap detail() const { return m_detail; }
  QVariantList conversation() const { return m_conversation; }
  QVariantList reviewThreads() const { return m_threads; }
  QVariantMap stack() const;
  QVariantMap stackConfirmation() const { return m_stackConfirmation; }
  QString codeStatus() const { return m_codeStatus; }
  QString codeMessage() const { return m_codeMessage; }
  QStringList viewedPaths() const;
  int viewedCount() const;
  bool busy() const { return m_busy > 0; }
  QString problem() const { return m_problem; }

  // Reads the pull request and its code again.
  Q_INVOKABLE void reload();
  // False (with `problem`) when there is nothing to send or nowhere to send it.
  Q_INVOKABLE bool comment(const QString& body);
  Q_INVOKABLE bool submitReview(const QString& verdict, const QString& body);
  // Merges it with `method`, or with the first of `mergeMethods`.
  Q_INVOKABLE bool merge(const QString& method = {});
  // Stack actions ask first: requestStackMerge(method) merges this layer and
  // the unmerged ones below it, requestStackRebase() rebases every unmerged
  // layer onto the base; confirmStack() sends it (`pullRequests.runAction`
  // with the stack's number and the heads that were shown) and cancelStack()
  // drops it.
  Q_INVOKABLE bool requestStackMerge(const QString& method = {});
  Q_INVOKABLE bool requestStackRebase();
  Q_INVOKABLE void confirmStack();
  Q_INVOKABLE void cancelStack();
  Q_INVOKABLE void retryStack();
  Q_INVOKABLE void setThreadResolved(const QString& threadId, bool resolved);
  Q_INVOKABLE void setViewed(const QString& path, bool viewed);
  Q_INVOKABLE bool isViewed(const QString& path) const { return m_viewed.contains(path); }
  // "#42" to the clipboard, told as a toast (pullRequest.copyNumber).
  Q_INVOKABLE void copyNumber();
  Q_INVOKABLE void openOnHost();

signals:
  void targetChanged();
  void stateChanged();
  void detailChanged();
  void stackChanged();
  void codeChanged();
  void viewedChanged();

private:
  QJsonObject reference() const;
  void load();
  void readDetail();
  void readStack();
  // The stack's unmerged layers, and the ones a merge at this layer takes.
  QList<QJsonObject> unmergedLayers() const;
  QList<QJsonObject> mergeLayers() const;
  void readCode(const QString& cursor, const QString& patch);
  void applyViewed();
  void setStatus(const QString& status, const QString& message = {});
  void setCode(const QString& status, const QString& message = {});
  void setProblem(const QString& problem);
  // Sends a change; `done` runs once it lands, then the pull request is read again.
  bool change(const QString& method, const QJsonObject& input, const QString& failure, std::function<void()> done = {});

  McClient* m_client;
  Notify m_notify;
  Open m_open;
  Copy m_copy;
  DiffModel m_model;
  QString m_environment;
  QString m_project;
  QString m_host;
  QString m_repository;
  int m_number = 0;
  bool m_online = false;
  bool m_active = false;
  // Read since it was last shown or changed.
  bool m_loaded = false;
  QString m_status = QStringLiteral("idle");
  QString m_message;
  QVariantMap m_detail;
  QVariantList m_conversation;
  QVariantList m_threads;
  // The stack as last read, what the viewer may do with it, and whether the
  // last read failed.
  QJsonObject m_stack;
  bool m_stackStale = false;
  bool m_viewerMayMerge = false;
  bool m_viewerMayRebase = false;
  QVariantMap m_stackConfirmation;
  QString m_stackMethod;
  QString m_codeStatus = QStringLiteral("idle");
  QString m_codeMessage;
  QSet<QString> m_viewed;
  int m_busy = 0;
  QString m_problem;
  // Bumped by every read of another pull request (or again); an answer lands
  // only when it is still the one asked for.
  quint64 m_generation = 0;
};
