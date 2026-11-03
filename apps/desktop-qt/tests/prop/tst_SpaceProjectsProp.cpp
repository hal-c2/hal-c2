// The Space sidebar's project sections and the page a file opens on, as a state
// machine over what moves them: a project's Space files changing and listed
// again, sections expanded and collapsed (here, or by another window through the
// device's preferences), files opened with the MC answering in any order or
// refusing, the project's Space arriving, and the user picking a page or the
// Space itself, and either Space's stream failing and coming back.
//
// After each step the sections are this MC's projects with files, each a project
// row and, when expanded, its folders and files depth first (folders before files,
// each by name); the expanded ones are what the device remembers. Only the latest
// open applies, and only if the user picked nothing since: it expands the file's
// section and shows the file's page once its project's Space has arrived, the
// Space's own page staying on show until then. Picking a Space page, or the Space,
// leaves the file's page in one step, and a project's Space arriving after that
// changes nothing. The view reads as unreachable while the selected Space's stream
// is down, or the file's project Space's while its page is on show, until a frame
// comes on the stream that failed.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SpaceController.h"

#include <QTemporaryDir>

#include <map>
#include <vector>

namespace prop = halc2::prop;

namespace {

const QString kEnvironment = QStringLiteral("env-a");
const QString kSpaceId = QStringLiteral("space-1");
const QStringList kPages = {QStringLiteral("page-1"), QStringLiteral("page-2")};
const QStringList kProjects = {QStringLiteral("alpha"), QStringLiteral("beta")};
const QStringList kFiles = {QStringLiteral("README.md"), QStringLiteral("docs/guide.md"), QStringLiteral("docs/api/Index.md"),
                            QStringLiteral("docs/zebra.md"), QStringLiteral("notes/a.md")};
const QString kExpandedKey = QStringLiteral("spaceExpandedProjects");

QString oneOf(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

QString projectSpace(const QString& project) { return QStringLiteral("project-") + project; }
QString pageOf(const QString& project, const QString& path) { return project + QLatin1Char(':') + path; }

// One open the MC holds: the nth asked, and what for.
struct Open {
  int n = 0;
  QString project;
  QString path;
  bool operator==(const Open&) const = default;
};

// A folder of files and folders, for the order the sections show them in.
struct Folder {
  std::map<QString, Folder> folders;
  QStringList files;
};

int byName(const QString& a, const QString& b) {
  const int folded = QString::compare(a, b, Qt::CaseInsensitive);
  return folded != 0 ? folded : QString::compare(a, b);
}

void emitFolder(const Folder& folder, const QString& at, int depth, QStringList& rows) {
  std::vector<QString> names;
  for (const auto& [name, _] : folder.folders) names.push_back(name);
  std::sort(names.begin(), names.end(), [](const QString& a, const QString& b) { return byName(a, b) < 0; });
  for (const QString& name : names) {
    const QString path = at.isEmpty() ? name : at + QLatin1Char('/') + name;
    rows.append(QStringLiteral("folder %1 %2").arg(depth).arg(path));
    emitFolder(folder.folders.at(name), path, depth + 1, rows);
  }
  QStringList files = folder.files;
  std::sort(files.begin(), files.end(), [](const QString& a, const QString& b) { return byName(a, b) < 0; });
  for (const QString& name : files) rows.append(QStringLiteral("file %1 %2").arg(depth).arg(at.isEmpty() ? name : at + QLatin1Char('/') + name));
}

struct Model {
  // The files each project's spaces section covers, as the MC lists them.
  QMap<QString, QSet<QString>> files{{kProjects.first(), {kFiles.at(0), kFiles.at(1)}}, {kProjects.last(), {}}};
  QSet<QString> expanded;
  std::vector<Open> opens;
  int asked = 0;
  // The open that applies when answered, or 0 once the user picked something since.
  int latest = 0;
  // The project whose Space is followed for a file's page, whether its copy arrived,
  // and the page waited for in it.
  QString followed;
  bool arrived = false;
  QString awaited;
  // What is on show: a Space page, or a file's page (`fileShown`).
  QString page = kPages.first();
  bool fileShown = false;
  // Which stream failed and has had no frame since.
  bool spaceDown = false;
  bool fileDown = false;

  bool unreachable() const { return spaceDown || (fileShown && fileDown); }
  void leaveFile() {
    followed.clear();
    arrived = false;
    awaited.clear();
    fileShown = false;
    fileDown = false;
  }
  void showAwaited() {
    if (!arrived || awaited.isEmpty()) return;
    page = std::exchange(awaited, QString());
    fileShown = true;
  }

  // Each section's rows, by project, as "kind depth path".
  QMap<QString, QStringList> sections() const {
    QMap<QString, QStringList> rows;
    for (auto it = files.cbegin(); it != files.cend(); ++it) {
      if (it.value().isEmpty()) continue;
      QStringList section{QStringLiteral("project %1").arg(expanded.contains(it.key()))};
      if (expanded.contains(it.key())) {
        Folder root;
        for (const QString& path : it.value()) {
          const QStringList parts = path.split(QLatin1Char('/'));
          Folder* at = &root;
          for (qsizetype i = 0; i + 1 < parts.size(); ++i) at = &at->folders[parts.at(i)];
          at->files.append(parts.last());
        }
        emitFolder(root, QString(), 1, section);
      }
      rows.insert(it.key(), section);
    }
    return rows;
  }
  QStringList remembered() const {
    QStringList keys;
    for (const QString& project : expanded) keys.append(kEnvironment + QLatin1Char(':') + project);
    keys.sort();
    return keys;
  }
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  // What the MC lists for each project, and the opens it holds.
  QMap<QString, QSet<QString>> files = Model().files;
  std::vector<std::pair<Open, FakeMc::Rpc>> held;
  int arrivedOpens = 0;
  // Lists of "probe", which no section shows, each answered with a file of its own.
  int probes = 0;

  Shell() {
    for (const QString& project : kProjects) {
      mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                                   {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}});
    }
    mc.onRpc(QStringLiteral("space.files.list"), [this](const FakeMc::Rpc& rpc) {
      const QString project = rpc.payload.value(QLatin1String("projectId")).toString();
      if (project == QLatin1String("probe")) {
        const QJsonObject file{{QStringLiteral("relativePath"), QStringLiteral("probe-%1.md").arg(++probes)}, {QStringLiteral("kind"), QStringLiteral("markdown")},
                               {QStringLiteral("page"), QJsonValue::Null}};
        return mc.reply(rpc, QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), QJsonArray{file}}});
      }
      QJsonArray listed;
      for (const QString& path : files.value(project)) {
        listed.append(QJsonObject{{QStringLiteral("relativePath"), path}, {QStringLiteral("kind"), QStringLiteral("markdown")},
                                  {QStringLiteral("page"), QJsonObject{{QStringLiteral("spaceId"), projectSpace(project)},
                                                                       {QStringLiteral("pageId"), pageOf(project, path)},
                                                                       {QStringLiteral("title"), path}}}});
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), listed},
                                {QStringLiteral("spaceId"), projectSpace(project)}});
    });
    mc.onRpc(QStringLiteral("space.page.openFile"), [this](const FakeMc::Rpc& rpc) {
      ++arrivedOpens;
      held.push_back({{arrivedOpens, rpc.payload.value(QLatin1String("projectId")).toString(), rpc.payload.value(QLatin1String("relativePath")).toString()}, rpc});
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.client()->isReady(); })) qFatal("the shell did not connect");
    const QJsonObject spaceRow{{QStringLiteral("id"), kSpaceId}, {QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    space()->receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                           {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("space"), kSpaceId, spaceRow})}},
                           {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    space()->selectSpace(kSpaceId);
    space()->receiveSpace(snapshot(kPages, QStringLiteral("log-1")));
    space()->selectPage(kPages.first());
    native.controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("space")));
  }

  SpaceController* space() { return native.controller<SpaceController>(); }
  SettingsController* settings() { return native.controller<SettingsController>(); }

  static QJsonObject snapshot(const QStringList& pages, const QString& handle) {
    QJsonArray rows;
    for (const QString& id : pages) {
      rows.append(QJsonArray{QStringLiteral("page"), id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                                         {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}});
    }
    return {{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
            {QStringLiteral("done"), true}, {QStringLiteral("handle"), handle}};
  }

  // The project's Space as a new snapshot brings it, a page for every file it has.
  void projectSpaceArrives(const QString& project) {
    QStringList pages;
    for (const QString& path : kFiles) pages.append(pageOf(project, path));
    space()->receiveFileSpace(snapshot(pages, QStringLiteral("project-log-") + project));
  }

  // Waits for the MC's answers so far to reach the client: it answers in order, so a
  // list asked now comes back after them.
  void settle() {
    const int before = probes;
    RC_ASSERT(space()->handle(QStringLiteral("space.files.list"), QVariantMap{{QStringLiteral("projectId"), QStringLiteral("probe")}}));
    const auto probed = [this] {
      const QVariantMap files = bridge.state()->value(QStringLiteral("space")).toMap().value(QStringLiteral("files")).toMap();
      return files.value(QStringLiteral("probe")).toMap().value(QStringLiteral("paths")).toMap().keys();
    };
    RC_ASSERT(prop::until([&] { return probes > before && probed() == QStringList{QStringLiteral("probe-%1.md").arg(probes)}; }));
  }

  QMap<QString, QStringList> sections() const {
    QMap<QString, QStringList> rows;
    SpaceProjects* projects = const_cast<Shell*>(this)->native.controller<SpaceController>()->projects();
    for (int i = 0; i < projects->rowCount(); ++i) {
      const QVariantMap row = projects->get(i);
      const QString kind = row.value(QStringLiteral("kind")).toString();
      const QString project = row.value(QStringLiteral("projectId")).toString();
      rows[project].append(kind == QLatin1String("project") ? QStringLiteral("project %1").arg(row.value(QStringLiteral("expanded")).toBool())
                                                            : QStringLiteral("%1 %2 %3").arg(kind).arg(row.value(QStringLiteral("depth")).toInt()).arg(row.value(QStringLiteral("path")).toString()));
    }
    return rows;
  }

  void check(const Model& model) {
    const auto remembered = [this] { return settings()->deviceValue(kExpandedKey).toStringList(); };
    prop::until([&] { return arrivedOpens == model.asked && sections() == model.sections() && remembered() == model.remembered(); });
    RC_ASSERT(arrivedOpens == model.asked);
    RC_ASSERT(held.size() == model.opens.size());
    RC_ASSERT(sections() == model.sections());
    RC_ASSERT(remembered() == model.remembered());
    RC_ASSERT(space()->spaceId() == kSpaceId);
    RC_ASSERT(space()->pageId() == model.page);
    RC_ASSERT(space()->fileSpaceId() == (model.fileShown ? projectSpace(model.followed) : QString()));
    RC_ASSERT((space()->status() == QLatin1String("unreachable")) == model.unreachable());
  }
};

