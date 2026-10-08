// The command palette (CommandPaletteController) as the user drives it in
// command mode, against a fake MC whose message search may be held back:
// opened, typed into, dismissed and toggled; commands registered, renamed,
// disabled and removed while it is open, and threads arriving or renamed;
// message search answers arriving late, after the query moved on; the
// highlight moved and set anywhere; entries run, including one no longer
// listed. After every step a list kept only from the model's row signals is
// the model as read afresh, QAbstractItemModelTester finds nothing wrong, the
// highlight is a row, and the test's commands and the threads are listed as
// the model says (by title, id or their messages), with what each shows.
// Inside each of the palette's signals, a row the signal does not move reads
// as it did before.

#include "Prop.h"

#include <QAbstractItemModelTester>
#include <QJsonArray>
#include <QTemporaryDir>

#include <memory>
#include <vector>

#include "CommandPaletteController.h"
#include "FakeMc.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

const QStringList kCommandIds{QStringLiteral("test.one"), QStringLiteral("test.two"), QStringLiteral("test.three")};
const QStringList kTitles{QStringLiteral("Alpha task"), QStringLiteral("Beta"), QStringLiteral("Run alpha"),
                          QStringLiteral("Slow")};
// The threads, and what their messages say; the last arrives late.
const QStringList kThreadIds{QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3"), QStringLiteral("t4")};
const QHash<QString, QString> kMessages{{QStringLiteral("t1"), QStringLiteral("slow login")},
                                        {QStringLiteral("t2"), QStringLiteral("beta notes")},
                                        {QStringLiteral("t3"), QStringLiteral("the alpha bug")},
                                        {QStringLiteral("t4"), QStringLiteral("alpha beta")}};
const QStringList kThreadTitles{QStringLiteral("Login"), QStringLiteral("Alpha draft"), QStringLiteral("Cart"),
                                QStringLiteral("Checkout")};
const QStringList kQueries{QString(),           QStringLiteral("a"),     QStringLiteral("al"),   QStringLiteral("alpha"),
                           QStringLiteral("be"), QStringLiteral("lo"),    QStringLiteral("slow"), QStringLiteral("test"),
                           QStringLiteral(">al"), QStringLiteral(">"),    QStringLiteral("t1"),   QStringLiteral("zz"),
                           QStringLiteral("alpha b"), QStringLiteral("login")};
const QString kProject = QStringLiteral("Shop");

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

// The palette's normalizeSearchText, for the queries and titles above.
QString normalized(const QString& text) { return text.toLower().simplified(); }

bool hasAll(const QString& haystack, const QStringList& tokens) {
  return std::all_of(tokens.cbegin(), tokens.cend(), [&haystack](const QString& token) { return haystack.contains(token); });
}

struct ModelCommand {
  QString title;
  bool enabled = true;
};

// What a row shows.
struct Row {
  QString title;
  QString description;
  QString group;
  QString kind;
  QString id;
  bool runnable = false;
  bool operator==(const Row&) const = default;
};

struct Model {
  bool open = false;
  QString query;
  QMap<QString, ModelCommand> commands;
  // The threads the shell has, by id, with their titles.
  QMap<QString, QString> threads;
  bool holding = false;
  // The normalized query the newest message search was sent for, whether its
  // answer is in, and the threads it named.
  QString sent;
  bool answered = false;
  QSet<QString> matched;
  // How many searches reached the MC.
  int searches = 0;
  QStringList ran;
  QString route;

  QStringList tokens() const { return normalized(actionsOnly() ? query.mid(1) : query).split(u' ', Qt::SkipEmptyParts); }
  bool actionsOnly() const { return query.startsWith(u'>'); }

  void answer() {
    answered = true;
    matched.clear();
    for (auto it = threads.cbegin(); it != threads.cend(); ++it) {
      if (kMessages.value(it.key()).contains(sent)) matched.insert(it.key());
    }
  }

  // The palette's generation moves on: no answer on its way counts.
  void forget() {
    sent.clear();
    answered = false;
    matched.clear();
  }

  void show() {
    open = true;
    query.clear();
    forget();
  }

  void close() {
    open = false;
    forget();
  }

  void setQuery(const QString& next) {
    if (next == query) return;
    query = next;
    if (!open) return;
    forget();
    if (!actionsOnly() && normalized(query).size() >= 2) {
      sent = normalized(query);
      ++searches;
      if (!holding) answer();
    }
  }

  // Whether the palette lists the test's command `id`.
  bool lists(const QString& id) const {
    if (!open || !commands.contains(id) || tokens().isEmpty()) return false;
    return hasAll(normalized(commands.value(id).title) + u' ' + id, tokens());
  }

  // Whether it lists the thread, and with what description.
  std::optional<QString> thread(const QString& id) const {
    if (!open || actionsOnly() || !threads.contains(id)) return std::nullopt;
    QString description = kProject;
    if (route == keyOf(id)) description += QStringLiteral(" · Current thread");
    const QStringList words = tokens();
    if (words.isEmpty() || hasAll(normalized(threads.value(id)) + u' ' + normalized(kProject) + u' ' + id, words)) {
      return description;
    }
    if (answered && sent == normalized(query) && matched.contains(id)) return kMessages.value(id);
    return std::nullopt;
  }
};

QtMessageHandler previousHandler = nullptr;
int modelTestFailures = 0;

void countModelTestFailures(QtMsgType type, const QMessageLogContext& context, const QString& message) {
  if (context.category && qstrcmp(context.category, "qt.modeltest") == 0 && type >= QtWarningMsg) ++modelTestFailures;
  previousHandler(type, context, message);
}

// The app on a fake MC with one project of three threads (a fourth to come),
// whose `orchestration.searchThreads` finds threads by their messages and
// waits while "messages" is held; stores in a home of its own.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  CommandPaletteController* palette = nullptr;
  CommandRegistry* registry = nullptr;
  std::unique_ptr<QAbstractItemModelTester> tester;
  // The list as a view keeps it, from the row signals alone.
  QList<Row> mirror;
  // What went wrong inside a signal, and signals that changed nothing.
  QStringList faults;
  QStringList ran;
  int searches = 0;
  // What a case reached: threads listed by their messages, entries run, and
  // runs of an entry no longer listed.
  int byMessages = 0;
  int runs = 0;
  int missing = 0;
  int highlighted = 0;
  bool open = false;
  QString query;

  Shell() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), kProject},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (int index = 0; index < 3; ++index) mc.threads.insert(kThreadIds.at(index), row(kThreadIds.at(index), kThreadTitles.at(index)));
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onRpc(QStringLiteral("orchestration.searchThreads"), [this](const FakeMc::Rpc& rpc) {
      ++searches;
      const auto answer = [this, rpc] {
        const QString query = rpc.payload.value(QLatin1String("query")).toString();
        QJsonArray matches;
        for (auto it = mc.threads.cbegin(); it != mc.threads.cend(); ++it) {
          if (kMessages.value(it.key()).contains(query, Qt::CaseInsensitive)) {
            matches.append(QJsonObject{{QStringLiteral("threadId"), it.key()}, {QStringLiteral("snippet"), kMessages.value(it.key())}});
          }
        }
        mc.reply(rpc, QJsonObject{{QStringLiteral("matches"), matches}});
      };
      if (mc.holding(QStringLiteral("messages"))) {
        mc.defer(answer);
      } else {
        answer();
      }
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] {
          return native.isActive() && native.store()->threadOnline(keyOf(QStringLiteral("t1"))) &&
                 native.store()->thread(keyOf(QStringLiteral("t3")));
        })) {
      qFatal("the shell did not start");
    }
    palette = native.controller<CommandPaletteController>();
    palette->setSearchDelay(0);
    registry = native.controller<KeybindingController>()->commands();
    QObject::connect(registry, &CommandRegistry::ran, palette, [this](const QString& command) {
      if (command.startsWith(QLatin1String("test."))) ran.append(command);
    });
    tester = std::make_unique<QAbstractItemModelTester>(palette, QAbstractItemModelTester::FailureReportingMode::Warning);
    mirror = rows();
    highlighted = palette->highlighted();
    watch();
  }

  static QJsonObject row(const QString& id, const QString& title) {
    return {{QStringLiteral("id"), id},
            {QStringLiteral("projectId"), QStringLiteral("p1")},
            {QStringLiteral("title"), title},
            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  }

  Row read(int row) const {
    const QModelIndex at = palette->index(row);
    return {at.data(CommandPaletteController::TitleRole).toString(),
            at.data(CommandPaletteController::DescriptionRole).toString(),
            at.data(CommandPaletteController::GroupRole).toString(),
            at.data(CommandPaletteController::KindRole).toString(),
            palette->idAt(row),
            at.data(CommandPaletteController::EnabledRole).toBool()};
  }

  QList<Row> rows() const {
    QList<Row> list;
    for (int row = 0; row < palette->rowCount(); ++row) list.append(read(row));
    return list;
  }

  // Rows outside [first, last] (of `count` now, `shift` after them) read as the mirror has them.
  void unmoved(const char* signal, int first, int last, int shift) {
    const int count = palette->rowCount();
    for (int row = 0; row < count; ++row) {
      if (row >= first && row <= last) continue;
      const int was = row > last ? row - shift : row;
      if (was < 0 || was >= mirror.size()) continue;
      if (read(row) != mirror.at(was)) {
        faults.append(QStringLiteral("%1: row %2 read %3, not %4")
                          .arg(QLatin1String(signal))
                          .arg(row)
                          .arg(read(row).title, mirror.at(was).title));
      }
    }
  }

  void watch() {
    using Base = QAbstractItemModel;
    QObject::connect(palette, &Base::rowsAboutToBeInserted, palette, [this](const QModelIndex&, int, int) {
      unmoved("rowsAboutToBeInserted", -1, -1, 0);
    });
    QObject::connect(palette, &Base::rowsInserted, palette, [this](const QModelIndex&, int first, int last) {
      unmoved("rowsInserted", first, last, last - first + 1);
      for (int row = first; row <= last; ++row) mirror.insert(row, read(row));
    });
    QObject::connect(palette, &Base::rowsAboutToBeRemoved, palette, [this](const QModelIndex&, int, int) {
      unmoved("rowsAboutToBeRemoved", -1, -1, 0);
    });
    QObject::connect(palette, &Base::rowsRemoved, palette, [this](const QModelIndex&, int first, int last) {
      mirror.remove(first, last - first + 1);
      unmoved("rowsRemoved", -1, -1, 0);
    });
    QObject::connect(palette, &Base::dataChanged, palette, [this](const QModelIndex& top, const QModelIndex& bottom) {
      unmoved("dataChanged", top.row(), bottom.row(), 0);
      for (int row = top.row(); row <= bottom.row(); ++row) mirror[row] = read(row);
    });
    QObject::connect(palette, &Base::modelReset, palette, [this] { mirror = rows(); });
    QObject::connect(palette, &Base::layoutChanged, palette, [this] { mirror = rows(); });
    // What QML binds to reads the rows as they stand.
    for (const auto signal : {&CommandPaletteController::modeChanged, &CommandPaletteController::resultsChanged}) {
      QObject::connect(palette, signal, palette, [this] { unmoved("a property's signal", -1, -1, 0); });
    }
    QObject::connect(palette, &CommandPaletteController::highlightedChanged, palette, [this] {
      unmoved("highlightedChanged", -1, -1, 0);
      if (palette->highlighted() == highlighted) faults.append(QStringLiteral("highlightedChanged for no change"));
      highlighted = palette->highlighted();
    });
    QObject::connect(palette, &CommandPaletteController::openChanged, palette, [this] {
      if (palette->isOpen() == open) faults.append(QStringLiteral("openChanged for no change"));
      open = palette->isOpen();
    });
    QObject::connect(palette, &CommandPaletteController::queryChanged, palette, [this] {
      unmoved("queryChanged", -1, -1, 0);
      if (palette->query() == query) faults.append(QStringLiteral("queryChanged for no change"));
      query = palette->query();
    });
  }

  // Every search asked for has reached the MC, and each answer not held has been read.
  void sync(const Model& model) {
    RC_ASSERT(prop::until([this, &model] { return searches >= model.searches; }));
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
    if (!model.holding) RC_ASSERT(prop::until([this] { return !palette->searching(); }));
  }

  int indexOf(const QString& kind, const QString& id) const {
    for (int row = 0; row < palette->rowCount(); ++row) {
      if (palette->kindAt(row) == kind && palette->idAt(row) == id) return row;
    }
    return -1;
  }

  QStringList commands() const {
    QStringList present;
    for (const QString& id : kCommandIds) {
      if (registry->contains(id)) present.append(id);
    }
    return present;
  }

  // Closed, nothing held, the test's commands gone; the threads and the route stay.
  Model reset() {
    mc.answerHeld();
    palette->dismiss();
    palette->setQuery(QString());
    for (const QString& id : kCommandIds) registry->remove(id);
    ran.clear();
    Model model;
    model.searches = searches;
    model.route = native.controller<NavigationController>()->threadKey();
    for (const QString& id : kThreadIds) {
      if (const auto thread = native.store()->thread(keyOf(id))) model.threads.insert(id, thread->title);
    }
    sync(model);
    faults.clear();
    modelTestFailures = 0;
    byMessages = runs = missing = 0;
    return model;
  }
};

