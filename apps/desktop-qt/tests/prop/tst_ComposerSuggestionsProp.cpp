// The composer's @ menu against a fake MC whose workspace search the test
// holds and answers: the user types and the search answers late, after the
// text moved on. A bare `@` is never searched, so its menu opens at once and
// says nothing matches; a word after it says nothing until the search for that
// word has answered, and an older word's answer (landing late) never counts.
// While the environment is away a word not yet answered says it can't be
// searched, and once it returns that word is asked again and answers. Moving the
// checkout asks the word again, and the old checkout's late answer never counts.
// Scope: the caret is at the end of the text, on one thread, with a workspace
// present. Not modelled: a route with no workspace and switching target between
// issuing a search and its answer; the claim above is proven only inside this
// envelope. A second property covers the slash menu for a word typed after
// other text.

#include "Prop.h"

#include "ComposerController.h"
#include "ComposerModel.h"
#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "WorkspaceController.h"

namespace prop = halc2::prop;

namespace {

// Typed with the cursor at the end: no menu, a bare @, and words after it, at
// the start of the text or after another word, that the workspace's one file,
// src/main.cpp, does and does not match.
const QStringList kTexts{QString(),
                         QStringLiteral("hello"),
                         QStringLiteral("@"),
                         QStringLiteral("@s"),
                         QStringLiteral("@sr"),
                         QStringLiteral("@m"),
                         QStringLiteral("@ss"),
                         QStringLiteral("@zz"),
                         QStringLiteral("hello @"),
                         QStringLiteral("hello @s"),
                         QStringLiteral("hello@s")};
const QString kNothing = QStringLiteral("No matching files or folders.");
const QString kUnavailable = QStringLiteral("Can't search files right now.");
const QString kSearching = QStringLiteral("Searching workspace files...");

// What the workspace's search finds for a query: the folder src and the file
// src/main.cpp, each when its last segment contains the query.
int matchesOf(const QString& query) {
  int found = 0;
  for (const QString& name : {QStringLiteral("src"), QStringLiteral("main.cpp")}) {
    if (name.contains(query, Qt::CaseInsensitive)) ++found;
  }
  return found;
}

struct Model {
  QString text;
  bool holding = false;
  // The query last searched, and whether its answer reached the composer.
  QString searched;
  bool answered = false;
  // The searches asked so far, each one the MC receives.
  int asked = 0;
  bool online = true;
  int moves = 0;

  // The @ word the composer itself reads from the text with the caret at its
  // end, so the model does not restate the trigger rules.
  std::optional<composer::Trigger> trigger() const {
    const auto found = composer::trigger(text, int(text.size()));
    return found && found->kind == QLatin1String("path") ? found : std::nullopt;
  }
  bool path() const { return trigger().has_value(); }
  QString query() const { return trigger() ? trigger()->query : QString(); }
  // A new word is searched if the environment is there; the same one is not
  // asked again.
  void search() {
    const QString word = query();
    if (!online || word.isEmpty() || word == searched) return;
    searched = word;
    answered = !holding;
    ++asked;
  }
};

struct Sut {
  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("t1")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    fakeFiles(mc).files.insert(QStringLiteral("src/main.cpp"), QStringLiteral("int main() {}"));
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      const QJsonObject provider{
          {QStringLiteral("instanceId"), QStringLiteral("codex")},
          {QStringLiteral("driver"), QStringLiteral("codex")},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-a")}}}},
          // For the slash menu: names that "/tmp" and "/thread" match fuzzily or
          // by description but do not start.
          {QStringLiteral("slashCommands"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("compact")},
                                                                   {QStringLiteral("description"), QStringLiteral("Compact this thread")}}}},
          {QStringLiteral("skills"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("template")},
                                                            {QStringLiteral("enabled"), true},
                                                            {QStringLiteral("description"), QStringLiteral("Fill this thread's template")}},
                                                QJsonObject{{QStringLiteral("name"), QStringLiteral("review")},
                                                            {QStringLiteral("enabled"), true},
                                                            {QStringLiteral("description"), QStringLiteral("Review the thread")}}}},
      };
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), QJsonArray{provider}},
                                                     {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), QJsonArray()}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 0},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->threadOnline(key); }));
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    RC_ASSERT(prop::until([this] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(key);
      return timeline && timeline->status() == QLatin1String("live") && shown().value(QStringLiteral("target")).toString() == key;
    }));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  QVariantMap shown() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }

  void type(const QString& text) {
    bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), key},
                                                                    {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                                         {QStringLiteral("revision"), ++revision}}},
                                                                    {QStringLiteral("text"), text},
                                                                    {QStringLiteral("cursor"), text.size()}});
  }

  // The MC's row of the thread changes.
  void sendThread(const QString& field, const QString& value) {
    QJsonObject& row = mc.threads[QStringLiteral("t1")];
    row.insert(field, value);
    mc.sendRow(QStringLiteral("t1"), row);
  }

  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString key = QStringLiteral("env-a:t1");
  int revision = 0;
};

