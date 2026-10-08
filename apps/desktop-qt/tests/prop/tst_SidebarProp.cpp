// The sidebar (src/native/SidebarController, SidebarModel) and where the
// window is (NavigationController) against a model of a cluster of MCs: the
// projects and threads each environment holds, and what the user did to the
// list. After every step the `sidebar` the shell publishes is the model's
// projection of it, row for row, and the window shows no thread that is gone.

#include "Prop.h"

#include <QDir>
#include <QLocale>

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <vector>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"

namespace {

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

const QDateTime kT0 = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
const std::string kOwn = "env-a";
const std::vector<std::string> kPeers{"b", "c"};
const std::vector<std::string> kEnvironments{"env-a", "b", "c"};
const std::vector<std::string> kThreadIds{"t1", "t2", "t3", "t4", "t5"};
const std::vector<std::string> kProjectIds{"p1", "p2"};
const std::vector<std::string> kTitles{"Alpha", "Beta", "Gamma"};
// When the projects were made: before any thread.
constexpr int kProjectsAt = -60;

// Minutes after kT0, as the rows carry them.
QString iso(int minutes) {
  return sidebar::formatIso(kT0.addSecs(qint64(minutes) * 60));
}
int minutesOf(const QString& stamp) {
  return int((sidebar::parseIso(stamp).value_or(0) - kT0.toMSecsSinceEpoch()) / 60000);
}

std::string keyOf(const std::string& environment, const std::string& id) {
  return environment + ":" + id;
}
std::pair<std::string, std::string> split(const std::string& key) {
  const size_t colon = key.find(':');
  return {key.substr(0, colon), key.substr(colon + 1)};
}
std::string mcOf(const std::string& environment) {
  return environment == kOwn ? "mc-a" : "mc-" + environment;
}

// One thread row, its times in minutes after kT0.
struct Row {
  std::string project;
  int title = 0;
  int created = 0;
  int updated = 0;
  std::optional<int> message;  // latestUserMessageAt
  std::optional<int> archived;
  std::string override;  // settledOverride, "" for none
  std::optional<int> settled;
  std::optional<int> unsettled;
  std::optional<int> snoozedUntil;
  std::optional<int> snoozedAt;
  std::optional<int> pinned;
  std::optional<std::string> pinKey;
  std::optional<std::string> activeKey;
  // On its way to this environment, and gone there (the forwarding record).
  std::optional<std::string> moving;
  std::optional<std::string> movedTo;
  bool operator==(const Row&) const = default;
};

struct Environment {
  bool online = true;
  std::map<std::string, int> projects;  // id -> title
  std::map<std::string, Row> threads;
  bool operator==(const Environment&) const = default;
};
using Environments = std::map<std::string, Environment>;

template <typename T>
void show(const std::optional<T>& value, std::ostream& os) {
  if (value) {
    os << *value;
  } else {
    os << "-";
  }
}

std::ostream& operator<<(std::ostream& os, const Row& row) {
  os << "{" << row.project << " '" << kTitles[size_t(row.title)] << "' @" << row.created << "/" << row.updated;
  if (row.message) os << " msg " << *row.message;
  if (row.archived) os << " archived " << *row.archived;
  if (!row.override.empty()) os << " " << row.override;
  if (row.settled) os << " settled " << *row.settled;
  if (row.unsettled) os << " unsettled " << *row.unsettled;
  if (row.snoozedUntil) {
    os << " snoozed " << *row.snoozedUntil << " (at ";
    show(row.snoozedAt, os);
    os << ")";
  }
  if (row.pinned) os << " pinned " << *row.pinned;
  if (row.pinKey) os << " pinKey " << *row.pinKey;
  if (row.activeKey) os << " activeKey " << *row.activeKey;
  if (row.moving) os << " moving->" << *row.moving;
  if (row.movedTo) os << " movedTo " << *row.movedTo;
  return os << "}";
}

std::ostream& operator<<(std::ostream& os, const Environments& environments) {
  for (const auto& [id, environment] : environments) {
    os << "\n  " << id << (environment.online ? "" : " (offline)") << ":";
    for (const auto& [project, title] : environment.projects) os << " " << project << "='" << kTitles[size_t(title)] << "'";
    for (const auto& [thread, row] : environment.threads) os << "\n    " << thread << " " << row;
  }
  return os;
}

// A command as the MC reads it (lib/hal_c2/orchestration.ex thread_fields).
struct Cmd {
  std::string type;
  std::optional<int> until;
  std::optional<std::string> orderKey;
};

Cmd commandOf(const QJsonObject& command) {
  Cmd cmd{command.value(QLatin1String("type")).toString().toStdString(), std::nullopt, std::nullopt};
  if (command.contains(QLatin1String("snoozedUntil"))) cmd.until = minutesOf(command.value(QLatin1String("snoozedUntil")).toString());
  if (command.contains(QLatin1String("orderKey"))) cmd.orderKey = command.value(QLatin1String("orderKey")).toString().toStdString();
  return cmd;
}

// What the command does to the row, as the real MC's projection; false for a
// command that does not change the sidebar's fields (a visit).
bool applyCommand(Row& row, const Cmd& cmd, int now) {
  if (cmd.type == "thread.archive") {
    row.archived = now;
  } else if (cmd.type == "thread.unarchive") {
    row.archived.reset();
  } else if (cmd.type == "thread.settle") {
    const bool kept = row.override == "settled" && !row.pinned && row.settled;
    row.settled = kept ? row.settled : now;
    row.override = "settled";
    row.unsettled.reset();
    row.pinned.reset();
    row.pinKey.reset();
    row.activeKey.reset();
  } else if (cmd.type == "thread.unsettle") {
    if (row.override != "active") row.unsettled = now;
    row.override = "active";
    row.settled.reset();
  } else if (cmd.type == "thread.snooze") {
    if (!(row.snoozedUntil && row.snoozedUntil == cmd.until && row.snoozedAt)) row.snoozedAt = now;
    row.snoozedUntil = cmd.until;
  } else if (cmd.type == "thread.unsnooze") {
    row.snoozedUntil.reset();
    row.snoozedAt.reset();
  } else if (cmd.type == "thread.pin") {
    if (row.override == "settled") {
      row.override = "active";
      row.settled.reset();
    }
    if (!row.pinned && cmd.orderKey) row.pinKey = cmd.orderKey;
    if (!row.pinned) row.pinned = now;
    row.snoozedUntil.reset();
    row.snoozedAt.reset();
  } else if (cmd.type == "thread.unpin") {
    row.pinned.reset();
    row.pinKey.reset();
  } else if (cmd.type == "thread.pin.reorder") {
    row.pinKey = cmd.orderKey;
  } else if (cmd.type == "thread.active.reorder") {
    row.activeKey = cmd.orderKey;
  } else {
    return false;
  }
  return true;
}

QJsonValue stamp(const std::optional<int>& minutes) {
  return minutes ? QJsonValue(iso(*minutes)) : QJsonValue(QJsonValue::Null);
}
QJsonValue text(const std::optional<std::string>& value) {
  return value ? QJsonValue(q(*value)) : QJsonValue(QJsonValue::Null);
}

QJsonObject threadJson(const std::string& id, const Row& row, int now) {
  return {
      {QStringLiteral("id"), q(id)},
      {QStringLiteral("projectId"), q(row.project)},
      {QStringLiteral("title"), q(kTitles[size_t(row.title)])},
      {QStringLiteral("createdAt"), iso(row.created)},
      {QStringLiteral("updatedAt"), iso(row.updated)},
      {QStringLiteral("latestUserMessageAt"), stamp(row.message)},
      {QStringLiteral("archivedAt"), stamp(row.archived)},
      {QStringLiteral("settledOverride"), row.override.empty() ? QJsonValue(QJsonValue::Null) : QJsonValue(q(row.override))},
      {QStringLiteral("settledAt"), stamp(row.settled)},
      {QStringLiteral("unsettledAt"), stamp(row.unsettled)},
      {QStringLiteral("snoozedUntil"), stamp(row.snoozedUntil)},
      {QStringLiteral("snoozedAt"), stamp(row.snoozedAt)},
      {QStringLiteral("pinnedAt"), stamp(row.pinned)},
      {QStringLiteral("pinOrderKey"), text(row.pinKey)},
      {QStringLiteral("activeOrderKey"), text(row.activeKey)},
      {QStringLiteral("moving"), row.moving ? QJsonValue(QJsonObject{{QStringLiteral("label"), q("to " + *row.moving)},
                                                                    {QStringLiteral("environmentId"), q(*row.moving)},
                                                                    {QStringLiteral("mc"), q(mcOf(*row.moving))},
                                                                    {QStringLiteral("at"), iso(now)}})
                                            : QJsonValue(QJsonValue::Null)},
      {QStringLiteral("movedTo"), row.movedTo ? QJsonValue(QJsonObject{{QStringLiteral("environmentId"), q(*row.movedTo)},
                                                                      {QStringLiteral("mc"), q(mcOf(*row.movedTo))}})
                                              : QJsonValue(QJsonValue::Null)},
  };
}

QJsonObject projectJson(const std::string& environment, const std::string& id, int title) {
  const QString root = q("/work/" + environment + "/" + id);
  return {
      {QStringLiteral("id"), q(id)},
      {QStringLiteral("title"), q(kTitles[size_t(title)])},
      {QStringLiteral("workspaceRoot"), root},
      {QStringLiteral("createdAt"), iso(kProjectsAt)},
      {QStringLiteral("updatedAt"), iso(kProjectsAt)},
      {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), q("repo-" + id)}, {QStringLiteral("rootPath"), root}}},
  };
}

