// SettingsController's device preferences as a state machine of two desktops on
// one home (two processes of it, or desktop-qt beside the Ljós desktop), which
// share preferences.json: each saves preferences, writes them once its event
// loop runs (off the GUI thread, CoalescingWriter) and hears the other's saves
// then too, and quits and starts again (writing what it has not yet); and the
// file is broken by hand and repaired. The model is the ledger's rule
// (features/settings/saving-settings.feature): the file holds every preference
// as it was last saved, by either, down to one entry of an object (one
// provider's models beside another's), and a desktop that has heard of a save,
// or started after it, shows it. A desktop's saves that have not landed yet
// stay what it shows, through what it hears, and land over what the file
// holds then: several of them at once, and over a save another desktop made
// meanwhile. A save of the value a desktop already shows changes nothing, even
// if the other saved another since. While the file does not read, a desktop
// that has found that out refuses saves and keeps what it showed, and what it
// saved before stays to be written, until it hears the file read again, or
// hears it deleted: then the next write writes what that desktop shows.
//
// Which of two desktops' writes lands first is up to their timers, so one
// desktop has saves waiting at a time, except that the other may save and
// quit, which writes its save at once. A desktop's own write lands before
// it hears the file: what it wrote is what it read, and a save made before it
// hears, or while the write is on its way, is made over that.

#include "Prop.h"

#include "CoalescingWriter.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonDocument>
#include <QDeadlineTimer>
#include <QSaveFile>
#include <QTemporaryDir>
#include <QThread>

#include <array>
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

QJsonObject with(QJsonObject object, const QString& name, const QJsonValue& value) {
  if (value.isUndefined()) object.remove(name);
  else object.insert(name, value);
  return object;
}

struct Model {
  // preferences.json as last saved, and what each desktop shows and last read
  // from it.
  QJsonObject file;
  std::array<QJsonObject, 2> view;
  std::array<QJsonObject, 2> read;
  // A desktop saved since it last wrote.
  std::array<bool, 2> pending{false, false};
  // The file is broken by hand; and which desktop has found that out.
  bool broken = false;
  // The file was deleted since it was last written.
  bool gone = false;
  std::array<bool, 2> unreadable{false, false};
};

// What a desktop changed since it read the file, put over what the file holds:
// each preference it changed, and of the object each entry it changed, or the
// whole object where the file holds none.
QJsonObject over(QJsonObject file, const QJsonObject& read, const QJsonObject& view) {
  for (const std::string& key : kKeys) {
    const QString name = QString::fromStdString(key);
    if (read.value(name) != view.value(name)) file = with(file, name, view.value(name));
  }
  const QJsonValue mine = view.value(kObject);
  const QJsonValue was = read.value(kObject);
  const QJsonValue held = file.value(kObject);
  if (mine == was) return file;
  if (!mine.isObject() || !held.isObject()) return with(file, kObject, mine);
  QJsonObject entries = held.toObject();
  for (const std::string& entry : kEntries) {
    const QString name = QString::fromStdString(entry);
    const QJsonValue value = mine.toObject().value(name);
    if (was.toObject().value(name) != value) entries = with(entries, name, value);
  }
  file.insert(kObject, entries);
  return file;
}

// The desktop's saves land, unless the file does not read: then they wait.
void land(Model& model, int desktop) {
  if (!model.pending[desktop] || model.broken) return;
  model.file = model.gone ? model.view[desktop] : over(model.file, model.read[desktop], model.view[desktop]);
  model.gone = false;
  model.pending[desktop] = false;
}

// The desktop reads the file: it shows what the file holds, with its saves
// still to land over it.
void hear(Model& model, int desktop) {
  model.view[desktop] = over(model.file, model.read[desktop], model.view[desktop]);
  model.read[desktop] = model.file;
}

// One save: `next` is the desktop's view with its change. Returns whether the
// model expects it saved.
bool save(Model& model, int desktop, const QJsonObject& next) {
  if (model.view[desktop] == next) return true;
  if (model.broken) model.unreadable[desktop] = true;
  if (model.unreadable[desktop]) return false;
  model.view[desktop] = next;
  model.pending[desktop] = true;
  return true;
}