using Command = rc::state::Command<Model, Shell>;

// The project's spaces section now covers another set of files, and the client lists them.
struct ChangeFiles : Command {
  QString project = oneOf(kProjects);
  std::vector<QString> chosen = *rc::gen::container<std::vector<QString>>(*rc::gen::inRange(0, 4), rc::gen::elementOf(std::vector<QString>(kFiles.cbegin(), kFiles.cend())));
  QSet<QString> files() const { return QSet<QString>(chosen.cbegin(), chosen.cend()); }
  void apply(Model& model) const override { model.files.insert(project, files()); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.files.insert(project, files());
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.files.list"), QVariantMap{{QStringLiteral("projectId"), project}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override {
    os << "ChangeFiles(" << project.toStdString() << ",";
    for (const QString& path : chosen) os << " " << path.toStdString();
    os << ")";
  }
};

struct SetExpanded : Command {
  QString project = oneOf(kProjects);
  bool expanded = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (expanded) {
      model.expanded.insert(project);
    } else {
      model.expanded.remove(project);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.project.setExpanded"), QVariantMap{{QStringLiteral("projectId"), project}, {QStringLiteral("expanded"), expanded}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SetExpanded(" << project.toStdString() << ", " << expanded << ")"; }
};

// Another window of this device writes which sections are expanded, with another
// MC's entry beside them that this one leaves alone.
struct OtherWindow : Command {
  std::vector<QString> chosen = *rc::gen::container<std::vector<QString>>(*rc::gen::inRange(0, 3), rc::gen::elementOf(std::vector<QString>(kProjects.cbegin(), kProjects.cend())));
  void apply(Model& model) const override { model.expanded = QSet<QString>(chosen.cbegin(), chosen.cend()); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    QStringList keys{QStringLiteral("env-b:alpha")};
    for (const QString& project : chosen) keys.append(kEnvironment + QLatin1Char(':') + project);
    RC_ASSERT(shell.settings()->writeDevice(kExpandedKey, keys));
    const auto here = [&] {
      QStringList mine;
      for (const QString& key : shell.settings()->deviceValue(kExpandedKey).toStringList()) {
        if (key.startsWith(kEnvironment + QLatin1Char(':'))) mine.append(key);
      }
      mine.sort();
      mine.removeDuplicates();
      return mine;
    };
    prop::until([&] { return shell.sections() == expected.sections(); });
    RC_ASSERT(shell.sections() == expected.sections());
    RC_ASSERT(here() == expected.remembered());
    RC_ASSERT(shell.settings()->deviceValue(kExpandedKey).toStringList().contains(QStringLiteral("env-b:alpha")));
    // What follows holds the device to this MC's entries alone.
    shell.settings()->writeDevice(kExpandedKey, expected.remembered().isEmpty() ? QVariant() : QVariant(expected.remembered()));
    shell.check(expected);
  }
  void show(std::ostream& os) const override {
    os << "OtherWindow(";
    for (const QString& project : chosen) os << " " << project.toStdString();
    os << ")";
  }
};

