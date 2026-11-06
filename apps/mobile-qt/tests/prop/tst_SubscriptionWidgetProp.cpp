// The Subscription usage widget's side in the app (src/SubscriptionWidget)
// against a model of the home screen, the app coming to the front and going
// away, the pooled limits UsageController hears, and the user's choice of
// windows per provider, in any order: every environment's limits are followed
// exactly while a widget is placed and the app is in front, a placed widget
// always draws what the latest limits and choices say, and the app says what
// it knows of the widget.

#include "Prop.h"

#include <QDir>
#include <QTemporaryDir>
#include <qpa/qwindowsysteminterface.h>

#include <memory>

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SubscriptionWidget.h"
#include "UsageController.h"
#include "features/FakeWidgetSystem.h"

namespace {

using S = QString;

const QStringList kDrivers{S("codex"), S("claudeAgent")};
const QStringList kShows{S("session"), S("weekly"), S("both")};

// Pooled limits as UsageController says them: some of the providers, each
// with a session window, a weekly one, or both.
rc::Gen<QVariantMap> genLimits() {
  return rc::gen::exec([] {
    QVariantList pools;
    for (const QString& driver : kDrivers) {
      if (!*rc::gen::arbitrary<bool>()) continue;
      const int which = *rc::gen::inRange(0, 3);
      QVariantList windows;
      for (int k = 0; k < 2; ++k) {
        if (which != 2 && which != k) continue;
        const bool session = k == 0;
        QVariantList accounts;
        for (int a = *rc::gen::inRange(1, 3); a > 0; --a) accounts.append(QVariantMap{{S("name"), S("account %1").arg(a)}});
        windows.append(QVariantMap{{S("key"), driver + (session ? S(":session") : S(":weekly"))},
                                   {S("kind"), session ? S("session") : S("weekly")},
                                   {S("label"), session ? S("5-hour") : S("Weekly")},
                                   {S("remainingPercent"), *rc::gen::inRange(0, 101)},
                                   {S("resetsAt"), session ? S("2026-09-23T11:00:00.000Z") : S("2026-09-26T10:00:00.000Z")},
                                   {S("accounts"), accounts}});
      }
      pools.append(QVariantMap{{S("driver"), driver}, {S("label"), driver}, {S("windows"), windows}});
    }
    return QVariantMap{{S("pools"), pools}, {S("notices"), QVariantList()}};
  });
}

QJsonObject undated(QJsonObject snapshot) {
  snapshot.remove(S("checkedAt"));
  return snapshot;
}

struct Model {
  int home = 0;          // widgets on the home screen
  bool placed = false;   // what the app last found there
  bool active = false;
  QVariantMap limits;    // the latest heard; empty before any
  QHash<QString, QString> shows;
  QJsonObject drawn;     // what the widget draws, undated
  int draws = 0;         // how many snapshots it was given

  // A placed widget is given what is known as soon as it differs.
  void redraw() {
    if (!placed || limits.isEmpty()) return;
    const QJsonObject next = undated(usage_widget::snapshot(limits, QDateTime(), shows));
    if (next == drawn) return;
    drawn = next;
    ++draws;
  }
};

struct Sut {
  Sut() : home(QDir::tempPath() + S("/widget-XXXXXX")) {
    bridge = std::make_unique<ShellBridge>();
    shell = std::make_unique<NativeShell>(bridge.get());
    shell->controller<SettingsController>()->setDevicePath(QDir(home.path()).filePath(S("preferences.json")));
    stateTo(Qt::ApplicationSuspended);
    widget = std::make_unique<SubscriptionWidget>(bridge.get(), shell.get(), system);
  }
  ~Sut() {
    widget.reset();
    shell.reset();
    bridge.reset();
    halc2::prop::settle();
  }

  static void stateTo(Qt::ApplicationState state) {
    QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(state);
  }

  UsageController* usage() const { return shell->controller<UsageController>(); }

  void check(const Model& m) const {
    RC_ASSERT(usage()->followsAll() == (m.placed && m.active));
    RC_ASSERT(static_cast<int>(system->shown.size()) == m.draws);
    if (m.draws > 0) RC_ASSERT(undated(system->drawn()) == m.drawn);
    const QVariantMap said = bridge->state()->value(S("usageWidget")).toMap();
    RC_ASSERT(said.value(S("placed")).toBool() == m.placed);
    const QVariantList providers = said.value(S("providers")).toList();
    const QVariantList pools = m.limits.value(S("pools")).toList();
    RC_ASSERT(providers.size() == pools.size());
    for (const QVariant& provider : providers) {
      const QString driver = provider.toMap().value(S("driver")).toString();
      RC_ASSERT(provider.toMap().value(S("show")).toString() == m.shows.value(driver, S("both")));
    }
  }

  QTemporaryDir home;
  std::shared_ptr<FakeWidgetSystem> system = std::make_shared<FakeWidgetSystem>();
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  std::unique_ptr<SubscriptionWidget> widget;
};

using Command = rc::state::Command<Model, Sut>;

// The user adds widgets to the home screen or takes them away; the app finds
// out when it next comes or goes.
struct Place : Command {
  int count = *rc::gen::inRange(0, 3);
  explicit Place(const Model&) {}
  void apply(Model& m) const override { m.home = count; }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.system->count = count;
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Place(" << count << ")"; }
};

struct Front : Command {
  bool active = *rc::gen::arbitrary<bool>();
  explicit Front(const Model&) {}
  void apply(Model& m) const override {
    if (active == m.active) return;
    m.active = active;
    m.placed = m.home > 0;
    m.redraw();
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    Sut::stateTo(active ? Qt::ApplicationActive : Qt::ApplicationSuspended);
    s.check(next);
  }
  void show(std::ostream& os) const override { os << (active ? "Front" : "Away"); }
};

// UsageController hears every environment's limits anew.
struct Hear : Command {
  QVariantMap limits = *genLimits();
  explicit Hear(const Model&) {}
  void apply(Model& m) const override {
    m.limits = limits;
    m.redraw();
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    emit s.usage()->allLimitsChanged(limits);
    s.check(next);
  }
  void show(std::ostream& os) const override { showValue(QVariant(limits), os); }
};

// The user chooses a provider's windows in Usage → Limits.
struct Choose : Command {
  QString driver = kDrivers.at(*rc::gen::inRange(0, static_cast<int>(kDrivers.size())));
  QString choice = kShows.at(*rc::gen::inRange(0, static_cast<int>(kShows.size())));
  explicit Choose(const Model&) {}
  void apply(Model& m) const override {
    m.shows.insert(driver, choice);
    m.redraw();
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.bridge->dispatch(S("usageWidget.show"), QVariantMap{{S("driver"), driver}, {S("show"), choice}});
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Choose(" << driver.toStdString() << ", " << choice.toStdString() << ")"; }
};

}  // namespace

class SubscriptionWidgetProp : public QObject {
  Q_OBJECT

private slots:
  void widget() {
    QVERIFY(rc::check("the widget follows and draws what the model says", [] {
      Model model;
      Sut sut;
      sut.check(model);
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Place, Front, Front, Hear, Hear, Choose>());
    }));
  }
};

HAL_C2_PROP_MAIN(SubscriptionWidgetProp)
#include "tst_SubscriptionWidgetProp.moc"
