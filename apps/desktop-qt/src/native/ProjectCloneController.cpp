#include "ProjectCloneController.h"

#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QRegularExpression>
#include <QSet>
#include <QUuid>

#include <algorithm>

#include "CommandPaletteController.h"
#include "DraftController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "ProjectController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ProjectCloneController> registrar(QStringLiteral("projectClones"));

const QString kSourceControlSettings = QStringLiteral("/settings/source-control");
// A finished clone's toast stays this long.
constexpr int kDoneToastMs = 8000;

// The owner/repo shorthand taken as a public GitHub repository.
const QRegularExpression kGitHubShorthand(QStringLiteral(R"(^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+(?:\.git)?$)"));

QString normalizePastedCloneUrl(const QString& input) {
  const QString trimmed = input.trimmed();
  if (!kGitHubShorthand.match(trimmed).hasMatch()) return trimmed;
  return QStringLiteral("https://github.com/") + trimmed +
         (trimmed.endsWith(QLatin1String(".git")) ? QString() : QStringLiteral(".git"));
}

// The folder `git clone` would pick:
// the last segment of an owner/repo or any form of remote URL, minus ".git";
// empty for a URL that stops at its host or port.
QString cloneDirectoryName(const QString& repositoryOrUrl) {
  const QString bare = repositoryOrUrl.section(QRegularExpression(QStringLiteral("[?#]")), 0, 0).trimmed();
  const qsizetype scheme = bare.indexOf(QLatin1String("://"));
  const bool hasHost = scheme >= 0 || QRegularExpression(QStringLiteral(R"(^[^/\\:]+@[^/\\:]+:)")).match(bare).hasMatch();
  const QString path = scheme >= 0 ? bare.mid(scheme + 3) : bare;
  QStringList segments = path.split(QRegularExpression(QStringLiteral(R"([/\\:]+)")), Qt::SkipEmptyParts);
  segments.removeIf([](const QString& segment) { return segment.trimmed().isEmpty(); });
  if (hasHost && segments.size() < 2) return {};
  const QString last = segments.isEmpty() ? QString() : segments.constLast().trimmed();
  if (hasHost && segments.size() == 2 && QRegularExpression(QStringLiteral(R"(^\d+$)")).match(last).hasMatch()) return {};
  return last.endsWith(QLatin1String(".git")) ? last.chopped(4) : last;
}

QString cloneDestinationPath(QString directory, const QString& name) {
  if (name.trimmed().isEmpty()) return directory;
  if (!directory.endsWith(QLatin1Char('/')) && !directory.endsWith(QLatin1Char('\\'))) directory += QLatin1Char('/');
  return directory + name.trimmed();
}

QString optionValue(const QJsonValue& option) {
  const QJsonObject object = option.toObject();
  return object.value(QLatin1String("_tag")) == QLatin1String("Some") ? object.value(QLatin1String("value")).toString()
                                                                      : QString();
}

// What a clone is called, and a summary of its progress.
QString displayName(const QJsonObject& clone) {
  const QString name = clone.value(QLatin1String("repository")).toObject().value(QLatin1String("nameWithOwner")).toString();
  if (!name.isEmpty()) return name;
  const QString destination = clone.value(QLatin1String("destinationPath")).toString();
  const QStringList segments = destination.split(QRegularExpression(QStringLiteral(R"([/\\])")), Qt::SkipEmptyParts);
  return segments.isEmpty() ? destination : segments.constLast();
}

QString progressSummary(const QJsonObject& clone) {
  static const QHash<QString, QString> labels{
      {QStringLiteral("connecting"), QStringLiteral("Connecting")},
      {QStringLiteral("counting"), QStringLiteral("Counting objects")},
      {QStringLiteral("receiving"), QStringLiteral("Receiving objects")},
      {QStringLiteral("resolving"), QStringLiteral("Resolving deltas")},
      {QStringLiteral("checkout"), QStringLiteral("Checking out files")},
  };
  QStringList parts{labels.value(clone.value(QLatin1String("stage")).toString())};
  if (clone.value(QLatin1String("percent")).isDouble()) parts << QStringLiteral("%1%").arg(clone.value(QLatin1String("percent")).toInt());
  const QString detail = clone.value(QLatin1String("detail")).toString();
  if (!detail.isEmpty()) parts << detail;
  return parts.join(QStringLiteral(" · "));
}

QString errorText(const std::optional<QString>& error) {
  return error && !error->isEmpty() ? *error : QStringLiteral("An error occurred.");
}

}  // namespace

