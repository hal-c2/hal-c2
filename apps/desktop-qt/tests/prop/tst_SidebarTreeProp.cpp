// The legacy sidebar's tree (legacySidebarEnabled; SidebarController,
// sidebar::buildTree) against a model of what the user did to it: which
// projects are folded, which list all their threads, how many threads a
// project shows, how projects are sorted and where the user dragged them.
// After every step the `sidebar.tree` the shell publishes is the model's
// projection, project by project and thread by thread. Turning the tree off
// shows the sections again and keeps what the user arranged for next time.
// The drop's and the count's laws (sidebar::reorderProjects,
// sidebar::clampThreadPreviewCount) are checked on their own.

#include "Prop.h"

#include <QLocale>

#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <vector>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
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
const std::vector<std::string> kProjects{"p1", "p2", "p3"};

QString iso(int minutes) {
  return sidebar::formatIso(kT0.addSecs(qint64(minutes) * 60));
}

// When project `index` was made: before any thread, in kProjects' order.
int projectCreated(size_t index) {
  return -60 + int(index);
}

struct Model {
  // Each project's threads by when they were made (minutes after kT0, which
  // names them too: "t<minute>"), oldest first.
  std::map<std::string, std::vector<int>> threads;
  int nextThread = 0;
  bool legacy = true;
  // sidebarThreadPreviewCount as written, unclamped.
  int count = sidebar::kDefaultThreadPreviewCount;
  // sidebarProjectSortOrder: "created_at" or "manual".
  std::string projectSort = "created_at";
  // sidebarProjectOrder, empty until the user drags.
  std::vector<std::string> arranged;
  std::set<std::string> folded;
  std::set<std::string> showingAll;
};

void showValue(const Model& model, std::ostream& os) {
  os << "{threads: ";
  rc::show(model.threads, os);
  os << ", legacy: " << model.legacy << ", count: " << model.count << ", sort: " << model.projectSort << ", arranged: ";
  rc::show(model.arranged, os);
  os << ", folded: ";
  rc::show(model.folded, os);
  os << ", all: ";
  rc::show(model.showingAll, os);
  os << "}";
}

// One project of the tree as the shell shows it.
struct ProjectView {
  std::string project;
  bool expanded = true;
  bool draggable = false;
  std::vector<std::string> threads;
  std::string more;  // "more", "less" or "" for none
  bool operator==(const ProjectView&) const = default;
};

void showValue(const ProjectView& view, std::ostream& os) {
  os << "{" << view.project << (view.expanded ? "" : " folded") << (view.draggable ? " draggable" : "") << " threads ";
  rc::show(view.threads, os);
  os << " more " << view.more << "}";
}

struct Projection {
  std::string mode;
  std::vector<ProjectView> tree;
  bool operator==(const Projection&) const = default;
};

void showValue(const Projection& view, std::ostream& os) {
  os << "{mode " << view.mode << ", tree ";
  rc::show(view.tree, os);
  os << "}";
}

std::string threadId(int minute) {
  return "t" + std::to_string(minute);
}

// The projects in the order the tree lists them.
std::vector<std::string> projectOrder(const Model& model) {
  std::vector<std::string> order = kProjects;  // as made, which "manual" keeps
  if (model.projectSort == "manual") {
    const auto rank = [&model](const std::string& project) {
      const auto found = std::find(model.arranged.begin(), model.arranged.end(), project);
      return found - model.arranged.begin();
    };
    std::stable_sort(order.begin(), order.end(), [&rank](const std::string& l, const std::string& r) { return rank(l) < rank(r); });
    return order;
  }
  // Newest thread first; a project without threads by when it was made.
  const auto at = [&model](const std::string& project) {
    const std::vector<int>& made = model.threads.at(project);
    const size_t index = size_t(std::find(kProjects.begin(), kProjects.end(), project) - kProjects.begin());
    return made.empty() ? projectCreated(index) : made.back();
  };
  std::stable_sort(order.begin(), order.end(), [&at](const std::string& l, const std::string& r) { return at(l) > at(r); });
  return order;
}

Projection expected(const Model& model) {
  if (!model.legacy) return {"attention", {}};
  const int limit = std::clamp(model.count, 1, 15);
  Projection view{"tree", {}};
  for (const std::string& project : projectOrder(model)) {
    ProjectView shown{project, !model.folded.count(project), model.projectSort == "manual", {}, ""};
    const std::vector<int>& made = model.threads.at(project);
    const bool all = model.showingAll.count(project) > 0;
    if (shown.expanded) {
      for (auto it = made.rbegin(); it != made.rend(); ++it) {
        if (!all && int(shown.threads.size()) == limit) break;
        shown.threads.push_back(threadId(*it));
      }
      if (int(made.size()) > limit) shown.more = all ? "less" : "more";
    }
    view.tree.push_back(shown);
  }
  return view;
}

