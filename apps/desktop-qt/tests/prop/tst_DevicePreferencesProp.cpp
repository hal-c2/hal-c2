// SettingsController's device preferences as a state machine of two desktops on
// one home (two processes of it, or desktop-qt beside the Ljós desktop), which
// share preferences.json: each saves preferences, hears the other's saves only
// once its event loop runs, and quits and starts again. The model is the
// ledger's rule (features/settings/saving-settings.feature): the file holds
// every preference as it was last saved, by either, and a desktop that has
// heard of a save, or started after it, shows it. A save of the value a desktop
// already shows changes nothing, even if the other saved another since.

#include "Prop.h"

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QFile>
#include <QJsonDocument>
#include <QTemporaryDir>

#include <array>
#include <memory>
#include <optional>
#include <string>

namespace prop = halc2::prop;

namespace {

const std::array<std::string, 3> kKeys{"appearance", "timestampFormat", "fontSizeInterface"};
// Empty removes the preference.
const std::array<std::string, 3> kValues{"", "one", "two"};

struct Model {
  // preferences.json, and what each desktop holds.
  QJsonObject file;
  std::array<QJsonObject, 2> view;
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

  QJsonObject file() const {
    QFile file(path());
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(file.readAll()).object();
  }

  QJsonObject view(int i) { return desktops[i]->settings()->deviceSettings(); }
};

using Command = rc::state::Command<Model, Sut>;

struct Save : Command {
  int desktop = *rc::gen::inRange(0, 2);
  std::string key = *rc::gen::elementOf(kKeys);
  std::string value = *rc::gen::elementOf(kValues);

  void apply(Model& model) const override {
    const QString name = QString::fromStdString(key);
    const QJsonValue next = value.empty() ? QJsonValue(QJsonValue::Undefined) : QJsonValue(QString::fromStdString(value));
    if (model.view[desktop].value(name) == next) return;
    if (value.empty()) model.file.remove(name);
    else model.file.insert(name, next);
    model.view[desktop] = model.file;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const QVariant saved = value.empty() ? QVariant() : QVariant(QString::fromStdString(value));
    RC_ASSERT(sut.desktops[desktop]->settings()->writeDevice(QString::fromStdString(key), saved));
    RC_ASSERT(sut.file() == next.file);
    RC_ASSERT(sut.view(desktop) == next.view[desktop]);
  }
  void show(std::ostream& os) const override {
    os << "Save desktop " << desktop << " " << key << " = " << (value.empty() ? "(removed)" : value);
  }
};

// Both event loops run: each desktop hears what the other saved.
struct Hear : Command {
  void apply(Model& model) const override { model.view = {model.file, model.file}; }
  void run(const Model& model, Sut& sut) const override {
    RC_ASSERT(prop::until([&] { return sut.view(0) == model.file && sut.view(1) == model.file; }));
    RC_ASSERT(sut.file() == model.file);
  }
  void show(std::ostream& os) const override { os << "Hear"; }
};

struct Restart : Command {
  int desktop = *rc::gen::inRange(0, 2);

  void apply(Model& model) const override { model.view[desktop] = model.file; }
  void run(const Model& model, Sut& sut) const override {
    sut.start(desktop);
    RC_ASSERT(sut.view(desktop) == model.file);
  }
  void show(std::ostream& os) const override { os << "Restart desktop " << desktop; }
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
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Save, Save, Save, Hear, Restart>());
    }));
  }
};

HAL_C2_PROP_MAIN(DevicePreferencesProp)
#include "tst_DevicePreferencesProp.moc"
