#include "WorkspaceController.h"

#include <QJsonValue>
#include <QUrl>
#include <QRegularExpression>

#include <algorithm>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "ThreadMenuController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<WorkspaceController> registrar(QStringLiteral("workspace"),
                                                               {QStringLiteral("workspace")});

// packages/contracts EDITORS, in the order the picker offers them.
const QList<std::pair<QString, QString>>& editorLabels() {
  static const QList<std::pair<QString, QString>> labels{
      {QStringLiteral("cursor"), QStringLiteral("Cursor")},
      {QStringLiteral("trae"), QStringLiteral("Trae")},
      {QStringLiteral("kiro"), QStringLiteral("Kiro")},
      {QStringLiteral("vscode"), QStringLiteral("VS Code")},
      {QStringLiteral("vscode-insiders"), QStringLiteral("VS Code Insiders")},
      {QStringLiteral("vscodium"), QStringLiteral("VSCodium")},
      {QStringLiteral("zed"), QStringLiteral("Zed")},
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity")},
      {QStringLiteral("idea"), QStringLiteral("IntelliJ IDEA")},
      {QStringLiteral("aqua"), QStringLiteral("Aqua")},
      {QStringLiteral("clion"), QStringLiteral("CLion")},
      {QStringLiteral("datagrip"), QStringLiteral("DataGrip")},
      {QStringLiteral("dataspell"), QStringLiteral("DataSpell")},
      {QStringLiteral("goland"), QStringLiteral("GoLand")},
      {QStringLiteral("phpstorm"), QStringLiteral("PhpStorm")},
      {QStringLiteral("pycharm"), QStringLiteral("PyCharm")},
      {QStringLiteral("rider"), QStringLiteral("Rider")},
      {QStringLiteral("rubymine"), QStringLiteral("RubyMine")},
      {QStringLiteral("rustrover"), QStringLiteral("RustRover")},
      {QStringLiteral("webstorm"), QStringLiteral("WebStorm")},
      {QStringLiteral("file-manager"), QStringLiteral("File Manager")},
  };
  return labels;
}

// Device settings keys.
const QString kLastEditor = QStringLiteral("lastEditor");
const QString kLastScripts = QStringLiteral("lastProjectScripts");

QString text(const QJsonObject& row, const char* key) {
  return row.value(QLatin1String(key)).toString();
}

std::optional<QString> optionalText(const QJsonObject& row, const char* key) {
  const QJsonValue value = row.value(QLatin1String(key));
  if (!value.isString() || value.toString().isEmpty()) return std::nullopt;
  return value.toString();
}

QVariant nullable(const QString& value) {
  return value.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(value);
}

QVariant nullable(const std::optional<QString>& value) {
  return value ? QVariant(*value) : QVariant::fromValue(nullptr);
}

// packages/shared sanitizeNewRefName: trimmed, whitespace runs as "-".
QString refName(const QString& raw) {
  static const QRegularExpression spaces(QStringLiteral("\\s+"));
  return raw.trimmed().replace(spaces, QStringLiteral("-"));
}

// packages/shared deriveLocalBranchNameFromRemoteRef: "origin/feature/x" is
// "feature/x".
QString localBranchOf(const QString& remoteRef) {
  const qsizetype slash = remoteRef.indexOf(QLatin1Char('/'));
  if (slash <= 0 || slash == remoteRef.size() - 1) return remoteRef;
  return remoteRef.mid(slash + 1);
}

// BranchToolbar.logic: the machine's own name, unless it is a generic one.
QString primaryLabel(const QString& label) {
  const QString lowered = label.trimmed().toLower();
  if (lowered.isEmpty() || lowered == QLatin1String("local") || lowered == QLatin1String("local environment")) {
    return QStringLiteral("This device");
  }
  return label.trimmed();
}

}  // namespace

WorkspaceController::WorkspaceController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                         QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

WorkspaceController::~WorkspaceController() {
  if (m_vcs) m_client->unsubscribe(m_vcs);
  if (m_config) m_client->unsubscribe(m_config);
}

void WorkspaceController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  connect(m_store, &ShellStore::changed, this, &WorkspaceController::refresh);
  if (auto* navigation = shell->controller<NavigationController>()) {
    connect(navigation, &NavigationController::changed, this, &WorkspaceController::refresh);
  }
  if (auto* settings = shell->controller<SettingsController>()) {
    connect(settings, &SettingsController::configChanged, this, &WorkspaceController::publish);
    connect(settings, &SettingsController::configChanged, this, &WorkspaceController::configChanged);
    connect(settings, &SettingsController::deviceChanged, this, &WorkspaceController::publish);
  }
  // The web's OpenInPicker shortcut: the route's folder in the preferred editor.
  if (auto* keys = shell->controller<KeybindingController>()) {
    const QString openFavorite = QStringLiteral("editor.openFavorite");
    keys->commands()->add(openFavorite, keybindings::commandLabel(openFavorite), [this] { openInEditor({}); });
    keys->commands()->setListed(openFavorite, false);
    keys->commands()->add(QStringLiteral("composer.previousWorktree"),
                          keybindings::commandLabel(QStringLiteral("composer.previousWorktree")),
                          [this] { usePreviousWorktree(); });
  }
  refresh();
}

void WorkspaceController::setDraftResolver(std::function<std::optional<DraftPlace>(const QString&)> resolve) {
  m_resolveDraft = std::move(resolve);
  refresh();
}

