#pragma once

#include <QString>

namespace timeline {

// The program a shell command runs, for a live row's "Ran git"
// (client-runtime commandProgramName): shell `-c` wrappers, `env`/`sudo`,
// `timeout` and similar wrappers, Windows shells and setup segments such as
// `cd dir &&` are looked through. Empty when nothing names a program: a bare
// `cd`, control flow, an unbalanced quote.
QString commandProgramName(const QString& command);

}  // namespace timeline
