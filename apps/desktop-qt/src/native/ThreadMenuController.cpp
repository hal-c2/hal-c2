#include "ThreadMenuController.h"

#include <QClipboard>
#include <QDateTime>
#include <QGuiApplication>
#include <QJsonArray>
#include <QUuid>

#include <algorithm>
#include <memory>

#include "../ShellBridge.h"
#include "DraftController.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<ThreadMenuController> registrar(QStringLiteral("threadMenu"));

// The settings page for projects; the route names which one.
const QString kProjectSettings = QStringLiteral("/settings/projects");

using Item = MenuController::Item;

// threadRuntimeCanArchive: an agent that is starting or working keeps the thread.
bool running(const sidebar::Thread& thread) {
  if (!thread.runtime) return false;
  const QString& status = thread.runtime->status;
  if (status == QLatin1String("preparing") || status == QLatin1String("starting") ||
      status == QLatin1String("running")) {
    return true;
  }
  return status == QLatin1String("queued") && thread.runtime->activeRunId.has_value();
}

// What the MC does not move: a thread with a turn under way or a question open.
bool busy(const sidebar::Thread& thread) {
  return running(thread) || thread.activeRunId.has_value() || thread.hasPendingApprovals || thread.hasPendingUserInput;
}

// The palette's menu of the projects a move may go into; it is never listed.
const QString kMoveProject = QStringLiteral("thread.move.project");

QString text(const QJsonObject& row, const char* key) {
  return row.value(QLatin1String(key)).toString();
}

// A machine as a move offers it. Labels are the user's own and may repeat: one
// that does among `offered` is told apart by its environment id.
QString machineName(const QString& label, const QString& environmentId, const QStringList& offered) {
  return offered.count(label) > 1 ? QStringLiteral("%1 · %2").arg(label, environmentId) : label;
}

bool setting(QObject* context, const char* key) {
  const auto* settings = NativeShell::of(context)->controller<SettingsController>();
  return settings && settings->setting(QString::fromLatin1(key)).toBool();
}

}  // namespace

ThreadMenuController::ThreadMenuController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                           QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_writeClipboard = [](const QString& text) {
    QClipboard* clipboard = QGuiApplication::clipboard();
    if (!clipboard) return false;
    clipboard->setText(text);
    return true;
  };
}

bool ThreadMenuController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  const double x = map.value(QStringLiteral("x")).toDouble();
  const double y = map.value(QStringLiteral("y")).toDouble();
  if (action == QLatin1String("thread.menu")) {
    return open(map.value(QStringLiteral("key")).toString(), x, y, false);
  }
  if (action == QLatin1String("thread.unpin")) {
    unpin(map.value(QStringLiteral("key")).toString());
    return true;
  }
  if (action == QLatin1String("workspace.titleMenu")) {
    const auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
    if (!workspace || !workspace->place()) return true;
    const WorkspaceController::Place& place = *workspace->place();
    if (!place.draftId.isEmpty()) {
      m_bridge->dispatch(QStringLiteral("draft.menu"),
                         QVariantMap{{QStringLiteral("draftId"), place.draftId},
                                     {QStringLiteral("x"), x},
                                     {QStringLiteral("y"), y}});
      return true;
    }
    open(place.threadKey(), x, y, true);
    return true;
  }
  return false;
}

