#include "ComputerNoticeController.h"

#include <QVariantMap>

#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThisMachine.h"
#include "ThreadStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ComputerNoticeController> registrar(QStringLiteral("threadComputer"),
                                                                    {QStringLiteral("threadComputer")});

const QString kKey = QStringLiteral("threadComputer");

}  // namespace

ComputerNoticeController::ComputerNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                                   QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &ComputerNoticeController::expire);
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant& value) {
    if (key == QLatin1String("serverUpdates")) seeComputers(value);
  });
  // Whether the cluster still tries a computer comes with the shell's frames;
  // and the client's own MC may change hands: which computer is "another" with
  // it.
  connect(store, &ShellStore::changed, this, [this] {
    seeComputers(m_bridge->state()->value(QStringLiteral("serverUpdates")));
    showThread();
  });
}

void ComputerNoticeController::activate() {
  if (auto* threads = NativeShell::of(this)->controller<ThreadStore>()) {
    connect(threads, &ThreadStore::activeThreadChanged, this, &ComputerNoticeController::showThread,
            Qt::UniqueConnection);
  }
  seeComputers(m_bridge->state()->value(QStringLiteral("serverUpdates")));
  showThread();
  m_bridge->publish(kKey, QVariant::fromValue(nullptr));
  changed(true);
}

void ComputerNoticeController::seeComputers(const QVariant& serverUpdates) {
  const QVariantMap state = serverUpdates.toMap();
  const QString appVersion = state.value(QStringLiteral("appVersion")).toString();
  QSet<QString> seen;
  bool moved = false;
  for (const QVariant& entry : state.value(QStringLiteral("machines")).toList()) {
    const QVariantMap machine = entry.toMap();
    const QString version = machine.value(QStringLiteral("version")).toString();
    ComputerNotice::Computer computer{
        machine.value(QStringLiteral("environmentId")).toString(), machine.value(QStringLiteral("label")).toString(),
        machine.value(QStringLiteral("online")).toBool(), machine.value(QStringLiteral("updating")).toBool(),
        !appVersion.isEmpty() && !version.isEmpty() && version != appVersion};
    computer.trying = m_store->environmentTrying(computer.id);
    computer.local = thisMachine::hosts(*m_store, *m_client, computer.id);
    seen.insert(computer.id);
    moved = m_notice.see(computer, nowMs()) || moved;
  }
  for (const QString& gone : m_seen - seen) moved = m_notice.forget(gone, nowMs()) || moved;
  m_seen = seen;
  changed(moved);
}

void ComputerNoticeController::showThread() {
  const NativeWindow* window = NativeShell::of(this);
  const ThreadStore* threads = window ? window->controller<ThreadStore>() : nullptr;
  const QString key = threads ? threads->activeThread() : QString();
  QString environment = key.section(QLatin1Char(':'), 0, 0);
  // The computer this client connects to has the window's own notice.
  if (environment == m_store->environmentOf(m_client->mc())) environment.clear();
  changed(m_notice.show(environment, nowMs()));
}

bool ComputerNoticeController::handle(const QString& action, const QVariant& payload) {
  const bool reconnect = action == QLatin1String("threadComputer.reconnect");
  if (!reconnect && action != QLatin1String("threadComputer.disconnect")) return false;
  const QString id = payload.toMap().value(QStringLiteral("environmentId")).toString();
  const auto& notice = m_notice.notice();
  // Only what the notice offers, for the computer it is about.
  if (!notice || notice->environmentId != id || !(reconnect ? notice->canReconnect : notice->canDisconnect))
    return true;
  if (reconnect) {
    ask(QStringLiteral("cluster.reconnect"), {{QStringLiteral("id"), id}}, tr("Could not reconnect environment"),
        [] {});
  } else {
    ask(QStringLiteral("cluster.switch"), {{QStringLiteral("id"), id}, {QStringLiteral("on"), false}},
        tr("Could not disconnect server"), [this] {
          if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
            navigation->open(NavigationController::Route::of(QStringLiteral("home")));
          }
        });
  }
  return true;
}

void ComputerNoticeController::ask(const QString& method, const QJsonObject& payload, const QString& failure,
                                   std::function<void()> done) {
  m_client->call(this, m_client->environment(), method, payload,
                 [this, failure, done = std::move(done)](const QJsonValue&, const std::optional<QString>& error) {
                   if (!error) return done();
                   if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                     toasts->show(QStringLiteral("error"), failure, *error);
                   }
                 });
}

void ComputerNoticeController::expire() {
  changed(m_notice.advance(nowMs()));
}

void ComputerNoticeController::changed(bool changed) {
  if (const auto deadline = m_notice.nextDeadline(nowMs())) {
    m_timer.start(int(std::max<qint64>(*deadline - nowMs(), 0)));
  } else {
    m_timer.stop();
  }
  if (!changed) return;
  const auto& notice = m_notice.notice();
  m_bridge->publish(kKey, notice ? QVariant(QVariantMap{{QStringLiteral("kind"), notice->kind},
                                                        {QStringLiteral("environmentId"), notice->environmentId},
                                                        {QStringLiteral("title"), notice->title},
                                                        {QStringLiteral("detail"), notice->detail},
                                                        {QStringLiteral("canReconnect"), notice->canReconnect},
                                                        {QStringLiteral("canDisconnect"), notice->canDisconnect}})
                                 : QVariant::fromValue(nullptr));
}
