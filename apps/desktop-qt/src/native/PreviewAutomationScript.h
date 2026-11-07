#pragma once

#include <QJsonObject>
#include <QJsonValue>
#include <QString>

// The scripts PreviewAutomationHost runs in a page. Each answers with one JSON
// string, so what comes back is the same whatever the engine makes of objects.
namespace previewscript {

// The page runtime called as `name(args)` in the isolated world: snapshots,
// locators, typing and the checks a wait polls. It answers
// {"ok": true, "value": ...} or {"ok": false, "kind": ..., "reason"?: ...},
// kind being invalid (a locator the page cannot read), missing (nothing
// visible and enabled matches), notEditable or error.
QString call(const QString& name, const QJsonObject& args);

// `expression` evaluated in the page's own world, its value kept under `key`
// when it is a promise: {"done": true, "value"?: json, "undefined"?: true} |
// {"done": true, "error": message} | {"done": true, "tooLarge": bytes} |
// {"pending": true}. Values over maxBytes of JSON are not sent.
QString evaluate(const QString& expression, const QString& key, int maxBytes);
// What a pending evaluation came to: null while it is pending, else as above.
QString settled(const QString& key);

// The parsed answer of a script, an empty object when it was not one.
QJsonObject parse(const QVariant& result);

}  // namespace previewscript
