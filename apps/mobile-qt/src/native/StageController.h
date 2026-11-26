#pragma once

#include <QString>

namespace stage {

// The app's own stage, set by main before the first window: "Dev" for a
// development shell, empty for a release. StageController publishes it.
void setAppStage(const QString& stage);

}  // namespace stage
