// What the in-app browser's pages may ask for (src/native/PagePermissions),
// over any order of tabs asking, following links to other apps, the user
// answering (the question on screen or a stale one), tabs closing and the app
// quitting: one question is on screen at a time and it is the oldest still
// waiting; a site is asked once about the clipboard and its answer kept, a
// clipboard request behind another question is refused without being kept, a
// link waits its turn and the same link from one tab is asked once, local and
// inline addresses are never asked about, and `questionChanged` fires exactly
// when the question on screen changes.

#include "Prop.h"

#include <QSignalSpy>

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "PagePermissions.h"

namespace {

const std::vector<std::string> kTabs{"t1", "t2"};
const std::vector<std::string> kOrigins{"", "http://a.test", "http://b.test"};
const std::vector<std::string> kKinds{"clipboard", "clipboard", "clipboard-write", "notifications", "geolocation",
                                      "camera", "microphone", "mouse-lock", "fonts", "screen", "bogus", ""};
const std::vector<std::string> kLinks{"slack://a", "slack://b", "mailto:ada@example.com", "https://x.test/",
                                      "data:text/plain,hi", "file:///etc/hosts", "javascript:void(0)", "", "no scheme"};

struct Question {
  int id = 0;
  std::string tab;
  std::string kind;
  std::string origin;
  std::string url;
};

struct Model {
  std::vector<Question> questions;  // the first is on screen
  std::map<std::string, bool> clipboard;
  int next = 0;

  int frontId() const { return questions.empty() ? 0 : questions.front().id; }

  int ask(Question question) {
    question.id = ++next;
    questions.push_back(question);
    return question.id;
  }
};

bool granted(const std::string& kind) {
  return kind == "clipboard-write" || kind == "geolocation" || kind == "mouse-lock";
}

// Whether the system is ever asked to open `url`: a link with a scheme the engine does not show itself.
bool outside(const std::string& url) {
  const QUrl parsed(QString::fromStdString(url));
  const std::string scheme = parsed.scheme().toStdString();
  return parsed.isValid() && (scheme == "slack" || scheme == "mailto");
}

struct Sut {
  PagePermissions permissions;
  QSignalSpy changed{&permissions, &PagePermissions::questionChanged};
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& before, const Model& expected, Sut& sut) {
  const QVariantMap shown = sut.permissions.question();
  if (expected.questions.empty()) {
    RC_ASSERT(shown.isEmpty());
  } else {
    const Question& front = expected.questions.front();
    RC_ASSERT(shown.value(QStringLiteral("id")).toInt() == front.id);
    RC_ASSERT(shown.value(QStringLiteral("tabId")).toString().toStdString() == front.tab);
    RC_ASSERT(shown.value(QStringLiteral("kind")).toString().toStdString() == front.kind);
    RC_ASSERT(shown.value(QStringLiteral("origin")).toString().toStdString() == front.origin);
    RC_ASSERT(shown.value(QStringLiteral("url")).toUrl() == QUrl(QString::fromStdString(front.url)));
  }
  RC_ASSERT(sut.changed.count() == (before.frontId() != expected.frontId() ? 1 : 0));
  sut.changed.clear();
}

struct Request : Command {
  std::string tab = *rc::gen::elementOf(kTabs);
  std::string origin = *rc::gen::elementOf(kOrigins);
  std::string kind = *rc::gen::elementOf(kKinds);

  explicit Request(const Model&) {}

  // The answer the page gets: grant, deny, or the id of the question it waits on.
  std::string answer(Model& model) const {
    if (kind != "clipboard") return granted(kind) ? "grant" : "deny";
    if (const auto known = model.clipboard.find(origin); known != model.clipboard.end()) return known->second ? "grant" : "deny";
    if (!model.questions.empty() || origin.empty()) return "deny";
    return std::to_string(model.ask({0, tab, "clipboard", origin, {}}));
  }

  void apply(Model& model) const override { answer(model); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const std::string wanted = answer(expected);
    const QVariantMap got = sut.permissions.request(QString::fromStdString(tab), QString::fromStdString(origin), QString::fromStdString(kind));
    const std::string answer = got.value(QStringLiteral("answer")).toString().toStdString();
    if (wanted == "grant" || wanted == "deny") {
      RC_ASSERT(answer == wanted);
    } else {
      RC_ASSERT(answer == std::string("ask"));
      RC_ASSERT(std::to_string(got.value(QStringLiteral("id")).toInt()) == wanted);
    }
    check(model, expected, sut);
  }

