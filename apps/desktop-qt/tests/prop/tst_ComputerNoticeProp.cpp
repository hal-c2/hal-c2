// What a thread says about the computer it runs on (src/native/ComputerNotice),
// over any order of computers going down and up, updating, changing version,
// leaving the cluster, the cluster giving up on it, the thread shown changing
// and time passing: the shown computer's notice follows from its state alone,
// a plain reconnect is only announced after two seconds down, an offline one
// can be reconnected, one down for 20 seconds that does not run here can be
// disconnected, and each step says whether it changed.

#include "Prop.h"

#include <map>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

#include "ComputerNotice.h"

namespace {

const std::vector<std::string> kComputers{"a", "b", "c"};

struct Computer {
  bool online = true;
  bool updating = false;
  bool otherVersion = false;
  bool trying = true;
  bool local = false;
  qint64 downSince = 0;
};

// What the notice shows: its kind, whether it offers to reconnect, and to
// disconnect.
using View = std::tuple<std::string, bool, bool>;

struct Model {
  qint64 now = 0;
  std::map<std::string, Computer> computers;
  std::string shown;

  // The kind shown, empty in the grace; none while the shown one is up.
  std::optional<std::string> kind() const {
    const auto computer = computers.find(shown);
    if (shown.empty() || computer == computers.end() || computer->second.online) return std::nullopt;
    if (!computer->second.trying) return "offline";
    if (computer->second.updating) return "updating";
    if (computer->second.otherVersion) return "finishingUpdate";
    if (now - computer->second.downSince >= ComputerNotice::kGraceMs) return "reconnecting";
    return "";
  }
  std::optional<View> view() const {
    const auto shownKind = kind();
    if (!shownKind) return std::nullopt;
    const Computer& computer = computers.at(shown);
    const bool disconnect =
        !computer.local && now - computer.downSince >= ComputerNotice::kDisconnectMs && *shownKind != "updating";
    return View{*shownKind, *shownKind == "offline", disconnect};
  }
  std::optional<qint64> nextDeadline() const {
    if (!kind()) return std::nullopt;
    const qint64 since = computers.at(shown).downSince;
    for (const qint64 deadline : {since + ComputerNotice::kGraceMs, since + ComputerNotice::kDisconnectMs}) {
      if (deadline > now) return deadline;
    }
    return std::nullopt;
  }
};

struct Sut {
  ComputerNotice notice;
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& expected, const Sut& sut) {
  const auto view = expected.view();
  const auto& notice = sut.notice.notice();
  RC_ASSERT(notice.has_value() == view.has_value());
  if (!view) return;
  const auto& [kind, reconnect, disconnect] = *view;
  RC_ASSERT(notice->kind.toStdString() == kind);
  RC_ASSERT(notice->canReconnect == reconnect);
  RC_ASSERT(notice->canDisconnect == disconnect);
  RC_ASSERT(notice->environmentId.toStdString() == expected.shown);
  RC_ASSERT(notice->title.isEmpty() == kind.empty());
  RC_ASSERT(sut.notice.nextDeadline(expected.now) == expected.nextDeadline());
}

// Runs `step` on a copy of the model and the real notice, and checks the two
// agree, and that the notice says it changed exactly when its kind did.
template <typename Step, typename Act>
void runStep(const Model& model, Sut& sut, Step step, Act act) {
  Model expected = model;
  step(expected);
  const bool changed = act(expected.now);
  check(expected, sut);
  RC_ASSERT(changed == (model.view() != expected.view() || (model.view() && model.shown != expected.shown)));
}

// The cluster says what a computer is now.
struct See : Command {
  std::string id = *rc::gen::elementOf(kComputers);
  bool online = *rc::gen::arbitrary<bool>();
  bool updating = *rc::gen::arbitrary<bool>();
  bool otherVersion = *rc::gen::arbitrary<bool>();
  bool trying = *rc::gen::arbitrary<bool>();
  bool local = *rc::gen::arbitrary<bool>();

  explicit See(const Model&) {}

  void apply(Model& model) const override {
    Computer& computer = model.computers[id];
    if (!online && computer.online) computer.downSince = model.now;
    computer.online = online;
    computer.updating = updating;
    computer.otherVersion = otherVersion;
    computer.trying = trying;
    computer.local = local;
  }

  void run(const Model& model, Sut& sut) const override {
    runStep(
        model, sut, [this](Model& m) { apply(m); },
        [&](qint64 now) {
          return sut.notice.see({QString::fromStdString(id), QStringLiteral("Computer ") + QString::fromStdString(id),
                                 online, updating, otherVersion, trying, local},
                                now);
        });
  }

  void show(std::ostream& os) const override {
    os << "See(" << id << (online ? ", online" : ", down") << (updating ? ", updating" : "")
       << (otherVersion ? ", otherVersion" : "") << (trying ? "" : ", given up") << (local ? ", local" : "") << ")";
  }
};

struct Forget : Command {
  std::string id = *rc::gen::elementOf(kComputers);

  explicit Forget(const Model&) {}

  void apply(Model& model) const override { model.computers.erase(id); }

  void run(const Model& model, Sut& sut) const override {
    runStep(
        model, sut, [this](Model& m) { apply(m); },
        [&](qint64 now) { return sut.notice.forget(QString::fromStdString(id), now); });
  }

  void show(std::ostream& os) const override { os << "Forget(" << id << ")"; }
};

// The user opens a thread on another computer, or on none.
struct Show : Command {
  std::string id = *rc::gen::elementOf(std::vector<std::string>{"", "a", "b", "c"});

  explicit Show(const Model&) {}

  void apply(Model& model) const override { model.shown = id; }

  void run(const Model& model, Sut& sut) const override {
    runStep(
        model, sut, [this](Model& m) { apply(m); },
        [&](qint64 now) { return sut.notice.show(QString::fromStdString(id), now); });
  }

  void show(std::ostream& os) const override { os << "Show(" << id << ")"; }
};

struct Advance : Command {
  qint64 by = *rc::gen::elementOf(std::vector<qint64>{0, 500, 1'999, 2'000, 10'000, 7'999, 8'000});

  explicit Advance(const Model&) {}

  void apply(Model& model) const override { model.now += by; }

  void run(const Model& model, Sut& sut) const override {
    runStep(model, sut, [this](Model& m) { apply(m); }, [&](qint64 now) { return sut.notice.advance(now); });
  }

  void show(std::ostream& os) const override { os << "Advance(" << by << ")"; }
};

}  // namespace

class ComputerNoticeProp : public QObject {
  Q_OBJECT

private slots:
  void followsTheShownComputer() {
    QVERIFY(rc::check(
        "the thread's notice follows its computer's state, and a plain "
        "reconnect waits two seconds, and a disconnect 20",
        [] {
          Sut sut;
          rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<See, See, Forget, Show, Advance, Advance>());
        }));
  }
};

HAL_C2_PROP_MAIN(ComputerNoticeProp)
#include "tst_ComputerNoticeProp.moc"
