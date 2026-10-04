#include "LoadBalancingController.h"

#include <QDateTime>
#include <QPointer>

#include <algorithm>


#include "ComposerController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "WorkspaceController.h"

namespace {

const QString kKey = QStringLiteral("loadBalancing");
const QString kEnabled = QStringLiteral("loadBalancingEnabled");
const QString kWeights = QStringLiteral("loadBalancingWeights");

const NativeControllerRegistrar<LoadBalancingController> registrar(QStringLiteral("loadBalancing"), {kKey});

struct Preference {
  int value;
  const char* label;
};
const Preference kPreferences[] = {{100, "Prefer"}, {50, "Normal"}, {25, "Less often"}, {0, "Manual only"}};

// Snaps a saved weight (older builds stored a slider value) onto the four preferences.
int preferenceOf(const QJsonValue& weight) {
  if (!weight.isDouble() || weight.toInt() == 50) return 50;
  if (weight.toInt() == 0) return 0;
  return weight.toInt() < 50 ? 25 : 100;
}

QString preferenceLabel(int preference) {
  for (const Preference& entry : kPreferences) {
    if (entry.value == preference) return QString::fromLatin1(entry.label);
  }
  return {};
}

QString repositoryOf(const QJsonObject& project) {
  return project.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString();
}

// Whether the machine can start a thread with the chosen provider.
bool offers(const QJsonArray& providers, const QJsonObject& chosen) {
  if (chosen.isEmpty()) return true;
  for (const QJsonValue& value : providers) {
    const QJsonObject provider = value.toObject();
    if (provider.value(QLatin1String("instanceId")) != chosen.value(QLatin1String("instanceId"))) continue;
    if (chosen.contains(QLatin1String("driver")) && provider.contains(QLatin1String("driver")) &&
        provider.value(QLatin1String("driver")) != chosen.value(QLatin1String("driver"))) {
      continue;
    }
    return provider.value(QLatin1String("enabled")).toBool(true) && provider.value(QLatin1String("installed")).toBool(true) &&
           provider.value(QLatin1String("status")).toString() != QLatin1String("error") &&
           provider.value(QLatin1String("auth")).toObject().value(QLatin1String("status")).toString() != QLatin1String("unauthenticated") &&
           provider.value(QLatin1String("availability")).toString() != QLatin1String("unavailable");
  }
  return false;
}

}  // namespace

QString LoadBalancingController::choose(const QList<Candidate>& candidates, qint64 now) {
  QString selected;
  double best = 0;
  for (const Candidate& candidate : candidates) {
    const QJsonObject& resources = candidate.resources;
    const QJsonValue utilization = resources.value(QLatin1String("cpuUtilization"));
    const double total = resources.value(QLatin1String("totalMemoryBytes")).toDouble();
    const double cpus = resources.value(QLatin1String("cpuCount")).toDouble();
    const qint64 sampledAt = candidate.receivedAt > 0 ? candidate.receivedAt : qint64(resources.value(QLatin1String("sampledAt")).toDouble());
    if (resources.isEmpty() || candidate.weight <= 0 || now - sampledAt > kStaleMs || sampledAt > now + 5000 || !utilization.isDouble() ||
        utilization.toDouble() >= 0.95 || total <= 0 || cpus <= 0) {
      continue;
    }
    const double memory = resources.value(QLatin1String("availableMemoryBytes")).toDouble() / total;
    if (memory <= 0.05) continue;
    const double score = candidate.weight * cpus * (1 - utilization.toDouble()) * memory;
    if (score > best) {
      selected = candidate.environmentId;
      best = score;
    }
  }
  return selected;
}

LoadBalancingController::LoadBalancingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_clock([] { return QDateTime::currentMSecsSinceEpoch(); }) {}

void LoadBalancingController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  if (auto* settings = shell->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, [this] {
      // A switch turned on, or a changed preference, places the new drafts anew.
      m_tried.clear();
      publish();
      balance();
    });
  }
  connect(m_store, &ShellStore::changed, this, [this] {
    publish();
    balance();
  });
  if (auto* workspace = shell->controller<WorkspaceController>()) {
    connect(workspace, &WorkspaceController::placeChanged, this, &LoadBalancingController::balance, Qt::QueuedConnection);
  }
  publish();
  balance();
}

