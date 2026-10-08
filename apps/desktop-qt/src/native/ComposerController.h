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

class McClient;
class ShellBridge;
class ShellStore;
class TimelineModel;

// The composer on the thread or new-thread draft the window shows (the
// route), against the MC: the draft itself (text, caret, model, options,
// modes, images, terminal excerpts, quoted replies), what the picker offers, the @ $ / suggestions, sending,
// follow-ups while a turn runs, stop, the thread's pending approvals and
// questions, and its proposed plan.
//
// Each thread keeps its draft here, saved on this machine (setStorePath) and
// the same in every window (NativeShell::common); a new thread's text is
// DraftController's. The catalogue is the `providers` of
// the route environment's config (WorkspaceController::environmentConfig), so
// a thread elsewhere lists its own machine's models. A new thread's first send
// launches it (`orchestration.launchThread`) in the checkout WorkspaceController
// picked, or in another machine's checkout of the repository when the MC
// places it there (`hal-c2.placeThread`, load balancing), and the window moves
// to the thread in the draft's place; a background send launches it and
// leaves the draft ready for another prompt.
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
// composer.model.multiple.toggle {instanceId, model} (a new thread's prompt
// goes to each model so chosen),
// composer.option.set {id, value}, composer.runtimeMode.set {mode},
// composer.interactionMode.set {mode}, composer.submit {text, intent, edit},
// composer.interrupt, composer.attach {files, folders} (a file is {name,
// mimeType, base64} for an image, {name, mimeType, path} for any other file,
// {name, text} for a pasted text), composer.attachment.remove {id},
// composer.attachment.retry {id}, composer.question.attach {requestId,
// questionId, files}, composer.question.attachment.remove {id},
// composer.terminalContext.add {terminalId, terminalLabel, lineStart, lineEnd,
// text}, composer.terminalContext.remove {id},
// composer.reviewComment.add {filePath, lineStart, lineEnd, text, diff,
// startIndex, endIndex, rangeLabel, sectionId, sectionTitle},
// composer.reviewComment.remove {id},
// composer.citation.add {messageId, text, start, end, prefix, suffix},
// composer.citation.comment {id, comment}, composer.citation.remove {id},
// composer.approval.respond {requestId, decision},
// composer.question.answer {requestId, answers}, composer.question.dismiss
// {requestId}, composer.plan.implement, composer.queue.remove {runId},
// composer.queue.steer {runId?} (the first queued without one),
// composer.queue.edit {runId?} (the last queued without one),
// composer.queue.edit.cancel, composer.stash, composer.stash.restore {id},
// composer.stash.delete {id}, composer.stash.menu {open?} (toggles without),
// composer.history.step {direction: "backward" | "forward"}.
//
// The stash (the web's promptStashStore) is this machine's, not a thread's:
// the prompts set aside with composer.stash, newest first, at most 20, kept
// with the drafts and the same in every window. Stashing an empty draft
// brings back the only entry, or opens the list. Publishes `composerStash`:
// {entries: [{id, snippet, createdAt}], open, shortcut}, `open` being this
// window's.
//
// A note on a diff's lines is a chip too (`composer.reviewComments`: {id,
// label "src/cart.ts L10-12", filePath, lineStart, lineEnd, text}); a send
// names it in the text and carries it as a `review-comment` context record
// (packages/contracts/src/composerContext.ts).
//
// A terminal excerpt is a chip on the draft (`composer.excerpts`), as
// the web's terminal context; a send appends an inline context link for each
// to the text and carries the excerpts as the message's `context` records,
// which the MC hands the provider (HalC2.ComposerContext).
//
// A quoted reply is a chip too (`composer.citations`: {id, text, comment}),
// the web's assistant citation: a selection of one of the thread's replies,
// with the user's comment on it. A send appends its
// `[Assistant quote](hal-c2-citation://v1/...)` link to the text, which holds
// the whole citation (packages/shared/src/assistantCitations.ts).
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
  ComposerController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  // The model the window's thread or draft will send with: {instanceId, model}, empty with none ready.
  QJsonObject currentSelection() const { return selection(target()); }
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
  // What the sidebar shows for a draft with something in it (the web app's
  // SidebarDraftRow): the text's first line, else how many attachments it
  // carries; nothing for an empty draft (composerDraftHasUserContent).
  std::optional<QString> draftPreview(const QString& target) const;
  // An image (a snapshot) joins `target`'s draft: a thread key or a draft id.
  // `source` rides with it to the MC when set (ChatImageAttachment.source).
  void attachImage(const QString& target, const QString& name, const QString& mimeType, const QByteArray& bytes,
                   const QJsonObject& source = {});
  // The draft's images: {id, name, mimeType, sizeBytes, source}.
  QVariantList attachments(const QString& target) const;
  // Whether `target`'s draft has files still on their way to the MC, or a
  // send in flight that carries the draft's attachments.
  bool attachmentsPending(const QString& target) const;
  // Adds `text` after the route's draft, a space apart from what is there
  // (the Files tab's Add to chat); false with no thread or draft open.
  bool insertAtEnd(const QString& text);
  // A draft's attachment as this machine holds it, for a viewer: {id, name,
  // mimeType, url (an image's bytes as a data URL), text (a file's, when it
  // is text this machine can read)}; empty when it is gone.
  QVariantMap attachmentPreview(const QString& id);