bool ThreadMenuController::open(const QString& key, double x, double y, bool header) {
  const auto thread = m_store->thread(key);
  if (!thread) return false;
  auto* shell = NativeShell::of(this);
  SidebarController* sidebar = shell->sidebar();
  const QStringList selection = sidebar->selection();
  if (!header && selection.size() > 1 && selection.contains(key)) {
    openSelection(selection, x, y);
    return true;
  }
  const sidebar::Capabilities supports = m_store->capabilities(thread->environmentId);
  const bool online = m_store->threadOnline(key);
  const qint64 nowMs = sidebar->now().toMSecsSinceEpoch();
  const QJsonObject row = m_store->threadRow(key);

  QList<Item> items;
  // Actions the environment runs are off while it is offline.
  const auto add = [&items, online](Item item, bool needsEnvironment = true) {
    if (needsEnvironment && !online) item.enabled = false;
    items.append(std::move(item));
  };
  if (thread->branch) {
    add({QStringLiteral("new-thread-on-branch"), QStringLiteral("New thread on ") + *thread->branch,
         QStringLiteral("message-square-plus")},
        false);
  }
  if (supports.pinning) {
    add(thread->pinnedAt ? Item{QStringLiteral("unpin"), QStringLiteral("Unpin thread"), QStringLiteral("pin-off")}
                         : Item{QStringLiteral("pin"), QStringLiteral("Pin thread"), QStringLiteral("pin")});
  }
  // Arranging, where the thread has a place to move to.
  if (sidebar->canMove(key, true) || sidebar->canMove(key, false)) {
    Item up{QStringLiteral("move-up"), QStringLiteral("Move up"), QStringLiteral("arrow-up")};
    up.enabled = sidebar->canMove(key, true);
    add(up);
    Item down{QStringLiteral("move-down"), QStringLiteral("Move down"), QStringLiteral("arrow-down")};
    down.enabled = sidebar->canMove(key, false);
    add(down);
  }
  if (supports.settlement) {
    const bool settled = thread->settledOverride == QLatin1String("settled");
    add({settled ? QStringLiteral("unsettle") : QStringLiteral("settle"),
         settled ? QStringLiteral("Un-settle thread") : QStringLiteral("Settle thread"), QStringLiteral("circle-check")});
  }
  if (supports.snooze) {
    if (sidebar::effectiveSnoozed(*thread, nowMs)) {
      add({QStringLiteral("unsnooze"), QStringLiteral("Wake thread"), QStringLiteral("clock")});
    } else {
      Item snooze{QStringLiteral("snooze"), QStringLiteral("Snooze"), QStringLiteral("clock")};
      snooze.enabled = sidebar::canSnooze(*thread, nowMs);
      for (const sidebar::SnoozePreset& preset : sidebar->snoozePresets()) {
        snooze.children.append({QStringLiteral("snooze:") + preset.id, SidebarController::snoozeLabel(preset)});
      }
      Item custom{SidebarController::kCustomSnooze, QStringLiteral("Custom…")};
      custom.separatorBefore = true;
      snooze.children.append(custom);
      add(snooze);
    }
  }
  Item rename{QStringLiteral("rename"), QStringLiteral("Rename thread"), QStringLiteral("pencil")};
  rename.separatorBefore = true;
  add(rename);
  if (supports.titleRegeneration) {
    const bool regenerating = row.value(QLatin1String("titleRegeneration")).isObject();
    Item regenerate{QStringLiteral("regenerate-title"),
                    regenerating ? QStringLiteral("Regenerating…") : QStringLiteral("Regenerate title"),
                    QStringLiteral("refresh-cw")};
    regenerate.enabled = !regenerating;
    add(regenerate);
  }
  add({QStringLiteral("mark-unread"), QStringLiteral("Mark unread"), QStringLiteral("mail-open")});
  const std::optional<QString> projectKey = sidebar->logicalProjectKey(thread->environmentId, thread->projectId);
  if (!header && projectKey) {
    const bool scoped = sidebar->scope() == projectKey;
    const sidebar::ProjectGroup* group = sidebar->group(*projectKey);
    const QString label = group ? group->summary.value(QStringLiteral("displayName")).toString() : QString();
    add({QStringLiteral("filter-by-project"),
         scoped ? QStringLiteral("Show all projects") : QStringLiteral("Filter by ") + label,
         QStringLiteral("folder-tree")},
        false);
  }
  Item copy{QStringLiteral("copy"), QStringLiteral("Copy"), QStringLiteral("copy")};
  copy.separatorBefore = true;
  copy.children.append({QStringLiteral("copy-path"), QStringLiteral("Path"), QStringLiteral("folder")});
  if (thread->branch) {
    copy.children.append({QStringLiteral("copy-branch"), QStringLiteral("Branch"), QStringLiteral("git-branch")});
  }
  copy.children.append({QStringLiteral("copy-thread-id"), QStringLiteral("Thread ID"), QStringLiteral("hash")});
  copy.children.append({QStringLiteral("copy-link"), QStringLiteral("Link"), QStringLiteral("link")});
  add(copy, false);
  if (projectKey) add({QStringLiteral("project-settings"), QStringLiteral("Project settings"), QStringLiteral("settings")}, false);
  add({QStringLiteral("fork"), QStringLiteral("Fork thread"), QStringLiteral("git-fork")});
  // Another machine of the cluster can take the thread.
  const QStringList environments = m_store->environments();
  const bool elsewhere = std::any_of(environments.cbegin(), environments.cend(),
                                     [&](const QString& environment) { return environment != thread->environmentId; });
  if (elsewhere) add({QStringLiteral("move"), QStringLiteral("Move to another machine…"), QStringLiteral("arrow-right-left")});
  Item archive{QStringLiteral("archive"), QStringLiteral("Archive thread"), QStringLiteral("archive")};
  archive.separatorBefore = true;
  archive.enabled = !running(*thread);
  add(archive);
  Item remove{QStringLiteral("delete"), QStringLiteral("Delete"), QStringLiteral("trash")};
  remove.destructive = true;
  add(remove);

  shell->controller<MenuController>()->open(x, y, items, [this, key, x, y](const QString& id) { choose(key, id, x, y); });
  return true;
}

void ThreadMenuController::openSelection(const QStringList& keys, double x, double y) {
  auto* shell = NativeShell::of(this);
  SidebarController* sidebar = shell->sidebar();
  const qint64 nowMs = sidebar->now().toMSecsSinceEpoch();
  const qsizetype count = keys.size();
  qsizetype pinned = 0, regenerable = 0, regenerating = 0;
  bool snoozable = true, settleable = true, anyRunning = false, online = true;
  for (const QString& key : keys) {
    const auto thread = m_store->thread(key);
    if (!thread) continue;
    const sidebar::Capabilities supports = m_store->capabilities(thread->environmentId);
    if (supports.pinning && thread->pinnedAt) ++pinned;
    if (supports.titleRegeneration) {
      if (m_store->threadRow(key).value(QLatin1String("titleRegeneration")).isObject()) {
        ++regenerating;
      } else {
        ++regenerable;
      }
    }
    snoozable = snoozable && supports.snooze && sidebar::canSnooze(*thread, nowMs);
    settleable = settleable && supports.settlement;
    anyRunning = anyRunning || running(*thread);
    online = online && m_store->threadOnline(key);
  }
  const auto counted = [](const QString& label, qsizetype of) { return QStringLiteral("%1 (%2)").arg(label).arg(of); };
  QList<Item> items;
  const auto add = [&items, online](Item item) {
    if (!online) item.enabled = false;
    items.append(std::move(item));
  };
  // Each count is what the action touches.
  if (pinned > 0) add({QStringLiteral("unpin"), counted(QStringLiteral("Unpin"), pinned), QStringLiteral("pin-off")});
  if (settleable) add({QStringLiteral("settle"), counted(QStringLiteral("Settle"), count), QStringLiteral("circle-check")});
  if (snoozable) {
    Item snooze{QStringLiteral("snooze"), counted(QStringLiteral("Snooze"), count), QStringLiteral("clock")};
    for (const sidebar::SnoozePreset& preset : sidebar->snoozePresets()) {
      snooze.children.append({QStringLiteral("snooze:") + preset.id, SidebarController::snoozeLabel(preset)});
    }
    Item custom{SidebarController::kCustomSnooze, QStringLiteral("Custom…")};
    custom.separatorBefore = true;
    snooze.children.append(custom);
    add(snooze);
  }
  if (regenerable > 0) {
    add({QStringLiteral("regenerate-title"), counted(QStringLiteral("Regenerate titles"), regenerable), QStringLiteral("refresh-cw")});
  } else if (regenerating > 0) {
    Item busy{QStringLiteral("regenerate-title"), counted(QStringLiteral("Regenerating…"), regenerating), QStringLiteral("refresh-cw")};
    busy.enabled = false;
    add(busy);
  }
  add({QStringLiteral("mark-unread"), counted(QStringLiteral("Mark unread"), count), QStringLiteral("mail-open")});
  Item archive{QStringLiteral("archive"), counted(QStringLiteral("Archive"), count), QStringLiteral("archive")};
  archive.separatorBefore = true;
  archive.enabled = !anyRunning;
  add(archive);
  Item remove{QStringLiteral("delete"), counted(QStringLiteral("Delete"), count), QStringLiteral("trash")};
  remove.destructive = true;
  add(remove);
  shell->controller<MenuController>()->open(x, y, items, [this, keys](const QString& id) { chooseForSelection(keys, id); });
}