// client-runtime startThreadTurn's bootstrap, from the checkout the header
// shows: a new worktree off the picked (else current) branch, the worktree
// picked, or the project folder. A folder that is not a repository always
// starts in the folder, as the web's send mode.
WorkspaceController::Launch WorkspaceController::launch(const QString& draftId) const {
  Launch launch;
  const std::optional<DraftPlace> draft = m_resolveDraft ? m_resolveDraft(draftId) : std::nullopt;
  if (!draft) {
    launch.problem = QStringLiteral("This draft no longer points to an available project.");
    return launch;
  }
  const Checkout checkout = m_checkouts.value(draftId);
  const bool moved = !checkout.environmentId.isEmpty();
  launch.environmentId = moved ? checkout.environmentId : draft->environmentId;
  launch.projectId = moved ? checkout.projectId : draft->projectId;
  launch.tied = moved || checkout.branch || checkout.worktreePath;
  // The checkout's status is known only for the draft the window shows.
  const bool shown = m_place && m_place->draftId == draftId;
  const bool repo = !(shown && m_git && !m_git->local.value(QLatin1String("isRepo")).toBool(true));
  const QString current = shown ? currentBranch() : QString();
  const std::optional<QString> branch =
      checkout.branch ? checkout.branch : (current.isEmpty() ? std::nullopt : std::optional(current));
  const auto withBranch = [&](QJsonObject strategy) {
    if (branch) strategy.insert(QStringLiteral("branch"), *branch);
    return strategy;
  };
  if (checkout.worktreePath) {
    launch.strategy = withBranch({{QStringLiteral("type"), QStringLiteral("existing_worktree")},
                                  {QStringLiteral("worktreePath"), *checkout.worktreePath}});
  } else if (repo && checkout.envMode == QLatin1String("worktree")) {
    if (!branch) {
      launch.problem = QStringLiteral("Select a base branch before sending in New worktree mode.");
      return launch;
    }
    launch.strategy = {{QStringLiteral("type"), QStringLiteral("worktree")}, {QStringLiteral("baseRef"), *branch}};
    if (checkout.startFromOrigin) launch.strategy.insert(QStringLiteral("startFromOrigin"), true);
  } else {
    launch.strategy = withBranch({{QStringLiteral("type"), QStringLiteral("root")}});
  }
  return launch;
}

// --- Where the route is ---------------------------------------------------------------

std::optional<WorkspaceController::Place> WorkspaceController::resolve() const {
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (!navigation) return std::nullopt;
  const NavigationController::Route& route = navigation->route();
  Place place;
  if (route.kind == QLatin1String("thread")) {
    const QJsonObject row = m_store->threadRow(route.threadKey);
    // A thread the shell does not list (yet: a member's rows come once it joins).
    if (row.isEmpty()) return std::nullopt;
    place.environmentId = route.threadKey.left(route.threadKey.indexOf(QLatin1Char(':')));
    place.threadId = text(row, "id");
    place.projectId = text(row, "projectId");
    place.worktreePath = optionalText(row, "worktreePath").value_or(QString());
  } else if (route.kind == QLatin1String("draft")) {
    if (!m_resolveDraft) return std::nullopt;
    const std::optional<DraftPlace> draft = m_resolveDraft(route.draftId);
    if (!draft) return std::nullopt;
    const Checkout checkout = m_checkouts.value(route.draftId);
    const bool moved = !checkout.environmentId.isEmpty();
    place.environmentId = moved ? checkout.environmentId : draft->environmentId;
    place.projectId = moved ? checkout.projectId : draft->projectId;
    place.threadId = draft->threadId;
    place.draftId = route.draftId;
    place.worktreePath = checkout.worktreePath.value_or(QString());
  } else {
    return std::nullopt;
  }
  const QJsonObject project = m_store->projectRow(place.environmentId, place.projectId);
  place.root = text(project, "workspaceRoot");
  place.scripts = project.value(QLatin1String("scripts")).toArray();
  return place;
}

void WorkspaceController::refresh() {
  if (!m_active) return;
  std::optional<Place> place = resolve();
  const auto same = [](const std::optional<Place>& a, const std::optional<Place>& b) {
    if (a.has_value() != b.has_value()) return false;
    if (!a) return true;
    return a->environmentId == b->environmentId && a->threadId == b->threadId && a->projectId == b->projectId &&
           a->draftId == b->draftId && a->root == b->root && a->worktreePath == b->worktreePath &&
           a->scripts == b->scripts;
  };
  const bool changed = !same(place, m_place);
  const bool otherThread = !place || !m_place || place->threadKey() != m_place->threadKey();
  m_place = std::move(place);
  if (otherThread) {
    m_optimisticBranch.reset();
    m_query.clear();
  }
  if (m_place && m_place->threadKey() == m_renameWanted) {
    m_renameWanted.clear();
    ++m_renameRequestId;
  }
  follow(m_place ? m_place->cwd() : QString());
  // Another machine's editors; one that is unreachable ends the watch at once,
  // so it waits for the machine to be back.
  if (m_place && m_place->environmentId != m_client->environment() && m_store->environmentOnline(m_place->environmentId)) {
    watchConfig(m_place->environmentId);
  } else {
    watchConfig({});
  }
  // The row caught up with the switch.
  if (m_optimisticBranch && m_place && m_place->draftId.isEmpty() &&
      optionalText(threadRow(), "branch") == m_optimisticBranch && !m_switching) {
    m_optimisticBranch.reset();
  }
  if (changed) emit placeChanged();
  publish();
}

QJsonObject WorkspaceController::threadRow() const {
  if (!m_place || !m_place->draftId.isEmpty()) return {};
  return m_store->threadRow(m_place->threadKey());
}

