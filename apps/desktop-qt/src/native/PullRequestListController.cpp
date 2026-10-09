#include "PullRequestListController.h"

#include <QJsonArray>
#include <QUrl>

#include <algorithm>
#include <memory>

#include "CommandRegistry.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<PullRequestListController> registrar(QStringLiteral("pullRequestList"),
                                                                     {QStringLiteral("pullRequestList")});

const QString kKey = QStringLiteral("pullRequestList");
// Where the filters are kept on this device.
const QString kPreferences = QStringLiteral("pullRequestList");

// The filters and their defaults (the web's pullRequestListPreferences.ts).
const QVariantMap kDefaults{
    {QStringLiteral("state"), QStringLiteral("open")},  {QStringLiteral("involvement"), QStringLiteral("all")},
    {QStringLiteral("draft"), QString()},               {QStringLiteral("review"), QString()},
    {QStringLiteral("checks"), QString()},              {QStringLiteral("query"), QString()},
    {QStringLiteral("environmentId"), QString()},       {QStringLiteral("projectKey"), QString()},
};
const QHash<QString, QStringList> kChoices{
    {QStringLiteral("state"), {QStringLiteral("all"), QStringLiteral("open"), QStringLiteral("closed"), QStringLiteral("merged")}},
    {QStringLiteral("involvement"), {QStringLiteral("all"), QStringLiteral("reviewing"), QStringLiteral("authored")}},
    {QStringLiteral("draft"), {QString(), QStringLiteral("only"), QStringLiteral("hide")}},
    {QStringLiteral("review"),
     {QString(), QStringLiteral("approved"), QStringLiteral("changes-requested"), QStringLiteral("review-required"),
      QStringLiteral("none")}},
    {QStringLiteral("checks"), {QString(), QStringLiteral("passing"), QStringLiteral("failing")}},
};

// As many as the MC lists by default.
constexpr int kLimit = 99;

QString text(const QJsonObject& object, const char* field) {
  return object.value(QLatin1String(field)).toString();
}

QString rowKey(const QString& environmentId, const QJsonObject& entry) {
  return QStringLiteral("%1:%2:%3#%4")
      .arg(environmentId, text(entry, "host"), text(entry, "repository"))
      .arg(entry.value(QLatin1String("number")).toInt());
}

}  // namespace

PullRequestListController::PullRequestListController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                                     QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_filters(kDefaults) {}

void PullRequestListController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  if (auto* settings = shell->controller<SettingsController>()) {
    const QVariantMap kept = settings->deviceValue(kPreferences).toMap();
    for (auto it = kept.cbegin(); it != kept.cend(); ++it) {
      if (!kDefaults.contains(it.key())) continue;
      const QString value = it.value().toString();
      if (!kChoices.contains(it.key()) || kChoices.value(it.key()).contains(value)) m_filters.insert(it.key(), value);
    }
  }
  auto* navigation = shell->controller<NavigationController>();
  if (auto* keys = shell->controller<KeybindingController>()) {
    // "Open pull requests" is NavigationController's, listed while an
    // environment can serve pull requests.
    keys->commands()->add(QStringLiteral("pullRequests.refresh"), keybindings::commandLabel(QStringLiteral("pullRequests.refresh")),
                          [this, navigation] {
                            if (navigation->route().kind != QLatin1String("pullRequests")) {
                              navigation->open(NavigationController::Route::of(QStringLiteral("pullRequests")));
                            }
                            refresh();
                          });
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation] { setOpen(navigation->route().kind == QLatin1String("pullRequests")); });
  // An environment that comes back (or goes) changes who is asked.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (!m_open) return;
    const QStringList now = targets();
    QStringList asked = m_answers.keys();
    QStringList wanted = now;
    std::sort(asked.begin(), asked.end());
    std::sort(wanted.begin(), wanted.end());
    bool changed = asked != wanted;
    for (const QString& environmentId : now) {
      const Answer answer = m_answers.value(environmentId);
      if ((answer.status == QLatin1String("offline")) == m_store->environmentOnline(environmentId)) changed = true;
    }
    if (changed) load();
  });
  setOpen(navigation->route().kind == QLatin1String("pullRequests"));
  publish();
}