// --- What the cluster holds, as the shell reads it --------------------------

const Row* rowAt(const Environments& environments, const std::string& environment, const std::string& id) {
  const auto found = environments.find(environment);
  if (found == environments.end()) return nullptr;
  const auto row = found->second.threads.find(id);
  return row == found->second.threads.end() ? nullptr : &row->second;
}

// A row the shell shows: not a forwarding record, and not the source of a move
// whose destination already has it (ShellStore::lives).
bool lives(const Environments& environments, const std::string& id, const Row& row) {
  if (row.movedTo) return false;
  if (!row.moving) return true;
  const Row* arrived = rowAt(environments, *row.moving, id);
  if (environments.count(*row.moving) == 0) return true;
  return arrived == nullptr || arrived->movedTo.has_value();
}

bool livingKey(const Environments& environments, const std::string& key) {
  const auto [environment, id] = split(key);
  const Row* row = rowAt(environments, environment, id);
  return row && lives(environments, id, *row);
}

struct Living {
  std::string environment;
  std::string id;
  const Row* row;
  std::string key() const { return keyOf(environment, id); }
};

std::vector<Living> living(const Environments& environments) {
  std::vector<Living> result;
  for (const auto& [environment, members] : environments) {
    for (const auto& [id, row] : members.threads) {
      if (lives(environments, id, row)) result.push_back({environment, id, &row});
    }
  }
  return result;
}

std::vector<std::string> livingKeys(const Environments& environments) {
  std::vector<std::string> keys;
  for (const Living& thread : living(environments)) keys.push_back(thread.key());
  return keys;
}

bool groupExists(const Environments& environments, const std::string& project) {
  return std::any_of(environments.begin(), environments.end(),
                     [&project](const auto& entry) { return entry.second.projects.count(project) > 0; });
}

std::string groupKey(const std::string& project) {
  return "repo-" + project;
}

// --- The model ---------------------------------------------------------------

struct Model {
  int now = 0;
  Environments environments;
  // Members removed from the cluster, as they come back.
  Environments away;
  bool connected = true;
  bool holding = false;
  // Rows a held settle or snooze is waiting on (SidebarController::parking).
  std::set<std::string> parking;
  std::optional<std::string> scope;  // a project id
  std::set<std::string> selected;
  std::string anchor;
};

Model initialModel() {
  Model model;
  for (const std::string& environment : kEnvironments) model.environments[environment].projects["p1"] = 0;
  return model;
}

bool online(const Model& model, const std::string& environment) {
  const auto found = model.environments.find(environment);
  return found != model.environments.end() && found->second.online;
}

bool idUsed(const Model& model, const std::string& id) {
  for (const Environments* set : {&model.environments, &model.away}) {
    for (const auto& entry : *set) {
      if (entry.second.threads.count(id)) return true;
    }
  }
  return false;
}

struct Sections {
  std::vector<Living> pinned, active, snoozed, settled;
};

int compareIdentity(const Living& left, const Living& right) {
  if (left.id != right.id) return left.id < right.id ? -1 : 1;
  if (left.environment != right.environment) return left.environment < right.environment ? -1 : 1;
  return 0;
}

// The list's sections, scoped or every project's, in the order they render.
Sections sectionsOf(const Model& model, bool scoped) {
  Sections sections;
  for (const Living& thread : living(model.environments)) {
    const Row& row = *thread.row;
    if (row.archived) continue;
    if (scoped && model.scope && row.project != *model.scope) continue;
    if (row.snoozedUntil && *row.snoozedUntil > model.now) {
      sections.snoozed.push_back(thread);
    } else if (row.override == "settled") {
      sections.settled.push_back(thread);
    } else if (row.pinned) {
      sections.pinned.push_back(thread);
    } else {
      sections.active.push_back(thread);
    }
  }
  std::sort(sections.pinned.begin(), sections.pinned.end(), [](const Living& left, const Living& right) {
    const Row& l = *left.row;
    const Row& r = *right.row;
    if (l.pinKey.has_value() != r.pinKey.has_value()) return l.pinKey.has_value();
    if (l.pinKey && *l.pinKey != *r.pinKey) return *l.pinKey < *r.pinKey;
    if (!l.pinKey && l.created != r.created) return l.created > r.created;
    return compareIdentity(left, right) < 0;
  });
  std::sort(sections.active.begin(), sections.active.end(), [](const Living& left, const Living& right) {
    const Row& l = *left.row;
    const Row& r = *right.row;
    if (l.activeKey.has_value() != r.activeKey.has_value()) return !l.activeKey.has_value();
    if (l.activeKey && *l.activeKey != *r.activeKey) return *l.activeKey < *r.activeKey;
    const int leftAt = std::max(l.created, l.unsettled.value_or(0));
    const int rightAt = std::max(r.created, r.unsettled.value_or(0));
    if (!l.activeKey && leftAt != rightAt) return leftAt > rightAt;
    return compareIdentity(left, right) < 0;
  });
  // Soonest wake first; a tie reads the same every time.
  std::sort(sections.snoozed.begin(), sections.snoozed.end(), [](const Living& left, const Living& right) {
    if (*left.row->snoozedUntil != *right.row->snoozedUntil) return *left.row->snoozedUntil < *right.row->snoozedUntil;
    return compareIdentity(left, right) < 0;
  });
  std::sort(sections.settled.begin(), sections.settled.end(), [](const Living& left, const Living& right) {
    if (*left.row->settled != *right.row->settled) return *left.row->settled > *right.row->settled;
    return compareIdentity(left, right) < 0;
  });
  return sections;
}

std::vector<std::string> keysOf(const std::vector<Living>& section) {
  std::vector<std::string> keys;
  for (const Living& thread : section) keys.push_back(thread.key());
  return keys;
}

std::vector<std::string> orderedKeys(const Model& model) {
  const Sections sections = sectionsOf(model, true);
  std::vector<std::string> keys;
  for (const auto* section : {&sections.pinned, &sections.active, &sections.snoozed, &sections.settled}) {
    for (const Living& thread : *section) keys.push_back(thread.key());
  }
  return keys;
}

std::vector<std::string> sectionKeys(const Model& model, const std::string& section) {
  const Sections sections = sectionsOf(model, true);
  if (section == "pinned") return keysOf(sections.pinned);
  if (section == "active") return keysOf(sections.active);
  if (section == "snoozed") return keysOf(sections.snoozed);
  return keysOf(sections.settled);
}