// The desktop quits, writing what it has not yet unless the file does not
// read, and starts again.
void restart(Model& model, int desktop) {
  land(model, desktop);
  model.pending[desktop] = false;
  model.view[desktop] = model.broken ? QJsonObject() : model.file;
  model.read[desktop] = model.view[desktop];
  model.unreadable[desktop] = model.broken;
}

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

  QFileSystemWatcher* watcher(int i) { return desktops[i]->settings()->findChild<QFileSystemWatcher*>(); }
  CoalescingWriter* writer(int i) { return desktops[i]->settings()->findChild<CoalescingWriter*>(); }
  // The watchers' events, while they are not heard, are lost: told again.
  void deafen(bool deaf) {
    for (int i = 0; i < 2; ++i) watcher(i)->blockSignals(deaf);
  }
  void tell() {
    for (int i = 0; i < 2; ++i) {
      QMetaObject::invokeMethod(watcher(i), "directoryChanged", Q_ARG(QString, QFileInfo(path()).absolutePath()));
    }
  }

  QJsonObject view(int i) { return desktops[i]->settings()->deviceSettings(); }
  bool refuses(int i) { return !desktops[i]->settings()->deviceError().isEmpty(); }
  bool unsaved(int i) { return desktops[i]->settings()->deviceUnsaved(); }
};

constexpr char kBroken[] = "{ not json";

using Command = rc::state::Command<Model, Sut>;

void checkFile(const Model& model, Sut& sut) {
  if (model.broken) RC_ASSERT(sut.bytes() == QByteArray(kBroken));
  else if (model.gone) RC_ASSERT(!QFile::exists(sut.path()));
  else RC_ASSERT(sut.file() == model.file);
}

// Saves on one desktop wait only while the other's do not.
bool mayWait(const Model& model, int desktop) { return !model.pending[1 - desktop]; }

// A save waits to be written: the file is as it was.
void check(const Model& next, Sut& sut, int desktop, bool saved, bool expected) {
  RC_ASSERT(saved == expected);
  checkFile(next, sut);
  RC_ASSERT(sut.view(desktop) == next.view[desktop]);
  RC_ASSERT(sut.refuses(desktop) == next.unreadable[desktop]);
}

struct Save : Command {
  int desktop = *rc::gen::inRange(0, 2);
  std::string key = *rc::gen::elementOf(kKeys);
  std::string value = *rc::gen::elementOf(kValues);

  QJsonObject next(const Model& model) const { return with(model.view[desktop], QString::fromStdString(key), jsonOf(value)); }
  void checkPreconditions(const Model& model) const override { RC_PRE(mayWait(model, desktop)); }
  void apply(Model& model) const override { save(model, desktop, next(model)); }
  bool call(Sut& sut) const {
    const QVariant saved = value.empty() ? QVariant() : QVariant(QString::fromStdString(value));
    return sut.desktops[desktop]->settings()->writeDevice(QString::fromStdString(key), saved);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    const bool expected = save(next, desktop, this->next(model));
    check(next, sut, desktop, call(sut), expected);
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

  QJsonObject entries(const Model& model) const {
    return with(model.view[desktop].value(kObject).toObject(), QString::fromStdString(entry), jsonOf(value));
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(mayWait(model, desktop)); }
  void apply(Model& model) const override { save(model, desktop, with(model.view[desktop], kObject, entries(model))); }
  void run(const Model& model, Sut& sut) const override {
    const QVariant object = entries(model).toVariantMap();
    Model next = model;
    const bool expected = save(next, desktop, with(model.view[desktop], kObject, entries(model)));
    check(next, sut, desktop, sut.desktops[desktop]->settings()->writeDevice(kObject, object), expected);
  }
  void show(std::ostream& os) const override {
    os << "SaveEntry desktop " << desktop << " " << entry << " = " << (value.empty() ? "(removed)" : value);
  }
};

// Two saves on one desktop before either is written.
struct SaveTwice : Command {
  Save first;
  Save second;
  SaveTwice() { second.desktop = first.desktop; }

  void checkPreconditions(const Model& model) const override { RC_PRE(mayWait(model, first.desktop)); }
  void apply(Model& model) const override {
    first.apply(model);
    second.apply(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    first.run(next, sut);
    first.apply(next);
    second.run(next, sut);
  }
  void show(std::ostream& os) const override {
    first.show(os);
    os << ", then ";
    second.show(os);
  }
};

// The desktop saves and quits, which writes its save at once: while the other
// desktop's saves wait, they land over it.
struct SaveAndQuit : Command {
  Save change;