// The checkout's status, from the cluster member serving the thread's
// environment. It is followed again when the environment comes back online,
// since a member that is unreachable ends it at once with its reason
// (gitError()).
void WorkspaceController::follow(const QString& cwd) {
  const QString environment = m_place ? m_place->environmentId : QString();
  const bool online = !environment.isEmpty() && m_store->environmentOnline(environment);
  const QString key = environment.isEmpty() || cwd.isEmpty()
                          ? QString()
                          : environment + QLatin1Char('\n') + cwd + (online ? QStringLiteral("\n1") : QStringLiteral("\n0"));
  if (key == m_vcsKey) return;
  if (m_vcs) m_client->unsubscribe(m_vcs);
  m_vcs = 0;
  m_vcsKey = key;
  if (m_git || !m_gitError.isEmpty()) {
    m_git.reset();
    m_gitError.clear();
    emit gitChanged();
  }
  const bool hadRefs = !m_refsCwd.isEmpty();
  m_refs = {};
  m_refsTotal = 0;
  m_refsNextCursor.reset();
  m_refsLoadingMore = false;
  m_refsCwd.clear();
  ++m_refsGeneration;
  m_refsLoading = false;
  if (key.isEmpty()) return;
  m_vcs = m_client->subscribe(this, 
      {
          {QStringLiteral("type"), QStringLiteral("vcs")},
          {QStringLiteral("environment"), environment},
          {QStringLiteral("cwd"), cwd},
      },
      [this](const QJsonObject& frame) {
        if (frame.value(QLatin1String("t")).toString() == QLatin1String("error")) {
          m_git.reset();
          m_gitError = frame.value(QLatin1String("reason")).toVariant().toString();
          emit gitChanged();
          publish();
          return;
        }
        if (frame.value(QLatin1String("t")).toString() != QLatin1String("vcs")) return;
        const QJsonObject event = frame.value(QLatin1String("event")).toObject();
        const QString tag = text(event, "_tag");
        Git git = m_git.value_or(Git{});
        const QString previousRef = m_git ? text(m_git->local, "refName") : QString();
        if (tag == QLatin1String("snapshot")) {
          git.local = event.value(QLatin1String("local")).toObject();
          git.remote = event.value(QLatin1String("remote")).toObject();
        } else if (tag == QLatin1String("localUpdated")) {
          git.local = event.value(QLatin1String("local")).toObject();
        } else if (tag == QLatin1String("remoteUpdated")) {
          git.remote = event.value(QLatin1String("remote")).toObject();
        } else {
          return;
        }
        m_git = git;
        if (tag == QLatin1String("localUpdated")) followCheckout(previousRef, text(git.local, "refName"));
        emit gitChanged();
        if (m_optimisticBranch && !m_switching && text(git.local, "refName") == *m_optimisticBranch) {
          m_optimisticBranch.reset();
        }
        publish();
      });
  if (hadRefs) loadRefs();
}

// A thread on another machine has that machine's editors and providers.
void WorkspaceController::watchConfig(const QString& environmentId) {
  if (environmentId == m_configEnvironment) return;
  if (m_config) m_client->unsubscribe(m_config);
  m_config = 0;
  m_configEnvironment = environmentId;
  m_configElsewhere = {};
  emit configChanged();
  if (environmentId.isEmpty()) return;
  m_config = m_client->subscribe(this, 
      {
          {QStringLiteral("type"), QStringLiteral("config")},
          {QStringLiteral("environment"), environmentId},
          {QStringLiteral("usageLimitsCommand"), true},
      },
      [this](const QJsonObject& frame) {
        const QString type = frame.value(QLatin1String("t")).toString();
        if (type == QLatin1String("config")) {
          m_configElsewhere = frame.value(QLatin1String("config")).toObject();
        } else if (type == QLatin1String("config.providers")) {
          m_configElsewhere.insert(QStringLiteral("providers"), frame.value(QLatin1String("providers")));
        } else {
          return;
        }
        emit configChanged();
        publish();
      });
}

QJsonObject WorkspaceController::environmentConfig() const {
  // Another machine that is down has none until it is back.
  if (m_place && m_place->environmentId != m_client->environment()) {
    return m_place->environmentId == m_configEnvironment ? m_configElsewhere : QJsonObject();
  }
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings ? settings->config() : QJsonObject();
}

void WorkspaceController::loadRefs() {
  if (!m_place || m_place->cwd().isEmpty()) return;
  const QString cwd = m_place->cwd();
  const QString environmentId = m_place->environmentId;
  const quint64 generation = ++m_refsGeneration;
  m_refsCwd = cwd;
  m_refsLoading = m_refs.isEmpty();
  QJsonObject input{{QStringLiteral("cwd"), cwd}, {QStringLiteral("limit"), 100}};
  const QString query = refName(m_query);
  if (!query.isEmpty()) input.insert(QStringLiteral("query"), query);
  m_client->call(this, environmentId, QStringLiteral("vcs.listRefs"), input,
                 [this, generation](const QJsonValue& result, const std::optional<QString>&) {
                   if (generation != m_refsGeneration) return;
                   m_refsLoading = false;
                   const QJsonObject list = result.toObject();
                   m_refs = list.value(QLatin1String("refs")).toArray();
                   m_refsTotal = list.value(QLatin1String("totalCount")).toInt(m_refs.size());
                   const QJsonValue next = list.value(QLatin1String("nextCursor"));
                   m_refsNextCursor = next.isDouble() ? std::optional(next.toInt()) : std::nullopt;
                   m_refsLoadingMore = false;
                   publish();
                 });
  publish();
}

