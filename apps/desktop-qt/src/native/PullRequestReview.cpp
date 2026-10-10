#include "PullRequestReview.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>

#include <algorithm>

#include "McClient.h"

namespace {

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QString login(const QJsonValue& actor) {
  return actor.toObject().value(QLatin1String("login")).toString();
}

QString stateLabel(const QJsonObject& detail) {
  const QString state = text(detail, QLatin1String("state"));
  if (state == QLatin1String("merged")) return QStringLiteral("Merged");
  if (state == QLatin1String("closed")) return QStringLiteral("Closed");
  return detail.value(QLatin1String("isDraft")).toBool() ? QStringLiteral("Draft") : QStringLiteral("Open");
}

// allowedPullRequestMergeMethods: what the host offers, narrowed to what the
// repository allows (one that says nothing allows them all).
QStringList mergeMethods(const QJsonObject& detail) {
  const QJsonObject allowed = detail.value(QLatin1String("mergeCapabilities")).toObject();
  QStringList methods;
  for (const QJsonValue& method : detail.value(QLatin1String("capabilities")).toObject().value(QLatin1String("mergeMethods")).toArray()) {
    if (allowed.isEmpty() || allowed.value(method.toString()).toBool()) methods.append(method.toString());
  }
  return methods;
}

// The host can merge and this viewer may (a permission the host says nothing
// of is granted): an open pull request that is not a draft.
bool canMerge(const QJsonObject& detail) {
  if (text(detail, QLatin1String("state")) != QLatin1String("open") || detail.value(QLatin1String("isDraft")).toBool()) return false;
  const auto offers = [](const QJsonValue& actions) { return actions.toArray().contains(QStringLiteral("merge")); };
  if (!offers(detail.value(QLatin1String("capabilities")).toObject().value(QLatin1String("actions")))) return false;
  const QJsonValue permissions = detail.value(QLatin1String("viewerPermissions"));
  return !permissions.isObject() || offers(permissions.toObject().value(QLatin1String("actions")));
}

QVariantMap detailOf(const QJsonObject& detail) {
  QVariantList checks;
  for (const QJsonValue& value : detail.value(QLatin1String("checks")).toArray()) {
    const QJsonObject check = value.toObject();
    checks.append(QVariantMap{{QStringLiteral("name"), text(check, QLatin1String("name"))},
                              {QStringLiteral("status"), text(check, QLatin1String("status"))},
                              {QStringLiteral("description"), text(check, QLatin1String("description"))},
                              {QStringLiteral("url"), text(check, QLatin1String("url"))}});
  }
  QStringList labels;
  for (const QJsonValue& label : detail.value(QLatin1String("labels")).toArray()) labels.append(text(label.toObject(), QLatin1String("name")));
  QStringList reviewers;
  for (const QJsonValue& reviewer : detail.value(QLatin1String("reviewers")).toArray()) reviewers.append(login(reviewer));
  return {
      {QStringLiteral("title"), text(detail, QLatin1String("title"))},
      {QStringLiteral("body"), text(detail, QLatin1String("body"))},
      {QStringLiteral("url"), text(detail, QLatin1String("url"))},
      {QStringLiteral("author"), login(detail.value(QLatin1String("author")))},
      {QStringLiteral("state"), detail.value(QLatin1String("isDraft")).toBool() && text(detail, QLatin1String("state")) == QLatin1String("open")
                                    ? QStringLiteral("draft")
                                    : text(detail, QLatin1String("state"))},
      {QStringLiteral("stateLabel"), stateLabel(detail)},
      {QStringLiteral("branches"), QStringLiteral("%1 → %2").arg(text(detail, QLatin1String("headBranch")), text(detail, QLatin1String("baseBranch")))},
      {QStringLiteral("labels"), labels},
      {QStringLiteral("reviewers"), reviewers},
      {QStringLiteral("mergeability"), text(detail, QLatin1String("mergeability"))},
      {QStringLiteral("behindBy"), detail.value(QLatin1String("behindBy")).toInt()},
      {QStringLiteral("checks"), checks},
      {QStringLiteral("canMerge"), canMerge(detail)},
      {QStringLiteral("mergeMethods"), mergeMethods(detail)},
  };
}

}  // namespace

