#pragma once

#include <QString>

class FakeMc;

// Makes the source control host `kind` ("gitlab") of the fake's
// `server.discoverSourceControl` (SourceControlSettingsSteps.cpp) installed
// and signed in, or missing.
void setSourceControlHost(FakeMc& mc, const QString& kind, bool ready);