void WorkspaceController::loadMoreRefs() {
  if (!m_place || m_place->cwd().isEmpty() || !m_refsNextCursor || m_refsLoadingMore || m_refsLoading) return;
  const quint64 generation = m_refsGeneration;
  m_refsLoadingMore = true;
  QJsonObject input{{QStringLiteral("cwd"), m_place->cwd()}, {QStringLiteral("limit"), 100}, {QStringLiteral("cursor"), *m_refsNextCursor}};
  const QString query = refName(m_query);
  if (!query.isEmpty()) input.insert(QStringLiteral("query"), query);
  m_client->call(this, m_place->environmentId, QStringLiteral("vcs.listRefs"), input,
                 [this, generation](const QJsonValue& result, const std::optional<QString>&) {
                   // A search or another checkout started the list over.
                   if (generation != m_refsGeneration) return;
                   m_refsLoadingMore = false;
                   const QJsonObject list = result.toObject();
                   for (const QJsonValue& ref : list.value(QLatin1String("refs")).toArray()) m_refs.append(ref);
                   m_refsTotal = list.value(QLatin1String("totalCount")).toInt(m_refsTotal);
                   const QJsonValue next = list.value(QLatin1String("nextCursor"));
                   m_refsNextCursor = next.isDouble() ? std::optional(next.toInt()) : std::nullopt;
                   publish();
                 });
}

// The web's resolveLiveThreadBranchUpdate, for a thread that was on the
// checkout's branch: a thread deliberately on another branch is left alone,
// as is a worktree's temporary branch.
void WorkspaceController::followCheckout(const QString& previousRef, const QString& ref) {
  if (!m_place || !m_place->draftId.isEmpty() || m_switching) return;
  if (previousRef.isEmpty() || ref.isEmpty() || previousRef == ref) return;
  if (optionalText(threadRow(), "branch") != std::optional(previousRef)) return;
  static const QRegularExpression temporary(
      QStringLiteral("^hal-c2/(?:[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$"));
  if (temporary.match(ref.trimmed().toLower()).hasMatch()) return;
  m_client->dispatchCommand(this, m_place->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                                {QStringLiteral("threadId"), m_place->threadId},
                                {QStringLiteral("branch"), ref},
                            },
                            [](const QJsonValue&, const std::optional<QString>&) {});
}

// --- What the header shows ------------------------------------------------------------

bool WorkspaceController::locked() const {
  const QJsonObject row = threadRow();
  if (row.isEmpty()) return false;
  const auto set = [&row](const char* key) {
    const QJsonValue value = row.value(QLatin1String(key));
    return !value.isNull() && !value.isUndefined() && !(value.isString() && value.toString().isEmpty());
  };
  return row.value(QLatin1String("itemCount")).toInt() > 0 || set("latestUserMessageAt") || set("latestRunId") ||
         set("activeProviderThreadId");
}

// BranchToolbar.logic resolveEffectiveEnvMode, with the mode picked for a
// server thread that has not started yet.
QString WorkspaceController::envMode() const {
  if (!m_place) return QStringLiteral("local");
  if (!m_place->draftId.isEmpty()) {
    if (!m_place->worktreePath.isEmpty()) return QStringLiteral("local");
    return m_checkouts.value(m_place->draftId).envMode;
  }
  if (!m_place->worktreePath.isEmpty()) return QStringLiteral("worktree");
  if (!locked() && m_pending.contains(m_place->threadKey())) return m_pending.value(m_place->threadKey()).envMode;
  return QStringLiteral("local");
}

bool WorkspaceController::envModeChangeable() const {
  if (!m_place) return false;
  if (!m_place->draftId.isEmpty()) return true;
  return !locked() && m_place->worktreePath.isEmpty();
}

QString WorkspaceController::currentBranch() const {
  if (!m_git || !m_git->local.value(QLatin1String("isRepo")).toBool(true)) return {};
  return text(m_git->local, "refName");
}

QJsonArray WorkspaceController::editors() const {
  const QJsonArray available = environmentConfig().value(QLatin1String("availableEditors")).toArray();
  QJsonArray result;
  for (const auto& [id, label] : editorLabels()) {
    if (available.contains(id)) result.append(QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("label"), label}});
  }
  return result;
}

// The one last opened, else the first the machine has.
QString WorkspaceController::preferredEditor(const QJsonArray& editors) const {
  if (editors.isEmpty()) return {};
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    const QString last = settings->deviceValue(kLastEditor).toString();
    for (const QJsonValue& editor : editors) {
      if (text(editor.toObject(), "id") == last) return last;
    }
  }
  return text(editors.first().toObject(), "id");
}

// BranchToolbar.logic's environment options: this project's checkout on each
// machine (projects sharing its repository), the MC's own first. A draft may
// also move to any project on a machine without a checkout.
QVariantList WorkspaceController::environmentChoices() const {
  if (!m_place) return {};
  const QString own = m_client->environment();
  const QJsonObject project = m_store->projectRow(m_place->environmentId, m_place->projectId);
  const QString repository =
      project.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString();
  struct Choice {
    QString environmentId;
    QString key;
    QString label;
    bool primary;
  };
  QList<Choice> checkouts;
  QList<Choice> elsewhere;
  for (const QString& environmentId : m_store->environments()) {
    const QJsonObject descriptor = m_store->environment(environmentId);
    const bool primary = environmentId == own;
    const QString label = primary ? primaryLabel(text(descriptor, "label"))
                                  : (text(descriptor, "label").isEmpty() ? environmentId : text(descriptor, "label"));
    QList<QJsonObject> projects = m_store->projectRows(environmentId);
    std::sort(projects.begin(), projects.end(),
              [](const QJsonObject& a, const QJsonObject& b) { return text(a, "title") < text(b, "title"); });
    const auto checkout = std::find_if(projects.cbegin(), projects.cend(), [&](const QJsonObject& row) {
      if (environmentId == m_place->environmentId && text(row, "id") == m_place->projectId) return true;
      return !repository.isEmpty() &&
             row.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString() ==
                 repository;
    });
    if (checkout != projects.cend()) {
      checkouts.append({environmentId, environmentId + QLatin1Char(':') + text(*checkout, "id"), label, primary});
    } else if (!m_place->draftId.isEmpty()) {
      for (const QJsonObject& row : std::as_const(projects)) {
        elsewhere.append({environmentId, environmentId + QLatin1Char(':') + text(row, "id"),
                          label + QStringLiteral(" · ") + text(row, "title"), primary});
      }
    }
  }
  std::stable_sort(checkouts.begin(), checkouts.end(), [](const Choice& a, const Choice& b) {
    if (a.primary != b.primary) return a.primary;
    return a.label.localeAwareCompare(b.label) < 0;
  });
  QVariantList result;
  for (const QList<Choice>* list : {&checkouts, &elsewhere}) {
    for (const Choice& choice : *list) {
      result.append(QVariantMap{
          {QStringLiteral("environmentId"), choice.environmentId},
          {QStringLiteral("key"), choice.key},
          {QStringLiteral("label"), choice.label},
      });
    }
  }
  return result;
}

