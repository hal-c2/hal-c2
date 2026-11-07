#include "SidebarController.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>

#include <utility>

#include "ComposerController.h"
#include "DraftController.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "McPluginController.h"
#include "ShellBridge.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "ThisMachine.h"
#include "ToastController.h"

namespace {

// The device preference that remembers the project the list is scoped to.
const QString kScopeKey = QStringLiteral("sidebarProjectScopeKey");

QString keyOf(const QVariantMap& payload) {
  return payload.value(QStringLiteral("key")).toString();
}

}  // namespace

SidebarController::SidebarController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                     QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_minute.setSingleShot(true);
  // Snoozes wake and "2h" labels tick over on the minute.
  connect(&m_minute, &QTimer::timeout, this, &SidebarController::refresh);
  connect(store, &ShellStore::changed, this, &SidebarController::refresh);
  m_visitLater.setSingleShot(true);
  connect(&m_visitLater, &QTimer::timeout, this, &SidebarController::visitOpenThread);
}

void SidebarController::activate() {
  m_active = true;
  if (auto* plugins = NativeShell::of(this)->controller<McPluginController>()) {
    connect(plugins, &McPluginController::runningChanged, this, &SidebarController::refresh, Qt::UniqueConnection);
  }
  refresh();
}

QList<sidebar::Thread> SidebarController::threads() const {
  QList<sidebar::Thread> threads = m_store->threads();
  const NativeWindow* window = NativeShell::of(this);
  const auto* plugins = window ? window->controller<McPluginController>() : nullptr;
  // Read through a const list and write only what changes: the list shares the
  // store's, and touching it mutably copies every thread.
  for (qsizetype i = 0; i < threads.size(); ++i) {
    const sidebar::Thread& thread = std::as_const(threads).at(i);
    if (!thread.listed && (!plugins || !plugins->keepsUnlisted(thread.environmentId, thread.pluginId))) threads[i].listed = true;
  }
  return threads;
}

void SidebarController::preview() {
  m_previewing = true;
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
  if (!m_active && !m_previewing) return;
  readSettings();
  const QList<sidebar::Thread> threads = this->threads();
  const QString ownEnvironment = m_store->environmentOf(m_client->mc());
  const auto shape = [this] {
    QStringList keys;
    for (const sidebar::ProjectGroup& group : m_groups) keys.append(group.key + QLatin1Char('=') + group.memberKeys.join(QLatin1Char(',')));
    return keys;
  };
  const QStringList before = shape();
  m_groups = sidebar::groupProjects(m_store->projects(), m_grouping, ownEnvironment, threads);
  const bool regrouped = shape() != before;
  // The scope this device chose last time, once per run, as soon as its
  // preferences are read (a preview can refresh before they are).
  if (const auto* settings = NativeShell::of(this)->controller<SettingsController>(); !m_scopeRestored && settings && !settings->devicePath().isEmpty()) {
    m_scopeRestored = true;
    const QJsonValue kept = settings->deviceSettings().value(kScopeKey);
    if (kept.isString() && !kept.toString().isEmpty()) m_scope = kept.toString();
  }
  // A scope whose project went away (removed, regrouped) shows everything
  // again. One restored from the preferences and not seen yet this run waits
  // until every environment has said what projects it has: a cached or
  // unreachable one cannot tell that the project is gone.
  if (m_scope && !m_store->previewing() && m_store->synchronized() && group(*m_scope) != nullptr) m_scopeSeen = true;
  if (m_scope && group(*m_scope) == nullptr && (m_scopeSeen || projectsReported())) {
    m_scope.reset();
    rememberScope();
  }
  const QDateTime now = m_now();
  sidebar::Input input;
  input.projects = m_groups;
  if (!ownEnvironment.isEmpty()) input.localEnvironmentId = ownEnvironment;
  input.localFolders = !ownEnvironment.isEmpty() && thisMachine::hosts(*m_store, *m_client, ownEnvironment);
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
  m_unsentThreads = composer ? composer->unsentThreads() : QSet<QString>();
  input.unsentDraftKeys = m_unsentThreads;
  input.selectedKeys = m_selected;
  input.settledLimit = m_settledShown;
  input.settledPage = m_settledPage;
  input.showSettledPluginThreads = m_showSettledPluginThreads;
  input.jumpLabels = m_jumpLabels;
  input.showJumpHints = m_showJumpHints;
  input.tree = m_tree;
  input.describeWake = [this, now](const QString& snoozedUntil) {
    return sidebar::wakeDescription(snoozedUntil, now, m_timestampFormat, m_locale);
  };
  m_view = sidebar::build(threads, input, m_scope,
                          [this](const QString& environmentId) { return m_store->capabilities(environmentId); },
                          now.toMSecsSinceEpoch());
  // A thread that went, or left the list (archived), is not selected any more,
  // so it does not come back selected.
  m_selected.removeIf([this](const QString& key) { return !m_view.orderedKeys.contains(key); });
  m_bridge->publish(QStringLiteral("sidebar"), m_view.state);
  const QTime time = now.time();
  m_minute.start(std::max(1000, 60000 - time.second() * 1000 - time.msec()));
  if (regrouped) emit grouped();
  announceMigratedThreads();
  visitOpenThread();
}