private:
  struct Attachment {
    QString id;
    QString name;
    QString mimeType;
    qint64 sizeBytes = 0;
    QString dataUrl;
    QJsonObject source;
    // A file (not an image) goes to the MC when it is added and the message
    // names the upload (`attachments.createUploadUrl`); an image goes with
    // its message (`assets.persistChatAttachments`).
    bool file = false;
    // Where a file's bytes are: a path on this machine, or a pasted text.
    QString path;
    QByteArray content;
    bool pastedText = false;
    // A file's upload: "uploading", "failed" (why, in `error`), or empty once
    // the MC has it as `remoteId` on `environmentId`.
    QString upload;
    QString error;
    QString remoteId;
    QString environmentId;
  };
  // The attachment `id` of any draft or answer; null when it is gone.
  Attachment* findAttachment(const QString& id);
  // Sends a file's bytes to the environment `target` runs on.
  void uploadFile(const QString& id, const QString& environmentId);
  // The environment a thread's or a new thread's files go to.
  QString environmentOf(const QString& target) const;
  // Why the files keep a send (or `what`) waiting, toasted; false when none do.
  bool filesBlock(const QList<Attachment>& attachments, const QString& what);
  static QJsonArray fileRecords(const QList<Attachment>& attachments);
  static QJsonObject attachmentJson(const Attachment& attachment);
  static std::optional<Attachment> attachmentOf(const QJsonObject& kept);
  // What the composer shows of attachments; `previews` adds each image's
  // thumbnail (thumbnail(), kept in m_previews).
  QVariantList shownAttachments(const QList<Attachment>& attachments, bool previews = false) const;
  // A dropped folder becomes a path the prompt names, where the MC shares
  // this machine's folders.
  bool attachFolders(const QString& target, const QVariantList& folders);
  // Files for the answer to one question of a pending request.
  bool attachToAnswer(const QString& requestId, QString questionId, const QVariantList& files);
  // A terminal selection on the draft (apps/web/src/lib/terminalContext.ts),
  // or with `citation` a quoted reply (AssistantCitation in
  // packages/contracts/src/assistantCitations.ts) and nothing else.
  struct Excerpt {
    QString id;
    QString terminalId;
    QString terminalLabel;
    int lineStart = 1;
    int lineEnd = 1;
    QString text;
    QJsonObject citation;
    // Set for a note on lines of a diff instead (a `review-comment` record):
    // {filePath, sectionId, sectionTitle, startIndex, endIndex, rangeLabel,
    // diff}; `text` is then the note and the lines are the file's.
    QJsonObject review;
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
    // A new thread's prompt goes to each of these instead: one thread per
    // model, each in its own worktree (the web's multiple models).
    std::optional<QList<QJsonObject>> multipleModels;
    QList<Attachment> attachments;
    QList<Excerpt> excerpts;
  };
  // A prompt set aside (composer.stash), with what it carried.
  struct StashEntry {
    QString id;
    QDateTime createdAt;
    QString text;
    QList<Attachment> attachments;
    QList<Excerpt> excerpts;
  };
  struct Send {
    QString target;
    QString environmentId;
    QString threadId;
    QList<QJsonObject> commands;
    // Uploaded first; the message carries what the MC stored.
    QList<Attachment> attachments;
    // Given back with the text if the send fails.
    QList<Excerpt> excerpts;
    // The text to give back if the send fails; empty for none.
    QString prompt;
  };

  bool interrupt();
  bool submit(const QVariantMap& payload);
  // A new thread's first send: its images, then the thread with its message.
  bool submitDraft(const QString& draftId, const QVariantMap& payload);
  // Where a new thread starts: the user's pick (`environmentId`, `projectId`),
  // or the checkout the MC chooses in its place. `then` is called once.
  void place(const QString& environmentId, const QString& projectId, bool tied, const QString& instanceId,
             std::function<void(const QString& environmentId, const QString& projectId)> then);
  void launched(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                const QList<Excerpt>& contexts, const QString& threadKey, const std::optional<QString>& error);
  bool restoreLaunch(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                     const QList<Excerpt>& contexts);
  // The prompt to every chosen model: `input` is the launch for one, less
  // its thread, model and checkout.
  bool submitToModels(const QString& draftId, const QList<QJsonObject>& models, const QJsonObject& input,
                      const QJsonObject& strategy, const QString& environmentId, const QString& text,
                      const QList<Attachment>& attachments, const QList<Excerpt>& contexts);
  bool toggleMultipleModel(const QString& target, const QString& instanceId, const QString& model);
  // A background send's answer: a toast that opens the thread, or one that
  // gives the prompt back.
  void launchedInBackground(const QString& draftId, const QString& text, const QList<Attachment>& attachments,
                            const QList<Excerpt>& contexts, const QString& threadKey,
                            const std::optional<QString>& error);
  // The model a thread (its own) or a draft (the project's default) starts from.
  QJsonObject baseSelection(const QString& key) const;
  // The message and the mode changes before it; empty `text` implements the plan.
  bool sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp, bool fromDraft);
  void sendNext(const QString& target);
  void dispatchAll(const Send& send, qsizetype index, std::function<void(const std::optional<QString>&)> done);
  bool attach(const QVariantList& files);
  static QString thumbnail(const QString& dataUrl);
  // A terminal selection joins the route's draft; blank ones are dropped.
  bool addTerminalContext(const QVariantMap& selection);
  // A note on lines of a diff joins the route's draft (ThreadDiff::comment).
  bool addReviewComment(const QVariantMap& comment);
  // A selection of one of the route thread's replies joins its draft.
  bool addCitation(const QVariantMap& selection);
  // The message text with a link per excerpt, note and quote, and the
  // excerpts' and notes' records as its `context`.
  static void withExcerpts(QJsonObject& message, const QList<Excerpt>& contexts);
  // Up and Down on the editor's edge lines walk the thread's sent prompts,
  // text only (the web's composerPromptHistory): back from an empty draft,
  // forward past the newest to an empty one. An edited recall is a draft.
  void stepHistory(const QString& target, bool backward);
  // Why the prompt cannot be sent as it is, or nothing: its length.
  static QString promptProblem(const QString& text);
  bool stash(const QString& target);
  void restoreStash(const QString& target, const QString& id);
  void setStashOpen(bool open);
  QVariantMap stashState() const;
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
  void carryDrafts();

  // The draft's text and caret; `edit` is the brick's, kept when invalid.
  void setText(const QString& target, const QString& text, int cursor, const QVariant& edit = {});
  // A standalone "/plan" or "/default": the mode changes and the text goes.
  bool slashMode(const QString& target, const QString& text);
  // A standalone "/usage-limits" on a provider that offers it: the provider's
  // limits show above the composer (`composer.usageLimits`) from what the
  // environment last reported, and nothing is sent to the agent.
  bool slashUsageLimits(const QString& target, const QString& text);
  // The limits "/usage-limits" opened, by thread or draft, until the next
  // message or `composer.usageLimits.dismiss`.
  QHash<QString, QVariantMap> m_usageLimits;
  void setInteractionMode(const QString& target, const QString& mode);
  bool selectModel(const QString& target, const QString& instanceId, const QString& model);
  // A send used this model: new threads start from it.
  void rememberModel(const QJsonObject& selection);
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
  // The other windows' composers show what this one changed in the drafts.
  void spread() const;
  bool running(const QString& target) const;
  void toast(const QString& title, const QString& description);
  void follow();
  void publish();
  QVariantMap turnState() const;
  QVariant composerState(const QVariantMap& turn) const;
  QVariantMap pickerState() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  // What every window's composer keeps.
  struct Kept {
    QHash<QString, Draft> drafts;
    // Newest first.
    QList<StashEntry> stash;
    // The model last sent with on each provider instance, and the instance
    // last sent with: a new thread starts from them (the web's sticky model).
    QHash<QString, QJsonObject> lastModels;
    QString lastInstance;
    QString path;
    // The images last written beside the drafts (imagesPath), so a keystroke
    // does not rewrite them.
    QString images;
  };
  // Where the drafts' images are kept: shell-composer-images.json beside them.
  QString imagesPath() const;
  Kept& m_kept;
  QHash<QString, Draft>& m_drafts;
  // Each thread's sends, the one in flight first: a thread sends one at a
  // time, in the order the user sent them.
  QHash<QString, QList<Send>> m_queues;
  // The route thread (or draft) and its stream.
  QString m_thread;
  QString m_draftId;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_timelineConnection;
  // The files attached to each question's answer, by request id then
  // question id; they go with the answer and stay out of the thread's draft.
  QHash<QString, QHash<QString, QList<Attachment>>> m_answerFiles;
  // Requests answered and waiting for the MC, and ones it said are gone.
  QSet<QString> m_responding;
  QSet<QString> m_closed;
  // Drafts whose first send is on the way.
  QSet<QString> m_launching;
  // The thumbnails of the draft images the composer has shown, by attachment id.
  mutable QHash<QString, QString> m_previews;
  QVariantMap m_published;
  QVariant m_publishedComposer;
  QVariantMap m_publishedPicker;
  QVariantMap m_publishedStash;
  // This window's stash list is open.
  bool m_stashOpen = false;
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
  // The sent prompt the composer is showing again: its message and text.
  struct Recall {
    QString target;
    QString entryId;
    QString recalled;
  };
  std::optional<Recall> m_recall;
};
