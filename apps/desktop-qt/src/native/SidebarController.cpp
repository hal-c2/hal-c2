#include "SidebarController.h"

#include "ComposerController.h"
#include "DraftController.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

QString keyOf(const QVariantMap& payload) {
  return payload.value(QStringLiteral("key")).toString();
}

}  // namespace

SidebarController::SidebarController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                     QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_minute.setSingleShot(true);
  // Snoozes wake and "2h" labels tick over on the minute, as the page's nowMinute.
  connect(&m_minute, &QTimer::timeout, this, &SidebarController::refresh);
  connect(store, &ShellStore::changed, this, &SidebarController::refresh);
}

void SidebarController::activate() {
  m_active = true;
  refresh();
}

const sidebar::ProjectGroup* SidebarController::group(const QString& key) const {
  for (const sidebar::ProjectGroup& group : m_groups) {
    if (group.key == key) return &group;
  }
  return nullptr;
}

std::optional<QString> SidebarController::logicalProjectKey(const QString& environmentId,
                                                            const QString& projectId) const {
  const QString physicalKey = environmentId + QLatin1Char(':') + projectId;
  for (const sidebar::ProjectGroup& group : m_groups) {
    if (group.memberKeys.contains(physicalKey)) return group.key;
  }
  return std::nullopt;
}

void SidebarController::refresh() {
  if (!m_active) return;
  readSettings();
  const QList<sidebar::Thread> threads = m_store->threads();
  const QString ownEnvironment = m_store->environmentOf(m_client->node());
  const auto shape = [this] {
    QStringList keys;
    for (const sidebar::ProjectGroup& group : m_groups) keys.append(group.key + QLatin1Char('=') + group.memberKeys.join(QLatin1Char(',')));
    return keys;
  };
  const QStringList before = shape();
  m_groups = sidebar::groupProjects(m_store->projects(), m_grouping, ownEnvironment, threads);
  const bool regrouped = shape() != before;
  // A scope whose project went away (removed, regrouped) shows everything again.
  if (m_scope && group(*m_scope) == nullptr) m_scope.reset();
  const QDateTime now = m_now();
  sidebar::Input input;
  input.projects = m_groups;
  if (!ownEnvironment.isEmpty()) input.localEnvironmentId = ownEnvironment;
  for (const QString& environment : m_store->environments()) {
    if (!m_store->environmentOnline(environment)) input.offlineEnvironments.insert(environment);
  }
  // The window's route marks the open thread or draft.
  input.activeDraftId = QVariant::fromValue(nullptr);
  QString openDraft;
  if (const auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
    const NavigationController::Route& route = navigation->route();
    if (route.kind == QLatin1String("thread")) input.activeThreadKey = route.threadKey;
    if (route.kind == QLatin1String("draft")) openDraft = route.draftId;
  }
  if (!openDraft.isEmpty()) input.activeDraftId = openDraft;
  const auto* composer = NativeShell::of(this)->controller<ComposerController>();
  const auto preview = [composer](const QString& id) { return composer ? composer->draftPreview(id) : std::nullopt; };
  if (openDraft != m_openDraftId) {
    m_openDraftId = openDraft;
    m_openDraftLabel = openDraft.isEmpty() ? std::nullopt : preview(openDraft);
  }
  m_draftLabels.clear();
  if (const auto* drafts = NativeShell::of(this)->controller<DraftController>()) {
    QList<const DraftController::Draft*> listed;
    for (const DraftController::Draft& draft : drafts->drafts()) {
      const auto label = draft.id == m_openDraftId ? m_openDraftLabel : preview(draft.id);
      if (!label) continue;
      m_draftLabels.insert(draft.id, *label);
      listed.append(&draft);
    }
    // Newest first; the stamps are ISO, so they sort as text.
    std::stable_sort(listed.begin(), listed.end(),
                     [](const auto* left, const auto* right) { return left->createdAt > right->createdAt; });
    for (const DraftController::Draft* draft : std::as_const(listed)) {
      const QString physical = draft->environmentId + QLatin1Char(':') + draft->projectId;
      input.drafts.append(QVariantMap{
          {QStringLiteral("draftId"), draft->id},
          {QStringLiteral("projectKey"), logicalProjectKey(draft->environmentId, draft->projectId).value_or(physical)},
          {QStringLiteral("label"), m_draftLabels.value(draft->id)},
      });
    }
  }
  m_view = sidebar::build(threads, input, m_scope,
                          [this](const QString& environmentId) { return m_store->capabilities(environmentId); },
                          now.toMSecsSinceEpoch());
  m_bridge->publish(QStringLiteral("sidebar"), m_view.state);
  const QTime time = now.time();
  m_minute.start(std::max(1000, 60000 - time.second() * 1000 - time.msec()));
  if (regrouped) emit grouped();
}