void SidebarController::announceMigratedThreads() {
  static const QString kAnnounced = QStringLiteral("migratedThreadsAnnounced");
  if (!m_store->synchronized()) return;
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  // Announced once per device; the notice still showing counts the threads
  // that arrive after it.
  if (!settings || (m_migrationToast.isEmpty() && settings->deviceSettings().value(kAnnounced).toBool())) return;
  // Counted when a snapshot lands or the list grows, not on every row change:
  // migrated threads come with the MC's snapshot, or row by row when the
  // import runs while the app is open, and counting them reads every thread.
  const QList<sidebar::Thread> threads = m_store->threads();
  const std::pair checked{m_store->snapshots(), threads.size()};
  if (checked == m_migrationChecked) return;
  m_migrationChecked = checked;
  qsizetype migrated = 0;
  for (const sidebar::Thread& thread : threads) {
    if (m_store->threadRow(thread.key()).value(QLatin1String("historyOrigin")) == QLatin1String("v1_import")) ++migrated;
  }
  const QString title = QStringLiteral("Your threads were brought over");
  const QString description =
      migrated == 1 ? QStringLiteral("1 thread from the previous version is in the list, with its conversation.")
                    : QStringLiteral("%1 threads from the previous version are in the list, with their conversations.").arg(migrated);
  if (!m_migrationToast.isEmpty()) {
    // Dismissed: the count stops there.
    if (!toasts()->update(m_migrationToast, title, description)) m_migrationToast.clear();
    return;
  }
  if (migrated == 0 || !settings->writeDevice(kAnnounced, true)) return;
  m_migrationToast = toasts()->show(QStringLiteral("info"), title, description);
}

void SidebarController::visitOpenThread() {
  constexpr qint64 kVisitEveryMs = 5000;
  const QString key = activeThreadKey();
  const auto thread = key.isEmpty() ? std::nullopt : m_store->thread(key);
  if (!thread || !m_client->isReady() || !m_store->threadOnline(key)) return;
  if (!m_store->capabilities(thread->environmentId).visitedTracking) return;
  if (!m_store->threadRow(key).contains(QLatin1String("lastVisitedAt"))) return;
  const auto updatedAt = sidebar::parseIso(thread->updatedAt);
  if (!updatedAt) return;
  const auto visitedAt = sidebar::parseIso(thread->lastVisitedAt);
  if (visitedAt && *visitedAt >= *updatedAt) return;
  // Once per change: the answer's row comes after this runs again, and a
  // thread marked unread while open stays unread until something new happens.
  const QString visit = key + QLatin1Char(':') + thread->updatedAt;
  if (visit == m_visited) return;
  const auto completedAt = thread->latestRun ? sidebar::parseIso(thread->latestRun->completedAt) : std::nullopt;
  const bool unseenCompletion = completedAt && (!visitedAt || *completedAt > *visitedAt);
  if (!unseenCompletion && m_sinceVisit.isValid() && m_sinceVisit.elapsed() < kVisitEveryMs) {
    m_visitLater.start(int(kVisitEveryMs - m_sinceVisit.elapsed()));
    return;
  }
  m_visited = visit;
  m_sinceVisit.start();
  command(thread->environmentId,
          {{QStringLiteral("type"), QStringLiteral("thread.visit")},
           {QStringLiteral("threadId"), thread->id},
           {QStringLiteral("visitedAt"), thread->updatedAt}},
          QString());
}

void SidebarController::draftEdited(const QString& id) {
  if (!m_active || id == m_openDraftId) return;
  const auto* composer = NativeShell::of(this)->controller<ComposerController>();
  const auto label = composer ? composer->draftPreview(id) : std::nullopt;
  // A thread's row is marked while its composer holds something unsent.
  if (m_store->thread(id)) {
    if (label.has_value() != m_unsentThreads.contains(id)) refresh();
    return;
  }
  const auto listed = m_draftLabels.constFind(id);
  if (listed == m_draftLabels.cend() ? label.has_value() : label != *listed) refresh();
}

