// SettingsController's device preferences as a state machine of two desktops on
// one home (two processes of it, or desktop-qt beside the Ljós desktop), which
// share preferences.json: each saves preferences, hears the other's saves only
// once its event loop runs, and quits and starts again; and the file is broken
// by hand and repaired. The model is the ledger's rule
// (features/settings/saving-settings.feature): the file holds every preference
// as it was last saved, by either, down to one entry of an object (one
// provider's models beside another's), and a desktop that has heard of a save,
// or started after it, shows it. A save of the value a desktop already shows
// changes nothing, even if the other saved another since. While the file does
// not read, a desktop that has found that out refuses saves and keeps what it
// showed, until it hears the file read again, or hears it deleted: then the
// next save writes what that desktop shows, with its change.

#include "Prop.h"

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QFile>
#include <QJsonDocument>
#include <QSaveFile>
#include <QTemporaryDir>

#include <array>
#include <functional>
#include <memory>
#include <optional>
#include <string>

namespace prop = halc2::prop;

namespace {

const std::array<std::string, 3> kKeys{"appearance", "timestampFormat", "fontSizeInterface"};
// Empty removes the preference.
const std::array<std::string, 3> kValues{"", "one", "two"};
// A preference whose value is an object each save changes one entry of, as
// providerModelPreferences is. No desktop holds it until one saves an entry.
const QString kObject = QStringLiteral("providerModelPreferences");
const std::array<std::string, 2> kEntries{"codex", "claude"};

QJsonValue jsonOf(const std::string& value) {
  return value.empty() ? QJsonValue(QJsonValue::Undefined) : QJsonValue(QString::fromStdString(value));
}

struct Model {
  // preferences.json as last saved, and what each desktop holds.
  QJsonObject file;
  std::array<QJsonObject, 2> view;
  // The file is broken by hand; and which desktop has found that out.
  bool broken = false;
  // The file was deleted since it was last written.
  bool gone = false;
  std::array<bool, 2> unreadable{false, false};
};

struct Desktop {
  ShellBridge bridge;
  NativeShell native{&bridge};
  SettingsController* settings() { return native.controller<SettingsController>(); }
};

struct Sut {
  QTemporaryDir home;
  std::array<std::unique_ptr<Desktop>, 2> desktops;

  QString path() const { return home.filePath(QStringLiteral("preferences.json")); }

  void start(int i) {
    desktops[i].reset();
    desktops[i] = std::make_unique<Desktop>();
    desktops[i]->settings()->setDevicePath(path());
  }

  // As another app, or a person, saves it.
  void write(const QByteArray& bytes) const {
    QSaveFile file(path());
    RC_ASSERT(file.open(QIODevice::WriteOnly));
    RC_ASSERT(file.write(bytes) == bytes.size());
    RC_ASSERT(file.commit());
  }

  QByteArray bytes() const {
    QFile file(path());
    if (!file.open(QIODevice::ReadOnly)) return {};
    return file.readAll();
  }
  QJsonObject file() const { return QJsonDocument::fromJson(bytes()).object(); }

  QJsonObject view(int i) { return desktops[i]->settings()->deviceSettings(); }
  bool refuses(int i) { return !desktops[i]->settings()->deviceError().isEmpty(); }
};

constexpr char kBroken[] = "{ not json";

using Command = rc::state::Command<Model, Sut>;

// One save: `next` is the desktop's view with its change. Returns whether the
// model expects it saved.
bool save(Model& model, int desktop, const QJsonObject& next, const std::function<void(QJsonObject&)>& change) {
  if (model.view[desktop] == next) return true;
  if (model.broken) model.unreadable[desktop] = true;
  if (model.unreadable[desktop]) return false;
  if (model.gone) model.file = next;
  else change(model.file);
  model.gone = false;
  model.view[desktop] = model.file;
  return true;
}

void check(const Model& next, Sut& sut, int desktop, bool saved, bool expected) {
  RC_ASSERT(saved == expected);
  if (next.broken) RC_ASSERT(sut.bytes() == QByteArray(kBroken));
  else RC_ASSERT(sut.file() == next.file);
  RC_ASSERT(sut.view(desktop) == next.view[desktop]);
  RC_ASSERT(sut.refuses(desktop) == next.unreadable[desktop]);
}

struct Save : Command {
  int desktop = *rc::gen::inRange(0, 2);
  std::string key = *rc::gen::elementOf(kKeys);
  std::string value = *rc::gen::elementOf(kValues);