bool PullRequestListController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("pullRequestList."))) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("pullRequestList.filter")) {
    const QString name = input.value(QStringLiteral("name")).toString();
    const QString value = input.value(QStringLiteral("value")).toString();
    if (!kDefaults.contains(name) || (kChoices.contains(name) && !kChoices.value(name).contains(value))) return true;
    if (m_filters.value(name).toString() == value) return true;
    m_filters.insert(name, value);
    if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
      QVariantMap kept;
      for (auto it = m_filters.cbegin(); it != m_filters.cend(); ++it) {
        if (it.value() != kDefaults.value(it.key())) kept.insert(it.key(), it.value());
      }
      settings->writeDevice(kPreferences, kept);
    }
    load();
  } else if (action == QLatin1String("pullRequestList.refresh")) {
    refresh();
  } else if (action == QLatin1String("pullRequestList.open")) {
    open(input.value(QStringLiteral("key")).toString());
  } else if (action == QLatin1String("pullRequestList.openOnHost")) {
    const QString url = row(input.value(QStringLiteral("key")).toString()).value(QStringLiteral("url")).toString();
    if (!url.isEmpty()) m_bridge->openExternal(QUrl(url));
  } else {
    return false;
  }
  return true;
}

void PullRequestListController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  if (!open) {
    // Nothing is read for a page nobody sees.
    ++m_generation;
    unsubscribe();
    m_notice.clear();
    publish();
    return;
  }
  load();
}

// The environments asked: every one of the cluster, or the one the filters name.
QStringList PullRequestListController::targets() const {
  QString only = m_filters.value(QStringLiteral("environmentId")).toString();
  const QString project = m_filters.value(QStringLiteral("projectKey")).toString();
  if (!project.isEmpty()) only = project.section(QLatin1Char(':'), 0, 0);
  QStringList environments;
  for (const QString& environmentId : m_store->environments()) {
    if (only.isEmpty() || environmentId == only) environments.append(environmentId);
  }
  return environments;
}

QJsonObject PullRequestListController::input(const QString& environmentId) const {
  QJsonObject filters;
  for (const char* name : {"draft", "review", "checks"}) {
    const QString value = m_filters.value(QLatin1String(name)).toString();
    if (!value.isEmpty()) filters.insert(QLatin1String(name), value);
  }
  QJsonObject payload{
      {QStringLiteral("state"), m_filters.value(QStringLiteral("state")).toString()},
      {QStringLiteral("involvement"), m_filters.value(QStringLiteral("involvement")).toString()},
      {QStringLiteral("limit"), kLimit},
  };
  if (!filters.isEmpty()) payload.insert(QStringLiteral("filters"), filters);
  const QString query = m_filters.value(QStringLiteral("query")).toString().trimmed();
  if (!query.isEmpty()) payload.insert(QStringLiteral("query"), query);
  const QString project = m_filters.value(QStringLiteral("projectKey")).toString();
  if (project.section(QLatin1Char(':'), 0, 0) == environmentId) {
    payload.insert(QStringLiteral("projectId"), project.section(QLatin1Char(':'), 1));
  }
  return payload;
}

void PullRequestListController::load() {
  if (!m_open) return;
  const quint64 generation = ++m_generation;
  QHash<QString, Answer> answers;
  for (const QString& environmentId : targets()) {
    // The last answer stays on screen until the new one lands.
    Answer answer = m_answers.value(environmentId);
    answer.status = m_store->environmentOnline(environmentId) ? QStringLiteral("loading") : QStringLiteral("offline");
    if (answer.status == QLatin1String("offline")) answer = {answer.status, QString(), {}};
    answers.insert(environmentId, answer);
  }
  m_answers = answers;
  for (const QString& environmentId : answers.keys()) {
    if (answers.value(environmentId).status != QLatin1String("loading")) continue;
    m_client->call(this, environmentId, QStringLiteral("pullRequests.list"), input(environmentId),
                   [this, generation, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation || !m_answers.contains(environmentId)) return;
                     Answer& answer = m_answers[environmentId];
                     if (error) {
                       answer = {QStringLiteral("failed"), *error, {}};
                     } else {
                       answer = {QStringLiteral("ready"), QString(), result.toObject()};
                     }
                     publish();
                   });
  }
  subscribe();
  publish();
}