std::string sectionOf(const Model& model, const std::string& key) {
  for (const char* section : {"pinned", "active", "snoozed", "settled"}) {
    const auto keys = sectionKeys(model, section);
    if (std::find(keys.begin(), keys.end(), key) != keys.end()) return section;
  }
  return {};
}

// What the shell redoes on every refresh: a scope whose project went shows
// everything, and only listed rows stay selected.
void normalize(Model& model) {
  if (!model.connected) return;
  if (model.scope && !groupExists(model.environments, *model.scope)) model.scope.reset();
  const std::vector<std::string> listed = orderedKeys(model);
  std::erase_if(model.selected, [&listed](const std::string& key) { return std::find(listed.begin(), listed.end(), key) == listed.end(); });
}

// A row action that goes to the thread's MC (SidebarController::command).
void dispatch(Model& model, const std::string& key, const Cmd& cmd) {
  const auto [environment, id] = split(key);
  if (!online(model, environment)) return;
  Row* row = &model.environments[environment].threads[id];
  applyCommand(*row, cmd, model.now);
}

// SidebarController::park: once per thread at a time.
void park(Model& model, const std::string& key, const Cmd& cmd) {
  if (model.parking.count(key) || !livingKey(model.environments, key)) return;
  const auto [environment, id] = split(key);
  if (!online(model, environment)) return;
  dispatch(model, key, cmd);
  if (model.holding) model.parking.insert(key);
}

// SidebarController::arrange: the order keys that put `key` where `ordered`
// has it, the threads the scope hides keeping theirs.
void arrange(Model& model, const std::string& section, const std::vector<std::string>& ordered, const std::string& key,
             bool pinning = false) {
  const bool pinned = section == "pinned";
  const Sections all = sectionsOf(model, false);
  QHash<QString, sidebar::Nullable> orderKeys;
  for (const Living& thread : pinned ? all.pinned : all.active) {
    const auto& orderKey = pinned ? thread.row->pinKey : thread.row->activeKey;
    orderKeys.insert(q(thread.key()), orderKey ? sidebar::Nullable(q(*orderKey)) : std::nullopt);
  }
  if (pinning) orderKeys.insert(q(key), std::nullopt);
  QStringList keys;
  for (const std::string& each : ordered) keys.append(q(each));
  for (const sidebar::OrderAssignment& assignment : sidebar::planReorder(keys, orderKeys, q(key))) {
    const std::string assigned = assignment.key.toStdString();
    const std::string type = pinning && assigned == key ? "thread.pin" : pinned ? "thread.pin.reorder" : "thread.active.reorder";
    dispatch(model, assigned, Cmd{type, std::nullopt, assignment.orderKey.toStdString()});
  }
}

// --- The projection ----------------------------------------------------------

struct RowView {
  std::string key, environment, projectKey, title, status, snoozedUntil, wakeLabel, movingTo;
  bool pinned = false, selected = false, offline = false, canSettle = false, canSnooze = false;
  bool operator==(const RowView&) const = default;
};
struct ProjectView {
  std::string key, displayName, environment, projectId, workspaceRoot, status;
  int threadCount = 0;
  bool operator==(const ProjectView&) const = default;
};
struct Projection {
  std::vector<RowView> pinned, active, snoozed, settled;
  int settledTotal = 0;
  std::vector<ProjectView> projects;
  std::string scope;
  std::vector<std::string> selected;
  bool operator==(const Projection&) const = default;
};

std::ostream& operator<<(std::ostream& os, const RowView& row) {
  os << row.key << "[" << row.projectKey << " '" << row.title << "' " << row.status;
  if (row.pinned) os << " pinned";
  if (!row.snoozedUntil.empty()) os << " until " << row.snoozedUntil;
  if (!row.wakeLabel.empty()) os << " wake " << row.wakeLabel;
  if (!row.movingTo.empty()) os << " moving " << row.movingTo;
  if (row.selected) os << " selected";
  if (row.offline) os << " offline";
  os << (row.canSettle ? " +settle" : "") << (row.canSnooze ? " +snooze" : "");
  return os << "]";
}

std::ostream& operator<<(std::ostream& os, const Projection& view) {
  const auto rows = [&os](const char* name, const std::vector<RowView>& section) {
    os << "\n  " << name << ":";
    for (const RowView& row : section) os << " " << row;
  };
  rows("pinned", view.pinned);
  rows("active", view.active);
  rows("snoozed", view.snoozed);
  rows("settled", view.settled);
  os << "\n  settledTotal " << view.settledTotal << ", scope '" << view.scope << "', selected";
  for (const std::string& key : view.selected) os << " " << key;
  os << "\n  projects:";
  for (const ProjectView& project : view.projects) {
    os << " " << project.key << "['" << project.displayName << "' " << project.environment << ":" << project.projectId << " "
       << project.workspaceRoot << " " << project.threadCount << " " << project.status << "]";
  }
  return os;
}

std::string wakeLabel(int until, int now) {
  const int remaining = until - now;
  if (remaining <= 0) return "now";
  if (remaining < 60) return std::to_string(remaining) + "m";
  if (remaining < 24 * 60) return std::to_string((remaining + 59) / 60) + "h";
  return std::to_string((remaining + 24 * 60 - 1) / (24 * 60)) + "d";
}

Projection expected(const Model& model) {
  Projection view;
  const Sections sections = sectionsOf(model, true);
  const std::vector<std::string> listed = orderedKeys(model);
  const auto rows = [&](const std::vector<Living>& section, bool snoozed) {
    std::vector<RowView> result;
    for (const Living& thread : section) {
      const Row& row = *thread.row;
      const bool offline = !online(model, thread.environment);
      // A message sent in the last two minutes is a turn about to start.
      const bool starting = row.message && std::abs(model.now - *row.message) <= 2;
      result.push_back(RowView{thread.key(), thread.environment, groupKey(row.project), kTitles[size_t(row.title)], "ready",
                               row.snoozedUntil ? iso(*row.snoozedUntil).toStdString() : "",
                               snoozed ? wakeLabel(*row.snoozedUntil, model.now) : "", row.moving ? "to " + *row.moving : "",
                               row.pinned.has_value(), model.selected.count(thread.key()) > 0, offline, !offline, !offline && !starting});
    }
    return result;
  };
  view.pinned = rows(sections.pinned, false);
  view.active = rows(sections.active, false);
  view.snoozed = rows(sections.snoozed, true);
  view.settled = rows(sections.settled, false);
  view.settledTotal = int(sections.settled.size());
  view.scope = model.scope ? groupKey(*model.scope) : "";
  for (const std::string& key : listed) {
    if (model.selected.count(key)) view.selected.push_back(key);
  }

  // Projects group by repository: one group per project id, named by its
  // members' one title or else the own machine's member's, newest activity first.
  struct Group {
    ProjectView view;
    std::string title;
    int at = kProjectsAt;
    bool withThreads = false;
  };
  std::vector<Group> groups;
  for (const std::string& project : kProjectIds) {
    std::vector<std::string> members;  // environments, in key order
    for (const auto& [environment, members_] : model.environments) {
      if (members_.projects.count(project)) members.push_back(environment);
    }
    if (members.empty()) continue;
    std::sort(members.begin(), members.end(),
              [&project](const std::string& l, const std::string& r) { return keyOf(l, project) < keyOf(r, project); });
    const std::string representative =
        std::find(members.begin(), members.end(), kOwn) != members.end() ? kOwn : members.front();
    std::set<int> titles;
    for (const std::string& environment : members) titles.insert(model.environments.at(environment).projects.at(project));
    const int title = titles.size() == 1 ? *titles.begin() : model.environments.at(representative).projects.at(project);
    Group group{ProjectView{groupKey(project), kTitles[size_t(title)], representative, project,
                            "/work/" + representative + "/" + project, "ready", 0},
                kTitles[size_t(model.environments.at(representative).projects.at(project))]};
    for (const Living& thread : living(model.environments)) {
      if (thread.row->archived || thread.row->project != project) continue;
      group.view.threadCount += 1;
      const int at = thread.row->message.value_or(thread.row->updated);
      group.at = group.withThreads ? std::max(group.at, at) : at;
      group.withThreads = true;
    }
    groups.push_back(group);
  }
  std::stable_sort(groups.begin(), groups.end(), [](const Group& left, const Group& right) {
    if (left.at != right.at) return left.at > right.at;
    if (const int byTitle = q(left.title).localeAwareCompare(q(right.title))) return byTitle < 0;
    return q(left.view.key).localeAwareCompare(q(right.view.key)) < 0;
  });
  for (const Group& group : groups) view.projects.push_back(group.view);
  return view;
}