void ThreadMenuController::commandEach(const QStringList& keys, const std::function<QJsonObject(const QString& threadId)>& make,
                                       std::function<void(const QStringList& failed, const QString& reason)> done) {
  struct Batch {
    qsizetype pending = 0;
    QStringList failed;
    QString reason;
  };
  auto batch = std::make_shared<Batch>();
  QList<std::pair<QString, sidebar::Thread>> targets;
  for (const QString& key : keys) {
    if (const auto thread = m_store->thread(key)) targets.append({key, *thread});
  }
  batch->pending = targets.size();
  if (targets.isEmpty()) return done({}, {});
  for (const auto& [key, thread] : std::as_const(targets)) {
    m_client->dispatchCommand(this, thread.environmentId, make(thread.id),
                              [batch, key, done](const QJsonValue&, const std::optional<QString>& error) {
                                if (error) {
                                  if (batch->failed.isEmpty()) batch->reason = *error;
                                  batch->failed.append(key);
                                }
                                if (--batch->pending == 0) done(batch->failed, batch->reason);
                              });
  }
}

void ThreadMenuController::chooseForSelection(const QStringList& keys, const QString& id) {
  auto* shell = NativeShell::of(this);
  SidebarController* sidebar = shell->sidebar();
  const auto typed = [](const char* type) {
    return [type](const QString& threadId) {
      return QJsonObject{{QStringLiteral("type"), QLatin1String(type)}, {QStringLiteral("threadId"), threadId}};
    };
  };
  const auto plural = [](qsizetype count) { return count == 1 ? QStringLiteral("thread") : QStringLiteral("threads"); };
  if (id == SidebarController::kCustomSnooze) {
    sidebar->askCustomSnooze(keys);
  } else if (id.startsWith(QLatin1String("snooze:"))) {
    QString until;
    for (const sidebar::SnoozePreset& preset : sidebar->snoozePresets()) {
      if (QStringLiteral("snooze:") + preset.id == id) until = preset.snoozedUntil;
    }
    if (until.isEmpty()) return;
    sidebar->clearSelection();
    commandEach(keys, [until](const QString& threadId) {
      return QJsonObject{{QStringLiteral("type"), QStringLiteral("thread.snooze")}, {QStringLiteral("threadId"), threadId},
                         {QStringLiteral("snoozedUntil"), until}};
    }, [this, plural, total = keys.size()](const QStringList& failed, const QString& reason) {
      if (failed.isEmpty()) return;
      toasts()->error(failed.size() < total ? QStringLiteral("Failed to snooze %1 %2").arg(failed.size()).arg(plural(failed.size()))
                                             : QStringLiteral("Failed to snooze threads"),
                      reason);
    });
  } else if (id == QLatin1String("unpin")) {
    QStringList pinned;
    for (const QString& key : keys) {
      const auto thread = m_store->thread(key);
      if (thread && thread->pinnedAt) pinned.append(key);
    }
    sidebar->clearSelection();
    commandEach(pinned, typed("thread.unpin"), [this](const QStringList& failed, const QString& reason) {
      if (!failed.isEmpty()) toasts()->error(QStringLiteral("Failed to unpin threads"), reason);
    });
  } else if (id == QLatin1String("settle")) {
    sidebar->clearSelection();
    for (const QString& key : keys) {
      const auto thread = m_store->thread(key);
      if (thread && thread->settledOverride != QLatin1String("settled")) {
        m_bridge->dispatch(QStringLiteral("thread.settle"), QVariantMap{{QStringLiteral("key"), key}});
      }
    }
  } else if (id == QLatin1String("regenerate-title")) {
    QStringList eligible;
    for (const QString& key : keys) {
      const auto thread = m_store->thread(key);
      if (thread && m_store->capabilities(thread->environmentId).titleRegeneration &&
          !m_store->threadRow(key).value(QLatin1String("titleRegeneration")).isObject()) {
        eligible.append(key);
      }
    }
    sidebar->clearSelection();
    commandEach(eligible, [](const QString& threadId) {
      return QJsonObject{{QStringLiteral("type"), QStringLiteral("thread.metadata.update")}, {QStringLiteral("threadId"), threadId},
                         {QStringLiteral("regenerateTitle"), true}};
    }, [this](const QStringList& failed, const QString& reason) {
      if (!failed.isEmpty()) toasts()->error(QStringLiteral("Failed to regenerate thread titles"), reason);
    });
  } else if (id == QLatin1String("mark-unread")) {
    sidebar->clearSelection();
    for (const QString& key : keys) m_bridge->dispatch(QStringLiteral("thread.markUnread"), QVariantMap{{QStringLiteral("key"), key}});
  } else if (id == QLatin1String("archive")) {
    sidebar->clearSelection();
    for (const QString& key : keys) archive(key);
  } else if (id == QLatin1String("delete")) {
    const auto run = [this, keys, typed] {
      commandEach(keys, typed("thread.delete"), [this, keys](const QStringList& failed, const QString& reason) {
        if (!failed.isEmpty()) toasts()->error(QStringLiteral("Failed to delete threads"), reason);
        // The threads that could not be deleted stay selected.
        QStringList deleted;
        for (const QString& key : keys) {
          if (!failed.contains(key)) deleted.append(key);
        }
        NativeShell::of(this)->sidebar()->deselect(deleted);
      });
    };
    if (setting(this, "confirmThreadDelete")) {
      shell->controller<MenuController>()->confirm(
          QStringLiteral("Delete %1 %2?").arg(keys.size()).arg(plural(keys.size())),
          QStringLiteral("This permanently clears conversation history for these threads."), QStringLiteral("Delete"), true, run);
    } else {
      run();
    }
  }
}

