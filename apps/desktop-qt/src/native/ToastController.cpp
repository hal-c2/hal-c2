#include "ToastController.h"

#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<ToastController> registrar(QStringLiteral("toasts"), {QStringLiteral("toasts")});

// The page's toasts stack at most this many; older ones drop off the bottom.
constexpr qsizetype kMaxToasts = 5;

}  // namespace

ToastController::ToastController(ShellBridge* bridge, NodeClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &ToastController::expire);
}

void ToastController::activate() {
  publish();
}

bool ToastController::handle(const QString& action, const QVariant& payload) {
  if (action != QLatin1String("notification.dismiss") && action != QLatin1String("notification.action")) {
    return false;
  }
  const QString id = payload.toMap().value(QStringLiteral("id")).toString();
  if (!id.startsWith(QLatin1String("native:"))) return false;
  if (action == QLatin1String("notification.action")) {
    for (const Toast& toast : m_toasts) {
      if (toast.id != id || !toast.action) continue;
      // Dismissed first: the action may show a toast of its own.
      const std::function<void()> run = toast.action->run;
      dismiss(id);
      if (run) run();
      return true;
    }
  }
  dismiss(id);
  return true;
}

QString ToastController::show(const QString& type, const QString& title, const QString& description,
                              std::optional<Action> action, int timeoutMs) {
  Toast toast{QStringLiteral("native:%1").arg(m_nextId++), type, title, description, std::move(action), {}};
  if (timeoutMs > 0) toast.deadline = m_now().addMSecs(timeoutMs);
  m_toasts.prepend(std::move(toast));
  while (m_toasts.size() > kMaxToasts) m_toasts.removeLast();
  publish();
  schedule();
  return m_toasts.first().id;
}

QString ToastController::error(const QString& title, const QString& description) {
  return show(QStringLiteral("error"), title,
              description.isEmpty() ? QStringLiteral("An error occurred.") : description);
}

bool ToastController::runAction(const QString& label) {
  // Newest first.
  for (const Toast& toast : std::as_const(m_toasts)) {
    if (!toast.action || toast.action->label != label) continue;
    handle(QStringLiteral("notification.action"), QVariantMap{{QStringLiteral("id"), toast.id}});
    return true;
  }
  return false;
}

void ToastController::dismiss(const QString& id) {
  const qsizetype removed = m_toasts.removeIf([&id](const Toast& toast) { return toast.id == id; });
  if (removed == 0) return;
  publish();
  schedule();
}

bool ToastController::update(const QString& id, const QString& title, const QString& description) {
  for (Toast& toast : m_toasts) {
    if (toast.id != id) continue;
    if (toast.title == title && toast.description == description) return true;
    toast.title = title;
    toast.description = description;
    ++toast.revision;
    publish();
    return true;
  }
  return false;
}

void ToastController::expire() {
  const QDateTime now = m_now();
  const qsizetype removed =
      m_toasts.removeIf([&now](const Toast& toast) { return toast.deadline && *toast.deadline <= now; });
  if (removed > 0) publish();
  schedule();
}

void ToastController::schedule() {
  std::optional<QDateTime> next;
  for (const Toast& toast : m_toasts) {
    if (toast.deadline && (!next || *toast.deadline < *next)) next = toast.deadline;
  }
  if (!next) {
    m_timer.stop();
    return;
  }
  m_timer.start(std::max<qint64>(0, m_now().msecsTo(*next)));
}

void ToastController::publish() {
  QVariantList items;
  for (const Toast& toast : m_toasts) {
    QVariantList actions;
    if (toast.action) {
      actions.append(QVariantMap{
          {QStringLiteral("id"), QStringLiteral("primary")},
          {QStringLiteral("label"), toast.action->label},
          {QStringLiteral("primary"), true},
      });
    }
    items.append(QVariantMap{
        {QStringLiteral("id"), toast.id},
        {QStringLiteral("type"), toast.type},
        {QStringLiteral("title"), toast.title},
        {QStringLiteral("description"),
         toast.description.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(toast.description)},
        {QStringLiteral("updateKey"), toast.revision},
        {QStringLiteral("actions"), actions},
    });
  }
  m_bridge->publish(QStringLiteral("toasts"), QVariantMap{{QStringLiteral("items"), items}});
}