QVariantMap WorkspaceController::build() const {
  if (!m_place) return {};
  const Place& place = *m_place;
  const bool draft = !place.draftId.isEmpty();
  const QJsonObject row = threadRow();
  const QJsonObject project = m_store->projectRow(place.environmentId, place.projectId);
  const Checkout checkout = m_checkouts.value(place.draftId);
  const QString mode = envMode();
  const bool changeable = envModeChangeable();
  QVariant previous = QVariant::fromValue(nullptr);
  if (const std::optional<PreviousWorktree> seed = previousWorktree()) {
    previous = QVariantMap{{QStringLiteral("label"), seed->branch ? QStringLiteral("Previous worktree (%1)").arg(*seed->branch)
                                                                  : QStringLiteral("Previous worktree")}};
  }

  // BranchToolbar.logic resolveBranchToolbarValue.
  const std::optional<QString> threadBranch = draft ? checkout.branch : optionalText(row, "branch");
  const QString current = currentBranch();
  std::optional<QString> branch;
  if (mode == QLatin1String("worktree") && place.worktreePath.isEmpty()) {
    branch = threadBranch ? threadBranch : (current.isEmpty() ? std::nullopt : std::optional(current));
  } else {
    branch = !current.isEmpty() ? std::optional(current) : threadBranch;
  }
  if (m_optimisticBranch) branch = m_optimisticBranch;

  QVariant git = QVariant::fromValue(nullptr);
  bool canOpenPullRequest = false;
  if (m_git) {
    const QJsonObject pr = m_git->remote.value(QLatin1String("pr")).toObject();
    QVariant pullRequest = QVariant::fromValue(nullptr);
    if (!pr.isEmpty()) {
      canOpenPullRequest = true;
      pullRequest = QVariantMap{
          {QStringLiteral("number"), pr.value(QLatin1String("number")).toInt()},
          {QStringLiteral("title"), text(pr, "title")},
          {QStringLiteral("url"), text(pr, "url")},
          {QStringLiteral("state"), text(pr, "state")},
      };
    }
    git = QVariantMap{
        {QStringLiteral("isRepo"), m_git->local.value(QLatin1String("isRepo")).toBool(true)},
        {QStringLiteral("hasWorkingTreeChanges"), m_git->local.value(QLatin1String("hasWorkingTreeChanges")).toBool()},
        {QStringLiteral("aheadCount"), m_git->remote.value(QLatin1String("aheadCount")).toInt()},
        {QStringLiteral("behindCount"), m_git->remote.value(QLatin1String("behindCount")).toInt()},
        {QStringLiteral("hasUpstream"), m_git->remote.value(QLatin1String("hasUpstream")).toBool()},
        {QStringLiteral("pullRequest"), pullRequest},
    };
  }

  const QJsonArray editorList = editors();
  const QString projectKey = place.environmentId + QLatin1Char(':') + place.projectId;
  QString lastScript = m_lastScript.value(projectKey);
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    lastScript = settings->deviceValue(kLastScripts).toMap().value(projectKey, lastScript).toString();
  }
  bool known = false;
  for (const QJsonValue& script : place.scripts) known = known || text(script.toObject(), "id") == lastScript;

  QVariantList branches;
  for (const QJsonValue& value : m_refs) {
    const QJsonObject ref = value.toObject();
    branches.append(QVariantMap{
        {QStringLiteral("name"), text(ref, "name")},
        {QStringLiteral("isRemote"), ref.value(QLatin1String("isRemote")).toBool()},
        {QStringLiteral("isDefault"), ref.value(QLatin1String("isDefault")).toBool()},
        {QStringLiteral("current"), ref.value(QLatin1String("current")).toBool()},
    });
  }

  return {
      {QStringLiteral("threadKey"), place.threadKey()},
      {QStringLiteral("projectTitle"), nullable(text(project, "title"))},
      {QStringLiteral("projectRoot"), nullable(place.root)},
      {QStringLiteral("threadTitle"), draft ? QStringLiteral("New thread") : text(row, "title")},
      {QStringLiteral("isDraft"), draft},
      {QStringLiteral("envMode"), mode},
      {QStringLiteral("envModeLabel"),
       changeable ? (mode == QLatin1String("worktree") ? QStringLiteral("New worktree")
                                                       : QStringLiteral("Current checkout"))
                  : (place.worktreePath.isEmpty() ? QStringLiteral("Local checkout") : QStringLiteral("Worktree"))},
      {QStringLiteral("envModeChangeable"), changeable},
      {QStringLiteral("startFromOrigin"), checkout.startFromOrigin},
      {QStringLiteral("branch"), nullable(branch)},
      {QStringLiteral("worktreePath"), nullable(place.worktreePath)},
      {QStringLiteral("git"), git},
      {QStringLiteral("canOpenPullRequest"), canOpenPullRequest},
      {QStringLiteral("editors"), editorList.toVariantList()},
      {QStringLiteral("preferredEditorId"), nullable(preferredEditor(editorList))},
      {QStringLiteral("scripts"), place.scripts.toVariantList()},
      {QStringLiteral("preferredScriptId"), known ? QVariant(lastScript) : QVariant::fromValue(nullptr)},
      {QStringLiteral("environments"), environmentChoices()},
      {QStringLiteral("activeEnvironmentId"), place.environmentId},
      // The MC serving it is out of reach (a cluster member asleep).
      {QStringLiteral("offline"), !m_store->environmentOnline(place.environmentId)},
      {QStringLiteral("environmentChangeable"), draft},
      {QStringLiteral("renameRequestId"), m_renameRequestId},
      {QStringLiteral("branchQuery"), m_query},
      {QStringLiteral("branches"), branches},
      {QStringLiteral("branchesTotal"), std::max(m_refsTotal, int(m_refs.size()))},
      {QStringLiteral("branchesLoading"), m_refsLoading},
      {QStringLiteral("branchSwitchPending"), m_switching},
      {QStringLiteral("branchChangeable"), !place.cwd().isEmpty()},
      {QStringLiteral("previousWorktree"), previous},
  };
}