QJsonObject threadJson(const std::string& project, int minute) {
  const QJsonValue none(QJsonValue::Null);
  return {
      {QStringLiteral("id"), q(threadId(minute))},
      {QStringLiteral("projectId"), q(project)},
      {QStringLiteral("title"), q("Thread " + std::to_string(minute))},
      {QStringLiteral("createdAt"), iso(minute)},
      {QStringLiteral("updatedAt"), iso(minute)},
      {QStringLiteral("latestUserMessageAt"), none},
      {QStringLiteral("archivedAt"), none},
      {QStringLiteral("settledOverride"), none},
      {QStringLiteral("settledAt"), none},
      {QStringLiteral("unsettledAt"), none},
      {QStringLiteral("snoozedUntil"), none},
      {QStringLiteral("snoozedAt"), none},
      {QStringLiteral("pinnedAt"), none},
      {QStringLiteral("pinOrderKey"), none},
      {QStringLiteral("activeOrderKey"), none},
      {QStringLiteral("moving"), none},
      {QStringLiteral("movedTo"), none},
      {QStringLiteral("plugin"), none},
  };
}

QJsonObject projectJson(size_t index) {
  const std::string& id = kProjects[index];
  const QString root = q("/work/" + id);
  return {
      {QStringLiteral("id"), q(id)},
      {QStringLiteral("title"), q("Project " + id)},
      {QStringLiteral("workspaceRoot"), root},
      {QStringLiteral("createdAt"), iso(projectCreated(index))},
      {QStringLiteral("updatedAt"), iso(projectCreated(index))},
      {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), q("repo-" + id)}, {QStringLiteral("rootPath"), root}}},
  };
}

Model initialModel() {
  Model model;
  // Up to eight threads a project, so some overflow the default six.
  for (const std::string& project : kProjects) {
    const int made = *rc::gen::inRange(0, 9);
    for (int i = 0; i < made; ++i) model.threads[project].push_back(model.nextThread++);
    model.threads[project];
  }
  return model;
}

struct Sut {
  FakeMc mc;
  QTemporaryDir home;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;

  explicit Sut(const Model& initial) {
    for (size_t i = 0; i < kProjects.size(); ++i) mc.projects.insert(q(kProjects[i]), projectJson(i));
    for (const auto& [project, made] : initial.threads) {
      for (const int minute : made) mc.threads.insert(q(threadId(minute)), threadJson(project, minute));
    }
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->sidebar()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    settings()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->sidebar()->setClock([] { return kT0.addSecs(3600); });
    native->restoreWindows();
    write(QStringLiteral("sidebarThreadSortOrder"), QStringLiteral("created_at"));
    write(QStringLiteral("sidebarProjectSortOrder"), QStringLiteral("created_at"));
    write(QStringLiteral("legacySidebarEnabled"), true);
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(halc2::prop::until([this] { return shellSubscribed(); }));
    sync();
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  SettingsController* settings() { return native->controller<SettingsController>(); }
  void write(const QString& key, const QVariant& value) { RC_ASSERT(settings()->writeDevice(key, value)); }
  QVariantMap state() const { return bridge->state()->value(QStringLiteral("sidebar")).toMap(); }
  void dispatch(const QString& action, const QVariantMap& payload) { bridge->dispatch(action, payload); }

  bool shellSubscribed() const {
    for (const QJsonObject& sub : mc.subscriptions) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) return true;
    }
    return false;
  }

  // A round trip through the MC: what it sent before is in.
  void sync() {
    native->cache()->drain();
    auto done = std::make_shared<bool>(false);
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [done](const QJsonValue&, const std::optional<QString>&) { *done = true; });
    RC_ASSERT(halc2::prop::until([done] { return *done; }));
  }

  // The tree's key of the project `id`, which the actions take.
  QString keyOf(const std::string& id) const {
    for (const QVariant& value : state().value(QStringLiteral("tree")).toList()) {
      const QVariantMap project = value.toMap();
      if (project.value(QStringLiteral("projectId")).toString() == q(id)) return project.value(QStringLiteral("key")).toString();
    }
    RC_FAIL("the tree lists no " + id);
  }

  Projection read() const {
    const QVariantMap sidebar = state();
    Projection view{sidebar.value(QStringLiteral("mode")).toString().toStdString(), {}};
    for (const QVariant& value : sidebar.value(QStringLiteral("tree")).toList()) {
      const QVariantMap project = value.toMap();
      ProjectView shown{project.value(QStringLiteral("projectId")).toString().toStdString(), project.value(QStringLiteral("expanded")).toBool(),
                        project.value(QStringLiteral("draggable")).toBool(), {},
                        project.value(QStringLiteral("more")).isNull() ? std::string() : project.value(QStringLiteral("more")).toString().toStdString()};
      for (const QVariant& row : project.value(QStringLiteral("threads")).toList()) {
        const QString key = row.toMap().value(QStringLiteral("key")).toString();
        shown.threads.push_back(key.mid(key.indexOf(QLatin1Char(':')) + 1).toStdString());
      }
      view.tree.push_back(shown);
    }
    return view;
  }

  void expect(const Model& model) {
    sync();
    const Projection actual = read();
    const Projection want = expected(model);
    if (!(actual == want)) RC_FAIL("the sidebar shows " + rc::toString(actual) + "\nthe model " + rc::toString(want));
  }
};

