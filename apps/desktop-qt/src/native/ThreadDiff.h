#pragma once

#include <optional>
#include <QJsonObject>
#include <QMap>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QVariantList>

#include <functional>

#include "DiffModel.h"

class McClient;
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
// The checkout itself can be reviewed too (`review.getDiffPreview`):
// WorkingTree is its uncommitted changes, Branch the whole branch against
// its base, which is the MC's choice until `baseRef` names another. A thread
// with no finished turn opens on the working tree. These do not follow the
// checkout: reload() asks again.
//
// Opening one changed file from a reply shows that file alone (`focusPath`)
// until the user asks for all of the selection's files again or picks
// another selection.
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
  // error (`message` is the MC's reason).
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString message READ message NOTIFY statusChanged)
  // The one file shown of the selection's `fileTotal`, or empty for all of them.
  Q_PROPERTY(QString focusPath READ focusPath NOTIFY focusChanged)
  Q_PROPERTY(int fileTotal READ fileTotal NOTIFY focusChanged)
  // The checkout is what is shown, not a turn (WorkingTree or Branch).
  Q_PROPERTY(bool reviewing READ reviewing NOTIFY selectionChanged)
  // The ref the branch is compared against: chosen ("" lets the MC pick), and
  // the refs the MC compared ("feature/tax" against "main").
  Q_PROPERTY(QString baseRef READ baseRef WRITE setBaseRef NOTIFY reviewChanged)
  Q_PROPERTY(QString comparedBase READ comparedBase NOTIFY reviewChanged)
  Q_PROPERTY(QString comparedHead READ comparedHead NOTIFY reviewChanged)
  // The MC cut the patch short; the files' counts are still whole.
  Q_PROPERTY(bool truncated READ truncated NOTIFY reviewChanged)
  Q_PROPERTY(bool ignoreWhitespace READ ignoreWhitespace WRITE setIgnoreWhitespace NOTIFY optionsChanged)
  Q_PROPERTY(bool wrap READ wrap WRITE setWrap NOTIFY optionsChanged)
  // A turn can be reverted to: the thread is not working and has a checkpoint.
  Q_PROPERTY(bool canRevert READ canRevert NOTIFY revertChanged)
  // The turn the user is asked to confirm reverting to, or 0.
  Q_PROPERTY(int revertTurn READ revertTurn NOTIFY revertChanged)
  Q_PROPERTY(bool reverting READ reverting NOTIFY revertChanged)

public:
  using Notify = std::function<void(const QString& type, const QString& title, const QString& description)>;
  // Selections that review the checkout.
  enum Review { WorkingTree = -2, Branch = -3 };
  Q_ENUM(Review)

  ThreadDiff(McClient* client, Notify notify, QObject* parent = nullptr);

  // The thread shown, and its timeline (for its checkpoints and whether it is
  // working; it may come later than the thread).
  void setThread(const QString& environmentId, const QString& threadId, TimelineModel* timeline);
  // The thread's checkout, for reviewing it; empty when it has none.
  void setCheckout(const QString& cwd);
  void setActive(bool active);

  DiffModel* model() { return &m_model; }
  QVariantList choices() const;
  int latestTurn() const { return m_turns.isEmpty() ? 0 : m_turns.lastKey(); }
  int selection() const { return m_selection; }
  Q_INVOKABLE void select(int selection);
  // Selects the turn the run (a turn id) finished; unknown runs change nothing.
  Q_INVOKABLE void selectRun(const QString& runId);
  int shownTurn() const;
  bool reviewing() const { return effectiveSelection() <= WorkingTree; }
  QString baseRef() const { return m_baseRef; }
  void setBaseRef(const QString& ref);
  QString comparedBase() const { return m_comparedBase; }
  QString comparedHead() const { return m_comparedHead; }
  bool truncated() const { return m_truncated; }
  QString status() const { return m_status; }
  QString message() const { return m_message; }
  bool ignoreWhitespace() const { return m_ignoreWhitespace; }
  void setIgnoreWhitespace(bool ignore);
  // Whether long lines wrap: what the user chose here, else the word wrap
  // setting (setDefaultWrap).
  bool wrap() const { return m_wrap.value_or(m_defaultWrap); }
  void setWrap(bool wrap);
  void setDefaultWrap(bool wrap);

  // Loads the selection again.
  Q_INVOKABLE void reload();
  // Asks the view to scroll to `path`'s file, expanding it.
  Q_INVOKABLE void revealFile(const QString& path);
  QString focusPath() const { return m_focus; }
  int fileTotal() const { return m_fileTotal; }
  // Shows only `path`'s file of the selection; one the selection did not
  // change leaves every file shown.
  Q_INVOKABLE void focusFile(const QString& path);
  Q_INVOKABLE void showAllFiles();
  // A note on lines `first` to `last` of `path` as the diff shows them
  // (`side` "old" for removed lines), for the prompt: commentRequested carries
  // it as a review comment (the composer's `composer.reviewComment.add`).
  // False when the diff shows no such lines or the note is blank.
  Q_INVOKABLE bool comment(const QString& path, const QString& side, int first, int last, const QString& note);

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
  void focusChanged();
  void commentRequested(const QVariantMap& comment);
  void reviewChanged();
  void revertChanged();
  // The view should show `row` of the model at its top.
  void revealRow(int row);

private:
  void readCheckpoints();
  // The selection shown: the working tree stands in for the latest turn of a
  // thread that has none.
  int effectiveSelection() const;
  void loadReview(int selection);
  void load();
  void setStatus(const QString& status, const QString& message = {});
  // Puts the loaded patch, or its focused file, in the model.
  void present();
  QString loadKey() const;

  McClient* m_client;
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
  QString m_cwd;
  QString m_baseRef;
  QString m_comparedBase;
  QString m_comparedHead;
  bool m_truncated = false;
  bool m_active = false;
  bool m_ignoreWhitespace = true;
  std::optional<bool> m_wrap;
  bool m_defaultWrap = false;
  QString m_status = QStringLiteral("idle");
  QString m_message;
  // What `model` shows (or is loading), so a repeat asks nothing.
  QString m_loaded;
  int m_request = 0;
  QString m_pendingReveal;
  // The selection's whole patch, and the one file of it shown.
  QString m_patch;
  QString m_focus;
  int m_fileTotal = 0;
  int m_revertTurn = 0;
  bool m_reverting = false;
};