void check(const Model& model, Shell& shell) {
  shell.sync(model);
  CommandPaletteController* palette = shell.palette;
  RC_ASSERT(shell.faults == QStringList());
  RC_ASSERT(modelTestFailures == 0);
  RC_ASSERT(shell.searches == model.searches);
  const QList<Row> rows = shell.rows();
  RC_ASSERT(shell.mirror == rows);
  RC_ASSERT(palette->isOpen() == model.open);
  RC_ASSERT(palette->query() == model.query);
  RC_ASSERT(shell.ran == model.ran);
  RC_ASSERT(shell.native.controller<NavigationController>()->threadKey() == model.route);
  if (!model.open) return;
  const int highlighted = palette->highlighted();
  const bool valid = rows.isEmpty() ? highlighted == 0 : highlighted >= 0 && highlighted < rows.size();
  RC_ASSERT(valid);
  for (const QString& id : kCommandIds) {
    const int row = shell.indexOf(QStringLiteral("action"), id);
    RC_ASSERT((row >= 0) == model.lists(id));
    if (row < 0) continue;
    RC_ASSERT(rows.at(row).title == model.commands.value(id).title);
    RC_ASSERT(rows.at(row).runnable == model.commands.value(id).enabled);
  }
  for (const QString& id : kThreadIds) {
    const int row = shell.indexOf(QStringLiteral("thread"), keyOf(id));
    const std::optional<QString> description = model.thread(id);
    RC_ASSERT((row >= 0) == description.has_value());
    if (row < 0) continue;
    RC_ASSERT(rows.at(row).title == model.threads.value(id));
    RC_ASSERT(rows.at(row).description == *description);
    if (*description == kMessages.value(id)) ++shell.byMessages;
  }
  // Each entry is listed once.
  QSet<QString> seen;
  for (const Row& row : rows) {
    const QString key = row.kind + u'\n' + row.id;
    RC_ASSERT(!seen.contains(key));
    seen.insert(key);
  }
}

