// Editing from one of the user's messages (the web's "Edit from here"): the
// conversation rewinds to before that message, and the message's prompt and
// attachments return to the composer to be changed and sent again.
//
// Publishes `rewind`: null, or {threadKey, rowId, turn} while the user is
// asked whether the files go back too.
//
// Actions: `rewind.request {rowId}` (a user message's row of the open
// thread) asks, or says why it cannot rewind; `rewind.confirm
// {restoreFiles}` fetches the message's attachments from the MC
// (`assets.createUrl`, then the bytes), rolls the thread back to the
// checkpoint before the message (`checkpoint.rollback`), and adds the prompt
// and the attachments to the thread's draft; `rewind.cancel` drops the
// question. A rewind that cannot happen changes nothing and says why.

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include <memory>

#include "ComposerController.h"
#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"
#include "WorkspaceController.h"

class RewindController : public QObject, public NativeController {
public:
  // packages/contracts PROVIDER_SEND_TURN_MAX_ATTACHMENTS.
  static constexpr int maxAttachments = 100;

  RewindController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    // The question is about the thread it was asked on.
    connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, [this] {
      if (!m_thread.isEmpty() && NativeShell::of(this)->controller<NavigationController>()->threadKey() != m_thread) cancel();
    });
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("rewind."))) return false;
    const QVariantMap map = payload.toMap();
    if (action == QLatin1String("rewind.request")) {
      request(map.value(QStringLiteral("rowId")).toString());
    } else if (action == QLatin1String("rewind.confirm")) {
      confirm(map.value(QStringLiteral("restoreFiles")).toBool());
    } else if (action == QLatin1String("rewind.cancel")) {
      cancel();
    }
    return true;
  }

