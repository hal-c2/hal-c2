// The window's XR workspace (XrController): opening and closing it, and
// XrHost reporting that it could not start (desktop/native-xr.feature). That
// XrHost makes and drops XrWorkspace as `xr` says needs Qt Quick 3D XR and an
// OpenXR runtime; tst_ShellExamples checks it where they are installed.

#include "Harness.h"
#include "World.h"
#include "XrController.h"

namespace {

int recenters(World& world) {
  return world.state(QStringLiteral("xr")).toMap().value(QStringLiteral("recenter")).toInt();
}

bool open(World& world) {
  return world.state(QStringLiteral("xr")).toMap().value(QStringLiteral("open")).toBool();
}

void expectOpen(World& world, bool want) {
  expect(open(world) == want, QStringLiteral("the window's xr is %1").arg(show(world.state(QStringLiteral("xr")))));
}

const Steps steps([] {
  const QString q = kQuoted;
  step(QStringLiteral("the XR workspace is (open|closed)"), [](World& world, const Captures& c, const Table&) {
    const bool want = c[0] == QLatin1String("open");
    if (!world.checking) world.native().controller<XrController>()->setOpen(want);
    expectOpen(world, want);
  });
  step(QStringLiteral("the user toggles the XR workspace"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("xr.toggle"), {});
  });
  step(QStringLiteral("the XR workspace turns to face where the user is looking"), [](World& world, const Captures&, const Table&) {
    expect(recenters(world) == 1, QStringLiteral("the window's xr is %1").arg(show(world.state(QStringLiteral("xr")))));
  });
  step(QStringLiteral("the XR workspace does not turn"), [](World& world, const Captures&, const Table&) {
    expect(recenters(world) == 0, QStringLiteral("the window's xr is %1").arg(show(world.state(QStringLiteral("xr")))));
  });
  step(QStringLiteral("the XR workspace fails to start because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("xr.failed"), QVariantMap{{QStringLiteral("message"), c[0]}});
  });
});

}  // namespace