void SidebarController::draftEdited(const QString& id) {
  if (!m_active || id == m_openDraftId) return;
  const auto* composer = NativeShell::of(this)->controller<ComposerController>();
  const auto label = composer ? composer->draftPreview(id) : std::nullopt;
  const auto listed = m_draftLabels.constFind(id);
  if (listed == m_draftLabels.cend() ? label.has_value() : label != *listed) refresh();
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
  // An environment without visit tracking keeps unread and woke markers in the page.
  if ((action == QLatin1String("thread.markUnread") || action == QLatin1String("thread.wokeDismiss")) &&
      !m_store->capabilities(thread->environmentId).visitedTracking) {
    return false;
  }
  const QJsonObject target{{QStringLiteral("threadId"), thread->id}};
  auto with = [&target](std::initializer_list<std::pair<QString, QJsonValue>> fields) {
    QJsonObject command = target;
    for (const auto& [name, value] : fields) command.insert(name, value);
    return command;
  };

  if (action == QLatin1String("thread.settle")) {
    // Settling drops the pin; undoing puts it back where it was.
    const sidebar::Nullable pinOrderKey = thread->pinnedAt ? thread->pinOrderKey : sidebar::Nullable();
    const bool pinned = thread->pinnedAt.has_value();
    park(key, with({{QStringLiteral("type"), QStringLiteral("thread.settle")}}),
         QStringLiteral("Failed to settle thread"), [this, key, target, pinned, pinOrderKey] {
           toasts()->show(QStringLiteral("success"), QStringLiteral("Settled"), QString(),
                          ToastController::Action{QStringLiteral("Undo"), [this, key, target, pinned, pinOrderKey] {
                            const auto thread = m_store->thread(key);
                            if (!thread) return;
                            QJsonObject unsettle = target;
                            unsettle.insert(QStringLiteral("type"), QStringLiteral("thread.unsettle"));
                            unsettle.insert(QStringLiteral("reason"), QStringLiteral("user"));
                            command(thread->environmentId, unsettle, QStringLiteral("Failed to un-settle thread"),
                                    [this, environmentId = thread->environmentId, target, pinned, pinOrderKey] {
                                      if (!pinned) return;
                                      QJsonObject pin = target;
                                      pin.insert(QStringLiteral("type"), QStringLiteral("thread.pin"));
                                      if (pinOrderKey) pin.insert(QStringLiteral("orderKey"), *pinOrderKey);
                                      command(environmentId, pin, QStringLiteral("Failed to pin thread"));
                                    });
                          }});
         });
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
  m_client->dispatchCommand(this, 
      environmentId, std::move(command),
      [this, failureTitle, onSuccess = std::move(onSuccess)](const QJsonValue&, const std::optional<QString>& error) {
        if (!error) {
          if (onSuccess) onSuccess();
        } else if (!failureTitle.isEmpty()) {
          toasts()->error(failureTitle, *error);
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
  if (activeThreadKey() == key) {
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
      navigate = [this, next = *next] {
        NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::thread(next));
      };
    } else {
      // Nothing left to show: a new thread in the same project.
      navigate = [this, environmentId = thread->environmentId, projectId = thread->projectId] {
        if (auto* drafts = NativeShell::of(this)->controller<DraftController>()) drafts->start(environmentId, projectId);
      };
    }
  }

  m_client->dispatchCommand(this, 
      thread->environmentId, std::move(parkCommand),
      [this, key, failureTitle, navigate = std::move(navigate), onSuccess = std::move(onSuccess)](
          const QJsonValue&, const std::optional<QString>& error) {
        m_pending.remove(key);
        if (error) {
          toasts()->error(failureTitle, *error);
          return;
        }
        // A navigation made while the command was pending wins over the plan.
        if (navigate && activeThreadKey() == key) navigate();
        if (onSuccess) onSuccess();
      });
}

void SidebarController::openSnoozeMenu(const QString& key, double x, double y) {
  const QList<sidebar::SnoozePreset> presets = snoozePresets();
  QList<MenuController::Item> items;
  for (const sidebar::SnoozePreset& preset : presets) {
    items.append({QStringLiteral("snooze:") + preset.id, snoozeLabel(preset)});
  }
  NativeShell::of(this)->controller<MenuController>()->open(x, y, items, [this, key, presets](const QString& id) {
    for (const sidebar::SnoozePreset& preset : presets) {
      if (QStringLiteral("snooze:") + preset.id == id) snooze(key, preset.snoozedUntil);
    }
  });
}

QList<sidebar::SnoozePreset> SidebarController::snoozePresets() const {
  return sidebar::snoozePresets(m_now(), m_timestampFormat, m_locale);
}

QString SidebarController::snoozeLabel(const sidebar::SnoozePreset& preset) {
  return preset.label + QStringLiteral(" (") + preset.whenLabel + QLatin1Char(')');
}

void SidebarController::snooze(const QString& key, const QString& snoozedUntil) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  park(key,
       {{QStringLiteral("type"), QStringLiteral("thread.snooze")},
        {QStringLiteral("threadId"), thread->id},
        {QStringLiteral("snoozedUntil"), snoozedUntil}},
       QStringLiteral("Failed to snooze thread"), [this, key, snoozedUntil] {
         const QString when = sidebar::wakeDescription(snoozedUntil, m_now(), m_timestampFormat, m_locale);
         toasts()->show(QStringLiteral("success"), QStringLiteral("Snoozed until ") + when, QString(),
                        ToastController::Action{QStringLiteral("Undo"), [this, key] {
                                                  m_bridge->dispatch(QStringLiteral("thread.unsnooze"),
                                                                     QVariantMap{{QStringLiteral("key"), key}});
                                                }});
       });
}

QString SidebarController::activeThreadKey() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

ToastController* SidebarController::toasts() const {
  return NativeShell::of(this)->controller<ToastController>();
}

void SidebarController::readSettings() {
  m_grouping = {};
  m_timestampFormat = QStringLiteral("locale");
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings) return;
  const QJsonObject device = settings->deviceSettings();
  const auto text = [&device](const char* key, QString& into) {
    const QJsonValue value = device.value(QLatin1String(key));
    if (value.isString() && !value.toString().isEmpty()) into = value.toString();
  };
  text("sidebarProjectGroupingMode", m_grouping.mode);
  text("sidebarProjectSortOrder", m_grouping.sortOrder);
  text("timestampFormat", m_timestampFormat);
  const QJsonObject overrides = device.value(QLatin1String("sidebarProjectGroupingOverrides")).toObject();
  for (auto it = overrides.constBegin(); it != overrides.constEnd(); ++it) {
    if (it.value().isString()) m_grouping.overrides.insert(it.key(), it.value().toString());
  }
}
