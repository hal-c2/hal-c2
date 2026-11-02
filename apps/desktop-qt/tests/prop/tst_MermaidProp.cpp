// MermaidController as a state machine over what reaches it: a diagram shown
// (by any block, in any window, as often as it is laid out), the MC's answer,
// the call failing because the MC is away, the MC coming back, and the user
// asking again. The model is what the clients promise in
// features/timeline/markdown.feature and features/files/file-viewer-and-editing.feature:
// a diagram is drawn once, not over and over, per theme and source; while it
// is asked for it says so, and once answered it shows the answer; only one
// that failed is asked for again.

#include "Prop.h"

#include "McClient.h"
#include "MermaidController.h"

#include <QMap>

#include <optional>
#include <vector>

namespace {

const QStringList kSources{QStringLiteral("flowchart LR\n  A --> B"), QStringLiteral("sequenceDiagram\n  A->>B: hi"),
                           QStringLiteral("flowchart LR\n  A[open --> B")};
const QStringList kThemes{QStringLiteral("light"), QStringLiteral("dark")};

QString keyOf(const QString& source, const QString& theme) { return theme + QLatin1Char('\n') + source; }

template <typename T>
T pick(const QList<T>& pool) { return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend())); }

// How the MC answers a call.
enum class Outcome { Drawn, Unsupported, Invalid, Failed, Away };
const QList<Outcome> kOutcomes{Outcome::Drawn, Outcome::Unsupported, Outcome::Invalid, Outcome::Failed, Outcome::Away};

QString statusOf(Outcome outcome) {
  switch (outcome) {
    case Outcome::Drawn: return QStringLiteral("drawn");
    case Outcome::Unsupported: return QStringLiteral("unsupported");
    case Outcome::Invalid: return QStringLiteral("invalid");
    case Outcome::Failed:
    case Outcome::Away: return QStringLiteral("failed");
  }
  return {};
}

struct Model {
  // key → what it shows: "drawing" while asked for, else the answer's status.
  QMap<QString, QString> shown;
  int asked = 0;

  QStringList pending() const {
    QStringList keys;
    for (auto it = shown.begin(); it != shown.end(); ++it) {
      if (it.value() == QLatin1String("drawing")) keys.append(it.key());
    }
    return keys;
  }
  QStringList failed() const {
    QStringList keys;
    for (auto it = shown.begin(); it != shown.end(); ++it) {
      if (it.value() == QLatin1String("failed")) keys.append(it.key());
    }
    return keys;
  }
};

struct Sut {
  struct Call {
    QJsonObject input;
    McClient::Reply reply;
  };
  McClient client;
  MermaidController diagrams{nullptr, &client};
  QList<Call> calls;  // asked, not yet answered
  int asked = 0;

  Sut() {
    diagrams.setAsk([this](QObject*, const QJsonObject& input, McClient::Reply reply) {
      calls.append({input, std::move(reply)});
      ++asked;
    });
  }

  std::optional<qsizetype> callFor(const QString& key) const {
    for (qsizetype i = 0; i < calls.size(); ++i) {
      if (keyOf(calls.at(i).input.value(QLatin1String("source")).toString(), calls.at(i).input.value(QLatin1String("theme")).toString()) == key) {
        return i;
      }
    }
    return std::nullopt;
  }
};

// What the controller shows for every diagram the model knows, and that each
// one being asked for has exactly one call out.
void check(const Model& model, Sut& sut) {
  RC_ASSERT(sut.asked == model.asked);
  RC_ASSERT(sut.calls.size() == model.pending().size());
  for (auto it = model.shown.begin(); it != model.shown.end(); ++it) {
    const qsizetype cut = it.key().indexOf(QLatin1Char('\n'));
    const QString theme = it.key().left(cut);
    const QString source = it.key().mid(cut + 1);
    RC_ASSERT(sut.diagrams.diagram(source, theme).value(QStringLiteral("status")).toString() == it.value());
    RC_ASSERT(sut.callFor(it.key()).has_value() == (it.value() == QLatin1String("drawing")));
  }
  for (const Sut::Call& call : std::as_const(sut.calls)) {
    RC_ASSERT(call.input.value(QLatin1String("format")).toString() == QStringLiteral("svg"));
  }
}

