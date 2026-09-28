#include "SidebarController.h"

#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

QString keyOf(const QVariantMap& payload) {
  return payload.value(QStringLiteral("key")).toString();
}

QVariant nullVariant() {
  return QVariant::fromValue(nullptr);
}

}  // namespace

SidebarController::SidebarController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                     QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_minute.setSingleShot(true);
  // Snoozes wake and "2h" labels tick over on the minute, as the page's nowMinute.
  connect(&m_minute, &QTimer::timeout, this, &SidebarController::refresh);
  connect(store, &ShellStore::changed, this, &SidebarController::refresh);
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant& value) {
    if (key != QLatin1String("sidebarInput")) return;
    m_input = sidebar::Input::fromVariant(value);
    m_inputReceived = true;
    refresh();
  });
}

void SidebarController::activate() {
  m_active = true;
  refresh();
}

void SidebarController::refresh() {
  if (!m_active) return;
  // A scope whose project went away (removed, regrouped) shows everything again.
  if (m_inputReceived && m_scope && m_input.group(*m_scope) == nullptr) m_scope.reset();
  const QDateTime now = m_now();
  m_view = sidebar::build(m_store->threads(), m_input, m_scope,
                          [this](const QString& environmentId) { return m_store->capabilities(environmentId); },
                          now.toMSecsSinceEpoch());
  m_bridge->publish(QStringLiteral("sidebar"), m_view.state);
  const QTime time = now.time();
  m_minute.start(std::max(1000, 60000 - time.second() * 1000 - time.msec()));
}

bool SidebarController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("sidebar.scope")) {
    const QVariant projectKey = map.value(QStringLiteral("projectKey"));
    m_scope = projectKey.typeId() == QMetaType::QString ? sidebar::Nullable(projectKey.toString())
                                                        : std::nullopt;
    refresh();
    // The page still walks the list for its thread-traversal keybindings.
    m_bridge->sendToPage(action, payload);
    return true;
  }
  if (action == QLatin1String("contextMenu.select")) {
    const QString requestId = map.value(QStringLiteral("requestId")).toString();
    if (!requestId.startsWith(QLatin1String("native:"))) return false;
    if (m_menu && m_menu->requestId == requestId) {
      m_bridge->publish(QStringLiteral("contextMenu"), nullVariant());
      const QVariant id = map.value(QStringLiteral("id"));
      if (id.typeId() == QMetaType::QString) selectSnooze(id.toString());
      m_menu.reset();
    }
    return true;
  }

  static const QStringList kRowActions{
      QStringLiteral("thread.settle"),     QStringLiteral("thread.unsettle"),
      QStringLiteral("thread.unsnooze"),   QStringLiteral("thread.snoozeMenu"),
      QStringLiteral("thread.wokeDismiss"), QStringLiteral("thread.markUnread"),
  };
  if (!kRowActions.contains(action)) return false;
  const QString key = keyOf(map);
  // A thread the node's cluster does not know (an environment the page paired
  // by itself) stays with the page.
  const auto thread = m_store->thread(key);
  if (!thread) return false;
  const QJsonObject target{{QStringLiteral("threadId"), thread->id}};
  auto with = [&target](std::initializer_list<std::pair<QString, QJsonValue>> fields) {
    QJsonObject command = target;
    for (const auto& [name, value] : fields) command.insert(name, value);
    return command;
  };

  if (action == QLatin1String("thread.settle")) {
    park(key, with({{QStringLiteral("type"), QStringLiteral("thread.settle")}}),
         QStringLiteral("Failed to settle thread"));
  } else if (action == QLatin1String("thread.unsettle")) {
    command(thread->environmentId,
            with({{QStringLiteral("type"), QStringLiteral("thread.unsettle")},
                  {QStringLiteral("reason"), QStringLiteral("user")}}),
            QStringLiteral("Failed to un-settle thread"));
  } else if (action == QLatin1String("thread.unsnooze")) {
    command(thread->environmentId,
            with({{QStringLiteral("type"), QStringLiteral("thread.unsnooze")},
                  {QStringLiteral("reason"), QStringLiteral("user")}}),
            QStringLiteral("Failed to wake thread"));
  } else if (action == QLatin1String("thread.snoozeMenu")) {
    openSnoozeMenu(key, map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble());
  } else if (action == QLatin1String("thread.wokeDismiss")) {
    // Visiting up to the wake clears the pill without opening the thread.
    const auto wokeAt = sidebar::wokeAt(*thread, m_now().toMSecsSinceEpoch());
    if (wokeAt) {
      command(thread->environmentId,
              with({{QStringLiteral("type"), QStringLiteral("thread.visit")},
                    {QStringLiteral("visitedAt"), *wokeAt}}),
              QString());
    }
  } else {
    command(thread->environmentId, with({{QStringLiteral("type"), QStringLiteral("thread.mark-unread")}}),
            QString());
  }
  return true;
}

void SidebarController::command(const QString& environmentId, QJsonObject command, const QString& failureTitle,
                                std::function<void()> onSuccess) {
  m_client->dispatchCommand(
      environmentId, std::move(command),
      [this, failureTitle, onSuccess = std::move(onSuccess)](const QJsonValue&, const std::optional<QString>& error) {
        if (!error) {
          if (onSuccess) onSuccess();
        } else if (!failureTitle.isEmpty()) {
          toast(QStringLiteral("error"), failureTitle,
                error->isEmpty() ? QStringLiteral("An error occurred.") : *error);
        }
      });
}