ProjectCloneController::ProjectCloneController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                               QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  connect(store, &ShellStore::changed, this, [this] {
    if (!m_active) return;
    follow();
    if (m_started && m_store->project(m_started->first + QLatin1Char(':') + m_started->second)) {
      const auto [environmentId, projectId] = *std::exchange(m_started, std::nullopt);
      openProject(environmentId, projectId);
    }
  });
}

void ProjectCloneController::activate() {
  if (m_active) return;
  m_active = true;
  follow();
}

// --- Sources -------------------------------------------------------------------------

QList<CommandRegistry::Choice> ProjectCloneController::sources(const QString& environmentId) {
  // Asked again each time they are shown; a new answer refreshes them.
  discover(environmentId);
  static const QList<Source> providers{
      {QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("owner/repo")},
      {QStringLiteral("gitlab"), QStringLiteral("GitLab"), QStringLiteral("group/project")},
      {QStringLiteral("forgejo"), QStringLiteral("Forgejo / Gitea"), QStringLiteral("owner/repo")},
      {QStringLiteral("bitbucket"), QStringLiteral("Bitbucket"), QStringLiteral("workspace/repository")},
      {QStringLiteral("azure-devops"), QStringLiteral("Azure DevOps"), QStringLiteral("project/repository")},
  };
  // Git URL, then the providers ready first, each part by label.
  QList<Source> ordered = providers;
  std::stable_sort(ordered.begin(), ordered.end(), [&](const Source& left, const Source& right) {
    const bool leftReady = readiness(environmentId, left.kind).ready;
    const bool rightReady = readiness(environmentId, right.kind).ready;
    if (leftReady != rightReady) return leftReady;
    return left.label.localeAwareCompare(right.label) < 0;
  });
  ordered.prepend({QStringLiteral("url"), QStringLiteral("Git URL"), QStringLiteral("URL")});

  QList<CommandRegistry::Choice> choices;
  for (const Source& source : std::as_const(ordered)) {
    const bool url = source.kind == QLatin1String("url");
    CommandRegistry::Choice choice{QStringLiteral("clone-") + source.kind,
                                   url ? tr("Git URL") : tr("%1 repository").arg(source.label),
                                   url ? tr("Clone from a remote URL") : tr("Clone %1 %2").arg(source.label, source.hint)};
    choice.terms = {QStringLiteral("clone"), QStringLiteral("remote"), QStringLiteral("repository"),
                    QStringLiteral("repo"), QStringLiteral("git"), source.label};
    const Readiness ready = readiness(environmentId, source.kind);
    if (ready.ready) {
      choice.keepOpen = true;
      choice.run = [this, environmentId, source] { askRepository(environmentId, source); };
    } else {
      // The web disables it and offers its Setup Required button, which opens
      // the settings; here choosing the row is pressing that button.
      choice.description = tr("Setup Required · %1")
                               .arg(ready.hint.isEmpty() ? tr("Open Settings -> Source Control to configure this provider.")
                                                         : ready.hint);
      choice.terms << QStringLiteral("setup required");
      choice.run = [this] {
        NativeShell::of(this)->controller<NavigationController>()->open(
            NavigationController::Route::settings(kSourceControlSettings));
      };
    }
    choices.append(choice);
  }
  return choices;
}

// Whether the remote source can be cloned from.
ProjectCloneController::Readiness ProjectCloneController::readiness(const QString& environmentId,
                                                                   const QString& kind) const {
  if (kind == QLatin1String("url")) return {true, {}};
  const Readiness unavailable{false, tr("Provider status unavailable. Open Settings -> Source Control and rescan.")};
  const std::optional<QJsonObject>& discovery = m_discovery.value(environmentId).result;
  if (!discovery) return unavailable;
  for (const QJsonValue& value : discovery->value(QLatin1String("sourceControlProviders")).toArray()) {
    const QJsonObject provider = value.toObject();
    if (provider.value(QLatin1String("kind")).toString() != kind) continue;
    if (provider.value(QLatin1String("status")).toString() != QLatin1String("available")) {
      return {false, provider.value(QLatin1String("installHint")).toString()};
    }
    const QJsonObject auth = provider.value(QLatin1String("auth")).toObject();
    if (auth.value(QLatin1String("status")).toString() == QLatin1String("unauthenticated")) {
      const QString detail = optionValue(auth.value(QLatin1String("detail")));
      return {false, !detail.isEmpty() ? detail
                                       : tr("%1 is not authenticated. Open Settings -> Source Control for setup guidance.")
                                             .arg(provider.value(QLatin1String("label")).toString())};
    }
    return {true, {}};
  }
  return unavailable;
}