void PullRequestListController::refresh() {
  if (!m_open) return;
  const QStringList environments = targets();
  auto remaining = std::make_shared<int>(0);
  for (const QString& environmentId : environments) {
    if (!m_store->environmentOnline(environmentId)) continue;
    ++*remaining;
  }
  if (*remaining == 0) {
    load();
    return;
  }
  for (const QString& environmentId : environments) {
    if (!m_store->environmentOnline(environmentId)) continue;
    // Forgetting cached answers bumps the refresh revision too; the read
    // after every environment has forgotten is the one that counts.
    m_client->call(this, environmentId, QStringLiteral("pullRequests.invalidate"), QJsonObject(),
                   [this, remaining](const QJsonValue&, const std::optional<QString>&) {
                     if (--*remaining == 0) load();
                   });
  }
}

// While the page shows, each environment says when its pull requests changed.
void PullRequestListController::subscribe() {
  const QStringList environments = targets();
  for (auto it = m_subscriptions.begin(); it != m_subscriptions.end();) {
    if (environments.contains(it.key()) && m_store->environmentOnline(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    m_revisions.remove(it.key());
    it = m_subscriptions.erase(it);
  }
  for (const QString& environmentId : environments) {
    if (m_subscriptions.contains(environmentId) || !m_store->environmentOnline(environmentId)) continue;
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("pullRequestRefreshes")},
                            {QStringLiteral("environment"), environmentId}};
    m_subscriptions.insert(environmentId, m_client->subscribe(this, shape, [this, environmentId](const QJsonObject& frame) {
      if (frame.value(QLatin1String("t")).toString() != QLatin1String("pullRequestRefreshes")) return;
      const int revision = frame.value(QLatin1String("revision")).toInt();
      // The first frame is where the MC is now; only a later one is news.
      const bool known = m_revisions.contains(environmentId);
      const int last = m_revisions.value(environmentId);
      m_revisions.insert(environmentId, revision);
      if (known && revision != last) load();
    }));
  }
}

void PullRequestListController::unsubscribe() {
  for (const int id : std::as_const(m_subscriptions)) m_client->unsubscribe(id);
  m_subscriptions.clear();
  m_revisions.clear();
}

QVariantMap PullRequestListController::row(const QString& key) const {
  for (auto it = m_answers.cbegin(); it != m_answers.cend(); ++it) {
    for (const QJsonValue& value : it.value().result.value(QLatin1String("entries")).toArray()) {
      const QJsonObject entry = value.toObject();
      if (rowKey(it.key(), entry) != key) continue;
      QVariantMap found = entry.toVariantMap();
      found.insert(QStringLiteral("environmentId"), it.key());
      return found;
    }
  }
  return {};
}

// The thread working on the pull request opens; with none, the dialog offers to start one.
void PullRequestListController::open(const QString& key) {
  const QVariantMap entry = row(key);
  if (entry.isEmpty()) return;
  const QString environmentId = entry.value(QStringLiteral("environmentId")).toString();
  QJsonObject reference{
      {QStringLiteral("projectId"), entry.value(QStringLiteral("projectId")).toString()},
      {QStringLiteral("repository"), entry.value(QStringLiteral("repository")).toString()},
      {QStringLiteral("number"), entry.value(QStringLiteral("number")).toInt()},
  };
  if (!entry.value(QStringLiteral("host")).toString().isEmpty()) {
    reference.insert(QStringLiteral("host"), entry.value(QStringLiteral("host")).toString());
  }
  const QString projectId = entry.value(QStringLiteral("projectId")).toString();
  const QString url = entry.value(QStringLiteral("url")).toString();
  m_notice.clear();
  publish();
  m_client->call(this, environmentId, QStringLiteral("pullRequests.linkedThreads"), reference,
                 [this, key, environmentId, projectId, url](const QJsonValue& result, const std::optional<QString>& error) {
                   if (!m_open) return;
                   if (error) {
                     m_notice = {{QStringLiteral("key"), key}, {QStringLiteral("kind"), QStringLiteral("error")},
                                 {QStringLiteral("text"), *error}};
                     publish();
                     return;
                   }
                   // Newest first; an archived thread only when there is no other.
                   QString threadId;
                   for (const QJsonValue& value : result.toObject().value(QLatin1String("threads")).toArray()) {
                     const QJsonObject thread = value.toObject();
                     const bool archived = !thread.value(QLatin1String("archivedAt")).isNull() &&
                                           !thread.value(QLatin1String("archivedAt")).isUndefined();
                     if (threadId.isEmpty()) threadId = text(thread, "id");
                     if (!archived) {
                       threadId = text(thread, "id");
                       break;
                     }
                   }
                   if (threadId.isEmpty()) {
                     // The dialog resolves it and offers a thread on it, or its checkout.
                     m_bridge->dispatch(QStringLiteral("pullRequestThread.open"),
                                        QVariantMap{{QStringLiteral("reference"), url},
                                                    {QStringLiteral("environmentId"), environmentId},
                                                    {QStringLiteral("projectId"), projectId}});
                     return;
                   }
                   NativeShell::of(this)->controller<NavigationController>()->open(
                       NavigationController::Route::thread(environmentId + QLatin1Char(':') + threadId));
                 });
}