// The user edits a project's file as a page; the MC holds the answer.
struct OpenFile : Command {
  QString project = oneOf(kProjects);
  QString path = oneOf(kFiles);
  void apply(Model& model) const override {
    model.latest = ++model.asked;
    model.opens.push_back({model.asked, project, path});
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.openFile"), QVariantMap{{QStringLiteral("projectId"), project}, {QStringLiteral("relativePath"), path}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "OpenFile(" << project.toStdString() << ", " << path.toStdString() << ")"; }
};

// The MC answers one of the opens it holds, whichever: with the file's page, or
// refusing a file its project's spaces section does not cover.
struct AnswerOpen : Command {
  std::size_t index = *rc::gen::inRange<std::size_t>(0, 64);
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.opens.empty()); }
  Open which(const Model& model) const { return model.opens[index % model.opens.size()]; }
  void apply(Model& model) const override {
    const Open open = which(model);
    std::erase(model.opens, open);
    if (open.n != model.latest) return;
    model.latest = 0;
    if (!model.files.value(open.project).contains(open.path)) return;
    model.expanded.insert(open.project);
    if (model.followed != open.project) {
      // A page of the project followed before goes with its copy.
      if (model.fileShown) model.page.clear();
      model.followed = open.project;
      model.arrived = false;
      model.fileDown = false;
    }
    model.awaited = pageOf(open.project, open.path);
    model.showAwaited();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    const Open open = which(model);
    const auto found = std::find_if(shell.held.begin(), shell.held.end(), [&](const auto& held) { return held.first == open; });
    RC_ASSERT(found != shell.held.end());
    const FakeMc::Rpc rpc = found->second;
    shell.held.erase(found);
    if (shell.files.value(open.project).contains(open.path)) {
      shell.mc.reply(rpc, QJsonObject{{QStringLiteral("spaceId"), projectSpace(open.project)},
                                      {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), pageOf(open.project, open.path)}}},
                                      {QStringLiteral("created"), false}});
    } else {
      shell.mc.refuse(rpc, QStringLiteral("not a Space file"), QJsonObject{{QStringLiteral("reason"), QStringLiteral("notSpaceFile")}});
    }
    shell.settle();
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "AnswerOpen(" << index << ")"; }
};

