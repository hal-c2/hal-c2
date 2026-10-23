// The settings pages that follow the window's route (DeviceSettingsController,
// ProjectSettingsController, ScheduledTasksController,
// SourceControlSettingsController) against a fake MC. The user moves between
// settings pages, and the desktop quits and starts again in the same home: the
// window's page is the one section that shows itself open, including right
// after a restart, when the route was restored before the controllers
// activated.

#include "Prop.h"

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

// A page, and the section its controller publishes `open` on (none for a
// page these controllers do not follow).
struct Page {
  const char* route;
  const char* key;
};

constexpr Page kPages[] = {
    {"/settings/general", ""},
    {"/settings/integrations", "deviceSettings"},
    {"/settings/projects", "projectSettings"},
    {"/settings/source-control", "sourceControlSettings"},
    {"/settings/scheduled-tasks", "scheduledTasks"},
    {"/settings/archived", ""},
};
constexpr int kPageCount = sizeof(kPages) / sizeof(kPages[0]);

struct Model {
  int page = 0;
};

// The app on a fake MC, with a home that outlives each start.
struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;

  Sut() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
  }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native->isActive() && native->store()->synchronized(); })) qFatal("the shell did not start");
  }

  void quit() {
    native.reset();
    bridge.reset();
  }

  // A home with no route kept, as a property starts.
  void reset() {
    quit();
    QDir(home.path()).removeRecursively();
    start();
  }

  bool open(const char* key) const { return bridge->state()->value(QString::fromLatin1(key)).toMap().value(QStringLiteral("open")).toBool(); }
};

// Every section is open exactly when the window is on its page.
bool agrees(const Model& model, const Sut& sut) {
  return prop::until([&] {
    for (int i = 0; i < kPageCount; ++i) {
      if (*kPages[i].key && sut.open(kPages[i].key) != (i == model.page)) return false;
    }
    return true;
  });
}

using Command = rc::state::Command<Model, Sut>;

struct GoTo : Command {
  int page = *rc::gen::inRange(0, kPageCount);
  void apply(Model& model) const override { model.page = page; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.native->controller<NavigationController>()->open(NavigationController::Route::settings(QString::fromLatin1(kPages[page].route)));
    RC_ASSERT(agrees(next, sut));
  }
  void show(std::ostream& os) const override { os << "GoTo " << kPages[page].route; }
};

// The desktop quits and starts again: the route is restored before the controllers activate.
struct Restart : Command {
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    sut.quit();
    sut.start();
    RC_ASSERT(agrees(model, sut));
  }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class SettingsRoutesProp : public QObject {
  Q_OBJECT

private slots:
  void sections() {
    Sut sut;
    QVERIFY(rc::check("the open section is the window's page, also after a restart", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<GoTo, GoTo, Restart>());
    }));
  }
};

HAL_C2_PROP_MAIN(SettingsRoutesProp)
#include "tst_SettingsRoutesProp.moc"