using Command = rc::state::Command<Model, Sut>;

std::string genProject() {
  return *rc::gen::elementOf(kProjects);
}

// A thread made now, newest of all.
struct AddThread : Command {
  std::string project = genProject();
  void apply(Model& model) const override { model.threads[project].push_back(model.nextThread++); }
  void run(const Model& model, Sut& sut) const override {
    const int minute = model.nextThread;
    const QJsonObject json = threadJson(project, minute);
    sut.mc.threads.insert(q(threadId(minute)), json);
    sut.mc.sendRow(q(threadId(minute)), json);
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "AddThread(" << project << ")"; }
};

// The user turns the tree on or off in Settings.
struct SetLegacy : Command {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.legacy = on; }
  void run(const Model& model, Sut& sut) const override {
    sut.write(QStringLiteral("legacySidebarEnabled"), on);
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "SetLegacy(" << on << ")"; }
};

// A click on a project's header.
struct Fold : Command {
  std::string project = genProject();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.legacy); }
  void apply(Model& model) const override {
    if (!model.folded.erase(project)) model.folded.insert(project);
  }
  void run(const Model& model, Sut& sut) const override {
    sut.dispatch(QStringLiteral("sidebar.project.fold"), {{QStringLiteral("projectKey"), sut.keyOf(project)}});
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "Fold(" << project << ")"; }
};

// "Show more" or "Show less" under a project.
struct More : Command {
  std::string project = genProject();
  bool more = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.legacy); }
  void apply(Model& model) const override {
    if (more) {
      model.showingAll.insert(project);
    } else {
      model.showingAll.erase(project);
    }
  }
  void run(const Model& model, Sut& sut) const override {
    sut.dispatch(more ? QStringLiteral("sidebar.project.more") : QStringLiteral("sidebar.project.less"),
                 {{QStringLiteral("projectKey"), sut.keyOf(project)}});
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << (more ? "More(" : "Less(") << project << ")"; }
};

// The visible thread count, out of range too.
struct SetCount : Command {
  int count = *rc::gen::inRange(-2, 20);
  void apply(Model& model) const override { model.count = count; }
  void run(const Model& model, Sut& sut) const override {
    sut.write(QStringLiteral("sidebarThreadPreviewCount"), count);
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "SetCount(" << count << ")"; }
};

struct SortProjects : Command {
  std::string order = *rc::gen::elementOf(std::vector<std::string>{"created_at", "manual"});
  void apply(Model& model) const override { model.projectSort = order; }
  void run(const Model& model, Sut& sut) const override {
    sut.write(QStringLiteral("sidebarProjectSortOrder"), q(order));
    Model next = model;
    apply(next);
    sut.expect(next);
  }
  void show(std::ostream& os) const override { os << "SortProjects(" << order << ")"; }
};