PullRequestReview::PullRequestReview(McClient* client, Notify notify, Open open, QObject* parent)
    : QObject(parent), m_client(client), m_notify(std::move(notify)), m_open(std::move(open)) {
  m_copy = [](const QString& text) {
    QClipboard* clipboard = QGuiApplication::clipboard();
    if (!clipboard) return false;
    clipboard->setText(text);
    return true;
  };
  // A file read again keeps the mark it had.
  connect(&m_model, &DiffModel::patchChanged, this, &PullRequestReview::applyViewed);
}

QString PullRequestReview::key() const {
  return m_number > 0 ? QStringLiteral("%1/%2#%3").arg(m_host, m_repository).arg(m_number) : QString();
}

void PullRequestReview::setPullRequest(const QString& environmentId, const QString& projectId, const QString& host,
                                       const QString& repository, int number) {
  if (environmentId == m_environment && projectId == m_project && host == m_host && repository == m_repository && number == m_number) return;
  m_environment = environmentId;
  m_project = projectId;
  m_host = host;
  m_repository = repository;
  m_number = number;
  ++m_generation;
  m_loaded = false;
  m_detail.clear();
  m_stack = {};
  m_stackStale = false;
  m_stackConfirmation.clear();
  emit stackChanged();
  m_conversation.clear();
  m_threads.clear();
  m_viewed.clear();
  m_problem.clear();
  m_model.clear();
  setStatus(QStringLiteral("idle"));
  setCode(QStringLiteral("idle"));
  emit targetChanged();
  emit detailChanged();
  emit viewedChanged();
  if (m_active) load();
}

void PullRequestReview::clear() {
  setPullRequest({}, {}, {}, {}, 0);
}

void PullRequestReview::setOnline(bool online) {
  if (online == m_online) return;
  m_online = online;
  emit stateChanged();
  emit stackChanged();
  // Back online, what could not be read is read now.
  if (online && m_active && (!m_loaded || m_status == QLatin1String("error"))) load();
}

void PullRequestReview::setActive(bool active) {
  if (active == m_active) return;
  m_active = active;
  if (active && !m_loaded) load();
}

QJsonObject PullRequestReview::reference() const {
  return {{QStringLiteral("projectId"), m_project},
          {QStringLiteral("host"), m_host},
          {QStringLiteral("repository"), m_repository},
          {QStringLiteral("number"), m_number}};
}

void PullRequestReview::reload() {
  if (m_number <= 0) return;
  load();
}

void PullRequestReview::load() {
  if (m_number <= 0 || !m_online) return;
  m_loaded = true;
  ++m_generation;
  readDetail();
  setCode(QStringLiteral("loading"));
  readCode({}, {});
}

