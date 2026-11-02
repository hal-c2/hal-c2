// What SpaceController says of a project's Space files, and when it reads a page's
// file again, as a state machine over what moves them: lists asked for and
// answered (or refused) in any order, the connection going and coming back, the
// Space route opening and closing, the page selected, and pages starting or
// stopping following a file as the Space's copy brings them.
//
// After each step a project's files are what the MC last answered to the latest
// list asked for it, an older answer coming late changing nothing, and none, with
// the MC's error, once the latest was refused; a list asked offline goes out on connecting, and every
// project asked for is asked again on each connection. `space.page.syncFile` goes
// out once each time a file-backed page comes on show, and not again while it
// stays there, whatever else the Space's copy brings. Opening a file (answered
// or refused) opens the Space on its page, says that page in `written` for the
// phone's Space screen, and clears `written` first, so the same page said again
// is a change.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SpaceController.h"

#include <QTemporaryDir>

#include <vector>

namespace prop = halc2::prop;

namespace {

const QString kSpaceId = QStringLiteral("space-1");
const QStringList kPages = {QStringLiteral("page-1"), QStringLiteral("page-2")};
const QStringList kProjects = {QStringLiteral("alpha"), QStringLiteral("beta")};
const QString kRefusal = QStringLiteral("The project could not be read.");

QString oneOf(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

// The nth list asked for a project, and the file its answer names.
struct Ask {
  QString project;
  int n = 0;
  bool operator==(const Ask&) const = default;
};

QString answeredFile(const Ask& ask) { return QStringLiteral("%1-%2.md").arg(ask.project).arg(ask.n); }

struct Model {
  bool open = false;
  bool ready = true;
  QString page = kPages.first();
  QSet<QString> filed{kPages.first()};
  // The file-backed page on show the client last read again, and how often it did.
  QString synced;
  int syncs = 0;

  QSet<QString> wanted;
  QMap<QString, int> asked;
  std::vector<Ask> pending;
  // What the client says of each project: the answer it kept, 0 for a refusal, or nothing.
  QMap<QString, int> shown;
  // Every value `written` took, in order.
  QStringList written;

  QString onShow() const { return open && ready && filed.contains(page) ? page : QString(); }
  void settleSync() {
    const QString page = onShow();
    if (page == synced) return;
    synced = page;
    if (!page.isEmpty()) ++syncs;
  }
  void ask(const QString& project) {
    wanted.insert(project);
    if (!ready) return;
    pending.push_back({project, ++asked[project]});
  }
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  // The lists asked and not yet answered, and how many came for each project.
  std::vector<std::pair<Ask, FakeMc::Rpc>> held;
  QMap<QString, int> arrived;
  QStringList syncs;
  QStringList written;
  // How the MC answers the next `space.page.openFile`: the page, or "" to refuse it;
  // and how many it answered.
  QString opens;
  int answeredOpens = 0;

  Shell() {
    QObject::connect(&bridge, &ShellBridge::stateEntryChanged, &bridge, [this](const QString& key, const QVariant& value) {
      if (key != QLatin1String("space")) return;
      const QString now = value.toMap().value(QStringLiteral("written")).toString();
      if (now != (written.isEmpty() ? QString() : written.last())) written.append(now);
    });
    mc.onRpc(QStringLiteral("space.page.openFile"), [this](const FakeMc::Rpc& rpc) {
      ++answeredOpens;
      if (opens.isEmpty()) return mc.refuse(rpc, QStringLiteral("There is no such file."));
      mc.reply(rpc, QJsonObject{{QStringLiteral("spaceId"), kSpaceId},
                                {QStringLiteral("page"), QJsonObject{{QStringLiteral("id"), opens}}},
                                {QStringLiteral("created"), false}});
    });
    mc.onRpc(QStringLiteral("space.files.list"), [this](const FakeMc::Rpc& rpc) {
      const QString project = rpc.payload.value(QLatin1String("projectId")).toString();
      held.push_back({{project, ++arrived[project]}, rpc});
    });
    mc.onRpc(QStringLiteral("space.page.syncFile"), [this](const FakeMc::Rpc& rpc) {
      syncs.append(rpc.payload.value(QLatin1String("pageId")).toString());
      mc.reply(rpc, QJsonValue::Null);
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
    feedRows(Model().filed);
    space()->selectPage(kPages.first());
  }

  SpaceController* space() { return native.controller<SpaceController>(); }

  // The Space's copy as a new snapshot brings it; the fake serves no stream.
  void feedRows(const QSet<QString>& filed) {
    QJsonArray rows;
    for (const QString& id : kPages) {
      QJsonObject page{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                       {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
      page.insert(QStringLiteral("file"), filed.contains(id) ? QJsonValue(QJsonObject{{QStringLiteral("projectId"), kProjects.first()},
                                                                                       {QStringLiteral("path"), id + QStringLiteral(".md")},
                                                                                       {QStringLiteral("hash"), QStringLiteral("h")},
                                                                                       {QStringLiteral("size"), 1},
                                                                                       {QStringLiteral("missing"), false},
                                                                                       {QStringLiteral("conflictAt"), QJsonValue::Null}})
                                                             : QJsonValue(QJsonValue::Null));
      rows.append(QJsonArray{QStringLiteral("page"), id, page});
    }
    space()->receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
                           {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
  }

  QVariantMap files() const { return bridge.state()->value(QStringLiteral("space")).toMap().value(QStringLiteral("files")).toMap(); }

  // Waits for every list the model asked to reach the MC and for the client to say
  // what the model does, then holds it to that.
  void check(const Model& model) {
    QMap<QString, QStringList> expected;
    // A refused list reads as its error in place of its files.
    for (auto it = model.shown.cbegin(); it != model.shown.cend(); ++it) {
      expected.insert(it.key(), {it.value() == 0 ? kRefusal : answeredFile({it.key(), it.value()})});
    }
    const auto said = [&] {
      QMap<QString, QStringList> paths;
      const QVariantMap now = files();
      for (auto it = now.cbegin(); it != now.cend(); ++it) {
        const QVariantMap listed = it.value().toMap();
        QStringList keys = listed.value(QStringLiteral("paths")).toMap().keys();
        if (const QString error = listed.value(QStringLiteral("error")).toString(); !error.isEmpty()) keys.append(error);
        paths.insert(it.key(), keys);
      }
      return paths;
    };
    prop::until([&] {
      return native.client()->isReady() == model.ready && arrived == model.asked && held.size() == model.pending.size() && said() == expected &&
             syncs.size() == model.syncs && written == model.written;
    });
    RC_ASSERT(native.client()->isReady() == model.ready);
    RC_ASSERT(arrived == model.asked);
    RC_ASSERT(held.size() == model.pending.size());
    RC_ASSERT(said() == expected);
    RC_ASSERT(syncs.size() == model.syncs);
    if (!model.synced.isEmpty()) RC_ASSERT(syncs.last() == model.synced);
    RC_ASSERT(space()->pageId() == model.page);
    RC_ASSERT(written == model.written);
    RC_ASSERT((native.controller<NavigationController>()->route().kind == QLatin1String("space")) == model.open);
  }
};

using Command = rc::state::Command<Model, Shell>;

struct ListFiles : Command {
  QString project = oneOf(kProjects);
  void apply(Model& model) const override { model.ask(project); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.files.list"), QVariantMap{{QStringLiteral("projectId"), project}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "ListFiles(" << project.toStdString() << ")"; }
};

// The MC answers one of the lists it holds, whichever, or refuses it.
struct Answer : Command {
  std::size_t index = *rc::gen::inRange<std::size_t>(0, 64);
  bool refused = *rc::gen::weightedElement<bool>({{1, true}, {3, false}});
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.pending.empty()); }
  Ask which(const Model& model) const { return model.pending[index % model.pending.size()]; }
  void apply(Model& model) const override {
    const Ask ask = which(model);
    std::erase(model.pending, ask);
    if (ask.n != model.asked.value(ask.project)) return;
    if (refused) {
      model.shown.insert(ask.project, 0);
    } else {
      model.shown.insert(ask.project, ask.n);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    const Ask ask = which(model);
    const auto found = std::find_if(shell.held.begin(), shell.held.end(), [&](const auto& held) { return held.first == ask; });
    RC_ASSERT(found != shell.held.end());
    const FakeMc::Rpc rpc = found->second;
    shell.held.erase(found);
    if (refused) {
      shell.mc.refuse(rpc, kRefusal);
    } else {
      const QJsonObject file{{QStringLiteral("relativePath"), answeredFile(ask)}, {QStringLiteral("kind"), QStringLiteral("markdown")}, {QStringLiteral("page"), QJsonValue::Null}};
      shell.mc.reply(rpc, QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), QJsonArray{file}}});
    }
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "Answer(" << index << (refused ? ", refused" : "") << ")"; }
};

struct SetRoute : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.open = open;
    model.settleSync();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.native.controller<NavigationController>()->open(NavigationController::Route::of(open ? QStringLiteral("space") : QStringLiteral("usage")));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SetRoute(" << open << ")"; }
};

struct SelectPage : Command {
  QString page = oneOf(kPages);
  void apply(Model& model) const override {
    model.page = page;
    model.settleSync();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), page}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SelectPage(" << page.toStdString() << ")"; }
};

// The Space's copy brings a page following its file, or not; or brings what it had.
struct Filed : Command {
  QString page = oneOf(kPages);
  bool filed = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (filed) {
      model.filed.insert(page);
    } else {
      model.filed.remove(page);
    }
    model.settleSync();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.feedRows(expected.filed);
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "Filed(" << page.toStdString() << ", " << filed << ")"; }
};

// The user opens a project file, which the MC answers with one of the Space's
// pages or refuses.
struct OpenFile : Command {
  QString project = oneOf(kProjects);
  QString page = *rc::gen::weightedElement<QString>({{1, QString()}, {2, kPages.first()}, {2, kPages.last()}});
  void checkPreconditions(const Model& model) const override { RC_PRE(model.ready); }
  void apply(Model& model) const override {
    if (!model.written.isEmpty() && !model.written.last().isEmpty()) model.written.append(QString());
    if (page.isEmpty()) return;
    model.written.append(page);
    model.open = true;
    model.settleSync();
    model.page = page;
    model.settleSync();
    model.ask(project);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.opens = page;
    const int answered = shell.answeredOpens;
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.openFile"),
                                    QVariantMap{{QStringLiteral("projectId"), project}, {QStringLiteral("relativePath"), QStringLiteral("guide.md")}}));
    // Answered as this command says, not as the next one does.
    RC_ASSERT(prop::until([&] { return shell.answeredOpens > answered; }));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "OpenFile(" << project.toStdString() << ", " << (page.isEmpty() ? "refused" : page.toStdString()) << ")"; }
};

// What the MC held is lost with the connection.
struct GoOffline : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.ready); }
  void apply(Model& model) const override {
    model.ready = false;
    model.pending.clear();
    model.settleSync();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.stopAccepting();
    shell.mc.drop();
    shell.held.clear();
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "GoOffline"; }
};

struct GoOnline : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.ready); }
  void apply(Model& model) const override {
    model.ready = true;
    for (const QString& project : model.wanted) model.ask(project);
    model.settleSync();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.startAccepting();
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "GoOnline"; }
};

}  // namespace

class SpaceFilesProp : public QObject {
  Q_OBJECT

private slots:
  void keepsTheLatestListAndReadsTheShownFileOnce() {
    QVERIFY(rc::check("a project's files are the latest list's answer, a file-backed page is read again once each time it comes on show, and an opened file's page is said anew", [] {
      Shell shell;
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<ListFiles, ListFiles, Answer, Answer, Answer, SetRoute, SetRoute, SelectPage, Filed, OpenFile, GoOffline, GoOnline>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceFilesProp)
#include "tst_SpaceFilesProp.moc"
