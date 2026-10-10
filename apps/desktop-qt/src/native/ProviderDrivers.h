#pragma once

#include <QList>
#include <QPair>
#include <QSet>
#include <QString>
#include <QStringList>

// The provider drivers a user can add an instance of, with the settings each
// one's form shows: the driver options and the
// `providerSettingsForm` annotations of packages/contracts settings.ts, whose
// order and wording these follow. Keep them in step when a driver's settings
// change there.
namespace ProviderDrivers {

// One setting of a driver's `config` blob.
struct Field {
  QString key;
  QString label;
  QString description;
  QString placeholder;
  // text | password | select
  QString control = QStringLiteral("text");
  // A select's choices, {value, label}; the first is the default.
  QList<QPair<QString, QString>> options;
  // An emptied field is kept as "" rather than removed.
  bool keepEmpty = false;
};

// An environment variable the driver's form asks for by name.
struct Variable {
  QString name;
  QString label;
  QString description;
  QString placeholder;
  bool sensitive = false;
};

// A custom model option the driver reads, and its usual choices
// (descriptor presets by kind).
struct Option {
  QString id;
  QString label;
  // select | boolean
  QString type;
  // {id, label}; `defaultChoice` names the default.
  QList<QPair<QString, QString>> choices;
  QString defaultChoice;
};

struct Driver {
  QString id;
  QString label;
  // "Early Access" and the like.
  QString badge;
  // Whether HAL-C2 lists an instance named after the driver without one
  // being added.
  bool builtIn = true;
  QList<Field> fields;
  QList<Variable> variables;
  QList<Option> options;
};

const QList<Driver>& all();
const Driver* find(const QString& id);

// A label as an instance id suffix: lower case, runs of other characters as
// one "_", at most 48 characters.
QString slug(const QString& label);
// The id for a new instance labelled `label`: the driver alone for its own
// label or none, else "<driver>_<slug>", numbered "_2", "_3", … past the taken
// ones; the ACP Registry has no instance of its own, so "acpRegistry_custom".
QString deriveId(const QString& driver, const QString& label, const QSet<QString>& taken);
// Why `id` cannot name a new instance, or empty.
QString validateId(const QString& id, const QSet<QString>& taken);

}  // namespace ProviderDrivers
