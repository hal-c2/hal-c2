// What the open thread says of its place in the list: a settled thread says
// so above the composer, and can be un-settled from there, as the web's
// parked-thread banner did (features/threads/settle.feature). Sending a
// message un-settles it too; the MC does that.
//
// Publishes `threadNotice`: null unless the open thread is settled, else
// {threadKey, kind ("settled"), title, description, actionLabel, busy}.
//
// Action: `threadNotice.unsettle` un-settles the open thread. While the MC
// answers, the notice reads "Un-settling..." for that thread only; a refusal
// is a toast, and the thread stays settled.

#include <QJsonObject>
#include <QSet>
#include <QVariantMap>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

class ThreadNoticeController : public QObject, public NativeController {
public:
  ThreadNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, &ThreadNoticeController::publish);
    connect(m_store, &ShellStore::changed, this, &ThreadNoticeController::publish);
    publish();
  }

  bool handle(const QString& action, const QVariant&) override {
    if (!m_active || action != QLatin1String("threadNotice.unsettle")) return false;
    const QString key = openKey();
    if (!settled(key) || m_pending.contains(key)) return true;
    m_pending.insert(key);
    publish();
    const qsizetype colon = key.indexOf(QLatin1Char(':'));
    m_client->dispatchCommand(this, key.left(colon),
                              {{QStringLiteral("type"), QStringLiteral("thread.unsettle")},
                               {QStringLiteral("threadId"), key.mid(colon + 1)},
                               {QStringLiteral("reason"), QStringLiteral("user")}},
                              [this, key](const QJsonValue&, const std::optional<QString>& error) {
                                m_pending.remove(key);
                                if (error) {
                                  if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                                    toasts->error(QStringLiteral("Failed to un-settle thread"), *error);
                                  }
                                }
                                publish();
                              });
    return true;
  }

private:
  QString openKey() const {
    return NativeShell::of(this)->controller<NavigationController>()->threadKey();
  }

  bool settled(const QString& key) const {
    if (key.isEmpty()) return false;
    const auto thread = m_store->thread(key);
    return thread && m_store->capabilities(thread->environmentId).settlement && thread->settledOverride.value_or(QString()) == QLatin1String("settled");
  }

  void publish() {
    if (!m_active) return;
    const QString key = openKey();
    if (!settled(key)) {
      m_bridge->publish(QStringLiteral("threadNotice"), QVariant::fromValue(nullptr));
      return;
    }
    const bool busy = m_pending.contains(key);
    m_bridge->publish(QStringLiteral("threadNotice"),
                      QVariantMap{{QStringLiteral("threadKey"), key},
                                  {QStringLiteral("kind"), QStringLiteral("settled")},
                                  {QStringLiteral("title"), QStringLiteral("This thread is settled")},
                                  {QStringLiteral("description"), QStringLiteral("Send a message to unsettle")},
                                  {QStringLiteral("actionLabel"), busy ? QStringLiteral("Un-settling...") : QStringLiteral("Un-settle")},
                                  {QStringLiteral("busy"), busy}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  // Threads whose un-settle the MC has not answered yet.
  QSet<QString> m_pending;
};

namespace {
const NativeControllerRegistrar<ThreadNoticeController> registrar(QStringLiteral("threadNotice"), {QStringLiteral("threadNotice")});
}  // namespace