bool LoadBalancingController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("loadBalancing."))) return false;
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings) return true;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("loadBalancing.enable")) {
    // Off is the default, kept as its absence.
    settings->writeDevice(kEnabled, input.value(QStringLiteral("enabled")).toBool() ? QVariant(true) : QVariant());
  } else if (action == QLatin1String("loadBalancing.prefer")) {
    const QString environmentId = input.value(QStringLiteral("environmentId")).toString();
    if (environmentId.isEmpty()) return true;
    QJsonObject next = weights();
    next.insert(environmentId, preferenceOf(QJsonValue(input.value(QStringLiteral("value")).toInt())));
    settings->writeDevice(kWeights, next.toVariantMap());
  }
  return true;
}

bool LoadBalancingController::enabled() const {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings && settings->deviceSettings().value(kEnabled).toBool();
}

QJsonObject LoadBalancingController::weights() const {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings ? settings->deviceSettings().value(kWeights).toObject() : QJsonObject();
}

QStringList LoadBalancingController::machines() const {
  QStringList connected;
  if (!m_client->isReady()) return connected;
  for (const QString& environmentId : m_store->environments()) {
    if (m_store->environmentOnline(environmentId)) connected.append(environmentId);
  }
  // This machine first, the others by name.
  const QString local = m_client->environment();
  std::sort(connected.begin(), connected.end(), [this, &local](const QString& a, const QString& b) {
    if ((a == local) != (b == local)) return a == local;
    return QString::localeAwareCompare(label(a).toLower(), label(b).toLower()) < 0;
  });
  return connected;
}

QString LoadBalancingController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  if (!label.isEmpty()) return label;
  return environmentId == m_client->environment() ? QStringLiteral("This machine") : environmentId;
}

void LoadBalancingController::publish() {
  if (!m_active) return;
  const QStringList connected = machines();
  // One machine has nothing to balance against.
  if (connected.size() < 2) {
    m_bridge->publish(kKey, QVariant::fromValue(nullptr));
    return;
  }
  const QJsonObject saved = weights();
  QVariantList rows;
  QStringList summary;
  for (const QString& environmentId : connected) {
    const int preference = preferenceOf(saved.value(environmentId));
    rows.append(QVariantMap{{QStringLiteral("environmentId"), environmentId}, {QStringLiteral("label"), label(environmentId)}, {QStringLiteral("preference"), preference}});
    if (preference != 50) summary.append(label(environmentId) + QLatin1Char(' ') + preferenceLabel(preference).toLower());
  }
  QVariantList preferences;
  for (const Preference& entry : kPreferences) {
    preferences.append(QVariantMap{{QStringLiteral("value"), entry.value}, {QStringLiteral("label"), QString::fromLatin1(entry.label)}});
  }
  m_bridge->publish(kKey, QVariantMap{{QStringLiteral("enabled"), enabled()},
                                      {QStringLiteral("summary"), enabled() ? summary.join(QStringLiteral(" · ")) : QStringLiteral("Off")},
                                      {QStringLiteral("machines"), rows},
                                      {QStringLiteral("preferences"), preferences}});
}

LoadBalancingController::State LoadBalancingController::state(const QString& draftId) const {
  const Check check = m_checks.value(draftId);
  return {check.waiting > 0 && !check.quiet, check.failed && !check.quiet};
}

void LoadBalancingController::balance() {
  if (!m_active || !enabled()) return;
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!workspace || !workspace->place() || workspace->place()->draftId.isEmpty()) return;
  const QString draftId = workspace->place()->draftId;
  WorkspaceController::Checkout checkout = workspace->checkout(draftId);
  if (m_tried.contains(draftId)) return;
  // One the user tied to a machine stays there; one already on Auto balance is placed, or being placed.
  if (checkout.manual || checkout.automatic || checkout.branch || checkout.worktreePath || !checkout.environmentId.isEmpty()) return;
  // Only where the project has a checkout on more than one connected machine.
  int checkouts = 0;
  for (const QVariant& choice : workspace->environmentChoices()) {
    const QVariantMap entry = choice.toMap();
    checkouts += entry.value(QStringLiteral("checkout")).toBool() && m_store->environmentOnline(entry.value(QStringLiteral("environmentId")).toString());
  }
  if (checkouts < 2) return;
  m_tried.insert(draftId);
  place(draftId, true);
}

