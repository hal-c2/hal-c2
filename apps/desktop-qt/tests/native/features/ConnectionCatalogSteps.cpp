// The desktop's build of the saved-environment steps both surfaces share
// (ConnectionCatalogSteps.h), and its own: a damaged record of saved
// environments, and a keyring that refuses to keep a credential.

#include "Harness.h"
#include "SharedSteps.h"
#include "World.h"

#include "ConnectionCatalogSteps.h"

bool savedEnvironmentBlocked(World& world) {
  return connection_catalog::savedEnvironmentBlocked(world);
}

namespace connection_catalog {

const Steps desktopSteps([] {
  // A damaged record of saved environments.
  step(QStringLiteral("the desktop app's record of saved environments is damaged"), [](World& world, const Captures&, const Table&) {
    // Cut off as a crash mid-write leaves it, while the app was closed ("the app starts" is DesktopUpdateSteps').
    const QString path = recordFile(world);
    world.quit();
    catalog(world).damaged = R"({"version": 1, "environments": [{"id": "studio", "label": "Stu)";
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) fail(QStringLiteral("cannot write %1").arg(file.fileName()));
    file.write(catalog(world).damaged);
  });
  step(QStringLiteral("the app starts with no saved environments"), [](World& world, const Captures&, const Table&) {
    expect(listed(world).isEmpty() && saved(world).catalog()->environments().isEmpty(), QStringLiteral("saved environments are %1").arg(describeSaved(world)));
    // And the record file in its place is one it reads.
    QFile file(recordFile(world));
    const bool read = file.open(QIODevice::ReadOnly);
    const QJsonObject records = QJsonDocument::fromJson(file.readAll()).object();
    expect(read && records.value(QStringLiteral("version")) == 1 && records.value(QStringLiteral("environments")).toArray().isEmpty(),
           QStringLiteral("the record file is now %1").arg(QString::fromUtf8(QJsonDocument(records).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("the damaged record is kept apart so it can be inspected"), [](World& world, const Captures&, const Table&) {
    const QString aside = saved(world).catalog()->damaged();
    QFile file(aside);
    expect(!aside.isEmpty() && QFileInfo(aside).absolutePath() == QFileInfo(recordFile(world)).absolutePath() && file.open(QIODevice::ReadOnly) &&
               file.readAll() == catalog(world).damaged,
           QStringLiteral("the damaged record was kept as \"%1\"").arg(aside));
    expect(world.state(QStringLiteral("savedEnvironments")).toMap().value(QStringLiteral("damaged")) == aside,
           QStringLiteral("saved environments are %1").arg(describeSaved(world)));
  });
  step(QStringLiteral("the user can pair again without clearing anything by hand"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("savedEnvironments.pair"), QVariantMap{{QStringLiteral("link"), pairingLink(world)}});
    waitForState(world, kStudio, QStringLiteral("connected"));
    expect(listed(world).size() == 1 && world.secrets->secrets.value(kStudio) == kStudioSession,
           QStringLiteral("saved environments are %1").arg(describeSaved(world)));
  });

  // A keyring that refuses.
  step(QStringLiteral("the system's secure storage is unavailable to the app"), [](World& world, const Captures&, const Table&) {
    world.secrets->refusing = true;
  });
  step(QStringLiteral("the user pairs a new environment"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("savedEnvironments.pair"), QVariantMap{{QStringLiteral("link"), pairingLink(world)}});
    world.waitFor([&] { return !world.state(QStringLiteral("savedEnvironments")).toMap().value(QStringLiteral("pairing")).toBool(); },
                  [&] { return QStringLiteral("the pairing to end; saved environments are %1").arg(describeSaved(world)); });
  });
  step(QStringLiteral("the user is told the environment could not be saved"), [](World& world, const Captures&, const Table&) {
    const QString error = world.state(QStringLiteral("savedEnvironments")).toMap().value(QStringLiteral("error")).toString();
    expect(error == QLatin1String("Studio could not be saved: The system's secure storage is not available."),
           QStringLiteral("the user was told \"%1\"").arg(error));
  });
  step(QStringLiteral("the environment is not listed as saved"), [](World& world, const Captures&, const Table&) {
    expect(listed(world).isEmpty() && !saved(world).catalog()->find(kStudio) && saved(world).client(kStudio) == nullptr,
           QStringLiteral("saved environments are %1").arg(describeSaved(world)));
  });
  step(QStringLiteral("its credential is not written to disk in the clear"), [](World& world, const Captures&, const Table&) {
    const QStringList holding = filesHolding(world.homeDir(), kStudioSession);
    expect(holding.isEmpty() && world.secrets->secrets.isEmpty(),
           QStringLiteral("the credential is in %1").arg(holding.isEmpty() ? QStringLiteral("the keyring") : holding.join(QStringLiteral(", "))));
  });
});

}  // namespace connection_catalog