// A project's Space arrives: the one followed, or one still on its way after the
// user left it.
struct ProjectSpaceArrives : Command {
  QString project = oneOf(kProjects);
  void apply(Model& model) const override {
    if (model.followed != project) return;
    model.arrived = true;
    model.fileDown = false;
    model.showAwaited();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    // The client asks only for the Space it follows: another's copy cannot reach it.
    if (model.followed.isEmpty() || model.followed == project) shell.projectSpaceArrives(project);
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "ProjectSpaceArrives(" << project.toStdString() << ")"; }
};

struct SelectPage : Command {
  QString page = oneOf(kPages);
  void apply(Model& model) const override {
    model.latest = 0;
    model.leaveFile();
    model.page = page;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), page}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SelectPage(" << page.toStdString() << ")"; }
};

// The user picks the Space they are in: its own pages again, from the first.
struct SelectSpace : Command {
  void apply(Model& model) const override {
    model.latest = 0;
    if (model.fileShown) model.page = kPages.first();
    model.leaveFile();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.select"), QVariantMap{{QStringLiteral("spaceId"), kSpaceId}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SelectSpace"; }
};

// The stream of the selected Space, or of the project Space followed for a file's
// page, errors or ends.
struct StreamFails : Command {
  bool file = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (!file) model.spaceDown = true;
    else if (!model.followed.isEmpty()) model.fileDown = true;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (file) shell.space()->setFileUnreachable();
    else shell.space()->setUnreachable(true);
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "StreamFails(" << (file ? "file" : "space") << ")"; }
};

// The selected Space's stream comes back with the copy it had.
struct SpaceStreamBack : Command {
  void apply(Model& model) const override { model.spaceDown = false; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.space()->receiveSpace(shell.snapshot(kPages, QStringLiteral("log-1")));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SpaceStreamBack"; }
};

}  // namespace

class SpaceProjectsProp : public QObject {
  Q_OBJECT

private slots:
  void sectionsFollowTheFilesAndTheLatestOpenApplies() {
    QVERIFY(rc::check("the sections are each project's files by folder as expanded and remembered, and only the latest open, unpicked since, shows its page once its Space arrives", [] {
      Shell shell;
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<ChangeFiles, SetExpanded, SetExpanded, OtherWindow, OpenFile, OpenFile, AnswerOpen, AnswerOpen,
                                                         ProjectSpaceArrives, ProjectSpaceArrives, SelectPage, SelectSpace, StreamFails,
                                                         SpaceStreamBack>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceProjectsProp)
#include "tst_SpaceProjectsProp.moc"