std::string string(const QVariant& value) {
  return value.isNull() ? std::string() : value.toString().toStdString();
}

Projection read(const QVariantMap& state) {
  Projection view;
  const auto rows = [&state](const char* name) {
    std::vector<RowView> result;
    for (const QVariant& value : state.value(QLatin1String(name)).toList()) {
      const QVariantMap row = value.toMap();
      result.push_back(RowView{string(row.value(QStringLiteral("key"))), string(row.value(QStringLiteral("environmentId"))),
                               string(row.value(QStringLiteral("projectKey"))), string(row.value(QStringLiteral("title"))),
                               string(row.value(QStringLiteral("status"))), string(row.value(QStringLiteral("snoozedUntil"))),
                               string(row.value(QStringLiteral("wakeLabel"))), string(row.value(QStringLiteral("movingTo"))),
                               row.value(QStringLiteral("pinned")).toBool(), row.value(QStringLiteral("selected")).toBool(),
                               row.value(QStringLiteral("offline")).toBool(), row.value(QStringLiteral("canSettle")).toBool(),
                               row.value(QStringLiteral("canSnooze")).toBool()});
    }
    return result;
  };
  view.pinned = rows("pinned");
  view.active = rows("active");
  view.snoozed = rows("snoozed");
  view.settled = rows("settled");
  view.settledTotal = state.value(QStringLiteral("settledTotal")).toInt();
  view.scope = string(state.value(QStringLiteral("scopeProjectKey")));
  for (const QVariant& key : state.value(QStringLiteral("selectedKeys")).toList()) view.selected.push_back(key.toString().toStdString());
  for (const QVariant& value : state.value(QStringLiteral("projects")).toList()) {
    const QVariantMap project = value.toMap();
    view.projects.push_back(ProjectView{string(project.value(QStringLiteral("key"))), string(project.value(QStringLiteral("displayName"))),
                                        string(project.value(QStringLiteral("environmentId"))), string(project.value(QStringLiteral("projectId"))),
                                        string(project.value(QStringLiteral("workspaceRoot"))), string(project.value(QStringLiteral("status"))),
                                        project.value(QStringLiteral("threadCount")).toInt()});
  }
  return view;
}

// --- The shell under test ----------------------------------------------------

// The shell against one fake MC that serves the cluster: what the MC holds
// (`truth`, changed by the steps and by the commands it is sent) and the shell
// that shows it.
struct Sut {
  FakeMc mc;
  QTemporaryDir home;
  Environments truth;
  Environments away;
  int now = 0;
  int sidebarChanges = 0;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;

  explicit Sut(const Model& initial) : truth(initial.environments) {
    mc.onRpc(QStringLiteral("orchestration.dispatchCommand"), [this](const FakeMc::Rpc& rpc) { answer(rpc); });
    for (const auto& [environment, members] : truth) {
      if (environment != kOwn) mc.join(q(environment));
      for (const auto& [project, title] : members.projects) pushProject(environment, project);
      for (const auto& [id, row] : members.threads) push(environment, id);
    }
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->sidebar()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->sidebar()->setClock([this] { return kT0.addSecs(qint64(now) * 60); });
    native->restoreWindows();
    QObject::connect(bridge.get(), &ShellBridge::stateEntryChanged, bridge.get(), [this](const QString& key, const QVariant&) {
      if (key == QLatin1String("sidebar")) ++sidebarChanges;
    });
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(halc2::prop::until([this] { return shellSubscriptions() >= 1; }));
    sync();
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  SidebarController* sidebar() { return native->sidebar(); }
  NavigationController* navigation() { return native->controller<NavigationController>(); }
  QVariantMap state() const { return bridge->state()->value(QStringLiteral("sidebar")).toMap(); }

  int shellSubscriptions() const {
    int count = 0;
    for (const QJsonObject& sub : mc.subscriptions) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) count++;
    }
    return count;
  }

  // A round trip through the MC: what it sent before is in.
  void sync() {
    native->cache()->drain();
    auto done = std::make_shared<bool>(false);
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [done](const QJsonValue&, const std::optional<QString>&) { *done = true; });
    RC_ASSERT(halc2::prop::until([done] { return *done; }));
  }

  void dispatch(const QString& action, const QVariantMap& payload) { bridge->dispatch(action, payload); }

  // The MC's `orchestration.dispatchCommand`: applied at once, its answer held
  // while the step holds answers.
  void answer(const FakeMc::Rpc& rpc) {
    const std::string environment = rpc.environment.isEmpty() ? kOwn : rpc.environment.toStdString();
    const std::string id = rpc.payload.value(QLatin1String("threadId")).toString().toStdString();
    const auto found = truth.find(environment);
    Row* row = nullptr;
    if (found != truth.end()) {
      const auto it = found->second.threads.find(id);
      if (it != found->second.threads.end()) row = &it->second;
    }
    if (!row || row->movedTo) {
      mc.refuse(rpc, QStringLiteral("Thread not found"));
      return;
    }
    if (applyCommand(*row, commandOf(rpc.payload), now)) push(environment, id);
    if (mc.holding(QStringLiteral("answers"))) {
      mc.defer([this, rpc] { mc.reply(rpc, QJsonObject{}); });
    } else {
      mc.reply(rpc, QJsonObject{});
    }
  }

  // Sends the thread's row as it is now, or that it went.
  void push(const std::string& environment, const std::string& id) {
    const Row* row = rowAt(truth, environment, id);
    const QJsonObject json = row ? threadJson(id, *row, now)
                                 : QJsonObject{{QStringLiteral("id"), q(id)}, {QStringLiteral("deletedAt"), iso(now)}};
    if (environment == kOwn) {
      if (row) {
        mc.threads.insert(q(id), json);
      } else {
        mc.threads.remove(q(id));
      }
      mc.sendRow(q(id), json);
    } else {
      mc.sendPeerRow(q(environment), q(id), json);
    }
  }

  void pushProject(const std::string& environment, const std::string& id) {
    const auto& projects = truth[environment].projects;
    const auto found = projects.find(id);
    const QJsonObject json = found != projects.end()
                                 ? projectJson(environment, id, found->second)
                                 : QJsonObject{{QStringLiteral("id"), q(id)}, {QStringLiteral("deletedAt"), iso(now)}};
    if (environment == kOwn) {
      if (found != projects.end()) {
        mc.projects.insert(q(id), json);
      } else {
        mc.projects.remove(q(id));
      }
      mc.sendRow(q(id), json, QStringLiteral("project"));
    } else {
      mc.sendPeerRow(q(environment), q(id), json, QStringLiteral("project"));
    }
  }

  // The window shows no thread that is gone: one it shows lives, or is being
  // parked (it moves on when the MC answers).
  void expectNavigation(const Model& model) {
    const NavigationController::Route& route = navigation()->route();
    if (route.kind != QLatin1String("thread")) return;
    const std::string key = route.threadKey.toStdString();
    if (livingKey(model.environments, key) || model.parking.count(key)) return;
    RC_FAIL("the window shows " + key + ", which is gone");
  }

  void expect(const Model& model) {
    if (model.connected) sync();
    if (!(truth == model.environments)) {
      RC_FAIL("the MC holds" + rc::toString(truth) + "\nthe model" + rc::toString(model.environments));
    }
    if (!model.connected) return;
    const Projection actual = read(state());
    const Projection want = expected(model);
    if (!(actual == want)) RC_FAIL("the sidebar shows" + rc::toString(actual) + "\nthe model" + rc::toString(want));
    for (const std::string& key : model.parking) RC_ASSERT(sidebar()->parking(q(key)));
    expectNavigation(model);
  }
};