void LoadBalancingController::place(const QString& draftId, bool quietly) {
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!m_active || !workspace || !workspace->place() || workspace->place()->draftId != draftId) return;
  // The connected machines with a checkout of the draft's project.
  QList<Member> members;
  for (const QVariant& choice : workspace->environmentChoices()) {
    const QVariantMap entry = choice.toMap();
    const QString environmentId = entry.value(QStringLiteral("environmentId")).toString();
    const QString key = entry.value(QStringLiteral("key")).toString();
    if (!entry.value(QStringLiteral("checkout")).toBool() || !m_store->environmentOnline(environmentId)) continue;
    members.append({environmentId, key.mid(key.indexOf(QLatin1Char(':')) + 1)});
  }
  Check& check = m_checks[draftId];
  const int request = ++check.request;
  check.failed = false;
  check.waiting = 0;
  check.quiet = quietly;
  const QJsonObject saved = weights();
  const QString own = workspace->place()->environmentId;
  for (const Member& member : members) {
    const QString environmentId = member.environmentId;
    // A machine on manual only is not asked.
    if (preferenceOf(saved.value(environmentId)) <= 0) continue;
    check.waiting += 2;
    const auto answered = [this, draftId, request, members, own] {
      Check& check = m_checks[draftId];
      if (check.request != request || --check.waiting > 0) return;
      decide(draftId, request, members, own);
    };
    m_client->call(this, environmentId, QStringLiteral("server.getHostResources"), QJsonObject(),
                   [this, draftId, request, environmentId, answered](const QJsonValue& result, const std::optional<QString>& error) {
                     // A machine that does not answer keeps its last sample, which goes stale.
                     if (!error && result.isObject()) {
                       m_samples.insert(environmentId, {result.toObject(), m_clock()});
                     } else if (m_checks.value(draftId).request == request) {
                       m_checks[draftId].failed = true;
                     }
                     answered();
                   });
    // And for its providers (ServerConfig).
    m_client->call(this, environmentId, QStringLiteral("server.getConfig"), QJsonObject(),
                   [this, environmentId, answered](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!error && result.isObject()) {
                       m_providers.insert(environmentId, result.toObject().value(QLatin1String("providers")).toArray());
                       m_configured.insert(environmentId);
                     }
                     answered();
                   });
  }
  // The picker says it is checking.
  workspace->refresh();
  if (check.waiting == 0) decide(draftId, request, members, own);
}

void LoadBalancingController::decide(const QString& draftId, int request, const QList<Member>& members, const QString& ownEnvironment) {
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!workspace || m_checks.value(draftId).request != request) return;
  WorkspaceController::Checkout checkout = workspace->checkout(draftId);
  const bool quiet = m_checks.value(draftId).quiet;
  // Taken off Auto balance meanwhile, or tied to a machine: the user's choice stands.
  if (quiet ? (checkout.manual || checkout.automatic || checkout.branch || checkout.worktreePath) : !checkout.automatic) return;
  // The provider the draft will start with: the composer's choice, else the
  // first one ready where the draft is (as the composer defaults to).
  QJsonObject chosenProvider;
  QString instanceId;
  if (const auto* composer = NativeShell::of(this)->controller<ComposerController>()) {
    instanceId = composer->currentSelection().value(QLatin1String("instanceId")).toString();
  }
  for (const QJsonValue& value : m_providers.value(ownEnvironment)) {
    const QJsonObject provider = value.toObject();
    const QString id = provider.value(QLatin1String("instanceId")).toString();
    if (instanceId.isEmpty() ? !offers(QJsonArray{provider}, {{QStringLiteral("instanceId"), id}}) : id != instanceId) continue;
    chosenProvider.insert(QStringLiteral("instanceId"), id);
    if (provider.contains(QLatin1String("driver"))) chosenProvider.insert(QStringLiteral("driver"), provider.value(QLatin1String("driver")));
    break;
  }
  if (chosenProvider.isEmpty() && !instanceId.isEmpty()) chosenProvider.insert(QStringLiteral("instanceId"), instanceId);
  const QJsonObject saved = weights();
  QList<Candidate> candidates;
  for (const Member& member : members) {
    if (!m_store->environmentOnline(member.environmentId)) continue;
    // A machine whose providers are known must have the chosen one signed in.
    if (m_configured.contains(member.environmentId) && !offers(m_providers.value(member.environmentId), chosenProvider)) continue;
    const Sample sample = m_samples.value(member.environmentId);
    candidates.append({member.environmentId, sample.resources, sample.receivedAt, preferenceOf(saved.value(member.environmentId))});
  }
  const QString target = choose(candidates, m_clock());
  for (const Member& member : members) {
    if (target.isEmpty() || member.environmentId != target) continue;
    checkout.environmentId = member.environmentId;
    checkout.projectId = member.projectId;
    checkout.automatic = true;
    checkout.balanced = true;
    m_checks[draftId].failed = false;
    workspace->setCheckout(draftId, checkout);
    return;
  }
  // None could take it: the picker says so, and sending asks for a machine.
  workspace->refresh();
}