  bool change(Model& model) const {
    const QString name = QString::fromStdString(key);
    QJsonObject next = model.view[desktop];
    if (value.empty()) next.remove(name);
    else next.insert(name, jsonOf(value));
    return save(model, desktop, next, [&](QJsonObject& file) {
      if (value.empty()) file.remove(name);
      else file.insert(name, jsonOf(value));
    });
  }
  void apply(Model& model) const override { change(model); }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    const bool expected = change(next);
    const QVariant saved = value.empty() ? QVariant() : QVariant(QString::fromStdString(value));
    check(next, sut, desktop, sut.desktops[desktop]->settings()->writeDevice(QString::fromStdString(key), saved), expected);
  }
  void show(std::ostream& os) const override {
    os << "Save desktop " << desktop << " " << key << " = " << (value.empty() ? "(removed)" : value);
  }
};

// One entry of the object, built from what the desktop holds, as the callers
// of writeDevice do.
struct SaveEntry : Command {
  int desktop = *rc::gen::inRange(0, 2);
  std::string entry = *rc::gen::elementOf(kEntries);
  std::string value = *rc::gen::elementOf(kValues);

  static QJsonObject with(QJsonObject object, const QString& name, const std::string& value) {
    if (value.empty()) object.remove(name);
    else object.insert(name, jsonOf(value));
    return object;
  }
  QJsonObject entries(const Model& model) const {
    return with(model.view[desktop].value(kObject).toObject(), QString::fromStdString(entry), value);
  }
  bool change(Model& model) const {
    const QString name = QString::fromStdString(entry);
    QJsonObject next = model.view[desktop];
    next.insert(kObject, entries(model));
    // Only the entry this desktop changed: one it never held, removed, is
    // left as the other saved it. A file without the object takes this
    // desktop's whole, as the MC's carry_over does.
    const bool changed = model.view[desktop].value(kObject).toObject().value(name) != jsonOf(value);
    return save(model, desktop, next, [&](QJsonObject& file) {
      const QJsonValue held = file.value(kObject);
      if (!held.isObject()) file.insert(kObject, next.value(kObject));
      else file.insert(kObject, changed ? with(held.toObject(), name, value) : held.toObject());
    });
  }
  void apply(Model& model) const override { change(model); }
  void run(const Model& model, Sut& sut) const override {
    const QVariant object = entries(model).toVariantMap();
    Model next = model;
    const bool expected = change(next);
    check(next, sut, desktop, sut.desktops[desktop]->settings()->writeDevice(kObject, object), expected);
  }
  void show(std::ostream& os) const override {
    os << "SaveEntry desktop " << desktop << " " << entry << " = " << (value.empty() ? "(removed)" : value);
  }
};

// Both event loops run: each desktop hears what the file holds now.
struct Hear : Command {
  void apply(Model& model) const override {
    if (model.broken) model.unreadable = {true, true};
    else if (model.gone) model.unreadable = {false, false};
    else {
      model.view = {model.file, model.file};
      model.unreadable = {false, false};
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    RC_ASSERT(prop::until([&] {
      for (int i = 0; i < 2; ++i) {
        if (sut.view(i) != next.view[i] || sut.refuses(i) != next.unreadable[i]) return false;
      }
      return true;
    }));
  }
  void show(std::ostream& os) const override { os << "Hear"; }
};

struct Restart : Command {
  int desktop = *rc::gen::inRange(0, 2);

  void apply(Model& model) const override {
    model.view[desktop] = model.broken ? QJsonObject() : model.file;
    model.unreadable[desktop] = model.broken;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.start(desktop);
    RC_ASSERT(sut.view(desktop) == next.view[desktop]);
    RC_ASSERT(sut.refuses(desktop) == next.unreadable[desktop]);
  }
  void show(std::ostream& os) const override { os << "Restart desktop " << desktop; }
};

// A hand edit leaves the file unreadable.
struct Break : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.broken); }
  void apply(Model& model) const override {
    model.broken = true;
    model.gone = false;
  }
  void run(const Model&, Sut& sut) const override { sut.write(kBroken); }
  void show(std::ostream& os) const override { os << "Break"; }
};

// The person puts back what it held.
struct Repair : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.broken); }
  void apply(Model& model) const override { model.broken = false; }
  void run(const Model& model, Sut& sut) const override { sut.write(QJsonDocument(model.file).toJson()); }
  void show(std::ostream& os) const override { os << "Repair"; }
};

// The person deletes it, damaged or not.
struct Delete : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.gone); }
  void apply(Model& model) const override {
    model.file = {};
    model.broken = false;
    model.gone = true;
  }
  void run(const Model&, Sut& sut) const override { QFile::remove(sut.path()); }
  void show(std::ostream& os) const override { os << "Delete"; }
};

}  // namespace

class DevicePreferencesProp : public QObject {
  Q_OBJECT

private slots:
  void sharedFile() {
    QVERIFY(rc::check("two desktops on one home keep every preference either saved", [] {
      Sut sut;
      sut.start(0);
      sut.start(1);
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Save, Save, SaveEntry, SaveEntry, Hear, Restart, Break, Repair, Delete>());
    }));
  }
};

HAL_C2_PROP_MAIN(DevicePreferencesProp)
#include "tst_DevicePreferencesProp.moc"
