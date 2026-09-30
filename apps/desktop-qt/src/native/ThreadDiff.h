#pragma once

#include <QJsonObject>
#include <QMap>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QVariantList>

#include <functional>

#include "DiffModel.h"

class NodeClient;
class TimelineModel;

// The Diff tab: what a thread's turns changed, from the checkpoint each
// finished turn leaves (the stream's `checkpoint` entities, turn N being the
// ready one with appRunOrdinal N). One turn's diff is
// `orchestration.getTurnDiff` from N-1 to N, all changes
// `orchestration.getFullThreadDiff` up to the latest turn; either lands in
// `model` as rows.
//
// `selection` is -1 for the latest turn (the default, following new turns),
// 0 for all changes, or a turn number. Only a shown tab loads; a hidden one
// notes that it is stale and loads when shown again.
//
// Reverting asks first: requestRevert(turn) sets `revertTurn` until
// confirmRevert() dispatches `checkpoint.rollback` or cancelRevert() drops
// it. The outcome is told as a toast.
class ThreadDiff : public QObject {
  Q_OBJECT
  Q_PROPERTY(DiffModel* model READ model CONSTANT)
  // [{value, label}] for the picker: the latest turn, all changes, then each
  // finished turn, newest first.
  Q_PROPERTY(QVariantList choices READ choices NOTIFY turnsChanged)
  Q_PROPERTY(int latestTurn READ latestTurn NOTIFY turnsChanged)
  Q_PROPERTY(int selection READ selection WRITE select NOTIFY selectionChanged)
  // The turn shown (0: all changes).
  Q_PROPERTY(int shownTurn READ shownTurn NOTIFY selectionChanged)
  // idle, loading, ready, empty (nothing to show, `message` says why) or
  // error (`message` is the node's reason).
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString message READ message NOTIFY statusChanged)
  Q_PROPERTY(bool ignoreWhitespace READ ignoreWhitespace WRITE setIgnoreWhitespace NOTIFY optionsChanged)
  Q_PROPERTY(bool wrap READ wrap WRITE setWrap NOTIFY optionsChanged)
  // A turn can be reverted to: the thread is not working and has a checkpoint.
  Q_PROPERTY(bool canRevert READ canRevert NOTIFY revertChanged)
  // The turn the user is asked to confirm reverting to, or 0.
  Q_PROPERTY(int revertTurn READ revertTurn NOTIFY revertChanged)
  Q_PROPERTY(bool reverting READ reverting NOTIFY revertChanged)

public:
  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;

  ThreadDiff(NodeClient* client, Notify notify, QObject* parent = nullptr);

  // The thread shown, and its timeline (for its checkpoints and whether it is
  // working; it may come later than the thread).
  void setThread(const QString& environmentId, const QString& threadId, TimelineModel* timeline);
  void setActive(bool active);

  DiffModel* model() { return &m_model; }
  QVariantList choices() const;
  int latestTurn() const { return m_turns.isEmpty() ? 0 : m_turns.lastKey(); }
  int selection() const { return m_selection; }
  Q_INVOKABLE void select(int selection);
  // Selects the turn the run (a turn id) finished; unknown runs change nothing.
  Q_INVOKABLE void selectRun(const QString& runId);
  int shownTurn() const;
  QString status() const { return m_status; }
  QString message() const { return m_message; }
  bool ignoreWhitespace() const { return m_ignoreWhitespace; }
  void setIgnoreWhitespace(bool ignore);
  bool wrap() const { return m_wrap; }
  void setWrap(bool wrap);

  // Loads the selection again.
  Q_INVOKABLE void reload();
  // Asks the view to scroll to `path`'s file, expanding it.
  Q_INVOKABLE void revealFile(const QString& path);

  bool canRevert() const;
  int revertTurn() const { return m_revertTurn; }
  bool reverting() const { return m_reverting; }
  // Asks to revert to the checkpoint after `turn` (0: the turn shown, or the latest).
  Q_INVOKABLE void requestRevert(int turn = 0);
  Q_INVOKABLE void confirmRevert(bool restoreFiles = true);
  Q_INVOKABLE void cancelRevert();

signals:
  void turnsChanged();
  void selectionChanged();
  void statusChanged();
  void optionsChanged();
  void revertChanged();
  // The view should show `row` of the model at its top.
  void revealRow(int row);

private:
  void readCheckpoints();
  void load();
  void setStatus(const QString& status, const QString& message = {});
  QString loadKey() const;

  NodeClient* m_client;
  Notify m_notify;
  DiffModel m_model;
  QString m_environment;
  QString m_threadId;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_checkpointsConnection;
  QMetaObject::Connection m_workingConnection;
  // Turn number -> its ready checkpoint.
  QMap<int, QJsonObject> m_turns;
  int m_selection = -1;
  bool m_active = false;
  bool m_ignoreWhitespace = true;
  bool m_wrap = false;
  QString m_status = QStringLiteral("idle");
  QString m_message;
  // What `model` shows (or is loading), so a repeat asks nothing.
  QString m_loaded;
  int m_request = 0;
  QString m_pendingReveal;
  int m_revertTurn = 0;
  bool m_reverting = false;
};