void ProjectCloneController::discover(const QString& environmentId) {
  Discovery& discovery = m_discovery[environmentId];
  if (discovery.asking || !m_store->environmentOnline(environmentId)) return;
  discovery.asking = true;
  m_client->call(this, environmentId, QStringLiteral("server.discoverSourceControl"), QJsonObject{},
                 [this, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                   Discovery& discovery = m_discovery[environmentId];
                   discovery.asking = false;
                   // A failed scan keeps what the last one found.
                   if (error || discovery.result == result.toObject()) return;
                   discovery.result = result.toObject();
                   NativeShell::of(this)->controller<CommandPaletteController>()->refreshMenu();
                 });
}

// --- Repository and destination --------------------------------------------------------

void ProjectCloneController::askRepository(const QString& environmentId, const Source& source) {
  const bool url = source.kind == QLatin1String("url");
  m_busy = false;
  ++m_lookup;
  NativeShell::of(this)->controller<CommandPaletteController>()->ask(
      url ? tr("Git URL") : tr("%1 repository").arg(source.label),
      url ? tr("Enter Git clone URL") : tr("Enter %1 repository (%2)").arg(source.label, source.hint),
      url ? tr("Enter a Git clone URL and press Enter to continue.")
          : tr("Enter a repository path and press Enter to look it up."),
      [this, environmentId, source](const QString& input) { submitRepository(environmentId, source, input); });
}

void ProjectCloneController::submitRepository(const QString& environmentId, const Source& source, const QString& input) {
  if (!connected(environmentId) || m_busy) return;
  if (source.kind == QLatin1String("url")) {
    askDestination({environmentId, normalizePastedCloneUrl(input), cloneDirectoryName(input)});
    return;
  }
  m_busy = true;
  const int lookup = ++m_lookup;
  m_client->call(this, environmentId, QStringLiteral("sourceControl.lookupRepository"),
                 QJsonObject{{QStringLiteral("provider"), source.kind}, {QStringLiteral("repository"), input}},
                 [this, environmentId, lookup](const QJsonValue& result, const std::optional<QString>& error) {
                   // The user moved on meanwhile.
                   if (lookup != m_lookup) return;
                   m_busy = false;
                   if (error) {
                     NativeShell::of(this)->controller<ToastController>()->error(tr("Repository lookup failed"),
                                                                                 errorText(error));
                     return;
                   }
                   const QJsonObject repository = result.toObject();
                   // GitHub and Forgejo clone over HTTPS; the others keep SSH.
                   const QString provider = repository.value(QLatin1String("provider")).toString();
                   const bool https = provider == QLatin1String("github") || provider == QLatin1String("forgejo");
                   askDestination({environmentId,
                                   repository.value(https ? QLatin1String("url") : QLatin1String("sshUrl")).toString(),
                                   cloneDirectoryName(repository.value(QLatin1String("nameWithOwner")).toString())});
                 });
}

void ProjectCloneController::askDestination(const Chosen& chosen) {
  CommandPaletteController::BrowseOptions options;
  options.query = cloneDestinationPath(NativeShell::of(this)->controller<ProjectController>()->browseStart(chosen.environmentId),
                                       chosen.directoryName);
  options.pinned = chosen.directoryName;
  options.emptyText = tr("Choose a destination path and press Enter to clone.");
  options.keepOpen = true;
  m_busy = false;
  NativeShell::of(this)->controller<CommandPaletteController>()->browse(
      chosen.environmentId, [this, chosen](const QString& path) { start(chosen, path); }, options);
}

