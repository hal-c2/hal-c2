// This device's saved themes (ThemeController: saveCustom, duplicate,
// duplicateStandard, removeCustom) against a model of which themes are saved.
// The user saves new themes under names that collide with each other and with
// the built-ins, duplicates any theme offered and the standard look, removes
// saved themes, edit them in place, paste theme files in, flip the system between
// light and dark, and (once) an old install has a saved theme that took the standard look's id. After every step
// the saved ids are the ones the model says, each is stored once, a theme saved
// or duplicated as new never takes the standard look's id or an id already
// stored, and a copy of the standard look draws the standard colors whatever is
// saved.

#include "Prop.h"

#include <QJsonDocument>
#include <QTemporaryDir>

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ThemeController.h"

namespace prop = halc2::prop;

namespace {

const QString kStandard = QStringLiteral("hal-c2");
const QStringList kNames{QStringLiteral("Aurora"), QStringLiteral("HAL-C2"), QStringLiteral("Aurora copy"), QStringLiteral("Nord"),
                         QStringLiteral("Default")};

struct Model {
  QStringList builtIns;   // the ids the built-in themes offer
  int saved = 0;          // how many themes are stored on this device
  bool imposter = false;  // an old install's saved theme was put in, once
  int imports = 0;        // theme files pasted in, which name the next one
};

// The app's theme controller on a home of its own, with the system light.
struct Sut {
  QTemporaryDir home;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QMap<bool, QVariantMap> standard;  // by whether the system is dark: the standard look's colors

  Sut() {
    settings()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    for (const bool dark : {false, true}) {
      themes()->setSystemDark(dark);
      standard.insert(dark, themes()->draft(kStandard).value(QStringLiteral("colors")).toMap());
    }
    themes()->setSystemDark(false);
  }

  SettingsController* settings() { return native.controller<SettingsController>(); }
  ThemeController* themes() { return native.controller<ThemeController>(); }

  QJsonArray stored() { return settings()->deviceSettings().value(QStringLiteral("customThemes")).toArray(); }
  QStringList storedIds() {
    QStringList ids;
    for (const QJsonValue& value : stored()) ids.append(value.toObject().value(QLatin1String("id")).toString());
    return ids;
  }
  QStringList builtInIds() {
    QStringList ids;
    for (const QVariant& entry : themes()->available()) {
      const QVariantMap map = entry.toMap();
      if (map.value(QStringLiteral("source")) == QLatin1String("builtIn")) ids.append(map.value(QStringLiteral("id")).toString());
    }
    return ids;
  }
};

QVariantMap draft(const QString& label, const QString& appearance) {
  return {{QStringLiteral("label"), label},
          {QStringLiteral("appearance"), appearance},
          {QStringLiteral("colors"), QVariantMap{{QStringLiteral("canvas"), QStringLiteral("#101010")}, {QStringLiteral("accent"), QStringLiteral("#ff8800")}}}};
}

using Command = rc::state::Command<Model, Sut>;

// Each stored id is stored once, and as many are stored as the model says.
void verify(const Model& m, Sut& sut) {
  const QStringList ids = sut.storedIds();
  RC_ASSERT(QSet<QString>(ids.begin(), ids.end()).size() == ids.size());
  RC_ASSERT(int(ids.size()) == m.saved);
}

// What a new id may not be: one stored, a built-in's, or the standard look's.
void checkNew(const Model& m, const QStringList& before, const QString& id) {
  RC_ASSERT(!id.isEmpty());
  RC_ASSERT(id != kStandard);
  RC_ASSERT(!before.contains(id));
  RC_ASSERT(!m.builtIns.contains(id));
}

// A new theme under a name that may be taken.
struct Save : Command {
  QString name;
  bool darkTheme;
  explicit Save(const Model&) : name(kNames.at(*rc::gen::inRange<int>(0, int(kNames.size())))), darkTheme(*rc::gen::arbitrary<bool>()) {}
  void apply(Model& m) const override { m.saved++; }
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    const QString id = sut.themes()->saveCustom(draft(name, darkTheme ? QStringLiteral("dark") : QStringLiteral("light")));
    checkNew(m0, before, id);
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Save(" << name.toStdString() << (darkTheme ? ", dark" : ", light") << ")"; }
};

// An editable copy of any theme offered: a built-in, or one saved. The standard
// look is copied by DuplicateStandard, so an imposter's id is not offered here.
struct Duplicate : Command {
  int pick;
  explicit Duplicate(const Model&) : pick(*rc::gen::inRange<int>(0, 1000)) {}
  void apply(Model& m) const override { m.saved++; }
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    QStringList offered = m0.builtIns + before;
    offered.removeAll(kStandard);
    const QString source = offered.at(pick % offered.size());
    const QString id = sut.themes()->duplicate(source);
    checkNew(m0, before, id);
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Duplicate(" << pick << ")"; }
};

// A copy of the standard look as drawn now, whatever themes are saved.
struct DuplicateStandard : Command {
  void apply(Model& m) const override { m.saved++; }
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    const QString id = sut.themes()->duplicateStandard();
    checkNew(m0, before, id);
    RC_ASSERT(sut.themes()->draft(id).value(QStringLiteral("colors")).toMap() == sut.standard.value(sut.themes()->appearance() == QLatin1String("dark")));
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "DuplicateStandard"; }
};