  void apply(Model& model) const override {
    save(model, change.desktop, change.next(model));
    restart(model, change.desktop);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    const bool expected = save(next, change.desktop, change.next(model));
    RC_ASSERT(change.call(sut) == expected);
    restart(next, change.desktop);
    sut.start(change.desktop);
    checkFile(next, sut);
    RC_ASSERT(sut.view(change.desktop) == next.view[change.desktop]);
    RC_ASSERT(sut.refuses(change.desktop) == next.unreadable[change.desktop]);
  }
  void show(std::ostream& os) const override {
    change.show(os);
    os << ", and quit";
  }
};

// Both event loops run: what waits is written, and each desktop hears what
// the file holds then, with its own saves still to land over it.
struct Hear : Command {
  void apply(Model& model) const override {
    land(model, 0);
    land(model, 1);
    if (model.broken) model.unreadable = {true, true};
    else if (model.gone) model.unreadable = {false, false};
    else {
      for (int i = 0; i < 2; ++i) hear(model, i);
      model.unreadable = {false, false};
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.tell();
    RC_ASSERT(prop::until([&] {
      for (int i = 0; i < 2; ++i) {
        if (sut.view(i) != next.view[i] || sut.refuses(i) != next.unreadable[i] || sut.unsaved(i) != next.pending[i]) {
          return false;
        }
      }
      return true;
    }));
    checkFile(next, sut);
  }
  void show(std::ostream& os) const override { os << "Hear"; }
};

// The desktop's saves land before either desktop hears the file: it takes what
// it wrote as what it read, as a fresh read would, and its next save goes over
// that.
struct Land : Command {
  int desktop = *rc::gen::inRange(0, 2);

  void checkPreconditions(const Model& model) const override {
    RC_PRE(model.pending[desktop] && !model.broken && !model.unreadable[desktop]);
  }
  void apply(Model& model) const override {
    land(model, desktop);
    hear(model, desktop);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.deafen(true);
    const bool landed = prop::until([&] { return sut.writer(desktop)->idle(); });
    sut.deafen(false);
    RC_ASSERT(landed);
    checkFile(next, sut);
    RC_ASSERT(sut.view(desktop) == next.view[desktop]);
    RC_ASSERT(sut.refuses(desktop) == next.unreadable[desktop]);
  }
  void show(std::ostream& os) const override { os << "Land desktop " << desktop; }
};

// The desktop saves while its write is on its way, or has reached the disk
// and not been taken in yet (or, when it is too quick, after it landed): the
// save goes over what that write landed. The desktop has heard the file, so
// the write changes nothing else it shows.
struct SaveInFlight : Command {
  Save change;

  void checkPreconditions(const Model& model) const override {
    const int d = change.desktop;
    RC_PRE(model.pending[d] && !model.broken && !model.unreadable[d] && mayWait(model, d));
    RC_PRE(model.gone || model.file == model.read[d]);
  }
  void apply(Model& model) const override {
    land(model, change.desktop);
    hear(model, change.desktop);
    save(model, change.desktop, change.next(model));
  }
  void run(const Model& model, Sut& sut) const override {
    const int d = change.desktop;
    Model landed = model;
    land(landed, d);
    // An earlier write lands first; what is pending then goes as one write.
    // Neither desktop hears the file meanwhile.
    sut.deafen(true);
    const bool started = prop::until([&] { return !sut.writer(d)->writing(); }) &&
                         prop::until([&] { return sut.writer(d)->writing() || sut.writer(d)->idle(); });
    sut.deafen(false);
    RC_ASSERT(started);
    // Without the event loop, so the landing is not taken in.
    const QDeadlineTimer limit(5000);
    while (!(QFile::exists(sut.path()) && sut.file() == landed.file) && !limit.hasExpired()) QThread::msleep(1);
    Model next = model;
    apply(next);
    check(next, sut, d, change.call(sut), true);
  }
  void show(std::ostream& os) const override {
    change.show(os);
    os << ", while its write is on its way";
  }
};

struct Restart : Command {
  int desktop = *rc::gen::inRange(0, 2);

  void apply(Model& model) const override { restart(model, desktop); }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.start(desktop);
    checkFile(next, sut);
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
                       rc::state::gen::execOneOfWithArgs<Save, Save, SaveEntry, SaveEntry, SaveTwice, SaveAndQuit, Hear, Hear,
                                                         Land, Land, SaveInFlight, SaveInFlight, Restart, Break, Repair,
                                                         Delete>());
    }));
  }
};

HAL_C2_PROP_MAIN(DevicePreferencesProp)
#include "tst_DevicePreferencesProp.moc"