void ThreadMenuController::choose(const QString& key, const QString& id, double x, double y) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  const QVariantMap keyed{{QStringLiteral("key"), key}};
  if (id == SidebarController::kCustomSnooze) {
    shell->sidebar()->askCustomSnooze({key});
  } else if (id.startsWith(QLatin1String("snooze:"))) {
    for (const sidebar::SnoozePreset& preset : shell->sidebar()->snoozePresets()) {
      if (QStringLiteral("snooze:") + preset.id == id) shell->sidebar()->snooze(key, preset.snoozedUntil);
    }
  } else if (id == QLatin1String("new-thread-on-branch")) {
    newThreadOnBranch(key);
  } else if (id == QLatin1String("move-up") || id == QLatin1String("move-down")) {
    m_bridge->dispatch(QStringLiteral("thread.move"),
                       QVariantMap{{QStringLiteral("key"), key},
                                   {QStringLiteral("direction"), id == QLatin1String("move-up") ? QStringLiteral("up") : QStringLiteral("down")}});
  } else if (id == QLatin1String("pin")) {
    pin(key);
  } else if (id == QLatin1String("unpin")) {
    unpin(key);
  } else if (id == QLatin1String("settle")) {
    m_bridge->dispatch(QStringLiteral("thread.settle"), keyed);
  } else if (id == QLatin1String("unsettle")) {
    m_bridge->dispatch(QStringLiteral("thread.unsettle"), keyed);
  } else if (id == QLatin1String("unsnooze")) {
    m_bridge->dispatch(QStringLiteral("thread.unsnooze"), keyed);
  } else if (id == QLatin1String("rename")) {
    // The header edits the title; it is on its way there when not open.
    if (navigation->threadKey() != key) navigation->open(NavigationController::Route::thread(key));
    m_bridge->dispatch(QStringLiteral("workspace.rename.begin"), QVariantMap{{QStringLiteral("threadKey"), key}});
  } else if (id == QLatin1String("regenerate-title")) {
    command(key,
            {{QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
             {QStringLiteral("threadId"), thread->id},
             {QStringLiteral("regenerateTitle"), true}},
            QStringLiteral("Failed to regenerate thread title"));
  } else if (id == QLatin1String("mark-unread")) {
    m_bridge->dispatch(QStringLiteral("thread.markUnread"), keyed);
  } else if (id == QLatin1String("filter-by-project")) {
    const auto projectKey = shell->sidebar()->logicalProjectKey(thread->environmentId, thread->projectId);
    const bool scoped = shell->sidebar()->scope() == projectKey;
    m_bridge->dispatch(QStringLiteral("sidebar.scope"),
                       QVariantMap{{QStringLiteral("projectKey"),
                                    scoped || !projectKey ? QVariant::fromValue(nullptr) : QVariant(*projectKey)}});
  } else if (id == QLatin1String("copy-path")) {
    const QString path = workspacePath(key);
    if (path.isEmpty()) {
      toasts()->show(QStringLiteral("error"), QStringLiteral("Path unavailable"),
                     QStringLiteral("This thread does not have a workspace path to copy."));
    } else {
      copy(path, QStringLiteral("Path copied"), QStringLiteral("Failed to copy path"));
    }
  } else if (id == QLatin1String("copy-branch")) {
    if (thread->branch) copy(*thread->branch, QStringLiteral("Branch copied"), QStringLiteral("Failed to copy branch"));
  } else if (id == QLatin1String("copy-thread-id")) {
    copy(thread->id, QStringLiteral("Thread ID copied"), QStringLiteral("Failed to copy thread ID"));
  } else if (id == QLatin1String("copy-link")) {
    copy(NavigationController::threadLink(key), QStringLiteral("Link copied"), QStringLiteral("Failed to copy link"));
  } else if (id == QLatin1String("project-settings")) {
    openProjectSettings(key);
  } else if (id == QLatin1String("fork")) {
    fork(key);
  } else if (id == QLatin1String("move")) {
    chooseDestination(key, x, y);
  } else if (id == QLatin1String("archive")) {
    if (setting(this, "confirmThreadArchive")) {
      shell->controller<MenuController>()->confirm(QStringLiteral("Archive thread \"%1\"?").arg(thread->title), QString(),
                                                   QStringLiteral("Archive"), false, [this, key] { archive(key); });
    } else {
      archive(key);
    }
  } else if (id == QLatin1String("delete")) {
    if (setting(this, "confirmThreadDelete")) {
      shell->controller<MenuController>()->confirm(
          QStringLiteral("Delete thread \"%1\"?").arg(thread->title),
          QStringLiteral("This permanently clears conversation history for this thread."), QStringLiteral("Delete"), true,
          [this, key] { remove(key); });
    } else {
      remove(key);
    }
  }
}