using Command = rc::state::Command<Model, Sut>;

// --- What the MCs do ---------------------------------------------------------

std::string genEnvironment() {
  return *rc::gen::elementOf(kEnvironments);
}
std::string genThreadId() {
  return *rc::gen::elementOf(kThreadIds);
}

// A key of a thread the shell lists or holds; none fails the precondition.
std::string genLivingKey(const Model& model) {
  const std::vector<std::string> keys = livingKeys(model.environments);
  RC_PRE(!keys.empty());
  return *rc::gen::elementOf(keys);
}

struct CreateThread : Command {
  std::string environment = genEnvironment();
  std::string id = genThreadId();
  std::string project = *rc::gen::elementOf(kProjectIds);
  int title = *rc::gen::inRange(0, int(kTitles.size()));

  explicit CreateThread(const Model&) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(online(model, environment));
    RC_PRE(!idUsed(model, id));
    RC_PRE(model.environments.at(environment).projects.count(project) > 0);
  }
  static void mutate(Environments& environments, const std::string& environment, const std::string& id, const std::string& project,
                     int title, int now) {
    Row row;
    row.project = project;
    row.title = title;
    row.created = now;
    row.updated = now;
    environments[environment].threads[id] = row;
  }
  void apply(Model& model) const override {
    mutate(model.environments, environment, id, project, title, model.now);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    mutate(sut.truth, environment, id, project, title, sut.now);
    sut.push(environment, id);
    sut.expect(next);
  }
  void show(std::ostream& os) const override {
    os << "CreateThread(" << keyOf(environment, id) << " in " << project << " '" << kTitles[size_t(title)] << "')";
  }
};

// One thread's row changes on its MC: renamed, written to, archived or deleted.
struct ChangeThread : Command {
  std::string environment = genEnvironment();
  std::string id = genThreadId();
  std::string change = *rc::gen::elementOf(std::vector<std::string>{"rename", "message", "archive", "delete"});
  int title = *rc::gen::inRange(0, int(kTitles.size()));

  explicit ChangeThread(const Model&) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(online(model, environment));
    const Row* row = rowAt(model.environments, environment, id);
    RC_PRE(bool(row));
    RC_PRE(!row->movedTo);
    if (change == "archive") RC_PRE(!row->archived);
  }
  void mutate(Environments& environments, int now) const {
    auto& threads = environments[environment].threads;
    Row& row = threads[id];
    if (change == "rename") {
      row.title = title;
      row.updated = now;
    } else if (change == "message") {
      row.message = now;
      row.updated = now;
    } else if (change == "archive") {
      row.archived = now;
    } else {
      threads.erase(id);
    }
  }
  void apply(Model& model) const override {
    mutate(model.environments, model.now);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    mutate(sut.truth, sut.now);
    sut.push(environment, id);
    sut.expect(next);
  }
  void show(std::ostream& os) const override {
    os << "ChangeThread(" << keyOf(environment, id) << " " << change;
    if (change == "rename") os << " '" << kTitles[size_t(title)] << "'";
    os << ")";
  }
};

// A project comes, is renamed, or goes (only once no row is in it).
struct ChangeProject : Command {
  std::string environment = genEnvironment();
  std::string project = *rc::gen::elementOf(kProjectIds);
  std::string change = *rc::gen::elementOf(std::vector<std::string>{"put", "delete"});
  int title = *rc::gen::inRange(0, int(kTitles.size()));

  explicit ChangeProject(const Model&) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(online(model, environment));
    if (change == "delete") {
      const Environment& members = model.environments.at(environment);
      RC_PRE(members.projects.count(project) > 0);
      for (const auto& [id, row] : members.threads) RC_PRE(row.project != project);
      // A thread on its way here keeps its project here.
      for (const auto& [other, members_] : model.environments) {
        for (const auto& [id, row] : members_.threads) RC_PRE(!(row.moving == environment && row.project == project));
      }
    }
  }
  void mutate(Environments& environments) const {
    if (change == "put") {
      environments[environment].projects[project] = title;
    } else {
      environments[environment].projects.erase(project);
    }
  }
  void apply(Model& model) const override {
    mutate(model.environments);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    mutate(sut.truth);
    sut.pushProject(environment, project);
    sut.expect(next);
  }
  void show(std::ostream& os) const override {
    os << "ChangeProject(" << environment << ":" << project << " " << change;
    if (change == "put") os << " '" << kTitles[size_t(title)] << "'";
    os << ")";
  }
};

// A thread moves to another machine in steps: it is marked moving on its
// source, arrives on the destination, and leaves a forwarding record behind;
// or the move is called off before it arrives.
struct MoveThread : Command {
  std::string id = genThreadId();
  std::string step = *rc::gen::elementOf(std::vector<std::string>{"start", "arrive", "finish", "cancel"});
  std::string destination = genEnvironment();

  explicit MoveThread(const Model&) {}

  // Where the thread is now: its environment and row, on the move or not.
  static std::optional<std::string> sourceOf(const Environments& environments, const std::string& id) {
    for (const auto& [environment, members] : environments) {
      const auto found = members.threads.find(id);
      if (found != members.threads.end() && !found->second.movedTo && (found->second.moving || lives(environments, id, found->second))) {
        return environment;
      }
    }
    return std::nullopt;
  }

  void checkPreconditions(const Model& model) const override {
    const auto source = sourceOf(model.environments, id);
    RC_PRE(source.has_value());
    const Row& row = model.environments.at(*source).threads.at(id);
    if (step == "start") {
      RC_PRE(!row.moving && online(model, *source) && *source != destination);
      RC_PRE(model.environments.count(destination) > 0);
      RC_PRE(model.environments.at(destination).projects.count(row.project) > 0);
      RC_PRE(!rowAt(model.environments, destination, id));
      RC_PRE(!idUsedAway(model));
      return;
    }
    RC_PRE(row.moving.has_value());
    RC_PRE(model.environments.count(*row.moving) > 0);
    const Row* arrived = rowAt(model.environments, *row.moving, id);
    if (step == "arrive") {
      RC_PRE(!arrived && online(model, *row.moving));
      RC_PRE(model.environments.at(*row.moving).projects.count(row.project) > 0);
    } else if (step == "finish") {
      RC_PRE(bool(arrived) && online(model, *source));
    } else {
      RC_PRE(!arrived && online(model, *source));
    }
  }
  bool idUsedAway(const Model& model) const {
    return std::any_of(model.away.begin(), model.away.end(), [this](const auto& entry) { return entry.second.threads.count(id) > 0; });
  }
  // The environment whose row changed.
  std::string mutate(Environments& environments) const {
    const std::string source = *sourceOf(environments, id);
    Row& row = environments[source].threads[id];
    if (step == "start") {
      row.moving = destination;
      return source;
    }
    const std::string to = *row.moving;
    if (step == "arrive") {
      Row copy = row;
      copy.moving.reset();
      environments[to].threads[id] = copy;
      return to;
    }
    row.moving.reset();
    if (step == "finish") row.movedTo = to;
    return source;
  }
  void apply(Model& model) const override {
    mutate(model.environments);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.push(mutate(sut.truth), id);
    sut.expect(next);
  }
  void show(std::ostream& os) const override {
    os << "MoveThread(" << id << " " << step;
    if (step == "start") os << " to " << destination;
    os << ")";
  }
};

// A member's MC goes down or comes back; its rows stay.
struct SetOnline : Command {
  std::string environment = *rc::gen::elementOf(kPeers);
  bool up = *rc::gen::arbitrary<bool>();

  explicit SetOnline(const Model&) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.environments.count(environment) > 0);
    RC_PRE(model.environments.at(environment).online != up);
  }
  void apply(Model& model) const override {
    model.environments[environment].online = up;
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.truth[environment].online = up;
    sut.mc.setOnline(q(environment), up);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "SetOnline(" << environment << ", " << (up ? "up" : "down") << ")"; }
};

