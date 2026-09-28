#include "ComposerController.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QQmlPropertyMap>
#include <QUuid>

#include <memory>

#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"

ComposerController::ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                       QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

bool ComposerController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  if (action == QLatin1String("composer.interrupt")) return interrupt();
  if (action == QLatin1String("composer.submit")) return submit(payload.toMap());
  return false;
}

// Stops the thread's active run, or the latest one while it still waits on
// the provider or background work, as client-runtime's interruptThreadTurn.
bool ComposerController::interrupt() {
  const QVariantMap composer = m_bridge->state()->value(QStringLiteral("composer")).toMap();
  if (composer.value(QStringLiteral("routeKind")).toString() != QLatin1String("server")) return false;
  const auto thread = m_store->thread(composer.value(QStringLiteral("target")).toString());
  if (!thread) return false;
  sidebar::Nullable runId = thread->activeRunId;
  if (!runId && (thread->activityRunStatus == QStringLiteral("waiting") || thread->pendingBackgroundTasks > 0)) {
    runId = thread->latestRunId;
  }
  if (!runId) return true;
  m_client->dispatchCommand(thread->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("run.interrupt")},
                                {QStringLiteral("threadId"), thread->id},
                                {QStringLiteral("runId"), *runId},
                            },
                            [this](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) {
                                toast(QStringLiteral("Failed to interrupt the current turn."), *error);
                              }
                            });
  return true;
}

// A plain send: the page vouches for it in `composer.nativeSend` (computed for
// the prompt it last saw), this sets the thread's modes if they changed and
// dispatches the message. The page's draft clears at once and comes back if
// the node refuses.
bool ComposerController::submit(const QVariantMap& payload) {
  const QVariantMap composer = m_bridge->state()->value(QStringLiteral("composer")).toMap();
  const QVariant nativeSendValue = composer.value(QStringLiteral("nativeSend"));
  if (nativeSendValue.typeId() != QMetaType::QVariantMap) return false;
  const QVariantMap nativeSend = nativeSendValue.toMap();
  const QString prompt = nativeSend.value(QStringLiteral("prompt")).toString();
  // Typed after the page last looked: let the page validate the newer text.
  if (payload.contains(QStringLiteral("text")) && payload.value(QStringLiteral("text")).toString() != prompt) {
    return false;
  }
  // A background send queues behind the running turn: the page's pipeline.
  if (payload.value(QStringLiteral("intent"), QStringLiteral("foreground")).toString() != QLatin1String("foreground")) {
    return false;
  }
  const QString target = composer.value(QStringLiteral("target")).toString();
  if (composer.value(QStringLiteral("routeKind")).toString() != QLatin1String("server")) return false;
  const auto thread = m_store->thread(target);
  if (!thread) return false;
  if (m_sending.contains(target)) return true;
  m_sending.insert(target);

  const QString createdAt = sidebar::formatIso(m_now());
  const QString runtimeMode = nativeSend.value(QStringLiteral("runtimeMode")).toString();
  const QString interactionMode = nativeSend.value(QStringLiteral("interactionMode")).toString();
  QList<QJsonObject> commands;
  if (!runtimeMode.isEmpty() && runtimeMode != thread->runtimeMode) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.runtime-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("runtimeMode"), runtimeMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  if (!interactionMode.isEmpty() && interactionMode != thread->interactionMode) {
    commands.append({
        {QStringLiteral("type"), QStringLiteral("thread.interaction-mode.set")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("interactionMode"), interactionMode},
        {QStringLiteral("createdAt"), createdAt},
    });
  }
  commands.append({
      {QStringLiteral("type"), QStringLiteral("message.dispatch")},
      {QStringLiteral("createdBy"), QStringLiteral("user")},
      {QStringLiteral("creationSource"), QStringLiteral("web")},
      {QStringLiteral("threadId"), thread->id},
      {QStringLiteral("messageId"), QUuid::createUuid().toString(QUuid::WithoutBraces)},
      {QStringLiteral("text"), nativeSend.value(QStringLiteral("text")).toString()},
      {QStringLiteral("attachments"), QJsonArray()},
      {QStringLiteral("titleSeed"), nativeSend.value(QStringLiteral("titleSeed")).toString()},
      {QStringLiteral("modelSelection"), QJsonObject::fromVariantMap(nativeSend.value(QStringLiteral("modelSelection")).toMap())},
      {QStringLiteral("deliveryIntent"), QStringLiteral("auto")},
      {QStringLiteral("dispatchMode"), QJsonObject{{QStringLiteral("type"), QStringLiteral("start_immediately")}}},
  });

  // The same edit the brick sent, so it takes the cleared (or restored) text
  // as the answer to its own submit.
  const QVariant edit = payload.value(QStringLiteral("edit"));
  auto setText = [this, target, edit](const QString& text) {
    QVariantMap request{
        {QStringLiteral("target"), target},
        {QStringLiteral("text"), text},
        {QStringLiteral("cursor"), text.size()},
    };
    if (edit.isValid()) request.insert(QStringLiteral("edit"), edit);
    m_bridge->sendToPage(QStringLiteral("composer.text.set"), request);
  };
  setText(QString());

  const QString environmentId = thread->environmentId;
  auto next = std::make_shared<std::function<void(qsizetype)>>();
  *next = [this, commands, environmentId, next, prompt, target, setText](qsizetype index) {
    m_client->dispatchCommand(
        environmentId, commands.at(index),
        [this, commands, index, next, prompt, target, setText](const QJsonValue&, const std::optional<QString>& error) {
          if (!error && index + 1 < commands.size()) {
            (*next)(index + 1);
            return;
          }
          m_sending.remove(target);
          // Break the self-reference once the chain is done.
          const auto done = std::move(*next);
          if (!error) return;
          toast(QStringLiteral("Failed to send message"), *error);
          const QVariantMap now = m_bridge->state()->value(QStringLiteral("composer")).toMap();
          // Only into an untouched composer: newer typing is the user's.
          if (now.value(QStringLiteral("target")).toString() == target &&
              now.value(QStringLiteral("text")).toString().isEmpty()) {
            setText(prompt);
          }
        });
  };
  (*next)(0);
  return true;
}

void ComposerController::toast(const QString& title, const QString& description) {
  m_bridge->sendToPage(QStringLiteral("toast.show"),
                       QVariantMap{
                           {QStringLiteral("toastType"), QStringLiteral("error")},
                           {QStringLiteral("title"), title},
                           {QStringLiteral("description"),
                            description.isEmpty() ? QStringLiteral("An error occurred.") : description},
                       });
}
