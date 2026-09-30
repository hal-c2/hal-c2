// The window's XR workspace (XrController): opening and closing it, and
// XrHost reporting that it could not start (desktop/native-xr.feature). That
// XrHost makes and drops XrWorkspace as `xr` says needs Qt Quick 3D XR and an
// OpenXR runtime, so it is checked on a machine with glasses, not here.

#include "Harness.h"
#include "World.h"
#include "XrController.h"

namespace {

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
  step(QStringLiteral("the XR workspace fails to start because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("xr.failed"), QVariantMap{{QStringLiteral("message"), c[0]}});
  });
});

}  // namespace
