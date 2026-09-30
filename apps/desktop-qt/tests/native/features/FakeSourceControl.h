#pragma once

#include <QString>

class FakeNode;

// Makes the source control host `kind` ("gitlab") of the fake's
// `server.discoverSourceControl` (SourceControlSettingsSteps.cpp) installed
// and signed in, or missing.
void setSourceControlHost(FakeNode& node, const QString& kind, bool ready);
