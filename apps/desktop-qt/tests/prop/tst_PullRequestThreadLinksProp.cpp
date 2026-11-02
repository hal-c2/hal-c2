// PullRequestThreadLinks as a state machine over what the user does in a
// review's "Linked threads" menu and what the MC answers: switching the pull
// request reviewed, linking it to or unlinking it from this thread, choosing a
// thread in the picker, the MC refusing, and the MC's counts arriving late.
// One change is sent at a time, a refused one changes nothing but says why,
// and a count lands only for the pull request it was asked about.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PullRequestThreadLinks.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QSet>
#include <QTemporaryDir>

#include <algorithm>
#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kThreads = {QStringLiteral("t1"), QStringLiteral("t2")};
const QStringList kTitles = {QStringLiteral("Tax rules"), QStringLiteral("Other work")};
const QStringList kQueries = {QString(), QStringLiteral("tax"), QStringLiteral("other"), QStringLiteral("shop"), QStringLiteral("none")};

QString urlOf(int number) { return QStringLiteral("https://github.com/acme/shop/pull/%1").arg(number); }

struct Model {
  // The pull request reviewed (1 or 2, 0 before any) and whether it is shown in t1.
  int number = 0;
  bool inThread = false;
  // Which threads link which pull request.
  QSet<QPair<QString, int>> links;
  int count = -1;
  bool pickerOpen = false;
  QString query;
  bool refusing = false;
  int toasts = 0;
  int sent = 0;
  // Each pull request shown in turn; showing the same one again is not a new turn.
  int turn = 0;
  // Counts asked for and not yet answered: the turn asked in, and how many
  // threads linked its pull request then.
  QList<QPair<int, int>> asked;

  int linking(int pr) const {
    int n = 0;
    for (const QString& thread : kThreads) n += links.contains({thread, pr});
    return n;
  }
  void ask() { asked.append({turn, linking(number)}); }
  // A change sent for `thread`: refused, or done and counted again.
  void change(const QString& thread, bool link) {
    ++sent;
    if (refusing) {
      ++toasts;
      return;
    }
    if (link) links.insert({thread, number});
    else links.remove({thread, number});
    pickerOpen = false;
    query.clear();
    ask();
  }
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  std::unique_ptr<PullRequestThreadLinks> links;
  int toasts = 0;
  // The `pullRequests.linkedThreads` calls held, answered by AnswerCounts.
  QList<FakeMc::Rpc> held;