void PullRequestReview::readDetail() {
  const quint64 generation = m_generation;
  if (m_status != QLatin1String("ready")) setStatus(QStringLiteral("loading"));
  m_client->call(this, m_environment, QStringLiteral("pullRequests.detail"), reference(),
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     setStatus(QStringLiteral("error"), *error);
                     return;
                   }
                   m_detail = detailOf(result.toObject());
                   // A permission the host says nothing of is granted.
                   const QJsonObject detail = result.toObject();
                   const QJsonValue permissions = detail.value(QLatin1String("viewerPermissions"));
                   m_viewerMayMerge = detail.value(QLatin1String("capabilities")).toObject().value(QLatin1String("actions")).toArray().contains(QStringLiteral("merge")) &&
                                      (!permissions.isObject() || permissions.toObject().value(QLatin1String("actions")).toArray().contains(QStringLiteral("merge")));
                   m_viewerMayRebase = !permissions.isObject() || permissions.toObject().value(QLatin1String("stackRebase")).toBool(true);
                   setStatus(QStringLiteral("ready"));
                   emit detailChanged();
                   emit stackChanged();
                 });
  readStack();
  m_client->call(this, m_environment, QStringLiteral("pullRequests.activity"), reference(),
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation || error) return;
                   const QJsonObject activity = result.toObject();
                   QVariantList conversation;
                   for (const QJsonValue& value : activity.value(QLatin1String("comments")).toArray()) {
                     const QJsonObject comment = value.toObject();
                     conversation.append(QVariantMap{{QStringLiteral("id"), text(comment, QLatin1String("id"))},
                                                     {QStringLiteral("kind"), text(comment, QLatin1String("kind"))},
                                                     {QStringLiteral("author"), login(comment.value(QLatin1String("author")))},
                                                     {QStringLiteral("body"), text(comment, QLatin1String("body"))},
                                                     {QStringLiteral("createdAt"), text(comment, QLatin1String("createdAt"))},
                                                     {QStringLiteral("reviewState"), text(comment, QLatin1String("reviewState"))},
                                                     {QStringLiteral("path"), text(comment, QLatin1String("path"))}});
                   }
                   QVariantList threads;
                   for (const QJsonValue& value : activity.value(QLatin1String("reviewThreads")).toArray()) {
                     const QJsonObject thread = value.toObject();
                     QVariantList comments;
                     for (const QJsonValue& comment : thread.value(QLatin1String("comments")).toArray()) {
                       comments.append(QVariantMap{{QStringLiteral("author"), login(comment.toObject().value(QLatin1String("author")))},
                                                   {QStringLiteral("body"), text(comment.toObject(), QLatin1String("body"))}});
                     }
                     threads.append(QVariantMap{{QStringLiteral("id"), text(thread, QLatin1String("id"))},
                                                {QStringLiteral("path"), text(thread, QLatin1String("path"))},
                                                {QStringLiteral("line"), thread.value(QLatin1String("line")).toInt()},
                                                {QStringLiteral("resolved"), thread.value(QLatin1String("isResolved")).toBool()},
                                                {QStringLiteral("outdated"), thread.value(QLatin1String("isOutdated")).toBool()},
                                                {QStringLiteral("comments"), comments}});
                   }
                   m_conversation = conversation;
                   m_threads = threads;
                   emit detailChanged();
                 });
  m_client->call(this, m_environment, QStringLiteral("pullRequests.filesViewed"), reference(),
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation || error) return;
                   QSet<QString> viewed;
                   for (const QJsonValue& value : result.toObject().value(QLatin1String("files")).toArray()) {
                     if (text(value.toObject(), QLatin1String("state")) == QLatin1String("viewed")) {
                       viewed.insert(text(value.toObject(), QLatin1String("path")));
                     }
                   }
                   m_viewed = viewed;
                   applyViewed();
                 });
}

// Slices are whole files, so each one is shown as it lands.
void PullRequestReview::readCode(const QString& cursor, const QString& patch) {
  const quint64 generation = m_generation;
  QJsonObject input = reference();
  if (!cursor.isEmpty()) input.insert(QStringLiteral("cursor"), cursor);
  m_client->post(this, QStringLiteral("/api/pull-requests/diff"), input,
                 [this, generation, patch](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     setCode(QStringLiteral("error"), *error);
                     return;
                   }
                   const QJsonObject slice = result.toObject();
                   QString whole = patch;
                   if (!whole.isEmpty() && !whole.endsWith(QLatin1Char('\n'))) whole += QLatin1Char('\n');
                   whole += text(slice, QLatin1String("patch"));
                   m_model.setPatch(whole);
                   const QString next = text(slice, QLatin1String("nextCursor"));
                   if (next.isEmpty()) {
                     setCode(QStringLiteral("ready"));
                   } else {
                     readCode(next, whole);
                   }
                 });
}

QStringList PullRequestReview::viewedPaths() const {
  QStringList paths;
  for (const QString& path : m_model.paths()) {
    if (m_viewed.contains(path)) paths.append(path);
  }
  return paths;
}

int PullRequestReview::viewedCount() const {
  return int(viewedPaths().size());
}

void PullRequestReview::applyViewed() {
  for (int file = 0; file < m_model.fileCount(); ++file) {
    if (m_viewed.contains(m_model.path(file)) && m_model.expanded(file)) m_model.setExpanded(file, false);
  }
  emit viewedChanged();
}

void PullRequestReview::setViewed(const QString& path, bool viewed) {
  if (!m_online || m_number <= 0 || m_viewed.contains(path) == viewed) return;
  // Shown at once, taken back if the host refuses it.
  if (viewed) {
    m_viewed.insert(path);
  } else {
    m_viewed.remove(path);
  }
  m_model.setExpanded(m_model.fileOf(path), !viewed);
  emit viewedChanged();
  QJsonObject input = reference();
  input.insert(QStringLiteral("files"), QJsonArray{QJsonObject{{QStringLiteral("path"), path}, {QStringLiteral("viewed"), viewed}}});
  const quint64 generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("pullRequests.setFilesViewed"), input,
                 [this, generation, path, viewed](const QJsonValue&, const std::optional<QString>& error) {
                   if (!error || generation != m_generation) return;
                   if (viewed) {
                     m_viewed.remove(path);
                   } else {
                     m_viewed.insert(path);
                   }
                   m_model.setExpanded(m_model.fileOf(path), viewed);
                   emit viewedChanged();
                   m_notify(QStringLiteral("error"), QStringLiteral("Could not mark the file viewed"), *error);
                 });
}