void ThreadMenuController::command(const QString& key, QJsonObject command, const QString& failureTitle,
                                   std::function<void()> onSuccess) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  m_client->dispatchCommand(this, thread->environmentId, std::move(command),
                            [this, failureTitle, onSuccess = std::move(onSuccess)](const QJsonValue&,
                                                                                   const std::optional<QString>& error) {
                              if (error) {
                                toasts()->error(failureTitle, *error);
                              } else if (onSuccess) {
                                onSuccess();
                              }
                            });
}

// Archiving moves the window to a new thread in the project when it showed
// the thread; Undo brings the thread back, and the reader with it.
void ThreadMenuController::archive(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  const bool viewing = navigation->threadKey() == key;
  const QJsonObject target{{QStringLiteral("threadId"), thread->id}};
  QJsonObject archive = target;
  archive.insert(QStringLiteral("type"), QStringLiteral("thread.archive"));
  NativeShell::of(this)->sidebar()->park(key, archive, QStringLiteral("Failed to archive thread"), SidebarController::Leave::ProjectDraft, [this, key, target, viewing] {
    toasts()->showUndo(QStringLiteral("Archived"), QStringLiteral("Archived"), [this, key, target, viewing] {
                     QJsonObject unarchive = target;
                     unarchive.insert(QStringLiteral("type"), QStringLiteral("thread.unarchive"));
                     const QString environmentId = key.left(key.indexOf(QLatin1Char(':')));
                     m_client->dispatchCommand(this, environmentId, unarchive,
                                               [this, key, viewing](const QJsonValue&, const std::optional<QString>& error) {
                                                 if (error) {
                                                   toasts()->error(QStringLiteral("Failed to undo archive"), *error);
                                                   return;
                                                 }
                                                 if (viewing) {
                                                   NativeShell::of(this)->controller<NavigationController>()->open(
                                                       NavigationController::Route::thread(key));
                                                 }
                                               });
                   });
  });
}

QString ThreadMenuController::orphanedWorktree(const QString& key) const {
  const QString worktree = text(m_store->threadRow(key), "worktreePath").trimmed();
  if (worktree.isEmpty()) return {};
  for (const sidebar::Thread& other : m_store->threads()) {
    if (other.key() != key && text(m_store->threadRow(other.key()), "worktreePath").trimmed() == worktree) return {};
  }
  return worktree;
}

void ThreadMenuController::remove(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const QString worktree = orphanedWorktree(key);
  const QString root = text(m_store->projectRow(thread->environmentId, thread->projectId), "workspaceRoot");
  if (worktree.isEmpty() || root.isEmpty()) return removeWith(key, {});
  // The project's own rules, else the environment's.
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  const QJsonObject policy = QJsonValue::fromVariant(settings->value(QStringLiteral("projectSettingsOverrides.%1.worktreeCleanup").arg(thread->projectId))).toObject();
  const QString mode = text(policy, "mode");
  const bool automatic = mode == QLatin1String("custom") ? policy.value(QLatin1String("rules")).toObject().value(QLatin1String("worktreeOnDelete")).toBool()
                         : mode == QLatin1String("off")  ? false
                                                         : settings->value(QStringLiteral("storageCleanup.worktreeOnDelete")).toBool();
  if (automatic) return removeWith(key, worktree);
  NativeShell::of(this)->controller<MenuController>()->confirm(
      QStringLiteral("Delete the worktree too?"),
      QStringLiteral("This thread is the only one linked to this worktree: %1").arg(worktree.section(QLatin1Char('/'), -1)),
      QStringLiteral("Delete worktree"), true, [this, key, worktree] { removeWith(key, worktree); }, [this, key] { removeWith(key, {}); });
}

void ThreadMenuController::removeWith(const QString& key, const QString& worktree) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const QString root = text(m_store->projectRow(thread->environmentId, thread->projectId), "workspaceRoot");
  std::function<void()> cleanUp;
  if (!worktree.isEmpty()) {
    cleanUp = [this, environmentId = thread->environmentId, root, worktree] {
      m_client->call(this, environmentId, QStringLiteral("vcs.removeWorktree"),
                     QJsonObject{{QStringLiteral("cwd"), root}, {QStringLiteral("path"), worktree}, {QStringLiteral("force"), true}},
                     [this, worktree](const QJsonValue&, const std::optional<QString>& error) {
                       if (!error) return;
                       toasts()->error(QStringLiteral("Failed to delete worktree"),
                                       QStringLiteral("Could not remove %1. %2").arg(worktree.section(QLatin1Char('/'), -1), *error));
                     });
    };
  }
  NativeShell::of(this)->sidebar()->park(
      key, {{QStringLiteral("type"), QStringLiteral("thread.delete")}, {QStringLiteral("threadId"), thread->id}},
      QStringLiteral("Failed to delete thread"), SidebarController::Leave::ProjectFallback, std::move(cleanUp));
}