// Whether the menu is as the model says. A search the MC will answer (not held)
// is waited for; one held says it is searching, at once.
bool menuIs(const Model& m, const Sut& sut) {
  const QVariantMap shown = sut.shown();
  if (shown.value(QStringLiteral("text")).toString() != m.text) return false;
  const bool path = m.path();
  if (shown.value(QStringLiteral("triggerKind")).toString() != (path ? QStringLiteral("path") : QString())) return false;
  const QVariant empty = shown.value(QStringLiteral("suggestionsEmptyText"));
  const int count = int(shown.value(QStringLiteral("suggestions")).toList().size());
  if (!path) return count == 0 && empty.isNull();
  if (m.query().isEmpty()) return count == 0 && empty.toString() == kNothing;
  if (m.searched != m.query() || !m.answered) {
    return count == 0 && empty.toString() == (m.online ? kSearching : kUnavailable);
  }
  const int found = matchesOf(m.query());
  return count == found && (found > 0 ? empty.isNull() : empty.toString() == kNothing);
}

void verify(const Model& m, Sut& sut) {
  RC_ASSERT(prop::until([&] { return menuIs(m, sut); }));
  // Once the menu matches, the searches the MC received are exactly the ones
  // the model asked for: a duplicate search for the same word fails here.
  RC_ASSERT(fakeFiles(sut.mc).searches == m.asked);
}

using Command = rc::state::Command<Model, Sut>;

struct Type : Command {
  QString text = *rc::gen::elementOf(std::vector<QString>(kTexts.cbegin(), kTexts.cend()));
  void apply(Model& m) const override {
    m.text = text;
    m.search();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.type(text);
    const Model m1 = nextState(m0);
    // Hold and AnswerHeld act on the searches the MC has received, so a search
    // is received before the next command.
    RC_ASSERT(prop::until([&] { return fakeFiles(sut.mc).searches >= m1.asked; }));
    verify(m1, sut);
  }
  void show(std::ostream& os) const override { os << "Type(\"" << text.toStdString() << "\")"; }
};

// The MC holds the searches it is asked from now on.
struct Hold : Command {
  void apply(Model& m) const override { m.holding = true; }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.hold(QStringLiteral("search"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers every search it held, the older ones after the text moved on.
struct AnswerHeld : Command {
  void apply(Model& m) const override {
    m.holding = false;
    if (!m.searched.isEmpty()) m.answered = true;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.answerHeld();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "AnswerHeld"; }
};

// The environment drops: a search it had not answered is lost with it.
struct GoOffline : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.online); }
  void apply(Model& m) const override {
    m.online = false;
    if (!m.answered) m.searched.clear();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.setOnline(sut.mc.environmentId, false);
    RC_ASSERT(prop::until([&] { return !sut.native->store()->environmentOnline(sut.mc.environmentId); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "GoOffline"; }
};

// It returns, and the word in the text is asked if it has no answer.
struct GoOnline : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.online); }
  void apply(Model& m) const override {
    m.online = true;
    m.search();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.setOnline(sut.mc.environmentId, true);
    RC_ASSERT(prop::until([&] { return sut.native->store()->environmentOnline(sut.mc.environmentId); }));
    const Model m1 = nextState(m0);
    RC_ASSERT(prop::until([&] { return fakeFiles(sut.mc).searches >= m1.asked; }));
    verify(m1, sut);
  }
  void show(std::ostream& os) const override { os << "GoOnline"; }
};