using Command = rc::state::Command<Model, Sut>;

// A block shows the diagram: laid out, scrolled back, or drawn in another window.
struct Show : Command {
  QString source = pick(kSources);
  QString theme = pick(kThemes);

  void apply(Model& model) const override {
    if (model.shown.contains(keyOf(source, theme))) return;
    model.shown.insert(keyOf(source, theme), QStringLiteral("drawing"));
    ++model.asked;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    const QString status = sut.diagrams.diagram(source, theme).value(QStringLiteral("status")).toString();
    RC_ASSERT(status == expected.shown.value(keyOf(source, theme)));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Show(" << kSources.indexOf(source) << ", " << theme.toStdString() << ")"; }
};

struct Answer : Command {
  QString key;
  Outcome outcome;

  explicit Answer(const Model& model) : outcome(pick(kOutcomes)) {
    RC_PRE(!model.pending().isEmpty());
    key = pick(model.pending());
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(model.pending().contains(key)); }
  void apply(Model& model) const override { model.shown.insert(key, statusOf(outcome)); }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    const std::optional<qsizetype> at = sut.callFor(key);
    RC_ASSERT(at.has_value());
    const Sut::Call call = sut.calls.takeAt(*at);
    const int revision = sut.diagrams.revision();
    switch (outcome) {
      case Outcome::Drawn:
        call.reply(QJsonObject{{QStringLiteral("status"), QStringLiteral("drawn")}, {QStringLiteral("kind"), QStringLiteral("flowchart")},
                               {QStringLiteral("svg"), QStringLiteral("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"5\"/>")},
                               {QStringLiteral("width"), 10}, {QStringLiteral("height"), 5}},
                   std::nullopt);
        break;
      case Outcome::Unsupported:
      case Outcome::Invalid:
      case Outcome::Failed:
        call.reply(QJsonObject{{QStringLiteral("status"), statusOf(outcome)}, {QStringLiteral("kind"), QJsonValue()},
                               {QStringLiteral("reason"), QStringLiteral("no")}, {QStringLiteral("line"), 2}},
                   std::nullopt);
        break;
      case Outcome::Away:
        call.reply(QJsonValue(), QStringLiteral("disconnected"));
        break;
    }
    // Every answer is seen.
    RC_ASSERT(sut.diagrams.revision() > revision);
    const qsizetype cut = key.indexOf(QLatin1Char('\n'));
    const QVariantMap shown = sut.diagrams.diagram(key.mid(cut + 1), key.left(cut));
    if (outcome == Outcome::Drawn) {
      RC_ASSERT(shown.value(QStringLiteral("url")).toString().startsWith(QStringLiteral("data:image/svg+xml;base64,")));
      RC_ASSERT(shown.value(QStringLiteral("width")).toDouble() == 10.0);
    } else {
      RC_ASSERT(!shown.value(QStringLiteral("reason")).toString().isEmpty());
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "Answer(" << key.toStdString() << ", " << statusOf(outcome).toStdString() << (outcome == Outcome::Away ? " away" : "") << ")";
  }
};

// The user asks for a diagram that could not be drawn again.
struct Retry : Command {
  QString source = pick(kSources);
  QString theme = pick(kThemes);

  void apply(Model& model) const override {
    if (model.shown.value(keyOf(source, theme)) != QLatin1String("failed")) return;
    model.shown.insert(keyOf(source, theme), QStringLiteral("drawing"));
    ++model.asked;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.diagrams.retry(source, theme);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Retry(" << kSources.indexOf(source) << ", " << theme.toStdString() << ")"; }
};

// The MC is back: what failed is asked for again, nothing else.
struct Reconnect : Command {
  void apply(Model& model) const override {
    for (const QString& key : model.failed()) {
      model.shown.insert(key, QStringLiteral("drawing"));
      ++model.asked;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.diagrams.reconnected();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

}  // namespace

class MermaidProp : public QObject {
  Q_OBJECT

private slots:
  void cache() {
    QVERIFY(rc::check("a diagram is asked for once per theme and source, and again only after it failed", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Show, Show, Answer, Answer, Retry, Reconnect>());
    }));
  }
};

HAL_C2_PROP_MAIN(MermaidProp)
#include "tst_MermaidProp.moc"
