#include "ToastController.h"

#include "ShellBridge.h"

#include <algorithm>

namespace {

const NativeControllerRegistrar<ToastController> registrar(QStringLiteral("toasts"), {QStringLiteral("toasts")});

// The web app's toasts stack at most this many; older ones drop off the bottom.
constexpr qsizetype kMaxToasts = 5;

}  // namespace

ToastController::ToastController(ShellBridge* bridge, McClient*, QObject* parent)
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
  if (action == QLatin1String("notification.action")) {
    const int index = payload.toMap().value(QStringLiteral("actionId")).toString() == QLatin1String("secondary") ? 1 : 0;
    for (const Toast& toast : m_toasts) {
      if (toast.id != id || index >= toast.actions.size()) continue;
      // Dismissed first: the action may show a toast of its own.
      const Action chosen = toast.actions.at(index);
      if (!chosen.keepsToast) dismiss(id);
      if (chosen.run) chosen.run();
      return true;
    }
    // A click on an action the toast no longer offers (replace() changed
    // them under the pointer) leaves it be.
    return true;
  }
  const bool closed = action == QLatin1String("notification.dismiss") &&
                      std::any_of(m_toasts.cbegin(), m_toasts.cend(), [&id](const Toast& toast) { return toast.id == id; });
  dismiss(id);
  if (closed) emit closedByUser(id);
  return true;
}

QString ToastController::show(const QString& type, const QString& title, const QString& description,
                              std::optional<Action> action, int timeoutMs) {
  return showActions(type, title, description, action ? QList<Action>{std::move(*action)} : QList<Action>{}, timeoutMs);
}

QString ToastController::showActions(const QString& type, const QString& title, const QString& description,
                                     QList<Action> actions, int timeoutMs) {
  Toast toast{QStringLiteral("native:%1").arg(m_nextId++), type, title, description, std::move(actions), {}};
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
  // Newest first: the newest toast offering it, and the ones straight after
  // it that offer it for the same group.
  QList<std::pair<QString, QString>> chosen;  // toast id, action id
  QString group;
  for (const Toast& toast : std::as_const(m_toasts)) {
    // Of the two actions a toast shows; a third has no button to click.
    qsizetype found = -1;
    for (qsizetype index = 0; index < std::min<qsizetype>(toast.actions.size(), 2) && found < 0; ++index) {
      if (toast.actions.at(index).label == label) found = index;
    }
    if (found < 0) {
      if (chosen.isEmpty()) continue;
      break;
    }
    const QString& its = toast.actions.at(found).group;
    if (!chosen.isEmpty() && (group.isEmpty() || its != group)) break;
    group = its;
    chosen.append({toast.id, found == 0 ? QStringLiteral("primary") : QStringLiteral("secondary")});
  }
  for (const auto& [id, actionId] : std::as_const(chosen)) {
    handle(QStringLiteral("notification.action"),
           QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("actionId"), actionId}});
  }
  return !chosen.isEmpty();
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

bool ToastController::replace(const QString& id, const QString& type, const QString& title,
                              const QString& description, QList<Action> actions, int timeoutMs) {
  for (Toast& toast : m_toasts) {
    if (toast.id != id) continue;
    toast.type = type;
    toast.title = title;
    toast.description = description;
    toast.actions = std::move(actions);
    toast.deadline = timeoutMs > 0 ? std::optional(m_now().addMSecs(timeoutMs)) : std::nullopt;
    ++toast.revision;
    publish();
    schedule();
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
    // The lesser action sits before the primary one.
    QVariantList actions;
    for (qsizetype index = std::min<qsizetype>(toast.actions.size(), 2) - 1; index >= 0; --index) {
      actions.append(QVariantMap{
          {QStringLiteral("id"), index == 0 ? QStringLiteral("primary") : QStringLiteral("secondary")},
          {QStringLiteral("label"), toast.actions.at(index).label},
          {QStringLiteral("primary"), index == 0},
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