// A project's header dropped on another's: dragged up it lands above the
// target, dragged down below it. Sorted any other way than by hand, nothing
// moves.
struct Drop : Command {
  std::string project = genProject();
  std::string target = genProject();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.legacy); }
  void apply(Model& model) const override {
    if (model.projectSort != "manual" || project == target) return;
    std::vector<std::string> order = projectOrder(model);
    const auto from = std::find(order.begin(), order.end(), project) - order.begin();
    const auto onto = std::find(order.begin(), order.end(), target) - order.begin();
    order.erase(order.begin() + from);
    const auto at = std::find(order.begin(), order.end(), target) - order.begin();
    order.insert(order.begin() + (from < onto ? at + 1 : at), project);
    model.arranged = order;
  }
  void run(const Model& model, Sut& sut) const override {
    sut.dispatch(QStringLiteral("sidebar.project.drop"),
                 {{QStringLiteral("projectKey"), sut.keyOf(project)}, {QStringLiteral("targetKey"), sut.keyOf(target)}});
    Model next = model;
    apply(next);
    sut.expect(next);
    if (next.arranged.empty()) return;
    // What the device keeps is the folders' order.
    QStringList stored;
    for (const QJsonValue& value : sut.settings()->deviceSettings().value(SidebarController::kProjectOrder).toArray()) stored.append(value.toString());
    QStringList want;
    for (const std::string& id : next.arranged) want.append(sut.mc.environmentId + QStringLiteral(":/work/") + q(id));
    RC_ASSERT(stored == want);
  }
  void show(std::ostream& os) const override { os << "Drop(" << project << " on " << target << ")"; }
};

// Folders as physical keys, for the laws below.
QStringList genKeys() {
  const int size = *rc::gen::inRange(0, 7);
  QStringList keys;
  for (int i = 0; i < size; ++i) keys.append(QStringLiteral("k%1").arg(i));
  return keys;
}

QStringList genSubset(const QStringList& keys) {
  QStringList subset;
  for (const QString& key : keys) {
    if (*rc::gen::arbitrary<bool>()) subset.append(key);
  }
  return subset;
}

}  // namespace

class SidebarTreeProp : public QObject {
  Q_OBJECT

private slots:
  void treeFollowsTheUser() {
    QVERIFY(rc::check("the tree shows each project's threads as the user folded, expanded, counted and arranged them", [] {
      const Model initial = initialModel();
      Sut sut(initial);
      sut.expect(initial);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(initial, rc::state::gen::execOneOfWithArgs<AddThread, SetLegacy, Fold, Fold, More, More, SetCount,
                                                                                   SortProjects, Drop, Drop, Drop>()));
      rc::state::runAll(commands, initial, sut);
    }));
  }

  void reorderMovesOnlyTheDraggedFolders() {
    QVERIFY(rc::check("reorderProjects keeps every folder, the others in order, and lands the dragged next to the target", [] {
      QStringList order = genKeys();
      // In any order: a generated shuffle.
      for (qsizetype i = order.size() - 1; i > 0; --i) order.swapItemsAt(i, *rc::gen::inRange<qsizetype>(0, i + 1));
      const QStringList dragged = genSubset(order);
      const QStringList target = genSubset(order);
      const QStringList next = sidebar::reorderProjects(order, dragged, target);

      QStringList sortedOrder = order;
      QStringList sortedNext = next;
      sortedOrder.sort();
      sortedNext.sort();
      RC_ASSERT(sortedOrder == sortedNext);
      const auto without = [&dragged](QStringList keys) {
        for (const QString& key : dragged) keys.removeAll(key);
        return keys;
      };
      RC_ASSERT(without(next) == without(order));
      const bool overlaps = std::any_of(dragged.cbegin(), dragged.cend(), [&target](const QString& key) { return target.contains(key); });
      const bool inside = std::all_of(dragged.cbegin(), dragged.cend(), [&target](const QString& key) { return target.contains(key); });
      if (dragged.isEmpty() || target.isEmpty() || inside) {
        RC_ASSERT(next == order);
        return;
      }
      if (overlaps) return;
      // The dragged folders sit together, in their order, beside a target folder.
      QStringList draggedInOrder;
      for (const QString& key : order) {
        if (dragged.contains(key)) draggedInOrder.append(key);
      }
      const qsizetype first = next.indexOf(draggedInOrder.first());
      RC_ASSERT(next.mid(first, draggedInOrder.size()) == draggedInOrder);
      const bool besideTarget = (first > 0 && target.contains(next.at(first - 1))) ||
                                (first + draggedInOrder.size() < next.size() && target.contains(next.at(first + draggedInOrder.size())));
      RC_ASSERT(besideTarget);
    }));
  }

  void previewCountStaysInRange() {
    QVERIFY(rc::check("clampThreadPreviewCount is 1 to 15, and keeps a count in range", [](int count) {
      const int clamped = sidebar::clampThreadPreviewCount(count);
      RC_ASSERT(clamped >= sidebar::kMinThreadPreviewCount);
      RC_ASSERT(clamped <= sidebar::kMaxThreadPreviewCount);
      if (count >= sidebar::kMinThreadPreviewCount && count <= sidebar::kMaxThreadPreviewCount) RC_ASSERT(clamped == count);
    }));
  }
};

HAL_C2_PROP_MAIN(SidebarTreeProp)
#include "tst_SidebarTreeProp.moc"