std::optional<WorkspaceController::PreviousWorktree> WorkspaceController::previousWorktree() const {
  if (!m_place || m_place->draftId.isEmpty()) return std::nullopt;
  std::optional<PreviousWorktree> latest;
  qint64 latestAt = 0;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.environmentId != m_place->environmentId || thread.projectId != m_place->projectId || thread.archivedAt) {
      continue;
    }
    const QJsonObject row = m_store->threadRow(thread.key());
    const QString worktreePath = text(row, "worktreePath");
    const std::optional<qint64> updatedAt = sidebar::parseIso(thread.updatedAt);
    if (worktreePath.isEmpty() || worktreePath == m_place->worktreePath || !updatedAt) continue;
    if (!latest || *updatedAt > latestAt) {
      latest = PreviousWorktree{optionalText(row, "branch"), worktreePath};
      latestAt = *updatedAt;
    }
  }
  return latest;
}

// BranchToolbar's usePreviousWorktree: the draft points at the existing
// worktree, as picking a branch checked out there does, and the composer
// takes the keyboard back.
void WorkspaceController::usePreviousWorktree() {
  const std::optional<PreviousWorktree> previous = previousWorktree();
  if (!previous) return;
  setThreadBranch(previous->branch, previous->worktreePath);
  m_bridge->sendToBricks(QStringLiteral("composer.focus"));
}

void WorkspaceController::publish() {
  if (!m_active) return;
  const QVariantMap state = build();
  if (m_published && state == *m_published) return;
  m_published = state;
  m_bridge->publish(QStringLiteral("workspace"), state.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(state));
}

// --- What the header does -------------------------------------------------------------

bool WorkspaceController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("workspace."))) return false;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("workspace.rename.begin")) {
    const QString threadKey = args.value(QStringLiteral("threadKey")).toString();
    if (m_place && m_place->threadKey() == threadKey) {
      ++m_renameRequestId;
      publish();
    } else {
      // The route is on its way there.
      m_renameWanted = threadKey;
    }
    return true;
  }
  // The header's project: a new thread there (DraftController).
  if (action == QLatin1String("workspace.newThread")) {
    m_bridge->dispatch(QStringLiteral("thread.new"));
    return true;
  }
  if (!m_place) return true;
  if (action == QLatin1String("workspace.openPullRequest")) {
    openPullRequest();
    return true;
  }
  if (action == QLatin1String("workspace.previousWorktree")) {
    usePreviousWorktree();
    return true;
  }
  if (action == QLatin1String("workspace.rename")) {
    rename(args.value(QStringLiteral("title")).toString());
  } else if (action == QLatin1String("workspace.openInEditor")) {
    openInEditor(args.value(QStringLiteral("editorId")).toString());
  } else if (action == QLatin1String("workspace.openFile")) {
    openFileInEditor(args.value(QStringLiteral("path")).toString());
  } else if (action == QLatin1String("workspace.runScript")) {
    runScript(args.value(QStringLiteral("scriptId")).toString());
  } else if (action == QLatin1String("workspace.branch.search")) {
    m_query = args.value(QStringLiteral("query")).toString();
    loadRefs();
  } else if (action == QLatin1String("workspace.branch.select")) {
    selectBranch(args.value(QStringLiteral("name")).toString());
  } else if (action == QLatin1String("workspace.branch.create")) {
    createBranch(args.value(QStringLiteral("name")).toString());
  } else if (action == QLatin1String("workspace.branch.more")) {
    loadMoreRefs();
  } else if (action == QLatin1String("workspace.branch.copy")) {
    // The branch the header names (the web's "Copy branch name").
    const QString branch = build().value(QStringLiteral("branch")).toString();
    if (!branch.isEmpty()) {
      NativeShell::of(this)->controller<ThreadMenuController>()->copy(branch, QStringLiteral("Branch name copied"),
                                                                    QStringLiteral("Failed to copy branch name"));
    }
  } else if (action == QLatin1String("workspace.envMode.set")) {
    setEnvMode(args.value(QStringLiteral("mode")).toString());
  } else if (action == QLatin1String("workspace.startFromOrigin.set")) {
    if (!m_place->draftId.isEmpty()) {
      const bool enabled = args.value(QStringLiteral("enabled")).toBool();
      updateCheckout([enabled](Checkout& checkout) { checkout.startFromOrigin = enabled; });
    }
  } else if (action == QLatin1String("workspace.environment.set")) {
    const QString environmentId = args.value(QStringLiteral("environmentId")).toString();
    QString key = args.value(QStringLiteral("key")).toString();
    if (key.isEmpty()) {
      // An older sender names only the machine: its checkout of this project.
      for (const QVariant& choice : environmentChoices()) {
        if (choice.toMap().value(QStringLiteral("environmentId")).toString() == environmentId) {
          key = choice.toMap().value(QStringLiteral("key")).toString();
          break;
        }
      }
    }
    setEnvironment(key);
  }
  return true;
}

