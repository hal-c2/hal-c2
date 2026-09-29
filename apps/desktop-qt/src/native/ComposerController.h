#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QVariant>

#include <functional>
#include <optional>
#include <utility>

#include "ComposerModel.h"

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;
class TimelineModel;

// The composer on the thread or new-thread draft the window shows (the
// route), against the node: the draft itself (text, caret, model, options,
// modes, images, terminal excerpts), what the picker offers, the @ $ / suggestions, sending,
// follow-ups while a turn runs, stop, the thread's pending approvals and
// questions, and its proposed plan.
//
// Each thread keeps its draft here, saved on this machine (setStorePath); a
// new thread's text is DraftController's. The catalogue is the `providers` of
// the route environment's config (WorkspaceController::environmentConfig), so
// a linked thread lists its own machine's models. A new thread's first send
// launches it (`orchestration.launchThread`) in the checkout WorkspaceController
// picked, and the window moves to the thread in the draft's place; a
// background send launches it and leaves the draft ready for another prompt.
//
// Publishes `composer` (ShellComposerState in packages/contracts/src/shell.ts;
// null with no thread or draft open), `modelPicker` (ShellModelPickerState)
// and `turn`, the route thread's requests for the request bricks:
//   {threadKey, kind: "thread", running,
//    approvals: [{requestId, title, appName, detail, options: [{decision, label,
//      warning}], canRespond, responding, problem}],
//    questions: [{requestId, questions: [{id, header, question, options:
//      [{label, description}], multiSelect, allowCustomAnswer}], canRespond,
//      responding, problem}],
//    plan: {id, title, markdown} | null,  // offered while the thread is idle
//    queue: [{runId, text}]}
// `problem` says why a request cannot be answered, when it cannot. On a new
// thread's draft route the turn is {threadKey: draftId, kind: "draft",
// sending} with nothing pending; `sending` while its first send
// is on the way.
//
// `composer.edit` is the brick's last edit ({clientId, revision}) the shell
// applied: the brick adopts published text only when it answers its newest
// edit, so its own typing is never overwritten by an older echo, while the
// shell's changes (a suggestion, a cleared send, a restored failure) land.
//
// Actions: composer.text.set {target, text, cursor, edit},
// composer.suggest.select {id}, composer.suggest.dismiss,
// composer.model.select {instanceId, model},
// composer.model.favorite.toggle {instanceId, model},
// composer.option.set {id, value}, composer.runtimeMode.set {mode},
// composer.interactionMode.set {mode}, composer.submit {text, intent, edit},
// composer.interrupt, composer.attach {files}, composer.attachment.remove {id},
// composer.terminalContext.add {terminalId, terminalLabel, lineStart, lineEnd,
// text}, composer.terminalContext.remove {id},
// composer.approval.respond {requestId, decision},
// composer.question.answer {requestId, answers}, composer.question.dismiss
// {requestId}, composer.plan.implement, composer.queue.remove {runId},
// composer.queue.steer {runId?} (the first queued without one),
// composer.queue.edit {runId?} (the last queued without one),
// composer.queue.edit.cancel.
//
// A terminal excerpt is a chip on the draft (`composer.terminalContexts`), as
// the web's terminal context; a send appends an inline context link for each
// to the text and carries the excerpts as the message's `context` records,
// which the node hands the provider (HalC2.ComposerContext).
//
// Editing a queued message puts its text in the thread's composer
// (`composer.editingQueuedRunId`) and sets the thread's own draft aside; a
// send saves the edit (`queued-run.edit`, text only) and cancelling gives the
// draft back. A run that leaves the queue mid-edit ends it: a changed edit
// stays in the composer when the set-aside draft was empty, and is dropped
// with a toast otherwise.
class ComposerController : public QObject, public NativeController {
  Q_OBJECT

public:
  ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool isActive() const { return m_active; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  bool handle(const QString& action, const QVariant& payload) override;

  // Where the threads' drafts are kept; loads them from there.
  void setStorePath(const QString& path);
  // The thread's (or new thread's) draft text, as the composer last left it.
  QString draft(const QString& target) const;
  // The draft's terminal excerpts, with their text: {id, terminalId,
  // terminalLabel, lineStart, lineEnd, text}.
  QVariantList terminalContexts(const QString& target) const;

private:
  struct Attachment {
    QString id;
    QString name;
    QString mimeType;
    qint64 sizeBytes = 0;
    QString dataUrl;
  };
  // A terminal selection on the draft (apps/web/src/lib/terminalContext.ts).
  struct TerminalContext {
    QString id;
    QString terminalId;
    QString terminalLabel;
    int lineStart = 1;
    int lineEnd = 1;
    QString text;
  };
  struct Draft {
    QString text;  // a new thread's is DraftController's
    int cursor = 0;
    // The brick's last edit applied here: {clientId, revision}.
    QVariant edit;
    // The suggestions were dismissed; they return once the text changes.
    bool dismissed = false;
    // Chosen in the composer; the thread's own otherwise.
    std::optional<QJsonObject> modelSelection;
    QString runtimeMode;
    QString interactionMode;
    QList<Attachment> attachments;
    QList<TerminalContext> terminalContexts;
  };
  struct Send {
    QString target;
    QString environmentId;
    QString threadId;
    QList<QJsonObject> commands;
    // Uploaded first; the message carries what the node stored.
    QList<Attachment> attachments;
    // Given back with the text if the send fails.
    QList<TerminalContext> terminalContexts;
    // The text to give back if the send fails; empty for none.
    QString prompt;
  };

  bool interrupt();
  bool submit(const QVariantMap& payload);
  // A new thread's first send: its images, then the thread with its message.
  bool submitDraft(const QString& draftId, const QVariantMap& payload);
  void launched(const QString& draftId, const QString& threadKey, const std::optional<QString>& error);
  // A background send's answer: a toast that opens the thread, or one that
  // gives the prompt back.
  void launchedInBackground(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                            const QList<TerminalContext>& contexts, const QString& threadKey,
                            const std::optional<QString>& error);
  // The model a thread (its own) or a draft (the project's default) starts from.
  QJsonObject baseSelection(const QString& key) const;
  // The message and the mode changes before it; empty `text` implements the plan.
  bool sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp, bool fromDraft);
  void sendNext(const QString& target);
  void dispatchAll(const Send& send, qsizetype index, std::function<void(const std::optional<QString>&)> done);
  bool attach(const QVariantList& files);
  // A terminal selection joins the route's draft; blank ones are dropped.
  bool addTerminalContext(const QVariantMap& selection);
  // The message text with a context link per excerpt, and their records as
  // its `context`.
  static void withTerminalContexts(QJsonObject& message, const QList<TerminalContext>& contexts);
  bool respond(const QString& requestId, const QJsonObject& fields, const QString& failure);
  bool queueCommand(const QString& type, const QString& runId);
  bool editQueued(const QString& target, QString runId);
  bool saveQueuedEdit(const QString& target, const QString& text);
  // Gives the set-aside draft back; `keepEdit` leaves the edit's text instead.
  void endQueuedEdit(bool keepEdit = false);
  // Ends an edit whose run is no longer queued.
  void recoverQueuedEdit(const QVariantMap& turn);