// A member leaves the cluster, taking its rows, or joins again with them.
struct Membership : Command {
  std::string environment = *rc::gen::elementOf(kPeers);

  explicit Membership(const Model&) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.environments.count(environment) > 0 || model.away.count(environment) > 0);
  }
  static void mutate(Environments& environments, Environments& away, const std::string& environment) {
    if (environments.count(environment)) {
      Environment& leaving = away[environment] = environments.at(environment);
      leaving.online = true;
      environments.erase(environment);
    } else {
      environments[environment] = away.at(environment);
      away.erase(environment);
    }
  }
  void apply(Model& model) const override {
    mutate(model.environments, model.away, environment);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const bool leaving = sut.truth.count(environment) > 0;
    mutate(sut.truth, sut.away, environment);
    if (leaving) {
      sut.mc.remove(q(environment));
    } else {
      sut.mc.join(q(environment));
      for (const auto& [project, title] : sut.truth.at(environment).projects) sut.pushProject(environment, project);
      for (const auto& [id, row] : sut.truth.at(environment).threads) sut.push(environment, id);
    }
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Membership(" << environment << ")"; }
};

// The clock moves on: snoozes run out and wake labels count down. Standing
// still changes nothing the shell publishes.
struct Tick : Command {
  int minutes = *rc::gen::elementOf(std::vector<int>{0, 1, 9, 30, 61, 1500});

  explicit Tick(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override {
    model.now += minutes;
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.sync();
    const int before = sut.sidebarChanges;
    sut.now += minutes;
    sut.sidebar()->refresh();
    sut.expect(next);
    if (minutes == 0) RC_ASSERT(sut.sidebarChanges == before);
  }
  void show(std::ostream& os) const override { os << "Tick(" << minutes << "m)"; }
};

// The MC sends a row again as it was: the list does not change.
struct Resend : Command {
  std::string key;

  explicit Resend(const Model& model) : key(genLivingKey(model)) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.connected);
    RC_PRE(livingKey(model.environments, key));
    RC_PRE(online(model, split(key).first));
  }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    sut.sync();
    const int before = sut.sidebarChanges;
    const auto [environment, id] = split(key);
    sut.push(environment, id);
    sut.expect(model);
    RC_ASSERT(sut.sidebarChanges == before);
  }
  void show(std::ostream& os) const override { os << "Resend(" << key << ")"; }
};

// The connection to the MC drops; the MCs go on changing until it is back.
struct Disconnect : Command {
  explicit Disconnect(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override {
    model.connected = false;
    model.parking.clear();
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.sync();
    sut.mc.stopAccepting();
    sut.mc.drop();
    // The calls in flight fail, which ends their parking.
    RC_ASSERT(halc2::prop::until([&] {
      return std::none_of(model.parking.begin(), model.parking.end(), [&](const std::string& key) { return sut.sidebar()->parking(q(key)); });
    }));
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Disconnect"; }
};

struct Reconnect : Command {
  explicit Reconnect(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.connected); }
  void apply(Model& model) const override {
    model.connected = true;
    model.holding = false;
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const int before = sut.shellSubscriptions();
    sut.mc.answerHeld();
    sut.mc.startAccepting();
    RC_ASSERT(halc2::prop::until([&] { return sut.shellSubscriptions() > before; }));
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

// --- What the user does ------------------------------------------------------

// A row action on a thread the shell holds.
struct RowAction : Command {
  std::string key;
  std::string action = *rc::gen::elementOf(std::vector<std::string>{"settle", "snooze", "unsettle", "unsnooze", "unarchive", "open"});
  int minutes = *rc::gen::elementOf(std::vector<int>{10, 30, 60, 180, 2000});

  explicit RowAction(const Model& model) : key(genLivingKey(model)) {}

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.connected);
    RC_PRE(livingKey(model.environments, key));
  }
  void apply(Model& model) const override {
    if (action == "settle") {
      park(model, key, Cmd{"thread.settle", std::nullopt, std::nullopt});
    } else if (action == "snooze") {
      park(model, key, Cmd{"thread.snooze", model.now + minutes, std::nullopt});
    } else if (action == "unsettle") {
      dispatch(model, key, Cmd{"thread.unsettle", std::nullopt, std::nullopt});
    } else if (action == "unsnooze") {
      dispatch(model, key, Cmd{"thread.unsnooze", std::nullopt, std::nullopt});
    } else if (action == "unarchive") {
      dispatch(model, key, Cmd{"thread.unarchive", std::nullopt, std::nullopt});
    } else {
      model.anchor = key;
      model.selected.clear();
    }
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const QVariantMap keyed{{QStringLiteral("key"), q(key)}};
    if (action == "settle") {
      sut.dispatch(QStringLiteral("thread.settle"), keyed);
    } else if (action == "snooze") {
      sut.sidebar()->snooze(q(key), iso(model.now + minutes));
    } else if (action == "unsettle") {
      sut.dispatch(QStringLiteral("thread.unsettle"), keyed);
    } else if (action == "unsnooze") {
      sut.dispatch(QStringLiteral("thread.unsnooze"), keyed);
    } else if (action == "unarchive") {
      const auto [environment, id] = split(key);
      sut.dispatch(QStringLiteral("archivedThreads.unarchive"), {{QStringLiteral("environmentId"), q(environment)}, {QStringLiteral("threadId"), q(id)}});
    } else {
      sut.dispatch(QStringLiteral("thread.open"), keyed);
      RC_ASSERT(sut.navigation()->threadKey() == q(key));
    }
    sut.expect(next);
  }
  void show(std::ostream& os) const override {
    os << "RowAction(" << action << " " << key;
    if (action == "snooze") os << " +" << minutes << "m";
    os << ")";
  }
};

// Moving a pinned or active row one place up or down.
struct MoveRow : Command {
  std::string key;
  bool up = *rc::gen::arbitrary<bool>();

  explicit MoveRow(const Model& model) : key(genLivingKey(model)) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  // The section as it should read, or nothing when the row cannot move.
  std::optional<std::pair<std::string, std::vector<std::string>>> plan(const Model& model) const {
    const std::string section = sectionOf(model, key);
    if (section != "pinned" && section != "active") return std::nullopt;
    std::vector<std::string> ordered = sectionKeys(model, section);
    const auto index = std::find(ordered.begin(), ordered.end(), key) - ordered.begin();
    const auto other = index + (up ? -1 : 1);
    if (other < 0 || other >= std::ssize(ordered)) return std::nullopt;
    std::swap(ordered[size_t(index)], ordered[size_t(other)]);
    return std::pair{section, ordered};
  }
  void apply(Model& model) const override {
    if (const auto planned = plan(model)) arrange(model, planned->first, planned->second, key);
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.dispatch(QStringLiteral("thread.move"), {{QStringLiteral("key"), q(key)}, {QStringLiteral("direction"), up ? QStringLiteral("up") : QStringLiteral("down")}});
    sut.expect(next);
    expectArranged(model, next, plan(model));
  }
  // The row went where the user put it, unless an MC it needed is down.
  static void expectArranged(const Model& before, const Model& after,
                             const std::optional<std::pair<std::string, std::vector<std::string>>>& planned) {
    if (!planned) return;
    for (const std::string& key : planned->second) {
      if (!online(before, split(key).first)) return;
    }
    RC_ASSERT(sectionKeys(after, planned->first) == planned->second);
  }
  void show(std::ostream& os) const override { os << "MoveRow(" << key << (up ? " up" : " down") << ")"; }
};

// Dragging a row into a section, before one of its rows or at its end.
struct DropRow : Command {
  std::string key;
  std::string section = *rc::gen::elementOf(std::vector<std::string>{"pinned", "active", "snoozed", "settled"});
  std::string before;