bool SidebarController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("thread.select.clear")) {
    clearSelection();
    return true;
  }
  if (action == QLatin1String("thread.select.toggle") || action == QLatin1String("thread.select.range")) {
    const QString key = keyOf(map);
    if (!m_store->thread(key)) return true;
    const qsizetype anchor = m_view.orderedKeys.indexOf(m_anchor);
    const qsizetype target = m_view.orderedKeys.indexOf(key);
    if (action == QLatin1String("thread.select.toggle")) {
      if (!m_selected.remove(key)) {
        m_selected.insert(key);
        m_anchor = key;
      }
    } else if (anchor < 0 || target < 0) {
      // No anchor in the list: the row alone, which becomes the anchor.
      m_selected.insert(key);
      m_anchor = key;
    } else {
      for (qsizetype index = std::min(anchor, target); index <= std::max(anchor, target); ++index) {
        m_selected.insert(m_view.orderedKeys.at(index));
      }
    }
    refresh();
    return true;
  }
  if (action == QLatin1String("sidebar.more")) {
    m_settledShown += m_settledPage;
    refresh();
    return true;
  }
  if (action == QLatin1String("sidebar.project.fold") || action == QLatin1String("sidebar.project.more") ||
      action == QLatin1String("sidebar.project.less") || action == QLatin1String("sidebar.project.drop") ||
      action == QLatin1String("sidebar.project.menu")) {
    const QString key = map.value(QStringLiteral("projectKey")).toString();
    if (!group(key)) return true;
    if (action == QLatin1String("sidebar.project.fold")) {
      QSet<QString> folded = m_tree ? m_tree->folded : QSet<QString>();
      if (!folded.remove(key)) folded.insert(key);
      QStringList keys(folded.cbegin(), folded.cend());
      keys.sort();
      auto* settings = NativeShell::of(this)->controller<SettingsController>();
      if (settings) settings->writeDevice(kFoldedProjects, keys.isEmpty() ? QVariant() : QVariant(keys));
    } else if (action == QLatin1String("sidebar.project.drop")) {
      dropProject(key, map.value(QStringLiteral("targetKey")).toString());
    } else if (action == QLatin1String("sidebar.project.menu")) {
      openProjectMenu(key, map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble());
    } else {
      if (action == QLatin1String("sidebar.project.more")) {
        m_showingAll.insert(key);
      } else {
        m_showingAll.remove(key);
      }
      refresh();
    }
    return true;
  }
  if (action == QLatin1String("sidebar.options")) {
    openSortMenu(map.value(QStringLiteral("x")).toDouble(), map.value(QStringLiteral("y")).toDouble());
    return true;
  }
  if (action == QLatin1String("sidebar.scope")) {
    m_selected.clear();
    m_anchor.clear();
    const QVariant projectKey = map.value(QStringLiteral("projectKey"));
    m_scope = projectKey.typeId() == QMetaType::QString ? sidebar::Nullable(projectKey.toString())
                                                        : std::nullopt;
    // Picked from the projects listed now.
    m_scopeSeen = true;
    rememberScope();
    refresh();
    return true;
  }
  // Opening a thread that woke acknowledges the wake, as dismissing its pill does.
  if (action == QLatin1String("thread.open")) {
    // A plain open ends the selection and anchors the next range.
    m_anchor = keyOf(map);
    clearSelection();
    const auto opened = m_store->thread(keyOf(map));
    if (opened && m_store->capabilities(opened->environmentId).visitedTracking) {
      if (const auto wokeAt = sidebar::visibleWokeAt(*opened, m_now().toMSecsSinceEpoch())) {
        command(opened->environmentId,
                {{QStringLiteral("type"), QStringLiteral("thread.visit")},
                 {QStringLiteral("threadId"), opened->id},
                 {QStringLiteral("visitedAt"), *wokeAt}},
                QString());
      }
    }
    return false;
  }
  if (action == QLatin1String("thread.draft.discard")) {
    if (auto* composer = NativeShell::of(this)->controller<ComposerController>()) composer->discardDraft(keyOf(map));
    return true;
  }
  if (action == QLatin1String("thread.attachFiles")) {
    const QString key = keyOf(map);
    if (!m_store->thread(key)) return true;
    NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::thread(key));
    m_bridge->dispatch(QStringLiteral("composer.attach"), QVariantMap{{QStringLiteral("files"), map.value(QStringLiteral("files"))}});
    return true;
  }
  if (action == QLatin1String("snooze.custom.cancel")) {
    m_customSnoozeKeys.clear();
    m_bridge->publish(QStringLiteral("customSnooze"), QVariant::fromValue(nullptr));
    return true;
  }
  if (action == QLatin1String("snooze.custom.submit")) {
    if (m_customSnoozeKeys.isEmpty()) return true;
    const sidebar::CustomSnooze input{map.value(QStringLiteral("mode")).toString(), map.value(QStringLiteral("date")).toString(),
                                      map.value(QStringLiteral("time")).toString(), map.value(QStringLiteral("amount")).toString(),
                                      map.value(QStringLiteral("unit")).toString()};
    const sidebar::Nullable until = sidebar::resolveCustomSnooze(input, m_now(), m_zone);
    if (!until) {
      QVariantMap asked = m_bridge->state()->value(QStringLiteral("customSnooze")).toMap();
      asked.insert(QStringLiteral("error"), input.mode == QLatin1String("duration") ? QStringLiteral("Enter a positive duration.")
                                                                                     : QStringLiteral("Choose a valid date and time in the future."));
      m_bridge->publish(QStringLiteral("customSnooze"), asked);
      return true;
    }
    const QStringList keys = std::exchange(m_customSnoozeKeys, {});
    m_bridge->publish(QStringLiteral("customSnooze"), QVariant::fromValue(nullptr));
    clearSelection();
    for (const QString& key : keys) snooze(key, *until);
    return true;
  }
  if (action == QLatin1String("thread.move")) {
    const QString key = keyOf(map);
    const bool up = map.value(QStringLiteral("direction")).toString() == QLatin1String("up");
    const QString section = sectionOf(key);
    QStringList ordered = sectionKeys(section);
    const qsizetype index = ordered.indexOf(key);
    if (!canMove(key, up)) return true;
    ordered.swapItemsAt(index, index + (up ? -1 : 1));
    arrange(section, ordered, key);
    return true;
  }
  if (action == QLatin1String("thread.drop")) {
    drop(keyOf(map), map.value(QStringLiteral("section")).toString(), map.value(QStringLiteral("beforeKey")).toString());
    return true;
  }
  static const QStringList kRowActions{
      QStringLiteral("thread.settle"),     QStringLiteral("thread.unsettle"),
      QStringLiteral("thread.unsnooze"),   QStringLiteral("thread.snoozeMenu"),
      QStringLiteral("thread.wokeDismiss"), QStringLiteral("thread.markUnread"),
  };
  if (!kRowActions.contains(action)) return false;
  const QString key = keyOf(map);
  // A thread the MC's cluster does not know has nothing to act on.
  const auto thread = m_store->thread(key);
  if (!thread) return false;
  // An environment without visit tracking has no unread or woke markers to change.
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
    // The MC ends the snooze too; undoing snoozes again until the same time.
    const sidebar::Nullable snoozedUntil = thread->snoozedUntil;
    park(key, with({{QStringLiteral("type"), QStringLiteral("thread.settle")}}),
         QStringLiteral("Failed to settle thread"), Leave::NextCard, [this, key, target, pinned, pinOrderKey, snoozedUntil] {
           toasts()->showUndo(QStringLiteral("Settled"), QStringLiteral("Settled"), [this, key, target, pinned, pinOrderKey, snoozedUntil] {
                            const auto thread = m_store->thread(key);
                            if (!thread) return;
                            QJsonObject unsettle = target;
                            unsettle.insert(QStringLiteral("type"), QStringLiteral("thread.unsettle"));
                            unsettle.insert(QStringLiteral("reason"), QStringLiteral("user"));
                            command(thread->environmentId, unsettle, QStringLiteral("Failed to un-settle thread"),
                                    [this, environmentId = thread->environmentId, target, pinned, pinOrderKey, snoozedUntil] {
                                      if (pinned) {
                                        QJsonObject pin = target;
                                        pin.insert(QStringLiteral("type"), QStringLiteral("thread.pin"));
                                        if (pinOrderKey) pin.insert(QStringLiteral("orderKey"), *pinOrderKey);
                                        command(environmentId, pin, QStringLiteral("Failed to pin thread"));
                                      } else if (sidebar::parseIso(snoozedUntil).value_or(0) > m_now().toMSecsSinceEpoch()) {
                                        // Pinning spends a snooze, so only an unpinned thread is snoozed again.
                                        QJsonObject snooze = target;
                                        snooze.insert(QStringLiteral("type"), QStringLiteral("thread.snooze"));
                                        snooze.insert(QStringLiteral("snoozedUntil"), *snoozedUntil);
                                        command(environmentId, snooze, QStringLiteral("Failed to snooze thread"));
                                      }
                                    });
                          });
         });
  } else if (action == QLatin1String("thread.unsettle")) {
    command(thread->environmentId,
            with({{QStringLiteral("type"), QStringLiteral("thread.unsettle")},
                  {QStringLiteral("reason"), QStringLiteral("user")}}),
            QStringLiteral("Failed to un-settle thread"));
  } else if (action == QLatin1String("thread.unsnooze")) {
    // A snooze the limit recovery made is ended there, so the MC does not
    // snooze the thread again for the same reset.
    const QJsonObject recovery = m_store->threadRow(key).value(QLatin1String("limitRecovery")).toObject();
    const auto until = sidebar::parseIso(thread->snoozedUntil);
    const auto reset = sidebar::parseIso(sidebar::Nullable(recovery.value(QLatin1String("resetAt")).toString()));
    if (recovery.value(QLatin1String("snooze")).toBool() && thread->latestRun &&
        recovery.value(QLatin1String("runId")).toString() == thread->latestRun->runId && until && reset && *until == *reset) {
      command(thread->environmentId,
              with({{QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                    {QStringLiteral("limitRecovery"), QJsonObject{{QStringLiteral("runId"), recovery.value(QLatin1String("runId"))},
                                                                  {QStringLiteral("resetAt"), recovery.value(QLatin1String("resetAt"))},
                                                                  {QStringLiteral("snooze"), false}}}}),
              QStringLiteral("Failed to wake thread"));
      return true;
    }
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
// the list (or a new thread in the same project).
void SidebarController::park(const QString& key, QJsonObject parkCommand, const QString& failureTitle, Leave leave,
                             std::function<void()> onSuccess) {
  if (m_pending.contains(key)) return;
  const auto thread = m_store->thread(key);
  if (!thread) return;
  m_pending.insert(key);

  // Planned now, before the command reshuffles the list.
  std::function<void()> navigate;
  if (activeThreadKey() == key && leave == Leave::ProjectFallback) {
    navigate = [this, fallback = sidebar::fallbackAfterDelete(threads(), key, m_threadSortOrder)] {
      auto* navigation = NativeShell::of(this)->controller<NavigationController>();
      navigation->replace(fallback ? NavigationController::Route::thread(*fallback) : NavigationController::Route());
    };
  } else if (activeThreadKey() == key) {
    const QStringList& keys = m_view.orderedKeys;
    const qsizetype index = keys.indexOf(key);
    std::optional<QString> next;
    if (index != -1 && leave == Leave::NextCard) {
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
      // Nothing left to show: a new thread in the same project. The thread is
      // parked either way; a draft that could not be started is said.
      const QString type = parkCommand.value(QLatin1String("type")).toString();
      navigate = [this, type, environmentId = thread->environmentId, projectId = thread->projectId] {
        auto* drafts = NativeShell::of(this)->controller<DraftController>();
        if (!drafts || !drafts->start(environmentId, projectId).isEmpty()) return;
        const QString done = type == QLatin1String("thread.archive")  ? QStringLiteral("archived")
                             : type == QLatin1String("thread.settle") ? QStringLiteral("settled")
                                                                      : QStringLiteral("snoozed");
        toasts()->error(QStringLiteral("Thread %1, but navigation failed").arg(done), QStringLiteral("A new thread could not be started."));
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
  MenuController::Item custom{kCustomSnooze, QStringLiteral("Custom…")};
  custom.separatorBefore = true;
  items.append(custom);
  NativeShell::of(this)->controller<MenuController>()->open(x, y, items, [this, key, presets](const QString& id) {
    if (id == kCustomSnooze) return askCustomSnooze({key});
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
       QStringLiteral("Failed to snooze thread"), Leave::NextCard, [this, key, snoozedUntil] {
         const QString when = sidebar::wakeDescription(snoozedUntil, m_now(), m_timestampFormat, m_locale);
         toasts()->showUndo(QStringLiteral("Snoozed"), QStringLiteral("Snoozed until ") + when, [this, key] {
                                                  m_bridge->dispatch(QStringLiteral("thread.unsnooze"),
                                                                     QVariantMap{{QStringLiteral("key"), key}});
                                                });
       });
}

// Starts an hour from now.
void SidebarController::askCustomSnooze(const QStringList& keys) {
  if (keys.isEmpty()) return;
  m_customSnoozeKeys = keys;
  const QDateTime initial = m_now().toTimeZone(m_zone).addSecs(3600);
  m_bridge->publish(QStringLiteral("customSnooze"), QVariantMap{
                                                        {QStringLiteral("keys"), keys},
                                                        {QStringLiteral("date"), initial.date().toString(Qt::ISODate)},
                                                        {QStringLiteral("time"), initial.time().toString(QStringLiteral("HH:mm"))},
                                                        {QStringLiteral("error"), QString()},
                                                    });
}

QStringList SidebarController::sectionKeys(const QString& section) const {
  QStringList keys;
  for (const QVariant& row : m_view.state.value(section).toList()) keys.append(row.toMap().value(QStringLiteral("key")).toString());
  return keys;
}

QString SidebarController::sectionOf(const QString& key) const {
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    if (sectionKeys(section).contains(key)) return section;
  }
  return {};
}

bool SidebarController::canMove(const QString& key, bool up) const {
  const QString section = sectionOf(key);
  if (section != QLatin1String("pinned") && section != QLatin1String("active")) return false;
  const QStringList ordered = sectionKeys(section);
  const qsizetype index = ordered.indexOf(key);
  return up ? index > 0 : index < ordered.size() - 1;
}

void SidebarController::arrange(const QString& section, const QStringList& ordered, const QString& key, bool pinning) {
  const auto moved = m_store->thread(key);
  if (!moved) return;
  const bool pinned = section == QLatin1String("pinned");
  const QString capability = pinned ? QStringLiteral("threadPinReorder") : QStringLiteral("threadActiveReorder");
  if (!m_store->supports(moved->environmentId, capability)) {
    toasts()->error(pinned ? QStringLiteral("Failed to reorder pinned threads") : QStringLiteral("Failed to reorder active threads"),
                    pinned ? QStringLiteral("Update this environment's server to reorder pinned threads.")
                           : QStringLiteral("Update this environment's server to reorder active threads."));
    return;
  }
  // Every thread of the section keeps its key, the ones the scope hides too.
  QHash<QString, sidebar::Nullable> orderKeys;
  const qint64 nowMs = m_now().toMSecsSinceEpoch();
  const sidebar::Partition all = sidebar::partition(
      threads(), std::nullopt, [this](const QString& environmentId) { return m_store->capabilities(environmentId); }, nowMs);
  for (const sidebar::Thread& thread : pinned ? all.pinned : all.active) {
    orderKeys.insert(thread.key(), pinned ? thread.pinOrderKey : thread.activeOrderKey);
  }
  if (pinning) orderKeys.insert(key, std::nullopt);
  // A row whose environment is offline keeps its order; its capabilities are
  // only the ones cached for drawing it.
  QSet<QString> writable;
  for (const QString& listed : ordered) {
    const auto thread = m_store->thread(listed);
    if (thread && m_store->environmentOnline(thread->environmentId) && m_store->supports(thread->environmentId, capability)) {
      writable.insert(listed);
    }
  }
  const auto planned = sidebar::planWritableReorder(ordered, orderKeys, key, writable, !pinned);
  // A drop that cannot be stored beside the offline rows snaps back, as it would on reload.
  if (!planned) return;
  const QString failure = pinned ? QStringLiteral("Failed to reorder pinned threads") : QStringLiteral("Failed to reorder active threads");
  for (const sidebar::OrderAssignment& assignment : *planned) {
    const auto thread = m_store->thread(assignment.key);
    if (!thread) continue;
    const bool pin = pinning && assignment.key == key;
    command(thread->environmentId,
            {{QStringLiteral("type"), pin ? QStringLiteral("thread.pin") : pinned ? QStringLiteral("thread.pin.reorder") : QStringLiteral("thread.active.reorder")},
             {QStringLiteral("threadId"), thread->id},
             {QStringLiteral("orderKey"), assignment.orderKey}},
            pin ? QStringLiteral("Failed to pin thread") : failure);
  }
}

void SidebarController::drop(const QString& key, const QString& section, const QString& beforeKey) {
  const auto thread = m_store->thread(key);
  const QString from = sectionOf(key);
  if (!thread || from.isEmpty() || section == QLatin1String("snoozed")) return;
  const QVariantMap keyed{{QStringLiteral("key"), key}};
  const auto placed = [&] {
    QStringList ordered = sectionKeys(section);
    ordered.removeAll(key);
    const qsizetype before = beforeKey == key ? -1 : ordered.indexOf(beforeKey);
    ordered.insert(before < 0 ? ordered.size() : before, key);
    return ordered;
  };
  if (section == from) {
    if (section == QLatin1String("pinned") || section == QLatin1String("active")) {
      const QStringList ordered = placed();
      if (ordered != sectionKeys(section)) arrange(section, ordered, key);
    }
  } else if (section == QLatin1String("pinned")) {
    if (m_store->capabilities(thread->environmentId).pinning) arrange(section, placed(), key, true);
  } else if (section == QLatin1String("settled")) {
    handle(QStringLiteral("thread.settle"), keyed);
  } else if (from == QLatin1String("pinned")) {
    // Dragging out of the pinned rows says it: no question is asked.
    command(thread->environmentId, {{QStringLiteral("type"), QStringLiteral("thread.unpin")}, {QStringLiteral("threadId"), thread->id}},
            QStringLiteral("Failed to unpin thread"));
  } else if (from == QLatin1String("settled")) {
    handle(QStringLiteral("thread.unsettle"), keyed);
  } else if (from == QLatin1String("snoozed")) {
    handle(QStringLiteral("thread.unsnooze"), keyed);
  }
}

void SidebarController::dropProject(const QString& key, const QString& targetKey) {
  // Only an order the user keeps by hand takes a drag.
  if (m_grouping.sortOrder != QLatin1String("manual") || key == targetKey) return;
  const sidebar::ProjectGroup* dragged = group(key);
  const sidebar::ProjectGroup* target = group(targetKey);
  if (!dragged || !target) return;
  const auto folders = [](const sidebar::ProjectGroup& group) {
    QStringList keys;
    for (const sidebar::Project& member : group.members) {
      const QString physical = sidebar::physicalKey(member);
      if (!keys.contains(physical)) keys.append(physical);
    }
    return keys;
  };
  QStringList order;
  for (const sidebar::ProjectGroup& group : std::as_const(m_groups)) {
    for (const QString& physical : folders(group)) {
      if (!order.contains(physical)) order.append(physical);
    }
  }
  const QStringList next = sidebar::reorderProjects(order, folders(*dragged), folders(*target));
  if (next == order) return;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) settings->writeDevice(kProjectOrder, next);
}

void SidebarController::openProjectMenu(const QString& key, double x, double y) {
  const sidebar::ProjectGroup* project = group(key);
  if (!project || project->members.isEmpty()) return;
  auto* shell = NativeShell::of(this);
  auto* settings = shell->controller<SettingsController>();
  const QList<sidebar::Project> members = project->members;
  const bool grouped = members.size() > 1;
  // A grouped project's entries name the folder each acts on.
  const auto memberLabel = [this](const sidebar::Project& member) {
    const QString environment = m_store->environment(member.environmentId).value(QLatin1String("label")).toString();
    return environment.isEmpty() ? member.workspaceRoot : member.workspaceRoot + QStringLiteral(" (") + environment + QLatin1Char(')');
  };
  QHash<QString, std::function<void()>> run;
  const auto leaf = [&run](const QString& id, const QString& label, std::function<void()> action) {
    run.insert(id, std::move(action));
    return MenuController::Item{id, label};
  };
  const auto targeted = [&](const QString& action, const QString& label,
                            const std::function<MenuController::Item(const sidebar::Project&, const QString& id, const QString& label)>& make) {
    if (!grouped) return make(members.first(), action + QStringLiteral(":0"), label);
    MenuController::Item item{action, label};
    for (qsizetype i = 0; i < members.size(); ++i) {
      item.children.append(make(members.at(i), action + QLatin1Char(':') + QString::number(i), memberLabel(members.at(i))));
    }
    return item;
  };
  QList<MenuController::Item> items;
  items.append(targeted(QStringLiteral("rename"), QStringLiteral("Rename"), [&](const sidebar::Project& member, const QString& id, const QString& label) {
    return leaf(id, label, [this, memberKey = member.key()] {
      m_bridge->dispatch(QStringLiteral("project.rename"), QVariantMap{{QStringLiteral("projectKey"), memberKey}});
    });
  }));
  // The device's default, else the folder's own choice (sidebarProjectGroupingOverrides).
  static const QList<std::pair<QString, QString>> kGroupings{
      {QStringLiteral("inherit"), QStringLiteral("Use global default")},
      {QStringLiteral("repository"), QStringLiteral("Group by repository")},
      {QStringLiteral("repository_path"), QStringLiteral("Group by repository path")},
      {QStringLiteral("separate"), QStringLiteral("Keep separate")},
  };
  items.append(targeted(QStringLiteral("grouping"), QStringLiteral("Group into..."), [&](const sidebar::Project& member, const QString& id, const QString& label) {
    const QString folder = sidebar::physicalKey(member);
    const QString current = m_grouping.overrides.value(folder, QStringLiteral("inherit"));
    MenuController::Item choices{id, label};
    for (const auto& [choice, choiceLabel] : kGroupings) {
      MenuController::Item item = leaf(id + QLatin1Char(':') + choice, choiceLabel, [settings, folder, choice] {
        if (!settings) return;
        QJsonObject overrides = settings->deviceSettings().value(QLatin1String("sidebarProjectGroupingOverrides")).toObject();
        if (choice == QLatin1String("inherit")) {
          overrides.remove(folder);
        } else {
          overrides.insert(folder, choice);
        }
        settings->writeDevice(QStringLiteral("sidebarProjectGroupingOverrides"),
                              overrides.isEmpty() ? QVariant() : QVariant(overrides.toVariantMap()));
      });
      item.checked = choice == current;
      choices.children.append(item);
    }
    return choices;
  }));
  items.append(targeted(QStringLiteral("copy-path"), QStringLiteral("Copy Path"), [&](const sidebar::Project& member, const QString& id, const QString& label) {
    return leaf(id, label, [this, path = member.workspaceRoot] {
      QClipboard* clipboard = QGuiApplication::clipboard();
      if (!clipboard) {
        toasts()->error(QStringLiteral("Failed to copy path"), QStringLiteral("The clipboard could not be written."));
        return;
      }
      clipboard->setText(path);
      toasts()->show(QStringLiteral("success"), QStringLiteral("Path copied"), path);
    });
  }));
  items.append(leaf(QStringLiteral("project-settings"), QStringLiteral("Project settings"), [shell, key] {
    NavigationController::Route route = NavigationController::Route::settings(QStringLiteral("/settings/projects"));
    route.projectKey = key;
    shell->controller<NavigationController>()->open(route);
  }));
  items.last().icon = QStringLiteral("settings");
  MenuController::Item remove = targeted(QStringLiteral("delete"), QStringLiteral("Remove"), [&](const sidebar::Project& member, const QString& id, const QString& label) {
    MenuController::Item item = leaf(id, label, [this, memberKey = member.key()] {
      // A project with threads says so first; deleting it anyway still asks (ProjectController).
      const auto ask = [this, memberKey] {
        m_bridge->dispatch(QStringLiteral("project.remove"), QVariantMap{{QStringLiteral("projectKey"), memberKey}});
      };
      const auto project = m_store->project(memberKey);
      if (!project) return;
      qsizetype threads = 0;
      for (const sidebar::Thread& thread : m_store->threads()) {
        if (thread.environmentId == project->environmentId && thread.projectId == project->id && !thread.archivedAt) ++threads;
      }
      if (threads == 0) return ask();
      toasts()->show(QStringLiteral("warning"), QStringLiteral("Project is not empty"),
                     QStringLiteral("Delete all threads in this project before removing it."),
                     ToastController::Action{QStringLiteral("Delete anyway"), ask});
    });
    item.destructive = true;
    return item;
  });
  remove.icon = QStringLiteral("trash");
  remove.destructive = true;
  items.append(remove);
  shell->controller<MenuController>()->open(x, y, items, [run = std::move(run)](const QString& id) {
    if (const auto action = run.constFind(id); action != run.cend()) (*action)();
  });
}

void SidebarController::openSortMenu(double x, double y) {
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings) return;
  static const QList<std::pair<QString, QString>> kProjectOrders{
      {QStringLiteral("updated_at"), QStringLiteral("Last user message")},
      {QStringLiteral("created_at"), QStringLiteral("Created at")},
      {QStringLiteral("manual"), QStringLiteral("Manual")},
  };
  const auto choices = [](const QString& prefix, const QString& label, qsizetype count, const QString& current) {
    MenuController::Item item{prefix, label};
    for (qsizetype i = 0; i < count; ++i) {
      MenuController::Item choice{prefix + QLatin1Char(':') + kProjectOrders.at(i).first, kProjectOrders.at(i).second};
      choice.checked = kProjectOrders.at(i).first == current;
      item.children.append(choice);
    }
    return item;
  };
  const QList<MenuController::Item> items{
      choices(QStringLiteral("sidebarProjectSortOrder"), QStringLiteral("Sort projects"), 3, m_grouping.sortOrder),
      // Threads have no order of the user's own.
      choices(QStringLiteral("sidebarThreadSortOrder"), QStringLiteral("Sort threads"), 2, m_threadSortOrder),
  };
  NativeShell::of(this)->controller<MenuController>()->open(x, y, items, [settings](const QString& id) {
    const qsizetype colon = id.indexOf(QLatin1Char(':'));
    if (colon > 0) settings->writeDevice(id.left(colon), id.mid(colon + 1));
  });
}

void SidebarController::setJumpHints(const QStringList& labels, bool shown) {
  if (m_jumpLabels == labels && m_showJumpHints == shown) return;
  m_jumpLabels = labels;
  m_showJumpHints = shown;
  refresh();
}

QStringList SidebarController::selection() const {
  QStringList keys;
  for (const QString& key : m_view.orderedKeys) {
    if (m_selected.contains(key)) keys.append(key);
  }
  return keys;
}

void SidebarController::clearSelection() {
  if (m_selected.isEmpty()) return;
  m_selected.clear();
  refresh();
}

void SidebarController::deselect(const QStringList& keys) {
  qsizetype removed = 0;
  for (const QString& key : keys) removed += m_selected.remove(key);
  if (removed > 0) refresh();
}

QString SidebarController::activeThreadKey() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

ToastController* SidebarController::toasts() const {
  return NativeShell::of(this)->controller<ToastController>();
}

bool SidebarController::projectsReported() const {
  if (m_store->previewing() || !m_store->synchronized()) return false;
  for (const QString& environment : m_store->environments()) {
    if (!m_store->environmentOnline(environment)) return false;
  }
  return true;
}

void SidebarController::rememberScope() {
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    if (settings->deviceSettings().value(kScopeKey).toString() != m_scope.value_or(QString())) {
      settings->writeDevice(kScopeKey, m_scope ? QVariant(*m_scope) : QVariant());
    }
  }
}

void SidebarController::readSettings() {
  m_grouping = {};
  m_tree.reset();
  m_timestampFormat = QStringLiteral("locale");
  m_threadSortOrder = QStringLiteral("updated_at");
  m_showSettledPluginThreads = false;
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings) return;
  // The shell's own MC decides for the whole sidebar, as its Settings row shows.
  m_showSettledPluginThreads = settings->settings().value(QLatin1String("sidebarShowSettledPluginThreads")).toBool(false);
  const QJsonObject device = settings->deviceSettings();
  const auto text = [&device](const char* key, QString& into) {
    const QJsonValue value = device.value(QLatin1String(key));
    if (value.isString() && !value.toString().isEmpty()) into = value.toString();
  };
  text("sidebarProjectGroupingMode", m_grouping.mode);
  text("sidebarProjectSortOrder", m_grouping.sortOrder);
  text("timestampFormat", m_timestampFormat);
  text("sidebarThreadSortOrder", m_threadSortOrder);
  const QJsonObject overrides = device.value(QLatin1String("sidebarProjectGroupingOverrides")).toObject();
  for (auto it = overrides.constBegin(); it != overrides.constEnd(); ++it) {
    if (it.value().isString()) m_grouping.overrides.insert(it.key(), it.value().toString());
  }
  const auto strings = [&device](const QString& key) {
    QStringList values;
    for (const QJsonValue& value : device.value(key).toArray()) {
      if (value.isString()) values.append(value.toString());
    }
    return values;
  };
  m_grouping.manualOrder = strings(kProjectOrder);
  m_tree.reset();
  if (!device.value(QLatin1String("legacySidebarEnabled")).toBool(false)) return;
  sidebar::Tree tree;
  const QJsonValue count = device.value(QLatin1String("sidebarThreadPreviewCount"));
  tree.previewCount = sidebar::clampThreadPreviewCount(count.isDouble() ? count.toInt() : sidebar::kDefaultThreadPreviewCount);
  tree.threadSortOrder = m_threadSortOrder;
  const QStringList folded = strings(kFoldedProjects);
  tree.folded = QSet<QString>(folded.cbegin(), folded.cend());
  tree.showingAll = m_showingAll;
  tree.manual = m_grouping.sortOrder == QLatin1String("manual");
  m_tree = tree;
}