void PullRequestListController::publish() {
  if (!m_active) return;
  QVariantList environments;
  QStringList problems;
  QList<QVariantMap> rows;
  bool loading = false;
  QStringList failures;
  QStringList ids = m_answers.keys();
  std::sort(ids.begin(), ids.end());
  const bool several = m_store->environments().size() > 1;
  for (const QString& environmentId : ids) {
    const Answer& answer = m_answers.value(environmentId);
    const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
    const QString name = label.isEmpty() ? environmentId : label;
    environments.append(QVariantMap{{QStringLiteral("id"), environmentId},
                                    {QStringLiteral("label"), name},
                                    {QStringLiteral("status"), answer.status},
                                    {QStringLiteral("message"), answer.message}});
    if (answer.status == QLatin1String("loading")) loading = true;
    if (answer.status == QLatin1String("offline")) {
      problems.append(QStringLiteral("%1 cannot be reached; its pull requests are not listed.").arg(name));
    } else if (answer.status == QLatin1String("failed")) {
      failures.append(answer.message);
      problems.append(several ? QStringLiteral("%1: %2").arg(name, answer.message) : answer.message);
    }
    const QJsonObject viewers = answer.result.value(QLatin1String("viewers")).toObject();
    for (const QJsonValue& value : answer.result.value(QLatin1String("errors")).toArray()) {
      const QJsonObject error = value.toObject();
      // The MC phrases the reason (and keeps the host's own text in `detail`); the
      // project is named here, once.
      const QString reason = text(error, "reason");
      problems.append(reason.isEmpty() ? QStringLiteral("%1: %2").arg(text(error, "projectTitle"), text(error, "message"))
                                       : tr("%1 could not be read: %2").arg(text(error, "projectTitle"), reason));
    }
    for (const QJsonValue& value : answer.result.value(QLatin1String("entries")).toArray()) {
      const QJsonObject entry = value.toObject();
      const QJsonObject author = entry.value(QLatin1String("author")).toObject();
      QStringList labels;
      for (const QJsonValue& labelValue : entry.value(QLatin1String("labels")).toArray()) {
        labels.append(text(labelValue.toObject(), "name"));
      }
      const QString login = text(author, "login");
      const QString viewer = viewers.value(text(entry, "host")).toString();
      QString group = QStringLiteral("others");
      if (!viewer.isEmpty() && login == viewer) group = QStringLiteral("authored");
      else if (entry.value(QLatin1String("viewerReviewRequested")).toBool()) group = QStringLiteral("reviewRequested");
      rows.append({
          {QStringLiteral("key"), rowKey(environmentId, entry)},
          {QStringLiteral("group"), group},
          {QStringLiteral("environmentId"), environmentId},
          {QStringLiteral("environmentLabel"), several ? name : QString()},
          {QStringLiteral("projectTitle"), text(entry, "projectTitle")},
          {QStringLiteral("repository"), text(entry, "repository")},
          {QStringLiteral("number"), entry.value(QLatin1String("number")).toInt()},
          {QStringLiteral("title"), text(entry, "title")},
          {QStringLiteral("url"), text(entry, "url")},
          {QStringLiteral("state"), text(entry, "state")},
          {QStringLiteral("isDraft"), entry.value(QLatin1String("isDraft")).toBool()},
          {QStringLiteral("author"), login.isEmpty() ? QStringLiteral("ghost") : login},
          {QStringLiteral("headBranch"), text(entry, "headBranch")},
          {QStringLiteral("baseBranch"), text(entry, "baseBranch")},
          {QStringLiteral("updatedAt"), text(entry, "updatedAt")},
          {QStringLiteral("reviewDecision"), text(entry, "reviewDecision")},
          {QStringLiteral("checksState"), text(entry, "checksState")},
          {QStringLiteral("conflicting"), text(entry, "mergeability") == QLatin1String("conflicting")},
          {QStringLiteral("additions"), entry.value(QLatin1String("additions")).toInt()},
          {QStringLiteral("deletions"), entry.value(QLatin1String("deletions")).toInt()},
          {QStringLiteral("labels"), labels},
      });
    }
  }
  std::stable_sort(rows.begin(), rows.end(), [](const QVariantMap& a, const QVariantMap& b) {
    return a.value(QStringLiteral("updatedAt")).toString() > b.value(QStringLiteral("updatedAt")).toString();
  });
  QVariantList groups;
  const QList<std::pair<QString, QString>> kinds{{QStringLiteral("authored"), QStringLiteral("Authored")},
                                                 {QStringLiteral("reviewRequested"), QStringLiteral("Review requested")},
                                                 {QStringLiteral("others"), QStringLiteral("Others")}};
  for (const auto& [id, label] : kinds) {
    QVariantList members;
    for (const QVariantMap& entry : std::as_const(rows)) {
      if (entry.value(QStringLiteral("group")) == id) members.append(entry);
    }
    if (!members.isEmpty()) {
      groups.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("label"), label}, {QStringLiteral("rows"), members}});
    }
  }

  bool filtered = false;
  for (auto it = kDefaults.cbegin(); it != kDefaults.cend(); ++it) {
    if (it.key() != QLatin1String("query") && m_filters.value(it.key()) != it.value()) filtered = true;
  }
  const QString query = m_filters.value(QStringLiteral("query")).toString().trimmed();
  QVariant empty = QVariant::fromValue(nullptr);
  QVariant error = QVariant::fromValue(nullptr);
  const bool answered = std::any_of(ids.cbegin(), ids.cend(), [this](const QString& id) {
    return m_answers.value(id).status == QLatin1String("ready");
  });
  if (rows.isEmpty() && !loading) {
    if (!answered && !failures.isEmpty()) {
      error = QVariantMap{{QStringLiteral("title"), QStringLiteral("Could not load pull requests")},
                          {QStringLiteral("message"), failures.first()}};
    } else if (m_store->projects().isEmpty()) {
      empty = QVariantMap{{QStringLiteral("title"), QStringLiteral("No projects in this workspace")},
                          {QStringLiteral("body"), QStringLiteral("Add a project, and the pull requests from its repository appear here.")},
                          {QStringLiteral("action"), QStringLiteral("project.add")}};
    } else if (!query.isEmpty()) {
      QString shown = query.size() > 48 ? query.left(48) + QStringLiteral("…") : query;
      empty = QVariantMap{{QStringLiteral("title"), QStringLiteral("Nothing matches “%1”").arg(shown)},
                          {QStringLiteral("body"), QStringLiteral("The hosts were searched for it. Try fewer words, or search by number, author or branch.")}};
    } else if (filtered) {
      empty = QVariantMap{{QStringLiteral("title"), QStringLiteral("Nothing under these filters")},
                          {QStringLiteral("body"), QStringLiteral("Widen the state, involvement or project filter to see more.")}};
    } else if (answered) {
      empty = QVariantMap{{QStringLiteral("title"), QStringLiteral("No pull requests")},
                          {QStringLiteral("body"), QStringLiteral("Pull requests from every project in this workspace appear here.")}};
    }
  }

  QVariantList projects;
  QVariantList environmentChoices;
  for (const QString& environmentId : m_store->environments()) {
    const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
    environmentChoices.append(QVariantMap{{QStringLiteral("id"), environmentId},
                                          {QStringLiteral("label"), label.isEmpty() ? environmentId : label}});
  }
  for (const auto& project : m_store->projects()) {
    projects.append(QVariantMap{{QStringLiteral("key"), project.key()}, {QStringLiteral("label"), project.title}});
  }

  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("open"), m_open},
                              {QStringLiteral("loading"), loading},
                              {QStringLiteral("filters"), m_filters},
                              {QStringLiteral("filtered"), filtered},
                              {QStringLiteral("groups"), groups},
                              {QStringLiteral("count"), rows.size()},
                              {QStringLiteral("environments"), environments},
                              {QStringLiteral("environmentChoices"), environmentChoices},
                              {QStringLiteral("problems"), problems},
                              {QStringLiteral("empty"), empty},
                              {QStringLiteral("error"), error},
                              {QStringLiteral("projects"), projects},
                              {QStringLiteral("notice"), m_notice.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(m_notice)},
                          });
}