void ThreadMenuController::pin(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  command(key, {{QStringLiteral("type"), QStringLiteral("thread.pin")}, {QStringLiteral("threadId"), thread->id}},
          QStringLiteral("Failed to pin thread"));
}

void ThreadMenuController::unpin(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const auto run = [this, key, threadId = thread->id, orderKey = thread->pinOrderKey] {
    command(key, {{QStringLiteral("type"), QStringLiteral("thread.unpin")}, {QStringLiteral("threadId"), threadId}},
            QStringLiteral("Failed to unpin thread"), [this, key, threadId, orderKey] {
              toasts()->showUndo(QStringLiteral("Unpinned"), QStringLiteral("Unpinned"), [this, key, threadId, orderKey] {
                QJsonObject pin{{QStringLiteral("type"), QStringLiteral("thread.pin")}, {QStringLiteral("threadId"), threadId}};
                if (orderKey) pin.insert(QStringLiteral("orderKey"), *orderKey);
                command(key, pin, QStringLiteral("Failed to undo unpin"));
              });
            });
  };
  if (setting(this, "confirmThreadUnpin")) {
    NativeShell::of(this)->controller<MenuController>()->confirm(
        QStringLiteral("Unpin thread \"%1\"?").arg(thread->title),
        QStringLiteral("This will move the thread out of your pinned section."), QStringLiteral("Unpin"), false, run);
  } else {
    run();
  }
}

void ThreadMenuController::togglePin(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread || !m_store->capabilities(thread->environmentId).pinning) return;
  if (thread->pinnedAt) {
    unpin(key);
  } else {
    pin(key);
  }
}

void ThreadMenuController::toggleSettle(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread || !m_store->capabilities(thread->environmentId).settlement) return;
  const bool settled = thread->settledOverride == QLatin1String("settled");
  m_bridge->dispatch(settled ? QStringLiteral("thread.unsettle") : QStringLiteral("thread.settle"),
                     QVariantMap{{QStringLiteral("key"), key}});
}

// The thread's current pull request (the row's linkedPullRequest, else the
// one its checkout's branch has), else its id.
void ThreadMenuController::activate() {
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  auto* navigation = shell->controller<NavigationController>();
  commands->add(kCopyReference, keybindings::commandLabel(kCopyReference), [this, navigation] {
    if (!navigation->threadKey().isEmpty()) copyReference(navigation->threadKey());
  });
  commands->setTerms(kCopyReference, {QStringLiteral("copy"), QStringLiteral("pull request"), QStringLiteral("pr link"),
                                      QStringLiteral("thread id"), QStringLiteral("reference")});
  commands->add(kProjectSettingsCommand, tr("Project settings"), [this, navigation] {
    if (!navigation->threadKey().isEmpty()) openProjectSettings(navigation->threadKey());
  });
  commands->setTerms(kProjectSettingsCommand, {QStringLiteral("project"), QStringLiteral("settings"),
                                               QStringLiteral("scripts"), QStringLiteral("configuration")});
  // The cluster's other machines, as the shell lists them.
  commands->addMenu(kMove, tr("Move to another machine"), [this, navigation] {
    QList<CommandRegistry::Choice> machines;
    const QString key = navigation->threadKey();
    const auto thread = m_store->thread(key);
    if (!thread) return machines;
    QStringList labels;
    for (const QString& environmentId : m_store->environments()) {
      if (environmentId == thread->environmentId) continue;
      const QString machine = m_store->environment(environmentId).value(QLatin1String("label")).toString(environmentId);
      CommandRegistry::Choice choice{environmentId, machine};
      choice.enabled = m_store->environmentOnline(environmentId);
      if (!choice.enabled) choice.description = tr("Offline");
      choice.terms = {environmentId};
      choice.run = [this, key, environmentId, machine] { startMove(key, {environmentId, machine}, {0, 0, true}); };
      machines.append(choice);
      labels.append(machine);
    }
    for (CommandRegistry::Choice& choice : machines) choice.title = machineName(choice.title, choice.id, labels);
    std::sort(machines.begin(), machines.end(),
              [](const CommandRegistry::Choice& left, const CommandRegistry::Choice& right) { return left.title < right.title; });
    return machines;
  });
  commands->setTerms(kMove, {QStringLiteral("move"), QStringLiteral("machine"), QStringLiteral("cluster"),
                             QStringLiteral("transfer"), QStringLiteral("migrate")});
  commands->addMenu(kMoveProject, tr("Move into project"), [this] { return m_projectChoices; });
  commands->setListed(kMoveProject, false);
  connect(navigation, &NavigationController::changed, this, &ThreadMenuController::present);
  connect(m_store, &ShellStore::changed, this, &ThreadMenuController::present);
  connect(m_store, &ShellStore::changed, this, &ThreadMenuController::moveStopped);
  if (auto* workspace = shell->controller<WorkspaceController>()) {
    connect(workspace, &WorkspaceController::gitChanged, this, &ThreadMenuController::present);
  }
  present();
}

void ThreadMenuController::present() {
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  const QString key = shell->controller<NavigationController>()->threadKey();
  const auto thread = key.isEmpty() ? std::nullopt : m_store->thread(key);
  const QString url = thread ? pullRequestUrl(key) : QString();
  commands->setTitle(kCopyReference, url.isEmpty() ? tr("Copy thread ID") : tr("Copy PR link"));
  commands->setDescription(kCopyReference, url.isEmpty() && thread ? thread->id : url);
  commands->setListed(kCopyReference, thread.has_value());
  const auto project = thread ? m_store->project(thread->environmentId + QLatin1Char(':') + thread->projectId) : std::nullopt;
  commands->setDescription(kProjectSettingsCommand, project ? project->title : QString());
  commands->setListed(kProjectSettingsCommand, project.has_value());
  const QStringList environments = m_store->environments();
  commands->setDescription(kMove, thread ? thread->title : QString());
  commands->setListed(kMove, thread && std::any_of(environments.cbegin(), environments.cend(), [&](const QString& environment) {
                               return environment != thread->environmentId;
                             }));
}

