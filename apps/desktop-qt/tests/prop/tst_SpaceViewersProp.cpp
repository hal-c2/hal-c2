// Which page SpaceController says it is on (the `spacePresence` shape), as a state
// machine over what moves it: the Space route opening and closing, the page
// selected, the connection going and coming back, the phone's layout folding, and
// its Space screen saying a page is shown.
//
// After each step the MC has exactly one subscription, to the page on show, or none
// when there is none: the route is open, the client connected, and in the phone's
// layout (steps) the screen says so. What the client shows is who the MC has on that
// page, and nobody with no page on show.

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
const QStringList kDevices = {QStringLiteral("Phone"), QStringLiteral("Laptop")};

QString oneOf(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

struct Model {
  bool open = false;
  bool ready = true;
  bool bySteps = false;
  bool shown = false;
  QString page = kPages.first();
  // Who the MC has on each page.
  QHash<QString, QStringList> devices;

  QString followed() const { return open && ready && (!bySteps || shown) ? page : QString(); }
};

QJsonObject viewersFrame(const Model& model, int id, const QString& page) {
  QStringList devices = model.devices.value(page);
  devices.sort();
  QJsonArray viewers;
  if (!devices.isEmpty()) {
    viewers.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("user")}, {QStringLiteral("devices"), QJsonArray::fromStringList(devices)}});
  }
  return {{QStringLiteral("t"), QStringLiteral("spacePresence")}, {QStringLiteral("id"), id}, {QStringLiteral("viewers"), viewers}};
}

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  // What the fake MC answers a new subscriber from: the model as of the running step.
  Model told;

  Shell() {
    mc.onShape(QStringLiteral("spacePresence"), [this](int id, const QJsonObject& shape) {
      mc.send(viewersFrame(told, id, shape.value(QLatin1String("pageId")).toString()));
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.client()->isReady(); })) qFatal("the shell did not connect");
    feedPages();
  }

  SpaceController* space() { return native.controller<SpaceController>(); }

  // The Space and its pages, as its streams would bring them; the fake serves no stream.
  void feedPages() {
    const QJsonObject spaceRow{{QStringLiteral("id"), kSpaceId}, {QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    space()->receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                           {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{QStringLiteral("space"), kSpaceId, spaceRow})}},
                           {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    space()->selectSpace(kSpaceId);
    QJsonArray rows;
    for (const QString& id : kPages) {
      rows.append(QJsonArray{QStringLiteral("page"), id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("parentPageId"), QJsonValue::Null},
                                         {QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")}}});
    }
    space()->receiveSpace({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
                           {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    space()->selectPage(kPages.first());
  }

  QStringList subscribedPages() const {
    QStringList pages;
    for (const int id : mc.subscribers(QStringLiteral("spacePresence"))) pages.append(mc.shapeOf(id).value(QLatin1String("pageId")).toString());
    return pages;
  }

  // Waits for the client to settle on what the model says, then holds it to that.
  void check(const Model& model) {
    const QString followed = model.followed();
    const QStringList pages = followed.isEmpty() ? QStringList() : QStringList{followed};
    QStringList devices = followed.isEmpty() ? QStringList() : model.devices.value(followed);
    devices.sort();
    const auto settled = [&] {
      return native.client()->isReady() == model.ready && subscribedPages() == pages && space()->viewers().value(QStringLiteral("devices")).toStringList() == devices;
    };
    prop::until(settled);
    RC_ASSERT(native.client()->isReady() == model.ready);
    RC_ASSERT(subscribedPages() == pages);
    RC_ASSERT(space()->viewers().value(QStringLiteral("devices")).toStringList() == devices);
    RC_ASSERT(space()->pageId() == model.page);
  }
};

using Command = rc::state::Command<Model, Shell>;

struct SetRoute : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    if (model.open && !open) model.shown = false;
    model.open = open;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    shell.native.controller<NavigationController>()->open(NavigationController::Route::of(open ? QStringLiteral("space") : QStringLiteral("usage")));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SetRoute(" << open << ")"; }
};

struct SelectPage : Command {
  QString page = oneOf(kPages);
  void apply(Model& model) const override { model.page = page; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), page}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "SelectPage(" << page.toStdString() << ")"; }
};

// The phone folding (steps decide) or unfolding (the selected page is on show).
struct Fold : Command {
  bool bySteps = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.bySteps = bySteps; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    shell.space()->setPageShownBySteps(bySteps);
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "Fold(" << bySteps << ")"; }
};

struct PageShown : Command {
  bool shown = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.shown = shown; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    RC_ASSERT(shell.space()->handle(QStringLiteral("space.pageShown"), QVariantMap{{QStringLiteral("shown"), shown}}));
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "PageShown(" << shown << ")"; }
};

struct GoOffline : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.ready); }
  void apply(Model& model) const override { model.ready = false; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    shell.mc.stopAccepting();
    shell.mc.drop();
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "GoOffline"; }
};

struct GoOnline : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.ready); }
  void apply(Model& model) const override { model.ready = true; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    shell.mc.startAccepting();
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "GoOnline"; }
};

// A device comes to a page, or leaves it; only that page's subscriber hears.
struct DeviceMoves : Command {
  QString page = oneOf(kPages);
  QString device = oneOf(kDevices);
  void checkPreconditions(const Model& model) const override { RC_PRE(model.ready); }
  void apply(Model& model) const override {
    QStringList& devices = model.devices[page];
    if (!devices.removeOne(device)) devices.append(device);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.told = expected;
    for (const int id : shell.mc.subscribers(QStringLiteral("spacePresence"))) {
      if (shell.mc.shapeOf(id).value(QLatin1String("pageId")).toString() == page) shell.mc.send(viewersFrame(expected, id, page));
    }
    shell.check(expected);
  }
  void show(std::ostream& os) const override { os << "DeviceMoves(" << device.toStdString() << ", " << page.toStdString() << ")"; }
};

}  // namespace

class SpaceViewersProp : public QObject {
  Q_OBJECT

private slots:
  void followsThePageOnShow() {
    QVERIFY(rc::check("the client is on the page on show, and only that page, whatever moved", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<SetRoute, SetRoute, SelectPage, Fold, PageShown, PageShown, GoOffline, GoOnline, DeviceMoves>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceViewersProp)
#include "tst_SpaceViewersProp.moc"