  Shell() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (qsizetype i = 0; i < kThreads.size(); ++i) {
      mc.threads.insert(kThreads.at(i), QJsonObject{{QStringLiteral("id"), kThreads.at(i)},
                                                    {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                    {QStringLiteral("title"), kTitles.at(i)},
                                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-0%1T09:00:00Z").arg(2 - i)},
                                                    {QStringLiteral("pullRequests"), QJsonArray()}});
    }
    // The MC's projection of a link or unlink (orchestration.ex).
    mc.effects.append([this](const QJsonObject& command) {
      const QString type = command.value(QLatin1String("type")).toString();
      const QString threadId = command.value(QLatin1String("threadId")).toString();
      const int number = command.value(QLatin1String("number")).toInt();
      QJsonObject row = mc.threads.value(threadId);
      QJsonArray kept;
      for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
        if (value.toObject().value(QLatin1String("number")).toInt() != number) kept.append(value);
      }
      if (type == QLatin1String("thread.pull-request.link")) {
        kept.append(QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")},
                                {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                {QStringLiteral("number"), number},
                                {QStringLiteral("url"), command.value(QLatin1String("url"))},
                                {QStringLiteral("source"), QStringLiteral("manual")},
                                {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")}});
      }
      row.insert(QStringLiteral("pullRequests"), kept);
      mc.threads.insert(threadId, row);
      mc.sendRow(threadId, row);
    });
    // Counted when asked, answered when the property says.
    mc.onRpc(QStringLiteral("pullRequests.linkedThreads"), [this](const FakeMc::Rpc& rpc) {
      FakeMc::Rpc answer = rpc;
      QJsonArray threads;
      for (const QString& id : kThreads) {
        for (const QJsonValue& value : mc.threads.value(id).value(QLatin1String("pullRequests")).toArray()) {
          if (value.toObject().value(QLatin1String("number")) == rpc.payload.value(QLatin1String("number"))) threads.append(QJsonObject{{QStringLiteral("id"), id}});
        }
      }
      answer.payload.insert(QStringLiteral("threads"), threads);
      held.append(answer);
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] {
          return native.isActive() && native.store()->threadOnline(QStringLiteral("env-a:t1")) && native.store()->threadOnline(QStringLiteral("env-a:t2"));
        })) {
      qFatal("the shell did not start");
    }
    links = std::make_unique<PullRequestThreadLinks>(
        native.client(), native.store(), [this](const QString&, const QString&, const QString&) { ++toasts; }, nullptr);
  }

  int linkCommands() const {
    int n = 0;
    for (const QJsonObject& command : mc.commands) n += command.value(QLatin1String("type")).toString().startsWith(QLatin1String("thread.pull-request."));
    return n;
  }
  // The rows the MC sent have reached the store: each thread links what it should.
  bool landed(const Model& model) const {
    for (const QString& thread : kThreads) {
      if (links->links(thread) != model.links.contains({thread, model.number})) return false;
    }
    return true;
  }
};

void check(const Model& model, Shell& shell) {
  // What was sent has reached the MC, and what it answered has landed.
  RC_ASSERT(prop::until([&] { return !shell.links->pending() && shell.landed(model) && shell.held.size() == model.asked.size(); }));
  PullRequestThreadLinks& links = *shell.links;
  RC_ASSERT(links.available() == (model.number > 0));
  RC_ASSERT(links.count() == model.count);
  RC_ASSERT(links.pickerOpen() == model.pickerOpen);
  RC_ASSERT(links.query() == model.query);
  RC_ASSERT(shell.toasts == model.toasts);
  RC_ASSERT(shell.linkCommands() == model.sent);
  RC_ASSERT(shell.held.size() == model.asked.size());
  const bool here = model.inThread && model.links.contains({QStringLiteral("t1"), model.number});
  RC_ASSERT(links.linkedHere() == here);
  RC_ASSERT(links.menuLabel() == (here ? QStringLiteral("Unlink from this thread")
                                       : model.inThread ? QStringLiteral("Link to this thread") : QStringLiteral("Link to thread")));
  QVariantList wanted;
  if (model.pickerOpen) {
    for (qsizetype i = 0; i < kThreads.size(); ++i) {
      if (!(kTitles.at(i) + QStringLiteral(" Shop")).toLower().contains(model.query)) continue;
      wanted.append(QVariantMap{{QStringLiteral("id"), kThreads.at(i)},
                                {QStringLiteral("title"), kTitles.at(i)},
                                {QStringLiteral("project"), QStringLiteral("Shop")},
                                {QStringLiteral("linked"), model.links.contains({kThreads.at(i), model.number})}});
    }
  }
  RC_ASSERT(links.candidates() == wanted);
}

using Command = rc::state::Command<Model, Shell>;

// The review shows another pull request, or the same one in or outside the thread.
struct Show : Command {
  int number = *rc::gen::inRange(1, 3);
  bool inThread = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (number != model.number) {
      model.count = -1;
      model.pickerOpen = false;
      model.query.clear();
      model.number = number;
      ++model.turn;
      model.ask();
    }
    model.inThread = inThread;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.links->setTarget(QStringLiteral("env-a"), inThread ? QStringLiteral("t1") : QString(), QStringLiteral("github.com"), QStringLiteral("acme/shop"),
                           number, urlOf(number));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Show(#" << number << (inThread ? ", in t1)" : ", outside)"); }
};

// The menu's "Link to this thread" / "Unlink from this thread", clicked twice
// before the MC answers: only the first is sent.
struct ToggleHere : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.number > 0); }
  void apply(Model& model) const override {
    if (!model.inThread) {
      if (!model.pickerOpen) model.query.clear();
      model.pickerOpen = true;
      return;
    }
    model.change(QStringLiteral("t1"), !model.links.contains({QStringLiteral("t1"), model.number}));
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.links->toggleHere();
    if (model.inThread) {
      RC_ASSERT(shell.links->pending());
      shell.links->toggleHere();
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ToggleHere"; }
};

// A thread chosen in the picker; one that links it already is not linked again.
struct Choose : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>(kThreads.begin(), kThreads.end()));
  void checkPreconditions(const Model& model) const override { RC_PRE(model.number > 0); }
  void apply(Model& model) const override {
    if (!model.links.contains({thread, model.number})) model.change(thread, true);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.links->choose(thread);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Choose(" << thread.toStdString() << ")"; }
};

