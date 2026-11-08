// The options of the chosen model as the composer's controls show them: the
// provider's default marked, and an effort the prompt carries
// (features/composer/model-and-mode.feature).

#include <QQuickItem>
#include <QStringList>

#include "Brick.h"
#include "ComposerBrick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

QQuickItem* effortPicker(World& world) {
  composerBrick(world);
  QQuickItem* picker = composerPart(world, QStringLiteral("effortPicker"));
  expect(picker && picker->isVisible(), QStringLiteral("the composer shows no effort picker"));
  return picker;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Choosing another effort takes Ultrathink off the prompt.
  step(QStringLiteral("the draft reads %1 without %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return composerEditor(world)->property("text").toString() == c[0]; },
                  [&] { return QStringLiteral("the draft to read \"%1\"; it reads \"%2\"").arg(c[0], composerEditor(world)->property("text").toString()); });
    expect(!composerEditor(world)->property("text").toString().contains(c[1]), QStringLiteral("the draft still holds \"%1\"").arg(c[1]));
  });

  // The provider's default.
  step(QStringLiteral("the user opens the model's options"), [](World& world, const Captures&, const Table&) { effortPicker(world); });
  step(QStringLiteral("the provider's default effort is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList labels = effortPicker(world)->property("model").toStringList();
    const QStringList marked = labels.filter(QStringLiteral("(%1)").arg(c[0]));
    expect(marked.size() == 1 && marked.first().startsWith(QLatin1String("medium")), QStringLiteral("only the default marked \"%1\"; the effort offers %2").arg(c[0], labels.join(QStringLiteral(", "))));
  });
});

}  // namespace