// The route moves to another checkout, online: any search is of the old one,
// and a held answer from it that lands now changes nothing.
struct MoveCheckout : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.online); }
  void apply(Model& m) const override {
    ++m.moves;
    m.searched.clear();
    m.answered = false;
    m.search();
  }
  void run(const Model& m0, Sut& sut) const override {
    const Model m1 = nextState(m0);
    const QString cwd = QStringLiteral("/work/worktrees/%1").arg(m1.moves);
    sut.sendThread(QStringLiteral("worktreePath"), cwd);
    RC_ASSERT(prop::until([&] {
      const auto& place = sut.native->controller<WorkspaceController>()->place();
      return place && place->cwd() == cwd;
    }));
    RC_ASSERT(prop::until([&] { return fakeFiles(sut.mc).searches >= m1.asked; }));
    // The newest held answer may be the current search's; older ones never are.
    if (sut.mc.heldAnswers() >= 2) {
      sut.mc.answerOldestHeld();
      // Frames arrive in order, so this row landing means the answer has too.
      const QString marker = QStringLiteral("moved %1").arg(m1.moves);
      sut.sendThread(QStringLiteral("title"), marker);
      RC_ASSERT(prop::until([&] {
        const auto thread = sut.native->store()->thread(sut.key);
        return thread && thread->title == marker;
      }));
    }
    verify(m1, sut);
  }
  void show(std::ostream& os) const override { os << "MoveCheckout"; }
};

// What a slash menu item names: a built-in's word, or a skill's or command's name.
QString nameOf(const QVariant& item) {
  const QString id = item.toMap().value(QStringLiteral("id")).toString();
  return id.startsWith(QLatin1String("slash:")) ? id.mid(6) : id.section(u':', 2);
}

QStringList namesShown(const Sut& sut) {
  QStringList names;
  for (const QVariant& item : sut.shown().value(QStringLiteral("suggestions")).toList()) names.append(nameOf(item));
  names.sort();
  return names;
}

// A slash word after other text: one the names start with, or prose that
// some of them match fuzzily or by description.
rc::Gen<QString> slashWord() {
  return rc::gen::map(
      rc::gen::oneOf(rc::gen::elementOf(std::vector<std::string>{"", "thread", "this", "tmp", "src", "mo", "Mo", "pl", "de", "rev",
                                                                 "tem", "t", "compact", "skill", "skill:", "skill:re", "skill:x"}),
                     rc::gen::container<std::string>(rc::gen::elementOf(std::vector<char>{'m', 'o', 'p', 'l', 'd', 'e', 't', 'r', 'v', 'h', 'a'}))),
      [](const std::string& word) { return QString::fromStdString(word); });
}

}  // namespace

class ComposerSuggestionsProp : public QObject {
  Q_OBJECT

private slots:
  void theAtMenuSaysNothingMatchesOnlyForASearchThatAnswered() {
    QVERIFY(rc::check("a bare @ says nothing matches at once; a word does once its own search answered, never for an older one, and is asked again when the environment returns", [] {
      Sut sut;
      Model model;
      const auto commands = *rc::gen::scale(
          0.6, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Type, Type, Type, Hold, AnswerHeld, GoOffline, GoOnline, MoveCheckout>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // Enter takes the highlighted suggestion whenever the menu has one, so a
  // word in a sentence that the user did not mean as a command must leave it
  // empty and closed. The names on offer are what a bare "/" there lists.
  void aSlashWordInASentenceOffersOnlyTheNamesItStarts() {
    QVERIFY(rc::check("mid-sentence, a slash word offers exactly the names it starts and opens no menu when it starts none", [] {
      Sut sut;
      sut.type(QStringLiteral("fix /"));
      RC_ASSERT(prop::until([&] { return namesShown(sut).contains(QStringLiteral("review")); }));
      const QStringList all = namesShown(sut);
      RC_ASSERT(!all.contains(QStringLiteral("compact")));
      const auto lead = *rc::gen::elementOf(std::vector<std::string>{"fix", "summarise this", "first line\nthen"});
      const auto words = *rc::gen::container<std::vector<QString>>(slashWord());
      for (const QString& word : words) {
        const QString text = QString::fromStdString(lead) + QStringLiteral(" /") + word;
        sut.type(text);
        RC_ASSERT(prop::until([&] { return sut.shown().value(QStringLiteral("text")).toString() == text; }));
        const QString query = word.toLower();
        QStringList expected;
        for (const QString& name : all) {
          const bool skill = name == QLatin1String("template") || name == QLatin1String("review");
          const QString wanted = skill && query.startsWith(QLatin1String("skill:")) ? query.mid(6) : query;
          if (name.startsWith(wanted) || (skill && query.size() >= 3 && QStringLiteral("skill:").startsWith(query))) expected.append(name);
        }
        RC_LOG() << text.toStdString() << " offers " << namesShown(sut).join(u',').toStdString() << "\n";
        RC_ASSERT(namesShown(sut) == expected);
        const QString kind = sut.shown().value(QStringLiteral("triggerKind")).toString();
        RC_ASSERT(kind == (expected.isEmpty() ? QString() : QStringLiteral("slash-command")));
      }
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerSuggestionsProp)
#include "tst_ComposerSuggestionsProp.moc"
