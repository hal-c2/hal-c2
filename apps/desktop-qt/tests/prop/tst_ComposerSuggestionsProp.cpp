// The composer's @ menu against a fake MC whose workspace search the test
// holds and answers: the user types and the search answers late, after the
// text moved on. A bare `@` is never searched, so its menu opens at once and
// says nothing matches; a word after it says nothing until the search for that
// word has answered, and an older word's answer (landing late) never counts.

#include "Prop.h"

#include "ComposerController.h"
#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"

namespace prop = halc2::prop;

namespace {

// Typed with the cursor at the end: no menu, a bare @, and words after it that
// the workspace's one file, src/main.cpp, does and does not match.
const QStringList kTexts{QString(), QStringLiteral("hello"), QStringLiteral("@"), QStringLiteral("@s"), QStringLiteral("@sr"),
                         QStringLiteral("@zz")};
const QString kNothing = QStringLiteral("No matching files or folders.");

// What the workspace's search finds for a query: the folder src and no more.
int matchesOf(const QString& query) { return query.contains(QLatin1String("s"), Qt::CaseInsensitive) ? 1 : 0; }

struct Model {
  QString text;
  bool holding = false;
  // The query last searched, and whether its answer reached the composer.
  QString searched;
  bool answered = false;

  QString query() const { return text.startsWith(QLatin1Char('@')) ? text.mid(1) : QString(); }
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

  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString key = QStringLiteral("env-a:t1");
  int revision = 0;
};

// Whether the menu is as the model says. A search the MC will answer (not held)
// is waited for; one held shows nothing yet, at once.
bool menuIs(const Model& m, const Sut& sut) {
  const QVariantMap shown = sut.shown();
  if (shown.value(QStringLiteral("text")).toString() != m.text) return false;
  const bool path = m.text.startsWith(QLatin1Char('@'));
  if (shown.value(QStringLiteral("triggerKind")).toString() != (path ? QStringLiteral("path") : QString())) return false;
  const QVariant empty = shown.value(QStringLiteral("suggestionsEmptyText"));
  const int count = int(shown.value(QStringLiteral("suggestions")).toList().size());
  if (!path) return count == 0 && empty.isNull();
  if (m.query().isEmpty()) return count == 0 && empty.toString() == kNothing;
  if (m.searched != m.query() || !m.answered) return count == 0 && empty.isNull();
  const int found = matchesOf(m.query());
  return count == found && (found > 0 ? empty.isNull() : empty.toString() == kNothing);
}

void verify(const Model& m, Sut& sut) {
  RC_ASSERT(prop::until([&] { return menuIs(m, sut); }));
}

using Command = rc::state::Command<Model, Sut>;

struct Type : Command {
  QString text = *rc::gen::elementOf(std::vector<QString>(kTexts.cbegin(), kTexts.cend()));
  void apply(Model& m) const override {
    m.text = text;
    const QString query = m.query();
    // A new word is searched; the same one is not asked again.
    if (!query.isEmpty() && query != m.searched) {
      m.searched = query;
      m.answered = !m.holding;
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.type(text);
    verify(nextState(m0), sut);
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

}  // namespace

class ComposerSuggestionsProp : public QObject {
  Q_OBJECT

private slots:
  void theAtMenuSaysNothingMatchesOnlyForASearchThatAnswered() {
    QVERIFY(rc::check("a bare @ says nothing matches at once; a word does once its own search answered, never for an older one", [] {
      Sut sut;
      Model model;
      const auto commands = *rc::gen::scale(
          0.6, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Type, Type, Type, Hold, AnswerHeld>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerSuggestionsProp)
#include "tst_ComposerSuggestionsProp.moc"