using Command = rc::state::Command<Model, Shell>;

struct Show : Command {
  void apply(Model& model) const override { model.show(); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.palette->show();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Show"; }
};

struct Toggle : Command {
  void apply(Model& model) const override {
    if (model.open) {
      model.close();
    } else {
      model.show();
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.palette->toggle();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Toggle"; }
};

// Escape, or Dismiss: with no submenu both close it.
struct Close : Command {
  bool escape = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (model.open) model.close();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (escape) {
      shell.palette->back();
    } else {
      shell.palette->dismiss();
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << (escape ? "Back" : "Dismiss"); }
};

struct Type : Command {
  QString query = pick(kQueries);

  void apply(Model& model) const override { model.setQuery(query); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.palette->setQuery(query);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Type(\"" << query.toStdString() << "\")"; }
};

struct Move : Command {
  int delta = *rc::gen::inRange(-3, 4);
  bool set = *rc::gen::arbitrary<bool>();

  void apply(Model&) const override {}
  void run(const Model& model, Shell& shell) const override {
    if (set) {
      shell.palette->setHighlighted(delta * 7);
    } else {
      shell.palette->move(delta);
    }
    check(model, shell);
  }
  void show(std::ostream& os) const override { os << (set ? "SetHighlighted(" : "Move(") << (set ? delta * 7 : delta) << ")"; }
};

struct Hold : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.hold(QStringLiteral("messages"));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers every search it held, the newest last.
struct Answer : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.holding); }
  void apply(Model& model) const override {
    model.holding = false;
    if (!model.sent.isEmpty() && !model.answered) model.answer();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.answerHeld();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Answer"; }
};

// A command registered, renamed, enabled or disabled, or removed while the
// palette may be open.
struct Register : Command {
  enum Op { Add, Remove, Retitle, Enable };
  Op op = pick(QList<Op>{Add, Add, Remove, Retitle, Enable});
  QString id = pick(kCommandIds);
  QString title = pick(kTitles);
  bool enabled = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override {
    const bool known = model.commands.contains(id);
    const bool valid = op == Add ? !known : known;
    RC_PRE(valid);
  }
  void apply(Model& model) const override {
    switch (op) {
      case Add:
        model.commands.insert(id, {title, true});
        break;
      case Remove:
        model.commands.remove(id);
        break;
      case Retitle:
        model.commands[id].title = title;
        break;
      case Enable:
        model.commands[id].enabled = enabled;
        break;
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    switch (op) {
      case Add:
        shell.registry->add(id, title, [] {});
        break;
      case Remove:
        shell.registry->remove(id);
        break;
      case Retitle:
        shell.registry->setTitle(id, title);
        break;
      case Enable:
        shell.registry->setEnabled(id, enabled);
        break;
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    const char* names[] = {"Add", "Remove", "Retitle", "Enable"};
    os << names[op] << "(" << id.toStdString();
    if (op == Add || op == Retitle) os << ", \"" << title.toStdString() << "\"";
    if (op == Enable) os << ", " << enabled;
    os << ")";
  }
};

// A thread arrives, or one is renamed, from the MC.
struct ThreadRow : Command {
  QString id = pick(kThreadIds);
  QString title = pick(kThreadTitles);

  void apply(Model& model) const override { model.threads.insert(id, title); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.threads.insert(id, Shell::row(id, title));
    shell.mc.sendRow(id, shell.mc.threads.value(id));
    RC_ASSERT(prop::until([&shell, this] {
      const auto thread = shell.native.store()->thread(keyOf(id));
      return thread && thread->title == title;
    }));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ThreadRow(" << id.toStdString() << ", \"" << title.toStdString() << "\")"; }
};

// Enter on a test command or a thread where the palette lists it, else on a
// row past the end: what is no longer listed runs nothing.
struct Run : Command {
  QString kind = pick(QStringList{QStringLiteral("action"), QStringLiteral("thread")});
  QString id = kind == QLatin1String("action") ? pick(kCommandIds) : pick(kThreadIds);

  bool listed(const Model& model) const {
    return kind == QLatin1String("action") ? model.lists(id) : model.thread(id).has_value();
  }
  void apply(Model& model) const override {
    if (!listed(model)) return;
    if (kind == QLatin1String("action")) {
      if (!model.commands.value(id).enabled) return;
      model.ran.append(id);
    } else {
      model.route = keyOf(id);
    }
    model.close();
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    const QString key = kind == QLatin1String("action") ? id : keyOf(id);
    const int row = shell.indexOf(kind, key);
    const bool ran = shell.palette->run(row >= 0 ? row : shell.palette->rowCount());
    ++(row >= 0 ? shell.runs : shell.missing);
    RC_ASSERT(ran == (listed(model) && (kind != QLatin1String("action") || model.commands.value(id).enabled)));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Run(" << kind.toStdString() << " " << id.toStdString() << ")"; }
};

}  // namespace

class KeysPaletteProp : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { previousHandler = qInstallMessageHandler(countModelTestFailures); }

  void palette() {
    Shell shell;
    QVERIFY(rc::check("the palette lists what the model says, and its views keep up", [&shell] {
      const Model initial = shell.reset();
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Show, Toggle, Close, Type, Type, Type, Move, Hold, Answer,
                                                         Register, Register, ThreadRow, Run>());
      RC_CLASSIFY(shell.byMessages > 0, "a thread listed by its messages");
      RC_CLASSIFY(shell.runs > 0, "an entry run");
      RC_CLASSIFY(shell.missing > 0, "an entry no longer listed run");
      shell.mc.answerHeld();
    }));
  }
};

HAL_C2_PROP_MAIN(KeysPaletteProp)
#include "tst_KeysPaletteProp.moc"