void ProjectCloneController::start(const Chosen& chosen, const QString& input) {
  if (!connected(chosen.environmentId) || m_busy) return;
  auto* shell = NativeShell::of(this);
  auto* toasts = shell->controller<ToastController>();
  QString destination = input.trimmed();
  if (destination.isEmpty()) return;
  const bool windowsPath = QRegularExpression(QStringLiteral(R"(^(?:[A-Za-z]:[\\/]|\\\\))")).match(destination).hasMatch();
  const QString os = m_store->environment(chosen.environmentId).value(QLatin1String("platform")).toObject().value(QLatin1String("os")).toString();
  if (windowsPath && !os.startsWith(QLatin1String("win"))) {
    toasts->error(tr("Clone failed"), tr("Windows-style paths are only supported on Windows."));
    return;
  }
  // A relative path is under the project the window shows.
  if (destination == QLatin1String(".") || destination == QLatin1String("..") ||
      destination.startsWith(QLatin1String("./")) || destination.startsWith(QLatin1String("../"))) {
    const QString threadKey = shell->controller<NavigationController>()->threadKey();
    const QJsonObject thread = m_store->threadRow(threadKey);
    const QString root = threadKey.startsWith(chosen.environmentId + QLatin1Char(':'))
                             ? m_store->projectRow(chosen.environmentId, thread.value(QLatin1String("projectId")).toString())
                                   .value(QLatin1String("workspaceRoot"))
                                   .toString()
                             : QString();
    if (root.isEmpty()) {
      toasts->error(tr("Clone failed"), tr("Relative paths require an active project."));
      return;
    }
    destination = QDir::cleanPath(root + QLatin1Char('/') + destination);
  }
  QString title = destination;
  while (title.size() > 1 && (title.endsWith(QLatin1Char('/')) || title.endsWith(QLatin1Char('\\')))) title.chop(1);
  title = title.section(QRegularExpression(QStringLiteral(R"([/\\])")), -1);

  const QString projectId = QUuid::createUuid().toString(QUuid::WithoutBraces);
  m_busy = true;
  m_client->call(this, chosen.environmentId, QStringLiteral("projectClone.start"),
                 QJsonObject{{QStringLiteral("projectId"), projectId},
                             {QStringLiteral("title"), title},
                             {QStringLiteral("createdAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
                             {QStringLiteral("remoteUrl"), chosen.remoteUrl},
                             {QStringLiteral("destinationPath"), destination}},
                 [this, environmentId = chosen.environmentId, projectId](const QJsonValue&,
                                                                          const std::optional<QString>& error) {
                   m_busy = false;
                   auto* shell = NativeShell::of(this);
                   if (error) {
                     // The palette stays for another destination.
                     shell->controller<ToastController>()->error(tr("Clone failed"), errorText(error));
                     return;
                   }
                   // The clone goes on in the background, in its toast.
                   shell->controller<CommandPaletteController>()->finish();
                   if (m_store->project(environmentId + QLatin1Char(':') + projectId)) {
                     openProject(environmentId, projectId);
                   } else {
                     m_started = {environmentId, projectId};
                   }
                 });
}

bool ProjectCloneController::connected(const QString& environmentId) {
  if (m_store->environmentOnline(environmentId)) return true;
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  NativeShell::of(this)->controller<ToastController>()->error(
      tr("Environment unavailable"),
      tr("%1 is not connected.").arg(label.isEmpty() ? tr("The selected environment") : label));
  return false;
}

void ProjectCloneController::openProject(const QString& environmentId, const QString& projectId) {
  if (NativeShell::of(this)->controller<DraftController>()->start(environmentId, projectId).isEmpty()) {
    NativeShell::of(this)->controller<ToastController>()->error(tr("Failed to open project"));
  }
}

// --- Clone toasts ----------------------------------------------------------------------

void ProjectCloneController::follow() {
  QStringList online;
  for (const QString& environmentId : m_store->environments()) {
    if (m_store->environmentOnline(environmentId)) online.append(environmentId);
  }
  for (auto it = m_subscriptions.begin(); it != m_subscriptions.end();) {
    if (online.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    // What it last reported stands until it is back.
    it = m_subscriptions.erase(it);
  }
  for (const QString& environmentId : std::as_const(online)) {
    if (m_subscriptions.contains(environmentId)) continue;
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("projectClones")},
                            {QStringLiteral("environment"), environmentId}};
    m_subscriptions.insert(environmentId, m_client->subscribe(this, shape, [this, environmentId](const QJsonObject& frame) {
      if (frame.value(QLatin1String("t")) != QLatin1String("projectClones")) return;
      reconcile(environmentId, frame.value(QLatin1String("clones")).toArray());
    }));
  }
}

// A toast per clone, changed in place.
void ProjectCloneController::reconcile(const QString& environmentId, const QJsonArray& clones) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  QHash<QString, Tracked>& tracked = m_toasts[environmentId];
  QSet<QString> seen;
  for (const QJsonValue& value : clones) {
    const QJsonObject clone = value.toObject();
    const QString projectId = clone.value(QLatin1String("projectId")).toString();
    const QString phase = clone.value(QLatin1String("phase")).toString();
    seen.insert(projectId);
    const QString shown = QStringList{phase, clone.value(QLatin1String("stage")).toString(),
                                      clone.value(QLatin1String("percent")).toVariant().toString(),
                                      clone.value(QLatin1String("detail")).toString(),
                                      clone.value(QLatin1String("error")).toString()}
                              .join(QLatin1Char(':'));
    const auto found = tracked.constFind(projectId);
    if (found != tracked.cend() && found->shown == shown) continue;

    const QString name = displayName(clone);
    const QString destination = clone.value(QLatin1String("destinationPath")).toString();
    QString type;
    QString title;
    QString description;
    QList<ToastController::Action> actions;
    int timeoutMs = 0;
    if (phase == QLatin1String("running")) {
      type = QStringLiteral("loading");
      title = tr("Cloning %1").arg(name);
      description = progressSummary(clone);
      actions = {{tr("Cancel"),
                  [this, environmentId, projectId] {
                    cloneAction(environmentId, QStringLiteral("projectClone.cancel"), projectId, tr("Failed to cancel clone"));
                  },
                  true}};
    } else if (phase == QLatin1String("done")) {
      type = QStringLiteral("success");
      title = tr("Cloned %1").arg(name);
      description = destination;
      timeoutMs = kDoneToastMs;
      actions = {{tr("Open project"), [this, environmentId, projectId] { openProject(environmentId, projectId); }}};
    } else {
      // Failed or cancelled: the project stays, pointing at an empty folder.
      const bool cancelled = phase == QLatin1String("cancelled");
      type = cancelled ? QStringLiteral("info") : QStringLiteral("error");
      title = cancelled ? tr("Cancelled cloning %1").arg(name) : tr("Failed to clone %1").arg(name);
      const QString error = clone.value(QLatin1String("error")).toString();
      description = cancelled ? destination : error.isEmpty() ? tr("The clone failed.") : error;
      actions = {{tr("Retry"),
                  [this, environmentId, projectId] {
                    cloneAction(environmentId, QStringLiteral("projectClone.retry"), projectId, tr("Failed to retry clone"));
                  },
                  true},
                 // The MC drops the clone with its project, which takes the toast.
                 {tr("Remove project"), [this, environmentId, projectId] { removeProject(environmentId, projectId); }, true}};
    }
    if (found != tracked.cend() && toasts->replace(found->toastId, type, title, description, actions, timeoutMs)) {
      tracked[projectId] = {found->toastId, shown, phase};
    } else {
      tracked[projectId] = {toasts->showActions(type, title, description, actions, timeoutMs), shown, phase};
    }
  }
  // A clone the MC stopped reporting takes its toast, unless it finished:
  // that toast goes in its own time.
  for (auto it = tracked.begin(); it != tracked.end();) {
    if (seen.contains(it.key())) {
      ++it;
      continue;
    }
    if (it->phase != QLatin1String("done")) toasts->dismiss(it->toastId);
    it = tracked.erase(it);
  }
}

