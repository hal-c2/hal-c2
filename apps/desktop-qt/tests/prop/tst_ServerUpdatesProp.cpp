// ServerUpdates as a state machine over what the user does to the cluster's
// servers (update one, Update all, copy the command, answer the question) and
// what comes back (each server's answer, a server going offline), in any
// order. The model is the ledger's rule (features/settings/updates.feature,
// "Updating a server"): a server is called at most once at a time and only
// when it can update from here, a desktop app is never relaunched without a
// yes, a newer question replaces an unanswered one, and every answer is
// reported exactly once, for the server it came from.

#include "Prop.h"

#include "ServerUpdates.h"

#include <array>
#include <optional>
#include <utility>

namespace {

constexpr int kMachines = 4;
const QString kApp = QStringLiteral("1.4.0");
// One machine per way of updating.
const std::array<QString, kMachines> kSelfUpdate{QStringLiteral("boot-service"), QStringLiteral("desktop-managed"),
                                                 QStringLiteral("desktop-managed"), QString()};
const std::array<bool, kMachines> kDesktopAppUpdate{false, true, false, false};

QString idOf(int machine) {
  return QStringLiteral("env-%1").arg(machine);
}

QString labelOf(int machine) {
  return QStringLiteral("machine %1").arg(machine);
}

struct Model {
  std::array<bool, kMachines> behind{};
  std::array<bool, kMachines> online{true, true, true, true};
  std::array<bool, kMachines> updating{};
  // The question on screen: the machines a yes starts, or none.
  std::optional<QList<int>> question;
  bool copyFails = false;
  int toasts = 0;

  QString path(int machine) const {
    return ServerUpdates::path({idOf(machine), labelOf(machine), QString(), kSelfUpdate[machine], kDesktopAppUpdate[machine], true});
  }
  bool offered(int machine) const { return online[machine] && behind[machine] && !updating[machine]; }
  bool updatable(int machine) const {
    return offered(machine) && (path(machine) == QLatin1String("update") || path(machine) == QLatin1String("desktop"));
  }
};

struct Toast {
  QString type;
  QString title;
  QString description;
};

struct Sut {
  ServerUpdates updates;
  QHash<QString, ServerUpdates::Done> calls;
  QHash<QString, QString> targets;
  std::optional<std::function<void()>> accepted;
  QString question;
  QList<Toast> toasts;
  bool copyFails = false;
  QString clipboard;

  explicit Sut(const Model& model)
      : updates(ServerUpdates::Effects{
            .call =
                [this](const QString& id, const QString& target, ServerUpdates::Done done) {
                  // Never a second call to a server already updating.
                  RC_ASSERT(!calls.contains(id));
                  calls.insert(id, std::move(done));
                  targets.insert(id, target);
                },
            .confirm =
                [this](const QString& title, const QString&, std::function<void()> yes) {
                  question = title;
                  accepted = std::move(yes);
                },
            .toast = [this](const QString& type, const QString& title,
                            const QString& description) { toasts.append({type, title, description}); },
            .copy =
                [this](const QString& text) {
                  if (copyFails) return false;
                  clipboard = text;
                  return true;
                },
        }) {
    updates.setAppVersion(kApp);
    describe(model);
  }

  void describe(const Model& model) {
    QList<ServerUpdates::Machine> machines;
    for (int n = 0; n < kMachines; ++n) {
      machines.append({idOf(n), labelOf(n), model.behind[n] ? QStringLiteral("1.3.0") : kApp, kSelfUpdate[n], kDesktopAppUpdate[n],
                       model.online[n]});
    }
    updates.setMachines(machines);
  }
};

void check(const Model& model, const Sut& sut) {
  for (int n = 0; n < kMachines; ++n) {
    RC_ASSERT(sut.updates.updating(idOf(n)) == model.updating[n]);
    RC_ASSERT(sut.calls.contains(idOf(n)) == model.updating[n]);
    if (model.updating[n]) RC_ASSERT(sut.targets.value(idOf(n)) == kApp);
  }
  RC_ASSERT(sut.accepted.has_value() == model.question.has_value());
  RC_ASSERT(sut.toasts.size() == model.toasts);
  int updatable = 0;
  for (int n = 0; n < kMachines; ++n) updatable += model.updatable(n) ? 1 : 0;
  RC_ASSERT(sut.updates.state().value(QStringLiteral("updatable")).toInt() == updatable);
}

using Command = rc::state::Command<Model, Sut>;

struct Update : Command {
  int machine = *rc::gen::inRange(0, kMachines);