  // The thread the window shows (the shell's route), or empty.
  QString openThread() const;
  // The new-thread draft the window shows (DraftController's), or empty.
  QString openDraft() const;
  // The route's composer target: its draft id, or its thread when the shell
  // has the thread's row; empty otherwise.
  QString target() const;

  // The draft's text and caret; `edit` is the brick's, kept when invalid.
  void setText(const QString& target, const QString& text, int cursor, const QVariant& edit = {});
  // A standalone "/plan" or "/default": the mode changes and the text goes.
  bool slashMode(const QString& target, const QString& text);
  void setInteractionMode(const QString& target, const QString& mode);
  bool selectModel(const QString& target, const QString& instanceId, const QString& model);
  bool setOption(const QString& target, const QString& id, const QVariant& value);
  bool selectSuggestion(const QString& target, const QString& id);
  // The suggestions for the caret, with the trigger they answer.
  QList<composer::Suggestion> suggestions(const QString& target, const std::optional<composer::Trigger>& trigger) const;
  // Searches the workspace for an @ query the menu has no answer for yet.
  void searchPaths(const QString& target);

  // The catalogue of the route's environment.
  void refreshCatalogue();
  const composer::Instance* instanceOf(const QJsonObject& selection) const;
  // The draft's model: chosen, the thread's (or project default's), else the
  // first ready instance's default.
  QJsonObject selection(const QString& target) const;
  // A thread that has run keeps its provider.
  bool started(const QString& target) const;
  std::optional<composer::Lock> lockOf(const QString& target) const;
  // The web's resolveComposerInteractionMode: plan mode needs the setting
  // and a provider that has it.
  bool planModeOn(const composer::Instance* instance) const;
  QString runtimeModeOf(const QString& target) const;
  QString interactionModeOf(const QString& target) const;
  QVariant setting(const QString& key) const;
  void save() const;
  bool running(const QString& target) const;
  void toast(const QString& title, const QString& description);
  void follow();
  void publish();
  QVariantMap turnState() const;
  QVariant composerState(const QVariantMap& turn) const;
  QVariantMap pickerState() const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  QHash<QString, Draft> m_drafts;
  // Each thread's sends, the one in flight first: a thread sends one at a
  // time, in the order the user sent them.
  QHash<QString, QList<Send>> m_queues;
  // The route thread (or draft) and its stream.
  QString m_thread;
  QString m_draftId;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_timelineConnection;
  // Requests answered and waiting for the node, and ones it said are gone.
  QSet<QString> m_responding;
  QSet<QString> m_closed;
  // Drafts whose first send is on the way.
  QSet<QString> m_launching;
  QVariantMap m_published;
  QVariant m_publishedComposer;
  QVariantMap m_publishedPicker;
  QString m_storePath;
  QList<composer::Instance> m_catalogue;
  // The @ search the menu shows: its target and query, and what came back.
  struct PathSearch {
    QString target;
    QString query;
    bool done = false;
    QList<std::pair<QString, bool>> entries;
    int request = 0;
  };
  PathSearch m_paths;
  int m_nextAttachment = 1;
  // The queued message the route thread's composer is editing, and the
  // thread's draft set aside for it.
  struct QueuedEdit {
    QString thread;
    QString runId;
    QString original;
    QString saved;
    int savedCursor = 0;
    bool saving = false;
  };
  std::optional<QueuedEdit> m_queuedEdit;
};