// useRenameThread.
void WorkspaceController::rename(const QString& title) {
  if (!m_place->draftId.isEmpty()) return;
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const QString trimmed = title.trimmed();
  if (trimmed.isEmpty()) {
    toasts->show(QStringLiteral("warning"), QStringLiteral("Thread title cannot be empty"));
    return;
  }
  if (trimmed == text(threadRow(), "title")) return;
  m_client->dispatchCommand(this, m_place->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                                {QStringLiteral("threadId"), m_place->threadId},
                                {QStringLiteral("title"), trimmed},
                            },
                            [toasts](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) toasts->error(QStringLiteral("Failed to rename thread"), *error);
                            });
}

void WorkspaceController::openInEditor(const QString& editorId) {
  if (m_place) openInEditor(editorId, m_place->cwd());
}

bool WorkspaceController::openInEditor(const QString& editorId, const QString& path, bool reveal) {
  if (!m_place || path.isEmpty()) return false;
  const QJsonArray available = editors();
  const QString editor = reveal ? QStringLiteral("file-manager") : editorId.isEmpty() ? preferredEditor(available) : editorId;
  bool known = false;
  for (const QJsonValue& value : available) known = known || text(value.toObject(), "id") == editor;
  if (!known) return false;
  // Showing a file in its folder is not choosing an editor.
  if (!reveal) {
    if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) settings->writeDevice(kLastEditor, editor);
  }
  QJsonObject payload{{QStringLiteral("cwd"), path}, {QStringLiteral("editor"), editor}};
  if (reveal) payload.insert(QStringLiteral("reveal"), true);
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  m_client->call(this, m_place->environmentId, QStringLiteral("shell.openInEditor"), payload,
                 [toasts](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) toasts->error(QStringLiteral("Failed to open in editor."), *error);
                 });
  publish();
  return true;
}

// The web's openChangedFileInEditor (GitActionsControl.tsx).
void WorkspaceController::openFileInEditor(const QString& path) {
  if (!m_place || path.isEmpty()) return;
  const QString cwd = m_place->cwd();
  const QString target = path.startsWith(QLatin1Char('/')) || cwd.isEmpty() ? path : cwd + QLatin1Char('/') + path;
  // The same way the Files tab opens one; with no editor it says so.
  if (cwd.isEmpty() || !openInEditor({}, target)) {
    NativeShell::of(this)->controller<ToastController>()->error(QStringLiteral("Editor opening is unavailable."));
  }
}

// In the thread's terminal drawer; the one run last is offered first next time.
void WorkspaceController::runScript(const QString& scriptId) {
  auto* terminals = NativeShell::of(this)->controller<TerminalController>();
  if (!terminals || !terminals->runScript(scriptId)) return;
  const QString projectKey = m_place->environmentId + QLatin1Char(':') + m_place->projectId;
  m_lastScript.insert(projectKey, scriptId);
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    QVariantMap last = settings->deviceValue(kLastScripts).toMap();
    last.insert(projectKey, scriptId);
    settings->writeDevice(kLastScripts, last);
  }
  publish();
}

void WorkspaceController::setEnvMode(const QString& mode) {
  if (!envModeChangeable() || (mode != QLatin1String("local") && mode != QLatin1String("worktree"))) return;
  if (!m_place->draftId.isEmpty()) {
    updateCheckout([mode](Checkout& checkout) {
      checkout.envMode = mode;
      if (mode == QLatin1String("worktree")) checkout.worktreePath.reset();
    });
    return;
  }
  m_pending[m_place->threadKey()].envMode = mode;
  publish();
}

// "Run on": a draft moves to that machine's checkout of the project.
void WorkspaceController::setEnvironment(const QString& key) {
  if (m_place->draftId.isEmpty()) return;
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  if (colon <= 0) return;
  const QString environmentId = key.left(colon);
  const QString projectId = key.mid(colon + 1);
  if (m_store->projectRow(environmentId, projectId).isEmpty()) return;
  if (environmentId == m_place->environmentId && projectId == m_place->projectId) return;
  updateCheckout([&](Checkout& checkout) {
    checkout.environmentId = environmentId;
    checkout.projectId = projectId;
    checkout.branch.reset();
    checkout.worktreePath.reset();
  });
}

// useThreadBranchSelection selectBranch.
void WorkspaceController::selectBranch(const QString& name) {
  if (m_switching || m_place->cwd().isEmpty() || m_place->root.isEmpty()) return;
  QJsonObject ref;
  for (const QJsonValue& value : std::as_const(m_refs)) {
    if (text(value.toObject(), "name") == name) ref = value.toObject();
  }
  if (ref.isEmpty()) return;
  const QString activeWorktree = m_place->worktreePath;
  if (envMode() == QLatin1String("worktree") && activeWorktree.isEmpty() && !locked()) {
    // Picking the base of the worktree the thread will start in.
    setThreadBranch(name, std::nullopt);
    return;
  }
  // BranchToolbar.logic resolveBranchSelectionTarget.
  const QString refWorktree = text(ref, "worktreePath");
  if (!refWorktree.isEmpty()) {
    setThreadBranch(name, refWorktree == m_place->root ? std::nullopt : std::optional(refWorktree));
    return;
  }
  const std::optional<QString> nextWorktree =
      activeWorktree.isEmpty() || ref.value(QLatin1String("isDefault")).toBool() ? std::nullopt
                                                                                : std::optional(activeWorktree);
  const QString checkoutCwd = nextWorktree.value_or(m_place->root);
  const bool remote = ref.value(QLatin1String("isRemote")).toBool();
  const QString local = remote ? localBranchOf(name) : name;
  const std::optional<QString> previous = m_optimisticBranch;
  m_optimisticBranch = local;
  m_switching = true;
  publish();
  const QString threadKey = m_place->threadKey();
  m_client->call(this, m_place->environmentId, QStringLiteral("vcs.switchRef"),
                 QJsonObject{{QStringLiteral("cwd"), checkoutCwd}, {QStringLiteral("refName"), name}},
                 [this, threadKey, previous, remote, local, nextWorktree](const QJsonValue& result,
                                                                         const std::optional<QString>& error) {
                   m_switching = false;
                   const bool here = m_place && m_place->threadKey() == threadKey;
                   if (error) {
                     if (here) m_optimisticBranch = previous;
                     NativeShell::of(this)->controller<ToastController>()->error(QStringLiteral("Failed to switch ref."),
                                                                                *error);
                   } else if (here) {
                     const QJsonValue switched = result.toObject().value(QLatin1String("refName"));
                     const QString branch = remote && switched.isString() ? switched.toString() : local;
                     m_optimisticBranch = branch;
                     setThreadBranch(branch, nextWorktree);
                   }
                   if (here) loadRefs();
                   publish();
                 });
}

