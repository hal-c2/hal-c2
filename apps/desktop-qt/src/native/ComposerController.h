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

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;
class TimelineModel;

// The composer's turn on the thread the window shows (the route), against the
// node: sending, follow-ups while a turn runs, stop, image attachments, the
// thread's pending approvals and questions, and its proposed plan.
//
// Each thread keeps its draft here (text, model, options, modes, images), fed
// by the brick's own actions: `composer.text.set`, `composer.model.select`,
// `composer.option.set` and the mode actions are recorded and still reach the
// page, which follows. A send reads only the draft and the thread's shell row.
// A new thread's draft (DraftController's, which keeps its text) is kept the
// same way by draft id, and its first send launches the thread
// (`orchestration.launchThread`) in the checkout WorkspaceController picked;
// the window then moves to the thread in the draft's place. Slash commands (a
// prompt starting with "/"), background sends of a draft, and drafts the shell
// does not keep still go to the page.
//
// `turn` publishes the route thread's state for the request bricks:
//   {threadKey, kind: "thread", running, draft,
//    attachments: [{id, name, mimeType, sizeBytes}],
//    approvals: [{requestId, title, appName, detail, options: [{decision, label,
//      warning}], canRespond, responding, problem}],
//    questions: [{requestId, questions: [{id, header, question, options:
//      [{label, description}], multiSelect, allowCustomAnswer}], canRespond,
//      responding, problem}],
//    plan: {id, title, markdown} | null,  // offered while the thread is idle
//    queue: [{runId, text}]}
// `problem` says why a request cannot be answered, when it cannot.
// `draft` is the thread's text as it was when the window opened the thread.
// On a new thread's draft route the turn is {threadKey: draftId, kind:
// "draft", draft, attachments, sending} with nothing pending; `sending` while
// its first send is on the way. A draft the shell does not keep has an empty
// threadKey (the page's composer has it).
//
// Actions: composer.submit {text, intent, edit}, composer.interrupt,
// composer.attach {files}, composer.attachment.remove {id},
// composer.approval.respond {requestId, decision},
// composer.question.answer {requestId, answers}, composer.question.dismiss
// {requestId}, composer.plan.implement, composer.queue.remove {runId},
// composer.queue.steer {runId}.
class ComposerController : public QObject, public NativeController {
  Q_OBJECT

public:
  ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool isActive() const { return m_active; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  bool handle(const QString& action, const QVariant& payload) override;

  // The thread's draft text, as the composer last left it.
  QString draft(const QString& threadKey) const { return m_drafts.value(threadKey).text; }

private:
  struct Attachment {
    QString id;
    QString name;
    QString mimeType;
    qint64 sizeBytes = 0;
    QString dataUrl;
  };
  struct Draft {
    QString text;
    // Chosen in the composer; the thread's own otherwise.
    std::optional<QJsonObject> modelSelection;
    QString runtimeMode;
    QString interactionMode;
    QList<Attachment> attachments;
  };
  struct Send {
    QString target;
    QString environmentId;
    QString threadId;
    QList<QJsonObject> commands;
    // Uploaded first; the message carries what the node stored.
    QList<Attachment> attachments;
    QString prompt;
    std::function<void(const QString&)> setText;
  };

  bool interrupt();
  bool submit(const QVariantMap& payload);
  // A new thread's first send: its images, then the thread with its message.
  bool submitDraft(const QString& draftId, const QVariantMap& payload);
  void launch(const QString& draftId, const QString& environmentId, const QJsonObject& input);
  void launched(const QString& draftId, const QString& threadKey, const std::optional<QString>& error);
  // The model a thread (its own) or a draft (the project's default) starts from.
  QJsonObject baseSelection(const QString& key) const;
  // The message and the mode changes before it; empty `text` implements the plan.
  bool sendTurn(const QString& target, const QString& text, const QString& mode, bool planFollowUp,
                const QVariant& edit);
  void sendNext(const QString& target);
  void dispatchAll(const Send& send, qsizetype index, std::function<void(const std::optional<QString>&)> done);
  bool attach(const QVariantList& files);
  bool respond(const QString& requestId, const QJsonObject& fields, const QString& failure);
  bool queueCommand(const QString& type, const QString& runId);

  // The thread the window shows (the shell's route), or empty.
  QString openThread() const;
  // The new-thread draft the window shows (DraftController's), or empty.
  QString openDraft() const;
  // The same, when the shell keeps it; empty for one only the page has.
  QString nativeDraft() const;
  bool running(const QString& target) const;
  void toast(const QString& title, const QString& description);
  void follow();
  void publish();
  QVariantMap turnState() const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  QHash<QString, Draft> m_drafts;
  // Each thread's sends, the one in flight first: a thread sends one at a
  // time, in the order the user sent them.
  QHash<QString, QList<Send>> m_queues;
  // The route thread, the draft it had when opened, and its stream.
  QString m_thread;
  QString m_openedDraft;
  QString m_draftId;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_timelineConnection;
  // Requests answered and waiting for the node, and ones it said are gone.
  QSet<QString> m_responding;
  QSet<QString> m_closed;
  // Drafts whose first send is on the way.
  QSet<QString> m_launching;
  QHash<QString, QVariant> m_launchEdits;
  QVariantMap m_published;
  int m_nextAttachment = 1;
};