bool PullRequestReview::comment(const QString& body) {
  if (body.trimmed().isEmpty()) {
    setProblem(QStringLiteral("A comment cannot be empty."));
    return false;
  }
  QJsonObject input = reference();
  input.insert(QStringLiteral("body"), body);
  return change(QStringLiteral("pullRequests.comment"), input, QStringLiteral("Could not comment"));
}

void PullRequestReview::readStack() {
  const quint64 generation = m_generation;
  m_client->call(this, m_environment, QStringLiteral("pullRequests.stack"), reference(),
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation) return;
                   if (error) {
                     // What was read before stays, marked as possibly stale.
                     m_stackStale = !m_stack.isEmpty();
                   } else {
                     m_stack = result.toObject();
                     m_stackStale = false;
                   }
                   emit stackChanged();
                 });
}

void PullRequestReview::retryStack() {
  if (m_number > 0) readStack();
}

QList<QJsonObject> PullRequestReview::unmergedLayers() const {
  QList<QJsonObject> layers;
  for (const QJsonValue& layer : m_stack.value(QLatin1String("layers")).toArray()) {
    if (text(layer.toObject(), QLatin1String("state")) != QLatin1String("merged")) layers.append(layer.toObject());
  }
  return layers;
}

QList<QJsonObject> PullRequestReview::mergeLayers() const {
  QList<QJsonObject> layers;
  for (const QJsonValue& value : m_stack.value(QLatin1String("layers")).toArray()) {
    const QJsonObject layer = value.toObject();
    if (text(layer, QLatin1String("state")) != QLatin1String("merged")) layers.append(layer);
    if (layer.value(QLatin1String("number")).toInt() == m_number) return layers;
  }
  return {};
}

// What the stack is, and what can be done with it.
QVariantMap PullRequestReview::stack() const {
  const QJsonArray all = m_stack.value(QLatin1String("layers")).toArray();
  if (all.isEmpty()) return {};
  QVariantList layers;
  int position = 0;
  for (qsizetype index = 0; index < all.size(); ++index) {
    const QJsonObject layer = all.at(index).toObject();
    const bool current = layer.value(QLatin1String("number")).toInt() == m_number;
    if (current) position = int(index) + 1;
    layers.append(QVariantMap{{QStringLiteral("number"), layer.value(QLatin1String("number")).toInt()},
                              {QStringLiteral("title"), text(layer, QLatin1String("title"))},
                              {QStringLiteral("state"), text(layer, QLatin1String("state"))},
                              {QStringLiteral("current"), current}});
  }
  const auto ready = [](const QList<QJsonObject>& chosen) {
    return !chosen.isEmpty() && std::all_of(chosen.cbegin(), chosen.cend(), [](const QJsonObject& layer) {
      return text(layer, QLatin1String("state")) == QLatin1String("open") && !text(layer, QLatin1String("headSha")).isEmpty();
    });
  };
  const QList<QJsonObject> merging = mergeLayers();
  const bool noDrafts = std::none_of(merging.cbegin(), merging.cend(), [](const QJsonObject& layer) { return layer.value(QLatin1String("isDraft")).toBool(); });
  return {{QStringLiteral("number"), m_stack.value(QLatin1String("number")).toInt()},
          {QStringLiteral("base"), text(m_stack, QLatin1String("base"))},
          {QStringLiteral("position"), position},
          {QStringLiteral("size"), int(all.size())},
          {QStringLiteral("layers"), layers},
          {QStringLiteral("mergeCount"), int(merging.size())},
          {QStringLiteral("canMerge"), m_online && !m_stackStale && m_viewerMayMerge && ready(merging) && noDrafts},
          {QStringLiteral("canRebase"), m_online && !m_stackStale && m_viewerMayRebase && ready(unmergedLayers())},
          {QStringLiteral("stale"), m_stackStale},
          {QStringLiteral("notice"), m_stackStale ? QStringLiteral("Stack data may be stale. We couldn’t refresh it.") : QString()}};
}