  explicit DropRow(const Model& model) : key(genLivingKey(model)) {
    const std::vector<std::string> keys = sectionKeys(model, section);
    before = keys.empty() || *rc::gen::arbitrary<bool>() ? std::string() : *rc::gen::elementOf(keys);
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  std::vector<std::string> placed(const Model& model) const {
    std::vector<std::string> ordered = sectionKeys(model, section);
    std::erase(ordered, key);
    const auto at = before == key ? ordered.end() : std::find(ordered.begin(), ordered.end(), before);
    ordered.insert(at, key);
    return ordered;
  }
  std::optional<std::pair<std::string, std::vector<std::string>>> plan(const Model& model) const {
    const std::string from = sectionOf(model, key);
    if (from.empty() || (section != "pinned" && section != "active")) return std::nullopt;
    if (section == from && placed(model) == sectionKeys(model, section)) return std::nullopt;
    if (section != from && section != "pinned") return std::nullopt;
    return std::pair{section, placed(model)};
  }
  void apply(Model& model) const override {
    const std::string from = sectionOf(model, key);
    if (from.empty() || section == "snoozed") return normalize(model);
    if (section == from) {
      if ((section == "pinned" || section == "active") && placed(model) != sectionKeys(model, section)) {
        arrange(model, section, placed(model), key);
      }
    } else if (section == "pinned") {
      arrange(model, section, placed(model), key, true);
    } else if (section == "settled") {
      park(model, key, Cmd{"thread.settle", std::nullopt, std::nullopt});
    } else if (from == "pinned") {
      dispatch(model, key, Cmd{"thread.unpin", std::nullopt, std::nullopt});
    } else if (from == "settled") {
      dispatch(model, key, Cmd{"thread.unsettle", std::nullopt, std::nullopt});
    } else if (from == "snoozed") {
      dispatch(model, key, Cmd{"thread.unsnooze", std::nullopt, std::nullopt});
    }
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.dispatch(QStringLiteral("thread.drop"), {{QStringLiteral("key"), q(key)}, {QStringLiteral("section"), q(section)}, {QStringLiteral("beforeKey"), q(before)}});
    sut.expect(next);
    MoveRow::expectArranged(model, next, plan(model));
  }
  void show(std::ostream& os) const override { os << "DropRow(" << key << " into " << section << " before '" << before << "')"; }
};

// Selecting rows for a bulk action.
struct Select : Command {
  std::string key = keyOf(genEnvironment(), genThreadId());
  std::string how = *rc::gen::elementOf(std::vector<std::string>{"toggle", "range", "clear"});

  explicit Select(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override {
    if (how == "clear") {
      model.selected.clear();
      return;
    }
    if (!livingKey(model.environments, key)) return;
    const std::vector<std::string> ordered = orderedKeys(model);
    const auto anchor = std::find(ordered.begin(), ordered.end(), model.anchor);
    const auto target = std::find(ordered.begin(), ordered.end(), key);
    if (how == "toggle") {
      if (model.selected.erase(key) == 0) {
        model.selected.insert(key);
        model.anchor = key;
      }
    } else if (anchor == ordered.end() || target == ordered.end()) {
      model.selected.insert(key);
      model.anchor = key;
    } else {
      for (auto it = std::min(anchor, target); it <= std::max(anchor, target); ++it) model.selected.insert(*it);
    }
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.dispatch(q("thread.select." + how), {{QStringLiteral("key"), q(key)}});
    sut.expect(next);
    std::vector<std::string> selection;
    for (const QString& selected : sut.sidebar()->selection()) selection.push_back(selected.toStdString());
    RC_ASSERT(selection == expected(next).selected);
  }
  void show(std::ostream& os) const override { os << "Select(" << how << (how == "clear" ? "" : " " + key) << ")"; }
};

// Scoping the list to one project, or to all of them.
struct Scope : Command {
  std::optional<std::string> project =
      *rc::gen::arbitrary<bool>() ? std::optional<std::string>(*rc::gen::elementOf(kProjectIds)) : std::nullopt;