// useThreadBranchSelection createRef.
void WorkspaceController::createBranch(const QString& raw) {
  const QString name = refName(raw);
  const QString cwd = m_place->cwd();
  if (name.isEmpty() || cwd.isEmpty() || m_switching) return;
  const std::optional<QString> previous = m_optimisticBranch;
  const std::optional<QString> worktree =
      m_place->worktreePath.isEmpty() ? std::nullopt : std::optional(m_place->worktreePath);
  m_optimisticBranch = name;
  m_switching = true;
  publish();
  const QString threadKey = m_place->threadKey();
  m_client->call(this, m_place->environmentId, QStringLiteral("vcs.createRef"),
                 QJsonObject{{QStringLiteral("cwd"), cwd},
                             {QStringLiteral("refName"), name},
                             {QStringLiteral("switchRef"), true}},
                 [this, threadKey, previous, name, worktree](const QJsonValue& result,
                                                             const std::optional<QString>& error) {
                   m_switching = false;
                   const bool here = m_place && m_place->threadKey() == threadKey;
                   if (error) {
                     if (here) m_optimisticBranch = previous;
                     NativeShell::of(this)->controller<ToastController>()->error(
                         QStringLiteral("Failed to create and switch ref."), *error);
                   } else if (here) {
                     const QString created = result.toObject().value(QLatin1String("refName")).toString(name);
                     m_optimisticBranch = created;
                     m_query.clear();
                     setThreadBranch(created, worktree);
                   }
                   if (here) loadRefs();
                   publish();
                 });
}

// useThreadBranchSelection setThreadBranch: a server thread's metadata (its
// live session stopped when the checkout moves), or the draft's checkout.
void WorkspaceController::setThreadBranch(const std::optional<QString>& branch,
                                          const std::optional<QString>& worktreePath) {
  const std::optional<QString> activeWorktree =
      m_place->worktreePath.isEmpty() ? std::nullopt : std::optional(m_place->worktreePath);
  if (m_place->draftId.isEmpty()) {
    const QJsonObject row = threadRow();
    const QJsonValue session = row.value(QLatin1String("activeProviderThreadId"));
    if (session.isString() && !session.toString().isEmpty() && worktreePath != activeWorktree) {
      m_client->dispatchCommand(this, m_place->environmentId,
                                {
                                    {QStringLiteral("type"), QStringLiteral("provider-session.detach")},
                                    {QStringLiteral("threadId"), m_place->threadId},
                                    {QStringLiteral("reason"), QStringLiteral("client-requested")},
                                },
                                [](const QJsonValue&, const std::optional<QString>&) {});
    }
    m_client->dispatchCommand(this, m_place->environmentId,
                              {
                                  {QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                                  {QStringLiteral("threadId"), m_place->threadId},
                                  {QStringLiteral("branch"), branch ? QJsonValue(*branch) : QJsonValue()},
                                  {QStringLiteral("worktreePath"),
                                   worktreePath ? QJsonValue(*worktreePath) : QJsonValue()},
                              },
                              [](const QJsonValue&, const std::optional<QString>&) {});
    return;
  }
  // BranchToolbar.logic resolveDraftEnvModeAfterBranchChange.
  const QString mode = worktreePath || (envMode() == QLatin1String("worktree") && !activeWorktree)
                           ? QStringLiteral("worktree")
                           : QStringLiteral("local");
  updateCheckout([&](Checkout& checkout) {
    checkout.branch = branch;
    checkout.worktreePath = worktreePath;
    checkout.envMode = mode;
  });
}

void WorkspaceController::updateCheckout(const std::function<void(Checkout&)>& edit) {
  edit(m_checkouts[m_place->draftId]);
  refresh();
}

void WorkspaceController::setCheckout(const QString& draftId, const Checkout& checkout) {
  m_checkouts.insert(draftId, checkout);
  refresh();
}

void WorkspaceController::refreshGit() {
  if (!m_place || m_vcsKey.isEmpty()) return;
  m_client->call(this, m_place->environmentId, QStringLiteral("vcs.refreshStatus"),
                 QJsonObject{{QStringLiteral("cwd"), m_place->cwd()}},
                 [](const QJsonValue&, const std::optional<QString>&) {});
}

// The checkout's pull request, in the browser.
void WorkspaceController::openPullRequest() {
  const QString url = m_git ? text(m_git->remote.value(QLatin1String("pr")).toObject(), "url") : QString();
  if (!url.isEmpty()) m_bridge->openExternal(QUrl(url));
}