bool PullRequestReview::requestStackMerge(const QString& method) {
  const QVariantMap shown = stack();
  if (!shown.value(QStringLiteral("canMerge")).toBool()) return false;
  const QStringList methods = m_detail.value(QStringLiteral("mergeMethods")).toStringList();
  m_stackMethod = method.isEmpty() ? methods.value(0, QStringLiteral("merge")) : method;
  const int count = shown.value(QStringLiteral("mergeCount")).toInt();
  m_stackConfirmation = {
      {QStringLiteral("action"), QStringLiteral("merge")},
      {QStringLiteral("title"), QStringLiteral("Merge %1 pull %2?").arg(count).arg(count == 1 ? QStringLiteral("request") : QStringLiteral("requests"))},
      {QStringLiteral("description"),
       QStringLiteral("Merge #%1 and its unmerged layers below into %2 using %3. GitHub checks their rules before merging or queueing them and rebases the "
                      "remaining stack after merging.")
           .arg(m_number)
           .arg(shown.value(QStringLiteral("base")).toString(), m_stackMethod)},
      {QStringLiteral("confirmLabel"), QStringLiteral("Merge stack")}};
  emit stackChanged();
  return true;
}

bool PullRequestReview::requestStackRebase() {
  const QVariantMap shown = stack();
  if (!shown.value(QStringLiteral("canRebase")).toBool()) return false;
  const int count = int(unmergedLayers().size());
  m_stackConfirmation = {
      {QStringLiteral("action"), QStringLiteral("rebase")},
      {QStringLiteral("title"), QStringLiteral("Rebase %1 pull %2?").arg(count).arg(count == 1 ? QStringLiteral("request") : QStringLiteral("requests"))},
      {QStringLiteral("description"),
       QStringLiteral("Rebase the remote branches from bottom to top onto %1. This rewrites branch history and may restart checks. If a layer fails, "
                      "earlier updates remain.")
           .arg(shown.value(QStringLiteral("base")).toString())},
      {QStringLiteral("confirmLabel"), QStringLiteral("Rebase stack")}};
  emit stackChanged();
  return true;
}

void PullRequestReview::cancelStack() {
  if (m_stackConfirmation.isEmpty()) return;
  m_stackConfirmation.clear();
  emit stackChanged();
}

void PullRequestReview::confirmStack() {
  if (m_stackConfirmation.isEmpty()) return;
  const bool merging = m_stackConfirmation.value(QStringLiteral("action")) == QLatin1String("merge");
  m_stackConfirmation.clear();
  emit stackChanged();
  // The heads the user saw: the host refuses a stack that moved since.
  const QList<QJsonObject> layers = merging ? mergeLayers() : unmergedLayers();
  if (layers.isEmpty()) return;
  QJsonArray heads;
  for (const QJsonObject& layer : layers) {
    heads.append(QJsonObject{{QStringLiteral("number"), layer.value(QLatin1String("number"))}, {QStringLiteral("headSha"), layer.value(QLatin1String("headSha"))}});
  }
  QJsonObject input = reference();
  // A merge is asked at this layer, a rebase at the stack's top.
  input.insert(QStringLiteral("number"), merging ? m_number : layers.last().value(QLatin1String("number")).toInt());
  input.insert(QStringLiteral("stackNumber"), m_stack.value(QLatin1String("number")));
  input.insert(QStringLiteral("expectedStackHeads"), heads);
  input.insert(QStringLiteral("action"), merging ? QStringLiteral("merge") : QStringLiteral("update-branch"));
  if (merging) {
    input.insert(QStringLiteral("mergeMethod"), m_stackMethod);
  } else {
    input.insert(QStringLiteral("updateMethod"), QStringLiteral("rebase"));
  }
  change(QStringLiteral("pullRequests.runAction"), input, QStringLiteral("Stack operation did not complete"), [this, merging] {
    m_notify(QStringLiteral("success"), merging ? QStringLiteral("Stack merge request completed") : QStringLiteral("Stack rebased"),
             merging ? QStringLiteral("GitHub merged the stack or added it to its merge queue.") : QString());
  });
}