// Settling or snoozing the open thread moves to the next card that stays in
// the list (or a new thread in the same project), as the page's threadParking.
void SidebarController::park(const QString& key, QJsonObject parkCommand, const QString& failureTitle,
                             std::function<void()> onSuccess) {
  if (m_pending.contains(key)) return;
  const auto thread = m_store->thread(key);
  if (!thread) return;
  m_pending.insert(key);

  // Planned now, before the command reshuffles the list.
  std::function<void()> navigate;
  if (m_input.activeThreadKey == key) {
    const QStringList& keys = m_view.orderedKeys;
    const qsizetype index = keys.indexOf(key);
    std::optional<QString> next;
    if (index != -1) {
      for (qsizetype step = 1; step < keys.size(); ++step) {
        const QString& candidate = keys.at((index + step) % keys.size());
        if (!m_view.parkedKeys.contains(candidate)) {
          next = candidate;
          break;
        }
      }
    }
    if (next) {
      navigate = [this, next = *next] { m_bridge->sendToPage(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), next}}); };
    } else if (const auto projectKey = logicalProjectKey(*thread)) {
      navigate = [this, projectKey = *projectKey] {
        m_bridge->sendToPage(QStringLiteral("thread.new"), QVariantMap{{QStringLiteral("projectKey"), projectKey}});
      };
    }
  }

  m_client->dispatchCommand(
      thread->environmentId, std::move(parkCommand),
      [this, key, failureTitle, navigate = std::move(navigate), onSuccess = std::move(onSuccess)](
          const QJsonValue&, const std::optional<QString>& error) {
        m_pending.remove(key);
        if (error) {
          toast(QStringLiteral("error"), failureTitle,
                error->isEmpty() ? QStringLiteral("An error occurred.") : *error);
          return;
        }
        // A navigation made while the command was pending wins over the plan.
        if (navigate && m_input.activeThreadKey == key) navigate();
        if (onSuccess) onSuccess();
      });
}

std::optional<QString> SidebarController::logicalProjectKey(const sidebar::Thread& thread) const {
  const QString physicalKey = thread.environmentId + QLatin1Char(':') + thread.projectId;
  for (const sidebar::ProjectGroup& group : m_input.projects) {
    if (group.memberKeys.contains(physicalKey)) return group.key;
  }
  return std::nullopt;
}

void SidebarController::openSnoozeMenu(const QString& key, double x, double y) {
  const QList<sidebar::SnoozePreset> presets = sidebar::snoozePresets(m_now(), m_input.timestampFormat, m_locale);
  QVariantList items;
  for (const sidebar::SnoozePreset& preset : presets) {
    items.append(QVariantMap{
        {QStringLiteral("id"), QStringLiteral("snooze:") + preset.id},
        {QStringLiteral("label"), preset.label + QStringLiteral(" (") + preset.whenLabel + QLatin1Char(')')},
    });
  }
  m_menu = SnoozeMenu{QStringLiteral("native:%1").arg(m_nextMenuId++), key, presets};
  m_bridge->publish(QStringLiteral("contextMenu"), QVariantMap{
                                                       {QStringLiteral("requestId"), m_menu->requestId},
                                                       {QStringLiteral("surfaceId"), QStringLiteral("shell")},
                                                       {QStringLiteral("x"), x},
                                                       {QStringLiteral("y"), y},
                                                       {QStringLiteral("items"), items},
                                                   });
}

void SidebarController::selectSnooze(const QString& id) {
  const SnoozeMenu menu = *m_menu;
  for (const sidebar::SnoozePreset& preset : menu.presets) {
    if (QStringLiteral("snooze:") + preset.id != id) continue;
    const QString snoozedUntil = preset.snoozedUntil;
    const QString key = menu.key;
    const auto thread = m_store->thread(key);
    if (!thread) return;
    park(key,
         {{QStringLiteral("type"), QStringLiteral("thread.snooze")},
          {QStringLiteral("threadId"), thread->id},
          {QStringLiteral("snoozedUntil"), snoozedUntil}},
         QStringLiteral("Failed to snooze thread"), [this, key, snoozedUntil] {
           const QString when = sidebar::wakeDescription(snoozedUntil, m_now(), m_input.timestampFormat, m_locale);
           toast(QStringLiteral("success"), QStringLiteral("Snoozed until ") + when, QString(),
                 {
                     {QStringLiteral("timeout"), 5000},
                     {QStringLiteral("action"),
                      QVariantMap{
                          {QStringLiteral("label"), QStringLiteral("Undo")},
                          {QStringLiteral("dispatch"),
                           QVariantMap{
                               {QStringLiteral("type"), QStringLiteral("thread.unsnooze")},
                               {QStringLiteral("payload"), QVariantMap{{QStringLiteral("key"), key}}},
                           }},
                      }},
                 });
         });
    return;
  }
}

void SidebarController::toast(const QString& type, const QString& title, const QString& description,
                              const QVariantMap& extra) {
  QVariantMap payload = extra;
  payload.insert(QStringLiteral("toastType"), type);
  payload.insert(QStringLiteral("title"), title);
  if (!description.isEmpty()) payload.insert(QStringLiteral("description"), description);
  m_bridge->sendToPage(QStringLiteral("toast.show"), payload);
}
