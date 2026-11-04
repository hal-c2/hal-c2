// LayoutController as a state machine over what moves the thread list: the
// window's width and interface font, the list's edge dragged or reset, the
// toggle, and a restart reading the device's preferences back. The model is
// the ledger's rule (features/navigation/layout.feature): the list is never
// narrower than its minimum, leaves the thread its room while it is beside
// it, goes slim in a window under 1100, and in a window with no room for both
// keeps a rail beside the thread whose toggle shows the full list over it,
// without that being remembered.

#include "Prop.h"

#include "LayoutController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QTemporaryDir>

#include <algorithm>
#include <limits>
#include <memory>
#include <string>

namespace {

constexpr int kMin = LayoutController::kSidebarMinWidth;
constexpr int kContent = LayoutController::kContentMinWidth;

struct Model {
  // What the device remembers: hidden, and the width chosen (0 for the default).
  bool collapsed = false;
  int chosen = 0;
  // This run's: the window's width (0 until it says), its interface font,
  // and the full list shown over the thread.
  int window = 0;
  bool monospace = false;
  bool overlayOpen = false;

  bool narrow() const { return window > 0 && window < LayoutController::kRailBelow; }
  bool overlay() const { return narrow() && overlayOpen; }
  bool rail() const { return narrow() && !overlayOpen; }
  std::string mode() const {
    if (rail()) return "rail";
    return !narrow() && window > 0 && window < LayoutController::kSlimBelow ? "slim" : "full";
  }
  int fallback() const { return monospace ? LayoutController::kSidebarMonospaceWidth : LayoutController::kSidebarWidth; }
  int room() const { return window > 0 ? std::max(0, window - kContent) : std::numeric_limits<int>::max(); }
  int width() const {
    if (rail()) return LayoutController::kRailWidth;
    return std::max(std::min(chosen > 0 ? chosen : fallback(), room()), kMin);
  }
  bool hidden() const { return collapsed && !overlay(); }
};

struct Shell {
  struct Run {
    ShellBridge bridge;
    NativeShell native{&bridge};
  };
  QTemporaryDir home;
  std::unique_ptr<Run> run;

  Shell() { start(); }

  void start() {
    run.reset();
    run = std::make_unique<Run>();
    run->native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                             home.filePath(QStringLiteral("cache")));
    run->native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    run->native.restoreWindows();
    if (!layout()) qFatal("no LayoutController");
  }

  LayoutController* layout() { return run->native.controller<LayoutController>(); }
  void act(const char* action, const QVariantMap& payload = {}) {
    RC_ASSERT(layout()->handle(QLatin1String(action), payload));
  }
  QVariantMap published() const { return run->bridge.state()->value(QStringLiteral("layout")).toMap(); }
};

void check(const Model& model, Shell& shell) {
  const QVariantMap layout = shell.published();
  const int width = layout.value(QStringLiteral("sidebarWidth")).toInt();
  RC_ASSERT(width == model.width());
  RC_ASSERT(layout.value(QStringLiteral("sidebarMode")).toString().toStdString() == model.mode());
  RC_ASSERT(layout.value(QStringLiteral("sidebarOverlay")).toBool() == model.overlay());
  RC_ASSERT(layout.value(QStringLiteral("sidebarCollapsed")).toBool() == model.hidden());
  RC_ASSERT(shell.layout()->sidebarCollapsed() == model.hidden());
  // Never under its minimum but as the rail, and beside the thread only
  // with room for both.
  if (!model.rail()) RC_ASSERT(width >= kMin);
  if (model.window > 0 && !model.overlay()) RC_ASSERT(width <= model.window - kContent);
  // Only a window with room changes what the device remembers, and the
  // default is never written down.
  auto* settings = shell.run->native.controller<SettingsController>();
  RC_ASSERT(settings->deviceValue(QStringLiteral("sidebarCollapsed")).toBool() == model.collapsed);
  RC_ASSERT(settings->deviceValue(QStringLiteral("sidebarWidth")).toInt() == model.chosen);
}

using Command = rc::state::Command<Model, Shell>;

struct Toggle : Command {
  void apply(Model& model) const override {
    if (model.narrow()) model.overlayOpen = !model.overlayOpen;
    else model.collapsed = !model.collapsed;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.act("sidebar.toggle");
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Toggle"; }
};

struct Resize : Command {
  int width = *rc::gen::inRange(0, 900);

  void apply(Model& model) const override {
    const int clamped = std::max(std::min(width, model.room()), kMin);
    model.chosen = clamped == model.fallback() ? 0 : clamped;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.act("sidebar.resize", {{QStringLiteral("width"), width}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Resize(" << width << ")"; }
};

struct ResetWidth : Command {
  void apply(Model& model) const override { model.chosen = 0; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.act("sidebar.resize");
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "ResetWidth"; }
};

struct Window : Command {
  // Around the edges: the rail's, the slim rows', and the default's room.
  int width = *rc::gen::oneOf(rc::gen::inRange(800, 920), rc::gen::inRange(1040, 1160), rc::gen::inRange(640, 1600));

  void apply(Model& model) const override {
    const bool narrow = model.narrow();
    model.window = width;
    if (model.narrow() != narrow) model.overlayOpen = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.act("layout.window", {{QStringLiteral("width"), width}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Window(" << width << ")"; }
};

// The interface font changes between a proportional and a monospace face.
struct Font : Command {
  bool monospace = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override { model.monospace = monospace; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.act("layout.window", {{QStringLiteral("width"), model.window}, {QStringLiteral("monospace"), monospace}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Font(" << (monospace ? "monospace" : "sans") << ")"; }
};

// The app quits and starts again: the window has yet to say how wide it is.
struct Restart : Command {
  void apply(Model& model) const override {
    model.window = 0;
    model.monospace = false;
    model.overlayOpen = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.start();
    // The first thing a window does.
    shell.act("layout.window", {{QStringLiteral("width"), 0}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class LayoutProp : public QObject {
  Q_OBJECT

private slots:
  void sidebar() {
    QVERIFY(rc::check("the thread list keeps its minimum and the thread its room, or keeps a rail and goes over the thread", [] {
      Shell shell;
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<Toggle, Toggle, Resize, ResetWidth, Window, Window, Font, Restart>());
    }));
  }
};

HAL_C2_PROP_MAIN(LayoutProp)
#include "tst_LayoutProp.moc"