private:
  void refuse(const QString& why) { NativeShell::of(this)->controller<ToastController>()->error(tr("Could not rewind"), why); }

  void cancel() {
    if (m_thread.isEmpty()) return;
    m_thread.clear();
    m_point.clear();
    publish();
  }

  void request(const QString& rowId) {
    if (m_working) return;
    auto* shell = NativeShell::of(this);
    const QString thread = shell->controller<NavigationController>()->threadKey();
    TimelineModel* timeline = shell->controller<ThreadStore>()->timeline(thread);
    if (thread.isEmpty() || !timeline) return;
    const QVariantMap point = timeline->rewindPointOf(rowId);
    if (point.isEmpty()) return;
    // The thread's provider may be unable to forget what came after (the
    // web's supportsConversationRollback).
    const QString instance = m_store->threadRow(thread).value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")).toString();
    for (const QJsonValue& provider : shell->controller<WorkspaceController>()->environmentConfig().value(QLatin1String("providers")).toArray()) {
      const QJsonObject status = provider.toObject();
      if (status.value(QLatin1String("instanceId")).toString() == instance && status.value(QLatin1String("supportsConversationRollback")).isBool() &&
          !status.value(QLatin1String("supportsConversationRollback")).toBool()) {
        return refuse(tr("This provider does not support reverting conversation history. Start a new thread instead."));
      }
    }
    if (!m_store->threadOnline(thread)) return refuse(tr("Reconnect the environment before reverting checkpoints."));
    if (timeline->working()) return refuse(tr("Interrupt the current turn before reverting checkpoints."));
    if (!point.contains(QStringLiteral("checkpointId"))) return refuse(tr("There is no checkpoint before this message to rewind to."));
    m_thread = thread;
    m_row = rowId;
    m_point = point;
    publish();
  }

  void confirm(bool restoreFiles) {
    if (m_thread.isEmpty() || m_working) return;
    auto* composer = NativeShell::of(this)->controller<ComposerController>();
    const QString thread = m_thread;
    const QVariantMap point = m_point;
    cancel();
    if (composer->attachmentsPending(thread)) return refuse(tr("Wait for attachments to finish preparing before rewinding."));
    const QVariantList attachments = point.value(QStringLiteral("attachments")).toList();
    if (composer->attachments(thread).size() + attachments.size() > maxAttachments) {
      return refuse(tr("Make room for this message's attachments in the composer before rewinding."));
    }
    m_working = true;
    // The attachments first: a rewind that cannot give them back does not happen.
    auto fetched = std::make_shared<QVariantList>();
    fetch(thread, point, attachments, 0, fetched, restoreFiles);
  }

  void fetch(const QString& thread, const QVariantMap& point, const QVariantList& attachments, qsizetype index, std::shared_ptr<QVariantList> fetched,
             bool restoreFiles) {
    const QString environment = thread.left(thread.indexOf(QLatin1Char(':')));
    if (index >= attachments.size()) return rollBack(thread, point, *fetched, restoreFiles);
    const QVariantMap attachment = attachments.at(index).toMap();
    const auto failed = [this](const QString& why) {
      m_working = false;
      refuse(why.isEmpty() ? tr("This message's attachments could not be read.") : why);
    };
    m_client->call(this, environment, QStringLiteral("assets.createUrl"),
                   QJsonObject{{QStringLiteral("resource"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("attachment")},
                                                                         {QStringLiteral("attachmentId"), attachment.value(QStringLiteral("id")).toString()},
                                                                         {QStringLiteral("fileName"), attachment.value(QStringLiteral("name")).toString()},
                                                                         {QStringLiteral("mimeType"), attachment.value(QStringLiteral("mimeType")).toString()}}}},
                   [=, this](const QJsonValue& result, const std::optional<QString>& error) {
                     if (error) return failed(*error);
                     m_client->download(this, result.toObject().value(QLatin1String("relativeUrl")).toString(),
                                        [=, this](const QByteArray& bytes, const std::optional<QString>& error) {
                                          if (error) return failed(*error);
                                          QVariantMap file{{QStringLiteral("name"), attachment.value(QStringLiteral("name"))},
                                                           {QStringLiteral("mimeType"), attachment.value(QStringLiteral("mimeType"))}};
                                          if (attachment.value(QStringLiteral("type")) == QLatin1String("image")) {
                                            file.insert(QStringLiteral("base64"), QString::fromLatin1(bytes.toBase64()));
                                          } else {
                                            // A file goes back as a file of this machine, sent again with the next message.
                                            const QDir folder(QDir::temp().filePath(QStringLiteral("hal-c2-rewind/") + attachment.value(QStringLiteral("id")).toString()));
                                            QFile copy(folder.filePath(attachment.value(QStringLiteral("name")).toString()));
                                            if (!folder.mkpath(QStringLiteral(".")) || !copy.open(QIODevice::WriteOnly) || copy.write(bytes) < 0) return failed(copy.errorString());
                                            file.insert(QStringLiteral("path"), copy.fileName());
                                          }
                                          fetched->append(file);
                                          fetch(thread, point, attachments, index + 1, fetched, restoreFiles);
                                        });
                   });
  }

  void rollBack(const QString& thread, const QVariantMap& point, const QVariantList& files, bool restoreFiles) {
    const QString environment = thread.left(thread.indexOf(QLatin1Char(':')));
    m_client->dispatchCommand(this, environment,
                              {{QStringLiteral("type"), QStringLiteral("checkpoint.rollback")},
                               {QStringLiteral("threadId"), thread.mid(thread.indexOf(QLatin1Char(':')) + 1)},
                               {QStringLiteral("checkpointId"), point.value(QStringLiteral("checkpointId")).toString()},
                               {QStringLiteral("scopeId"), point.value(QStringLiteral("scopeId")).toString()},
                               {QStringLiteral("restoreFiles"), restoreFiles}},
                              [this, thread, point, files](const QJsonValue&, const std::optional<QString>& error) {
                                m_working = false;
                                if (error) return refuse(error->isEmpty() ? tr("Failed to revert thread state.") : *error);
                                // The prompt after what the composer holds, then the attachments.
                                auto* composer = NativeShell::of(this)->controller<ComposerController>();
                                const QString current = composer->draft(thread);
                                const QString prompt = point.value(QStringLiteral("text")).toString().trimmed();
                                const QString next = prompt.isEmpty() ? current : current.isEmpty() ? prompt : current + QStringLiteral("\n\n") + prompt;
                                // Only the thread the window still shows takes them in its composer.
                                if (NativeShell::of(this)->controller<NavigationController>()->threadKey() != thread) return;
                                m_bridge->dispatch(QStringLiteral("composer.text.set"),
                                                   QVariantMap{{QStringLiteral("target"), thread}, {QStringLiteral("text"), next}, {QStringLiteral("cursor"), next.size()}});
                                if (!files.isEmpty()) m_bridge->dispatch(QStringLiteral("composer.attach"), QVariantMap{{QStringLiteral("files"), files}});
                                m_bridge->sendToBricks(QStringLiteral("composer.focus"));
                              });
  }

  void publish() {
    m_bridge->publish(QStringLiteral("rewind"), m_thread.isEmpty() ? QVariant::fromValue(nullptr)
                                                                   : QVariant(QVariantMap{{QStringLiteral("threadKey"), m_thread},
                                                                                          {QStringLiteral("rowId"), m_row},
                                                                                          {QStringLiteral("turn"), m_point.value(QStringLiteral("turn"))}}));
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  // The thread and message the user is asked about; empty when not asked.
  QString m_thread;
  QString m_row;
  QVariantMap m_point;
  // A rewind is fetching attachments or waiting for the MC.
  bool m_working = false;
};

namespace {
const NativeControllerRegistrar<RewindController> registrar(QStringLiteral("rewind"), {QStringLiteral("rewind")});
}  // namespace