struct Remove : Command {
  int pick;
  explicit Remove(const Model&) : pick(*rc::gen::inRange<int>(0, 1000)) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.saved > 0); }
  void apply(Model& m) const override { m.saved--; }
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    RC_ASSERT(sut.themes()->removeCustom(before.at(pick % before.size())));
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Remove(" << pick << ")"; }
};

struct SetDark : Command {
  bool dark;
  explicit SetDark(const Model&) : dark(*rc::gen::arbitrary<bool>()) {}
  void apply(Model&) const override {}
  void run(const Model& m0, Sut& sut) const override {
    sut.themes()->setSystemDark(dark);
    verify(m0, sut);
  }
  void show(std::ostream& os) const override { os << "SetDark(" << dark << ")"; }
};

// A saved theme edited in place: its draft carries its id, so nothing new is stored
// and the ids stay the same, an imposter's among them.
struct Edit : Command {
  int pick;
  explicit Edit(const Model&) : pick(*rc::gen::inRange<int>(0, 1000)) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.saved > 0); }
  void apply(Model&) const override {}
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    const QString target = before.at(pick % before.size());
    QVariantMap edited = draft(QStringLiteral("Edited"), QStringLiteral("dark"));
    edited.insert(QStringLiteral("id"), target);
    RC_ASSERT(sut.themes()->saveCustom(edited) == target);
    RC_ASSERT(sut.storedIds() == before);
    verify(m0, sut);
  }
  void show(std::ostream& os) const override { os << "Edit(" << pick << ")"; }
};

// A theme file pasted in under a name of its own, sometimes asking for the standard
// look's id: it is added, or refused for that id.
struct Import : Command {
  int n;
  bool claimsStandard;
  explicit Import(const Model& m) : n(m.imports), claimsStandard(*rc::gen::arbitrary<bool>()) {}
  void apply(Model& m) const override {
    m.imports++;
    if (!claimsStandard) m.saved++;
  }
  void run(const Model& m0, Sut& sut) const override {
    const QStringList before = sut.storedIds();
    QJsonObject file{{QStringLiteral("version"), 1},
                     {QStringLiteral("name"), QStringLiteral("Imported %1").arg(n)},
                     {QStringLiteral("appearance"), QStringLiteral("dark")},
                     {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#101010")}}}};
    if (claimsStandard) file.insert(QStringLiteral("id"), kStandard);
    RC_ASSERT(sut.themes()->importText(QString::fromUtf8(QJsonDocument(file).toJson())) == !claimsStandard);
    sut.themes()->clearImport();
    if (!claimsStandard) {
      QStringList fresh = sut.storedIds();
      for (const QString& id : before) fresh.removeOne(id);
      RC_ASSERT(fresh.size() == 1);
      checkNew(m0, before, fresh.first());
    }
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Import(" << n << (claimsStandard ? ", hal-c2" : "") << ")"; }
};

// An install from before the standard look's id was kept from new themes.
struct Imposter : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.imposter); }
  void apply(Model& m) const override {
    m.imposter = true;
    m.saved++;
  }
  void run(const Model& m0, Sut& sut) const override {
    QJsonObject device = sut.settings()->deviceSettings();
    QJsonArray saved = device.value(QStringLiteral("customThemes")).toArray();
    saved.append(QJsonObject{{QStringLiteral("id"), kStandard},
                             {QStringLiteral("label"), QStringLiteral("Imposter")},
                             {QStringLiteral("appearance"), QStringLiteral("dark")},
                             {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#112233")}}}});
    device.insert(QStringLiteral("customThemes"), saved);
    sut.settings()->setDeviceSettings(device);
    Model expected = m0;
    apply(expected);
    verify(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Imposter"; }
};

}  // namespace

class ThemeLibraryProp : public QObject {
  Q_OBJECT

private slots:
  void library() {
    QVERIFY(rc::check("saved themes keep their ids unique, and never take the standard look's", [] {
      Sut sut;
      Model model;
      model.builtIns = sut.builtInIds();
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Save, Save, Duplicate, Duplicate, DuplicateStandard, Remove, SetDark, Imposter, Edit, Import>());
    }));
  }
};

HAL_C2_PROP_MAIN(ThemeLibraryProp)
#include "tst_ThemeLibraryProp.moc"