  void show(std::ostream& os) const override { os << "Request(" << tab << ", " << origin << ", " << kind << ")"; }
};

struct OpenLink : Command {
  std::string tab = *rc::gen::elementOf(kTabs);
  std::string url = *rc::gen::elementOf(kLinks);

  explicit OpenLink(const Model&) {}

  int asked(Model& model) const {
    if (!outside(url)) return 0;
    for (const Question& waiting : model.questions)
      if (waiting.tab == tab && waiting.url == url) return waiting.id;
    return model.ask({0, tab, "link", QUrl(QString::fromStdString(url)).scheme().toStdString(), url});
  }

  void apply(Model& model) const override { asked(model); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const int wanted = asked(expected);
    RC_ASSERT(sut.permissions.openLink(QString::fromStdString(tab), QUrl(QString::fromStdString(url))) == wanted);
    check(model, expected, sut);
  }

  void show(std::ostream& os) const override { os << "OpenLink(" << tab << ", " << url << ")"; }
};

// The user answers the question on screen, or one no longer asked (a stale button).
struct Answer : Command {
  bool shown = *rc::gen::arbitrary<bool>();
  int stale = *rc::gen::inRange(0, 8);
  bool allow = *rc::gen::arbitrary<bool>();

  explicit Answer(const Model&) {}

  int id(const Model& model) const { return shown ? model.frontId() : stale; }

  std::optional<Question> answer(Model& model) const {
    const int target = id(model);
    for (auto it = model.questions.begin(); it != model.questions.end(); ++it) {
      if (it->id != target) continue;
      const Question answered = *it;
      model.questions.erase(it);
      if (answered.kind == "clipboard") model.clipboard[answered.origin] = allow;
      return answered;
    }
    return std::nullopt;
  }

  void apply(Model& model) const override { answer(model); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const auto answered = answer(expected);
    const QVariantMap got = sut.permissions.answer(id(model), allow);
    RC_ASSERT(got.isEmpty() == !answered.has_value());
    if (answered) {
      RC_ASSERT(got.value(QStringLiteral("id")).toInt() == answered->id);
      RC_ASSERT(got.value(QStringLiteral("kind")).toString().toStdString() == answered->kind);
      RC_ASSERT(got.value(QStringLiteral("tabId")).toString().toStdString() == answered->tab);
    }
    check(model, expected, sut);
  }

  void show(std::ostream& os) const override {
    os << "Answer(" << (shown ? std::string("shown") : std::to_string(stale)) << (allow ? ", allow" : ", refuse") << ")";
  }
};

// A tab's page goes.
struct Forget : Command {
  std::string tab = *rc::gen::elementOf(kTabs);

  explicit Forget(const Model&) {}

  void apply(Model& model) const override {
    std::erase_if(model.questions, [this](const Question& question) { return question.tab == tab; });
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.permissions.forget(QString::fromStdString(tab));
    check(model, expected, sut);
  }

  void show(std::ostream& os) const override { os << "Forget(" << tab << ")"; }
};

// The app quits and starts again.
struct Clear : Command {
  explicit Clear(const Model&) {}

  void apply(Model& model) const override {
    model.questions.clear();
    model.clipboard.clear();
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.permissions.clear();
    check(model, expected, sut);
  }

  void show(std::ostream& os) const override { os << "Clear"; }
};

}  // namespace

class PagePermissionsProp : public QObject {
  Q_OBJECT

private slots:
  void asksOneQuestionAtATime() {
    QVERIFY(rc::check(
        "one question is on screen at a time, the oldest waiting; a site is asked "
        "about the clipboard once, links wait their turn, local addresses are never asked about",
        [] {
          Sut sut;
          rc::state::check(Model{}, sut,
                           rc::state::gen::execOneOfWithArgs<Request, Request, OpenLink, OpenLink, Answer, Answer, Forget, Clear>());
        }));
  }
};

HAL_C2_PROP_MAIN(PagePermissionsProp)
#include "tst_PagePermissionsProp.moc"