QString ThreadMenuController::pullRequestUrl(const QString& key) const {
  const auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  QString url = text(m_store->threadRow(key).value(QLatin1String("linkedPullRequest")).toObject(), "url");
  if (url.isEmpty() && workspace && workspace->place() && workspace->place()->threadKey() == key && workspace->git()) {
    url = text(workspace->git()->remote.value(QLatin1String("pr")).toObject(), "url");
  }
  return url;
}

void ThreadMenuController::copyReference(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const QString url = pullRequestUrl(key);
  if (url.isEmpty()) {
    copy(thread->id, QStringLiteral("Thread ID copied"), QStringLiteral("Failed to copy thread ID"));
  } else {
    copy(url, QStringLiteral("PR link copied"), QStringLiteral("Failed to copy PR link"));
  }
}

void ThreadMenuController::openProjectSettings(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  auto* shell = NativeShell::of(this);
  const auto projectKey = shell->sidebar()->logicalProjectKey(thread->environmentId, thread->projectId);
  NavigationController::Route route = NavigationController::Route::settings(kProjectSettings);
  route.projectKey = projectKey.value_or(QString());
  shell->controller<NavigationController>()->open(route);
}

void ThreadMenuController::undo() {
  toasts()->runAction(QStringLiteral("Undo"));
}

void ThreadMenuController::copy(const QString& value, const QString& successTitle, const QString& failureTitle) {
  if (m_writeClipboard(value)) {
    toasts()->show(QStringLiteral("success"), successTitle, value);
  } else {
    toasts()->error(failureTitle, QStringLiteral("The clipboard could not be written."));
  }
}

// The thread's worktree, else its project's folder.
QString ThreadMenuController::workspacePath(const QString& key) const {
  const QJsonObject row = m_store->threadRow(key);
  const QString worktree = text(row, "worktreePath");
  if (!worktree.isEmpty()) return worktree;
  const auto thread = m_store->thread(key);
  if (!thread) return {};
  return text(m_store->projectRow(thread->environmentId, thread->projectId), "workspaceRoot");
}

// A copy of the thread up to its latest finished run, opened once the MC has it.
void ThreadMenuController::fork(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const QString target = QUuid::createUuid().toString(QUuid::WithoutBraces);
  command(key,
          {{QStringLiteral("type"), QStringLiteral("thread.fork")},
           {QStringLiteral("sourceThreadId"), thread->id},
           {QStringLiteral("targetThreadId"), target},
           {QStringLiteral("sourcePoint"), QJsonObject{{QStringLiteral("type"), QStringLiteral("latest_stable")}}},
           {QStringLiteral("createdBy"), QStringLiteral("user")},
           {QStringLiteral("creationSource"), QStringLiteral("web")}},
          QStringLiteral("Failed to fork thread"), [this, environmentId = thread->environmentId, target] {
            NativeShell::of(this)->controller<NavigationController>()->open(
                NavigationController::Route::thread(environmentId + QLatin1Char(':') + target));
          });
}

// The machines that could take the thread, as a second menu where the first was.
void ThreadMenuController::chooseDestination(const QString& key, double x, double y) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  m_client->call(this, 
      thread->environmentId, QStringLiteral("hal-c2.moveDestinations"), QJsonObject{{QStringLiteral("threadId"), thread->id}},
      [this, key, x, y](const QJsonValue& result, const std::optional<QString>& error) {
        if (error) {
          toasts()->error(QStringLiteral("Failed to move thread"), *error);
          return;
        }
        QList<Item> items;
        QHash<QString, QString> labels;
        QStringList offered;
        for (const QJsonValue& value : result.toArray()) offered.append(text(value.toObject(), "machine"));
        for (const QJsonValue& value : result.toArray()) {
          const QJsonObject destination = value.toObject();
          const QString id = text(destination, "environmentId");
          const QString machine = text(destination, "machine");
          const QString name = machineName(machine, id, offered);
          const bool online = destination.value(QLatin1String("online")).toBool();
          Item item{QStringLiteral("machine:") + id, online ? name : name + QStringLiteral(" (offline)"), QStringLiteral("monitor")};
          item.enabled = online;
          items.append(item);
          labels.insert(id, machine);
        }
        if (items.isEmpty()) {
          toasts()->show(QStringLiteral("info"), QStringLiteral("No other machine can take this thread"));
          return;
        }
        NativeShell::of(this)->controller<MenuController>()->open(x, y, items, [this, key, x, y, labels](const QString& item) {
          const QString id = item.mid(QStringLiteral("machine:").size());
          startMove(key, {id, labels.value(id, id)}, {x, y});
        });
      });
}