  void apply(Model& model) const override {
    if (!model.offered(machine)) return;
    const QString path = model.path(machine);
    if (path == QLatin1String("command")) {
      ++model.toasts;
    } else if (path == QLatin1String("update")) {
      model.updating[machine] = true;
    } else if (path == QLatin1String("desktop")) {
      model.question = QList<int>{machine};
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    const qsizetype before = sut.toasts.size();
    sut.updates.update(idOf(machine));
    if (model.offered(machine) && model.path(machine) == QLatin1String("command")) {
      // The command for this app's version, said to be run on that machine.
      const Toast& toast = sut.toasts.at(before);
      RC_ASSERT(toast.type == (model.copyFails ? QLatin1String("error") : QLatin1String("success")));
      RC_ASSERT(toast.description.contains(QStringLiteral("npx hal-c2@") + kApp) && toast.description.contains(labelOf(machine)));
      if (!model.copyFails) RC_ASSERT(sut.clipboard == QStringLiteral("npx hal-c2@") + kApp);
    }
    if (expected.question != model.question) RC_ASSERT(sut.question.contains(labelOf(machine)));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Update(" << machine << ")"; }
};

struct UpdateAll : Command {
  void apply(Model& model) const override {
    QList<int> eligible;
    bool desktop = false;
    for (int n = 0; n < kMachines; ++n) {
      if (!model.updatable(n)) continue;
      eligible.append(n);
      desktop = desktop || model.path(n) == QLatin1String("desktop");
    }
    if (eligible.isEmpty()) return;
    if (desktop) {
      model.question = eligible;
      return;
    }
    for (int n : eligible) model.updating[n] = true;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.updates.updateAll();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "UpdateAll"; }
};

struct Answer : Command {
  bool yes = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (!model.question) return;
    if (yes) {
      for (int n : *model.question) model.updating[n] = true;
    }
    model.question.reset();
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    if (sut.accepted) {
      const auto accepted = *std::exchange(sut.accepted, std::nullopt);
      if (yes) accepted();
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Answer(" << (yes ? "yes" : "no") << ")"; }
};

struct Reply : Command {
  int machine = *rc::gen::inRange(0, kMachines);
  bool ok = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    if (!model.updating[machine]) return;
    model.updating[machine] = false;
    ++model.toasts;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    if (sut.calls.contains(idOf(machine))) {
      const ServerUpdates::Done done = sut.calls.take(idOf(machine));
      sut.targets.remove(idOf(machine));
      done({ok, kApp, ok ? QString() : QStringLiteral("Disk is full")});
      // Reported for the machine that answered, with what it said.
      const Toast& toast = sut.toasts.last();
      RC_ASSERT(toast.type == (ok ? QLatin1String("success") : QLatin1String("error")));
      if (ok) {
        RC_ASSERT(toast.title == QStringLiteral("%1 updated").arg(labelOf(machine)));
        RC_ASSERT(toast.description == (kSelfUpdate[machine] == QLatin1String("desktop-managed") ? QStringLiteral("Desktop app relaunched on %1.").arg(kApp)
                                                                                                 : QStringLiteral("Reconnected on hal-c2@%1.").arg(kApp)));
      } else {
        RC_ASSERT(toast.description == QLatin1String("Disk is full"));
      }
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Reply(" << machine << ", " << (ok ? "ok" : "failed") << ")"; }
};

struct Copy : Command {
  int machine = *rc::gen::inRange(0, kMachines);

  void apply(Model& model) const override { ++model.toasts; }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.updates.copyCommand(idOf(machine));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Copy(" << machine << ")"; }
};

// A server goes offline or comes back, or the clipboard starts or stops refusing.
struct World : Command {
  int machine = *rc::gen::inRange(0, kMachines);
  bool online = *rc::gen::arbitrary<bool>();
  bool copyFails = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override {
    model.online[machine] = online;
    model.copyFails = copyFails;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.copyFails = copyFails;
    sut.describe(expected);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "World(" << machine << (online ? " online" : " offline") << ")"; }
};

}  // namespace

class ServerUpdatesProp : public QObject {
  Q_OBJECT

private slots:
  void servers() {
    QVERIFY(rc::check("each server is updated once at a time, desktop apps only on a yes, every answer reported once", [] {
      Model model;
      for (int n = 0; n < kMachines; ++n) model.behind[n] = *rc::gen::arbitrary<bool>();
      Sut sut(model);
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Update, Update, UpdateAll, Answer, Reply, Reply, Copy, World>());
    }));
  }
};

HAL_C2_PROP_MAIN(ServerUpdatesProp)
#include "tst_ServerUpdatesProp.moc"