bool PullRequestReview::merge(const QString& method) {
  if (!m_detail.value(QStringLiteral("canMerge")).toBool()) {
    setProblem(QStringLiteral("This pull request cannot be merged from here."));
    return false;
  }
  const QStringList methods = m_detail.value(QStringLiteral("mergeMethods")).toStringList();
  const QString chosen = method.isEmpty() ? methods.value(0) : method;
  if (!chosen.isEmpty() && !methods.contains(chosen)) {
    setProblem(QStringLiteral("This repository does not allow that merge method."));
    return false;
  }
  QJsonObject input = reference();
  input.insert(QStringLiteral("action"), QStringLiteral("merge"));
  // No method leaves it to the host's default.
  if (!chosen.isEmpty()) input.insert(QStringLiteral("mergeMethod"), chosen);
  return change(QStringLiteral("pullRequests.runAction"), input, QStringLiteral("Could not merge the pull request"), [this] {
    m_notify(QStringLiteral("success"), QStringLiteral("Merged"), QStringLiteral("#%1").arg(m_number));
  });
}

bool PullRequestReview::submitReview(const QString& verdict, const QString& body) {
  if (verdict != QLatin1String("comment") && verdict != QLatin1String("approve") && verdict != QLatin1String("request-changes")) return false;
  // Only an approval may say nothing (the MC's own rule).
  if (verdict != QLatin1String("approve") && body.trimmed().isEmpty()) {
    setProblem(QStringLiteral("A review needs a summary or at least one comment."));
    return false;
  }
  QJsonObject input = reference();
  input.insert(QStringLiteral("verdict"), verdict);
  input.insert(QStringLiteral("body"), body);
  input.insert(QStringLiteral("comments"), QJsonArray());
  return change(QStringLiteral("pullRequests.submitReview"), input, QStringLiteral("Could not submit the review"), [this, verdict] {
    m_notify(QStringLiteral("success"),
             verdict == QLatin1String("approve")           ? QStringLiteral("Approved")
             : verdict == QLatin1String("request-changes") ? QStringLiteral("Changes requested")
                                                          : QStringLiteral("Review submitted"),
             QStringLiteral("#%1").arg(m_number));
  });
}

void PullRequestReview::setThreadResolved(const QString& threadId, bool resolved) {
  QJsonObject input = reference();
  input.insert(QStringLiteral("threadId"), threadId);
  input.insert(QStringLiteral("resolved"), resolved);
  change(QStringLiteral("pullRequests.setThreadResolution"), input,
         resolved ? QStringLiteral("Could not resolve the thread") : QStringLiteral("Could not reopen the thread"));
}

bool PullRequestReview::change(const QString& method, const QJsonObject& input, const QString& failure, std::function<void()> done) {
  if (m_number <= 0) return false;
  if (!m_online) {
    setProblem(QStringLiteral("The environment is offline."));
    return false;
  }
  setProblem({});
  ++m_busy;
  emit stateChanged();
  const quint64 generation = m_generation;
  m_client->call(this, m_environment, method, input,
                 [this, generation, failure, done = std::move(done)](const QJsonValue&, const std::optional<QString>& error) {
                   --m_busy;
                   emit stateChanged();
                   if (generation != m_generation) return;
                   if (error) {
                     setProblem(*error);
                     m_notify(QStringLiteral("error"), failure, *error);
                     return;
                   }
                   if (done) done();
                   readDetail();
                 });
  return true;
}

void PullRequestReview::copyNumber() {
  if (m_number <= 0) return;
  if (m_copy(QStringLiteral("#%1").arg(m_number))) {
    m_notify(QStringLiteral("success"), QStringLiteral("PR number copied"), {});
  } else {
    m_notify(QStringLiteral("error"), QStringLiteral("Failed to copy PR number"), {});
  }
}

void PullRequestReview::openOnHost() {
  const QString url = m_detail.value(QStringLiteral("url")).toString();
  if (!url.isEmpty()) m_open(url);
}

void PullRequestReview::setStatus(const QString& status, const QString& message) {
  if (status == m_status && message == m_message) return;
  m_status = status;
  m_message = message;
  emit stateChanged();
}

void PullRequestReview::setCode(const QString& status, const QString& message) {
  if (status == m_codeStatus && message == m_codeMessage) return;
  m_codeStatus = status;
  m_codeMessage = message;
  emit codeChanged();
}

void PullRequestReview::setProblem(const QString& problem) {
  if (problem == m_problem) return;
  m_problem = problem;
  emit stateChanged();
}