void ThreadMenuController::startMove(const QString& key, const Machine& machine, const Asking& asking) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  const sidebar::Nullable runId = thread->activeRunId ? thread->activeRunId : thread->latestRunId;
  if (!busy(*thread) || !runId) {
    move(key, machine, QString(), false, asking);
    return;
  }
  NativeShell::of(this)->controller<MenuController>()->confirm(
      QStringLiteral("Stop \"%1\" and move it to %2?").arg(thread->title, machine.label),
      QStringLiteral("The agent is working in this thread. Its turn is stopped before the thread moves."),
      QStringLiteral("Stop and move"), false, [this, key, machine, asking, runId = *runId] {
        const auto thread = m_store->thread(key);
        if (!thread) return;
        const QString toast = toasts()->show(QStringLiteral("loading"), QStringLiteral("Stopping \"%1\"…").arg(thread->title),
                                             QString(), {}, 0);
        m_stopping.insert(key, {machine, asking, toast});
        m_client->dispatchCommand(this, thread->environmentId,
                                  {{QStringLiteral("type"), QStringLiteral("run.interrupt")},
                                   {QStringLiteral("threadId"), thread->id},
                                   {QStringLiteral("runId"), runId}},
                                  [this, key](const QJsonValue&, const std::optional<QString>& error) {
                                    if (!error || !m_stopping.contains(key)) return;
                                    toasts()->dismiss(m_stopping.take(key).toast);
                                    toasts()->error(QStringLiteral("Failed to move thread"), *error);
                                  });
      });
}

void ThreadMenuController::moveStopped() {
  for (const QString& key : m_stopping.keys()) {
    const auto thread = m_store->thread(key);
    if (thread && busy(*thread)) continue;
    const Stopping stopping = m_stopping.take(key);
    toasts()->dismiss(stopping.toast);
    if (thread) move(key, stopping.machine, QString(), false, stopping.asking);
  }
}

// `hal-c2.moveThread` answers moved, or asks to confirm what stays behind, or
// which project to move into; each question is asked and the move sent again.
void ThreadMenuController::move(const QString& key, const Machine& machine, const QString& projectId, bool confirmed,
                                const Asking& asking) {
  const auto thread = m_store->thread(key);
  if (!thread) return;
  QJsonObject input{{QStringLiteral("threadId"), thread->id}, {QStringLiteral("machine"), machine.id}};
  if (!projectId.isEmpty()) input.insert(QStringLiteral("projectId"), projectId);
  if (confirmed) input.insert(QStringLiteral("confirmed"), true);
  const QString progress = toasts()->show(QStringLiteral("loading"),
                                          QStringLiteral("Moving \"%1\" to %2…").arg(thread->title, machine.label), QString(), {}, 0);
  m_client->call(this, 
      thread->environmentId, QStringLiteral("hal-c2.moveThread"), input,
      [this, key, machine, projectId, confirmed, asking, progress, title = thread->title](
          const QJsonValue& result, const std::optional<QString>& error) {
        toasts()->dismiss(progress);
        if (error) {
          toasts()->error(QStringLiteral("Failed to move thread"), *error);
          return;
        }
        const QJsonObject answer = result.toObject();
        const QString status = text(answer, "status");
        auto* menus = NativeShell::of(this)->controller<MenuController>();
        if (status == QLatin1String("confirm")) {
          QStringList notes;
          for (const QJsonValue& note : answer.value(QLatin1String("notes")).toArray()) {
            notes.append(note.isObject() ? text(note.toObject(), "message") : note.toString());
          }
          notes.removeAll(QString());
          menus->confirm(QStringLiteral("Move \"%1\" to %2?").arg(title, machine.label),
                         notes.isEmpty() ? text(answer, "message") : notes.join(QLatin1Char('\n')), QStringLiteral("Move"),
                         false, [this, key, machine, projectId, asking] { move(key, machine, projectId, true, asking); });
        } else if (status == QLatin1String("choose_project")) {
          QList<Item> items;
          m_projectChoices.clear();
          for (const QJsonValue& value : answer.value(QLatin1String("projects")).toArray()) {
            const QJsonObject project = value.toObject();
            const QString id = text(project, "id");
            items.append({QStringLiteral("project:") + id, text(project, "title"), QStringLiteral("folder")});
            CommandRegistry::Choice choice{id, text(project, "title"), text(project, "workspaceRoot")};
            choice.run = [this, key, machine, confirmed, asking, id] { move(key, machine, id, confirmed, asking); };
            m_projectChoices.append(choice);
          }
          if (asking.palette) {
            NativeShell::of(this)->controller<KeybindingController>()->commands()->run(kMoveProject);
            return;
          }
          menus->open(asking.x, asking.y, items, [this, key, machine, confirmed, asking](const QString& id) {
            move(key, machine, id.mid(QStringLiteral("project:").size()), confirmed, asking);
          });
        } else if (status == QLatin1String("moved")) {
          toasts()->show(QStringLiteral("success"), text(answer, "message").isEmpty()
                                                        ? QStringLiteral("Moved to ") + machine.label
                                                        : text(answer, "message"));
          // The user who moved the thread is shown it where it lives now.
          const QString environmentId = text(answer, "environmentId");
          if (!environmentId.isEmpty()) {
            NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::thread(
                environmentId + QLatin1Char(':') + key.mid(key.indexOf(QLatin1Char(':')) + 1)));
          }
        }
      });
}

// A draft of the thread's project on its branch: its worktree when it has one,
// else the branch on the project's own checkout.
void ThreadMenuController::newThreadOnBranch(const QString& key) {
  const auto thread = m_store->thread(key);
  if (!thread || !thread->branch) return;
  auto* drafts = NativeShell::of(this)->controller<DraftController>();
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!drafts || !workspace) return;
  const QString worktree = text(m_store->threadRow(key), "worktreePath");
  WorkspaceController::Checkout checkout;
  checkout.envMode = worktree.isEmpty() ? QStringLiteral("local") : QStringLiteral("worktree");
  checkout.startFromOrigin = false;
  checkout.branch = *thread->branch;
  if (!worktree.isEmpty()) checkout.worktreePath = worktree;
  const QString draftId = drafts->start(thread->environmentId, thread->projectId);
  workspace->setCheckout(draftId, checkout);
}

ToastController* ThreadMenuController::toasts() const {
  return NativeShell::of(this)->controller<ToastController>();
}
