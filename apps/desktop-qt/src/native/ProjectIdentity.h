#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// How a project is told apart at a glance: the icon the user picked, else a two-character monogram in
// a colour, both derived from its name.
namespace projectidentity {

struct Identity {
  QString monogram;
  QString color;
};

// The automatic monogram and colour of a project called `name`.
Identity derive(const QString& name);
// packages/contracts ProjectIconColor, in the picker's order.
const QStringList& colors();
// The colour as the bricks paint it; gray for one this build does not know.
QString tint(const QString& color);
// The lucide icons the picker offers (those js/lucide.js can draw).
const QStringList& symbols();
// What the user typed as a monogram, as it is saved: NFKC, trimmed, upper case.
QString monogram(const QString& typed);
// One or two letters or numbers (ProjectMonogramText, counted in characters
// as the server counts them).
bool validMonogram(const QString& text);
// A project row's icon for the bricks: {kind (monogram | emoji | lucide),
// text, emoji, name, color, tint, automatic}. A monogram an older server
// keeps as a folder symbol with letters reads as a monogram.
QVariantMap icon(const QJsonObject& projectRow);
// The picked icon as the MC keeps it: a monogram travels as a folder symbol
// carrying its letters, so servers that only know symbols still show it.
QJsonObject wire(const QString& kind, const QString& value, const QString& color);
// Whether a file can be a project's icon, by its extension.
bool isImage(const QString& path);

}  // namespace projectidentity
