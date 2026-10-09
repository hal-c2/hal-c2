#include "ToastController.h"

#include "KeybindingController.h"
#include "NativeShell.h"
#include "ShellBridge.h"

#include <algorithm>

namespace {

const NativeControllerRegistrar<ToastController> registrar(QStringLiteral("toasts"), {QStringLiteral("toasts")});

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
  if (action == QLatin1String("notification.expand")) {
    setExpanded(payload.toMap().value(QStringLiteral("expanded")).toBool());
    return true;
  }
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
  Toast toast{QStringLiteral("native:%1").arg(m_nextId++), type, title, description, std::move(actions)};
  startTime(toast, timeoutMs);
  m_toasts.prepend(std::move(toast));
  publish();
  schedule();
  return m_toasts.first().id;
}

QString ToastController::showUndo(const QString& group, const QString& title, std::function<void()> undo) {
  QString hint;
  if (const NativeWindow* window = NativeShell::of(this)) {
    if (auto* keys = window->controller<KeybindingController>()) hint = keys->shortcutLabel(QStringLiteral("thread.undo"));
  }
  const QString description = hint.isEmpty() ? QString() : tr("%1 to undo").arg(hint);
  const auto reading = [&](int count) {
    return count == 1 ? title : tr("%1 %2 threads").arg(group).arg(count);
  };
  // The action as the sidebar and the menu build it, over the earlier one it joins.
  const auto joined = [&](std::function<void()> earlier) {
    return Action{QStringLiteral("Undo"),
                  [undo, earlier] {
                    undo();
                    if (earlier) earlier();
                  },
                  false, group};
  };
  if (!m_toasts.isEmpty()) {
    Toast& newest = m_toasts.first();
    if (!newest.actions.isEmpty() && newest.actions.first().label == QLatin1String("Undo") && newest.actions.first().group == group) {
      const int count = newest.count + 1;
      const QString id = newest.id;
      replace(id, newest.type, reading(count), description, {joined(newest.actions.first().run)}, 5000);
      newest.count = count;
      return id;
    }
  }
  const QString id = show(QStringLiteral("success"), reading(1), description, joined({}));
  return id;
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
    toast.count = 1;
    startTime(toast, timeoutMs);
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

void ToastController::setExpanded(bool expanded) {
  if (expanded == m_expanded) return;
  if (expanded) {
    // Gone before it holds: a toast already due does not linger.
    expire();
    if (m_toasts.isEmpty()) return;
  }
  m_expanded = expanded;
  const QDateTime now = m_now();
  for (Toast& toast : m_toasts) {
    if (expanded && toast.deadline) {
      toast.remainingMs = now.msecsTo(*toast.deadline);
      toast.deadline.reset();
    } else if (!expanded && toast.remainingMs > 0) {
      toast.deadline = now.addMSecs(toast.remainingMs);
      toast.remainingMs = 0;
    }
  }
  publish();
  schedule();
}

void ToastController::startTime(Toast& toast, int timeoutMs) {
  toast.deadline.reset();
  toast.remainingMs = 0;
  if (timeoutMs <= 0) return;
  if (m_expanded) {
    toast.remainingMs = timeoutMs;
  } else {
    toast.deadline = m_now().addMSecs(timeoutMs);
  }
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
  // An empty stack has nothing to hold open (Base UI's hover ends with it).
  if (m_toasts.isEmpty()) m_expanded = false;
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
  m_bridge->publish(QStringLiteral("toasts"),
                    QVariantMap{{QStringLiteral("items"), items}, {QStringLiteral("expanded"), m_expanded}});
}