  explicit Scope(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override {
    model.selected.clear();
    model.anchor.clear();
    model.scope = project;
    normalize(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.dispatch(QStringLiteral("sidebar.scope"),
                 {{QStringLiteral("projectKey"), project ? QVariant(q(groupKey(*project))) : QVariant::fromValue(nullptr)}});
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Scope(" << (project ? *project : "all") << ")"; }
};

// The MC holds its answers to commands, or gives them.
struct Hold : Command {
  explicit Hold(const Model&) {}

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override {
    if (model.holding) model.parking.clear();
    model.holding = !model.holding;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    if (model.holding) {
      sut.mc.answerHeld();
    } else {
      sut.mc.hold(QStringLiteral("answers"));
    }
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// --- Navigation history ------------------------------------------------------

// One environment's project and a peer to move threads to; the user opens
// threads and settings and goes back and forth while threads come, go and move.
struct Place {
  std::string kind;  // thread, draft or settings
  std::string key;
  bool operator==(const Place&) const = default;
};

std::ostream& operator<<(std::ostream& os, const Place& place) {
  return os << place.kind << (place.key.empty() ? "" : " " + place.key);
}

struct History {
  Environments environments;
  std::vector<Place> back;
  Place current{"draft", {}};
  std::vector<Place> forward;
};

// Where a thread key leads now (ShellStore::located).
std::string located(const Environments& environments, const std::string& key) {
  const auto [environment, id] = split(key);
  const Row* row = rowAt(environments, environment, id);
  if (row == nullptr || lives(environments, id, *row)) return key;
  for (const auto& [other, members] : environments) {
    const auto found = members.threads.find(id);
    if (found != members.threads.end() && lives(environments, id, found->second)) return keyOf(other, id);
  }
  return row->movedTo ? keyOf(*row->movedTo, id) : key;
}

Place resolve(const History& history, const Place& place) {
  return place.kind == "thread" ? Place{"thread", located(history.environments, place.key)} : place;
}

bool gone(const History& history, const Place& place) {
  return place.kind == "thread" && !livingKey(history.environments, place.key);
}

// The next place of `stack` the window can show: not gone, and not where it is.
std::optional<Place> takeReachable(History& history, std::vector<Place>& stack) {
  while (!stack.empty()) {
    const Place place = resolve(history, stack.back());
    stack.pop_back();
    if (!gone(history, place) && place != history.current) return place;
  }
  return std::nullopt;
}

void open(History& history, const Place& to) {
  if (to == history.current) return;
  history.forward.clear();
  if (!(to.kind == "settings" && history.current.kind == "settings")) {
    std::erase(history.back, history.current);
    history.back.push_back(history.current);
  }
  history.current = to;
}

// The window's place after the threads changed: one that moved is followed,
// one that went leaves for a draft.
void follow(History& history) {
  if (history.current.kind != "thread") return;
  history.current = resolve(history, history.current);
  if (gone(history, history.current)) history.current = Place{"draft", {}};
}

using HistoryCommand = rc::state::Command<History, Sut>;

void expectPlace(const History& history, Sut& sut) {
  sut.sync();
  const NavigationController::Route& route = sut.navigation()->route();
  const Place actual{route.kind.toStdString(), route.threadKey.toStdString()};
  if (!(actual == history.current)) {
    RC_FAIL("the window shows " + rc::toString(actual) + ", the model " + rc::toString(history.current));
  }
}

struct NavThread : HistoryCommand {
  std::string id = *rc::gen::elementOf(std::vector<std::string>{"t1", "t2", "t3"});
  std::string change = *rc::gen::elementOf(std::vector<std::string>{"create", "delete", "move"});

  explicit NavThread(const History&) {}

  std::optional<std::string> where(const Environments& environments) const {
    for (const auto& [environment, members] : environments) {
      const auto found = members.threads.find(id);
      if (found != members.threads.end() && lives(environments, id, found->second)) return environment;
    }
    return std::nullopt;
  }
  bool used(const Environments& environments) const {
    return std::any_of(environments.begin(), environments.end(), [this](const auto& entry) { return entry.second.threads.count(id) > 0; });
  }
  void checkPreconditions(const History& history) const override {
    if (change == "create") {
      RC_PRE(!used(history.environments));
    } else {
      RC_PRE(where(history.environments).has_value());
    }
  }
  // The environments whose rows changed.
  std::vector<std::string> mutate(Environments& environments, int now) const {
    if (change == "create") {
      CreateThread::mutate(environments, kOwn, id, "p1", 0, now);
      return {kOwn};
    }
    const std::string at = *where(environments);
    if (change == "delete") {
      environments[at].threads.erase(id);
      return {at};
    }
    // Moved whole: it arrives on the other machine and its record stays here.
    const std::string to = at == kOwn ? "b" : kOwn;
    Row& row = environments[at].threads[id];
    environments[to].threads.erase(id);
    environments[to].threads[id] = row;
    environments[to].threads[id].movedTo.reset();
    row.movedTo = to;
    return {to, at};
  }
  void apply(History& history) const override {
    mutate(history.environments, 0);
    follow(history);
  }
  void run(const History& history, Sut& sut) const override {
    History next = history;
    apply(next);
    for (const std::string& environment : mutate(sut.truth, sut.now)) sut.push(environment, id);
    expectPlace(next, sut);
  }
  void show(std::ostream& os) const override { os << "NavThread(" << change << " " << id << ")"; }
};

struct NavGo : HistoryCommand {
  std::string where = *rc::gen::elementOf(std::vector<std::string>{"thread", "settings", "back", "forward"});
  std::string key;

  explicit NavGo(const History& history) {
    if (where == "thread") {
      const std::vector<std::string> keys = livingKeys(history.environments);
      RC_PRE(!keys.empty());
      key = *rc::gen::elementOf(keys);
    }
  }

  void checkPreconditions(const History& history) const override {
    if (where == "thread") RC_PRE(livingKey(history.environments, key));
  }
  void apply(History& history) const override {
    if (where == "thread") {
      open(history, Place{"thread", key});
    } else if (where == "settings") {
      if (history.current.kind != "settings") open(history, Place{"settings", {}});
    } else if (where == "back") {
      const Place from = history.current;
      history.current = takeReachable(history, history.back).value_or(Place{"draft", {}});
      if (history.current != from) history.forward.push_back(from);
    } else {
      std::vector<Place> rest = history.forward;
      if (const auto to = takeReachable(history, rest)) {
        open(history, *to);
        history.forward = rest;
      } else {
        history.forward.clear();
      }
    }
  }
  void run(const History& history, Sut& sut) const override {
    History next = history;
    apply(next);
    if (where == "thread") {
      sut.dispatch(QStringLiteral("thread.open"), {{QStringLiteral("key"), q(key)}});
    } else if (where == "settings") {
      sut.dispatch(QStringLiteral("settings.open"), {});
    } else if (where == "back") {
      sut.navigation()->back();
    } else {
      sut.navigation()->forward();
    }
    expectPlace(next, sut);
  }
  void show(std::ostream& os) const override { os << "NavGo(" << where << (key.empty() ? "" : " " + key) << ")"; }
};

History initialHistory() {
  History history;
  history.environments[kOwn].projects["p1"] = 0;
  history.environments["b"];
  return history;
}

Model modelOf(const History& history) {
  Model model;
  model.environments = history.environments;
  return model;
}

// --- planReorder's law -------------------------------------------------------

// A section of `count` rows as the list shows it, the first `keyed` with order
// keys; rows the scope hides hold `hidden` keys of their own.
struct Section {
  QStringList shown;
  QHash<QString, sidebar::Nullable> orderKeys;
};

std::string genOrderKey() {
  const int length = *rc::gen::inRange(1, 4);
  std::string key;
  for (int i = 0; i < length; ++i) key += char('a' + *rc::gen::inRange(i + 1 == length ? 1 : 0, 26));
  return key;
}

}  // namespace

class SidebarProp : public QObject {
  Q_OBJECT

private slots:
  void sidebarFollowsTheCluster() {
    QVERIFY(rc::check("the sidebar shows the cluster's threads as the user arranged them", [] {
      const Model initial = initialModel();
      Sut sut(initial);
      // Every step is a round trip through the shell: shorter runs keep a case quick.
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(initial, rc::state::gen::execOneOfWithArgs<
                                                     CreateThread, CreateThread, CreateThread, ChangeThread, ChangeProject, MoveThread,
                                                     MoveThread, SetOnline, Membership, Tick, Resend, Disconnect, Reconnect, RowAction,
                                                     RowAction, RowAction, MoveRow, DropRow, DropRow, Select, Scope, Hold>()));
      rc::state::runAll(commands, initial, sut);
    }));
  }

  void historyNeverLandsOnAGoneThread() {
    QVERIFY(rc::check("back and forward skip threads that are gone and follow ones that moved", [] {
      const History initial = initialHistory();
      Sut sut(modelOf(initial));
      expectPlace(initial, sut);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(initial, rc::state::gen::execOneOfWithArgs<NavThread, NavThread, NavGo, NavGo, NavGo>()));
      rc::state::runAll(commands, initial, sut);
    }));
  }

  void reorderPutsTheRowWhereItWasDropped() {
    QVERIFY(rc::check("planReorder's keys sort the shown rows as ordered, past the hidden ones", [] {
      const bool pinned = *rc::gen::arbitrary<bool>();
      const int count = *rc::gen::inRange(1, 7);
      const int keyed = *rc::gen::inRange(0, count + 1);
      // As the section sorts: pinned rows keyed first, active ones unkeyed first.
      const QStringList spread = sidebar::spreadOrderKeys(keyed);
      Section section;
      for (int i = 0; i < count; ++i) section.shown.append(QStringLiteral("e:r%1").arg(i));
      for (int i = 0; i < count; ++i) {
        const int slot = pinned ? i : i - (count - keyed);
        section.orderKeys.insert(section.shown.at(i), slot >= 0 && slot < keyed ? sidebar::Nullable(spread.at(slot)) : std::nullopt);
      }
      QSet<QString> used;
      for (const auto& key : std::as_const(section.orderKeys)) {
        if (key) used.insert(*key);
      }
      const int hidden = *rc::gen::inRange(0, 4);
      for (int i = 0; i < hidden; ++i) {
        const QString key = q(genOrderKey());
        RC_PRE(!used.contains(key));
        used.insert(key);
        section.orderKeys.insert(QStringLiteral("e:h%1").arg(i), key);
      }
      const int from = *rc::gen::inRange(0, count);
      const int to = *rc::gen::inRange(0, count);
      QStringList ordered = section.shown;
      ordered.move(from, to);
      const QString moved = section.shown.at(from);
      RC_TAG(pinned ? "pinned" : "active");

      QHash<QString, sidebar::Nullable> after = section.orderKeys;
      QSet<QString> assigned;
      for (const sidebar::OrderAssignment& assignment : sidebar::planReorder(ordered, section.orderKeys, moved)) {
        RC_ASSERT(!assigned.contains(assignment.key));
        assigned.insert(assignment.key);
        after.insert(assignment.key, assignment.orderKey);
      }
      // No two rows share a key.
      QSet<QString> keys;
      for (auto it = after.cbegin(); it != after.cend(); ++it) {
        if (!it.value()) continue;
        RC_ASSERT(!keys.contains(*it.value()));
        keys.insert(*it.value());
      }
      // Unkeyed rows keep their relative order (they sort by age), keyed ones by key.
      QStringList sorted = section.shown;
      std::stable_sort(sorted.begin(), sorted.end(), [&](const QString& left, const QString& right) {
        const sidebar::Nullable& l = after.value(left);
        const sidebar::Nullable& r = after.value(right);
        if (l.has_value() != r.has_value()) return pinned ? l.has_value() : !l.has_value();
        if (l) return *l < *r;
        return section.shown.indexOf(left) < section.shown.indexOf(right);
      });
      if (sorted != ordered) {
        RC_FAIL("ordered " + ordered.join(QLatin1Char(',')).toStdString() + ", sorts as " + sorted.join(QLatin1Char(',')).toStdString());
      }
    }));
  }
};

HAL_C2_PROP_MAIN(SidebarProp)
#include "tst_SidebarProp.moc"