void ProjectCloneController::cloneAction(const QString& environmentId, const QString& method, const QString& projectId,
                                         const QString& failure) {
  // The toast follows the MC's clone; a request that never got there says so.
  m_client->call(this, environmentId, method, QJsonObject{{QStringLiteral("projectId"), projectId}},
                 [this, failure](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) NativeShell::of(this)->controller<ToastController>()->error(failure, errorText(error));
                 });
}

// Not forced, so a project that gained a
// thread meanwhile is refused rather than lost.
void ProjectCloneController::removeProject(const QString& environmentId, const QString& projectId) {
  m_client->call(this, environmentId, QStringLiteral("projects.mutate"),
                 QJsonObject{{QStringLiteral("type"), QStringLiteral("project.delete")},
                             {QStringLiteral("projectId"), projectId}},
                 [this, environmentId, projectId](const QJsonValue&, const std::optional<QString>& error) {
                   auto* shell = NativeShell::of(this);
                   if (error) {
                     shell->controller<ToastController>()->error(tr("Failed to remove project"), errorText(error));
                     return;
                   }
                   // Its draft goes with its row (DraftController); a window
                   // showing it goes home.
                   auto* navigation = shell->controller<NavigationController>();
                   const NavigationController::Route& route = navigation->route();
                   if (route.kind != QLatin1String("draft")) return;
                   const auto draft = shell->controller<DraftController>()->draft(route.draftId);
                   if (draft && draft->environmentId == environmentId && draft->projectId == projectId) {
                     navigation->replace(NavigationController::Route());
                   }
                 });
}