struct SetPicker : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.number > 0); }
  void apply(Model& model) const override {
    if (open == model.pickerOpen) return;
    model.pickerOpen = open;
    model.query.clear();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.links->setPickerOpen(open);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetPicker(" << open << ")"; }
};

struct Search : Command {
  QString query = *rc::gen::elementOf(std::vector<QString>(kQueries.begin(), kQueries.end()));
  void apply(Model& model) const override { model.query = query; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.links->setQuery(query);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Search(" << query.toStdString() << ")"; }
};

// The MC starts or stops refusing links and unlinks ("Thread is archived").
struct Refusing : Command {
  bool refusing = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refusing = refusing; }
  void run(const Model& model, Shell& shell) const override {
    for (const QString type : {QStringLiteral("thread.pull-request.link"), QStringLiteral("thread.pull-request.unlink")}) {
      if (refusing) shell.mc.refusals.insert(type, QStringLiteral("Thread is archived"));
      else shell.mc.refusals.remove(type);
    }
    Model expected = model;
    apply(expected);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Refusing(" << refusing << ")"; }
};

// The MC answers every count asked, oldest or newest first (it answers calls
// concurrently): only those asked while the pull request shown now was shown
// land, and the last of them to arrive wins.
struct AnswerCounts : Command {
  bool newestFirst = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.asked.isEmpty()); }
  void apply(Model& model) const override {
    QList<QPair<int, int>> asked = model.asked;
    if (newestFirst) std::reverse(asked.begin(), asked.end());
    for (const auto& [turn, count] : std::as_const(asked)) {
      if (turn == model.turn) model.count = count;
    }
    model.asked.clear();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    QList<FakeMc::Rpc> held = std::exchange(shell.held, {});
    if (newestFirst) std::reverse(held.begin(), held.end());
    for (const FakeMc::Rpc& rpc : held) shell.mc.reply(rpc, QJsonObject{{QStringLiteral("threads"), rpc.payload.value(QLatin1String("threads"))}});
    // Answers come in order: once a later call is answered, so are they.
    bool through = false;
    shell.native.client()->call(&shell.mc, QStringLiteral("env-a"), QStringLiteral("prop.roundTrip"), QJsonObject(),
                                [&through](const QJsonValue&, const std::optional<QString>&) { through = true; });
    RC_ASSERT(prop::until([&] { return through; }));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "AnswerCounts(" << (newestFirst ? "newest first" : "oldest first") << ")"; }
};

}  // namespace

class PullRequestThreadLinksProp : public QObject {
  Q_OBJECT

private slots:
  void linkedThreads() {
    QVERIFY(rc::check("one change at a time, a refusal changes nothing, a count lands only for its pull request", [] {
      Shell shell;
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<Show, ToggleHere, ToggleHere, Choose, SetPicker, Search, Refusing, AnswerCounts>());
    }));
  }
};

HAL_C2_PROP_MAIN(PullRequestThreadLinksProp)
#include "tst_PullRequestThreadLinksProp.moc"
