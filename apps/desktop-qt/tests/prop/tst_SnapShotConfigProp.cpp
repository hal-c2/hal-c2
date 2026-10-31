// CaptureShortcutConfig on real files in a temporary home. The user reviews
// installing or removing the shortcut and saves that review, a stale one or a
// review of nothing; the file changes behind its back.
// After every step the config is what only a current, unchanged review could
// have made it: HAL-C2's binding appears and goes as reviewed, the rest of the
// file is untouched, and each save's backup is the file it replaced.

#include "Prop.h"

#include <QDir>
#include <QFile>

#include "CaptureShortcutConfig.h"

namespace {

const QString kAppId = QStringLiteral("hal-c2");
const QStringList kKeys = {QStringLiteral("Ctrl+Shift+2"), QStringLiteral("Ctrl+Alt+K"), QStringLiteral("Super+F3")};
const QByteArray kOriginal = "binds {\n    Mod+T { spawn \"foot\"; }\n}\n";

struct Model {
  // The user's lines added behind HAL-C2's back; they survive every edit.
  int edits = 0;
  // The keys of the binding in the file.
  QString bound;
  // The review that can still be saved, and what it would do.
  bool reviewed = false;
  bool install = false;
  QString keys;
};

struct Config {
  QTemporaryDir home;
  QString path;
  std::unique_ptr<CaptureShortcutConfig> config;
  QString id;
  QStringList used;

  Model reset() {
    path = home.filePath(QStringLiteral(".config/niri/config.kdl"));
    QDir().mkpath(QFileInfo(path).absolutePath());
    write(kOriginal);
    QDir folder(QFileInfo(path).absolutePath());
    for (const QString& name : folder.entryList(QDir::Files | QDir::Hidden)) {
      if (name != QFileInfo(path).fileName()) folder.remove(name);
    }
    CaptureShortcutConfig::Tools tools;
    tools.validateNiri = [](const QString&) { return true; };
    tools.hyprlandBindings = [] { return QList<CaptureShortcutConfig::HyprlandBind>{}; };
    tools.reloadHyprland = [] { return QString(); };
    config = std::make_unique<CaptureShortcutConfig>(home.path(), tools);
    id.clear();
    used.clear();
    return {};
  }

  void write(const QByteArray& bytes) const {
    QFile file(path);
    RC_ASSERT(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(bytes);
  }

  QByteArray read() const {
    QFile file(path);
    RC_ASSERT(file.open(QIODevice::ReadOnly));
    return file.readAll();
  }

  void check(const Model& model) const {
    const QByteArray now = read();
    RC_ASSERT(now.contains("Mod+T { spawn \"foot\"; }"));
    RC_ASSERT(now.count("# mine") == model.edits);
    RC_ASSERT(now.count("hal-c2.SnapShot") == (model.bound.isEmpty() ? 0 : 1));
    if (!model.bound.isEmpty()) RC_ASSERT(now.contains(model.bound.toUtf8() + " repeat=false"));
  }
};

using Command = rc::state::Command<Model, Config>;

struct Review : Command {
  bool install = *rc::gen::arbitrary<bool>();
  QString keys = kKeys.at(*rc::gen::inRange(0, int(kKeys.size())));

  void apply(Model& model) const override {
    model.reviewed = true;
    model.install = install;
    model.keys = keys;
  }
  void run(const Model& model, Config& sut) const override {
    if (!sut.id.isEmpty()) sut.used.append(sut.id);
    QString error;
    const auto preview = sut.config->preview({QStringLiteral("niri"), sut.path, kAppId}, install, keys, &error);
    RC_ASSERT(preview.has_value());
    sut.id = preview->id;
    // A review writes nothing.
    sut.check(model);
  }
  void show(std::ostream& os) const override { os << "Review(" << (install ? "install " : "remove ") << keys.toStdString() << ")"; }
};

struct Save : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.reviewed); }
  void apply(Model& model) const override {
    model.reviewed = false;
    if (model.install) {
      model.bound = model.keys;
    } else {
      model.bound.clear();
    }
  }
  void run(const Model& model, Config& sut) const override {
    const QByteArray before = sut.read();
    QString error;
    const auto applied = sut.config->apply(sut.id, QStringLiteral("niri"), &error);
    Model next = model;
    apply(next);
    RC_ASSERT(applied.has_value());
    sut.check(next);
    RC_CLASSIFY(sut.read() != before, "changed the file");
    sut.used.append(sut.id);
    sut.id.clear();
    // Saving a review of nothing leaves no backup to read.
    if (sut.read() != before) {
      QFile backup(applied->backupPath);
      RC_ASSERT(backup.open(QIODevice::ReadOnly));
      RC_ASSERT(backup.readAll() == before);
    }
  }
  void show(std::ostream& os) const override { os << "Save"; }
};

// An id no longer current: an earlier review's, or the one just saved.
struct SaveStale : Command {
  void apply(Model&) const override {}
  void run(const Model& model, Config& sut) const override {
    if (sut.used.isEmpty()) return;
    QString error;
    const auto applied = sut.config->apply(sut.used.last(), QStringLiteral("niri"), &error);
    RC_ASSERT(!applied.has_value());
    RC_TAG("refused a stale id");
    sut.check(model);
  }
  void show(std::ostream& os) const override { os << "SaveStale"; }
};

// Someone edits the file: a review made before it cannot be saved.
struct EditBehind : Command {
  void apply(Model& model) const override {
    model.edits++;
    model.reviewed = false;
  }
  void run(const Model& model, Config& sut) const override {
    sut.write(sut.read() + "# mine\n");
    Model next = model;
    apply(next);
    sut.check(next);
    if (!model.reviewed) return;
    QString error;
    RC_ASSERT(!sut.config->apply(sut.id, QStringLiteral("niri"), &error).has_value());
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "EditBehind"; }
};

}  // namespace

class SnapShotConfigProp : public QObject {
  Q_OBJECT

private slots:
  void config() {
    Config sut;
    QVERIFY(rc::check("the config changes only by saving a current review, and keeps what the user wrote", [&sut] {
      const Model initial = sut.reset();
      rc::state::check(initial, sut, rc::state::gen::execOneOfWithArgs<Review, Review, Save, Save, SaveStale, EditBehind>());
    }));
  }
};

HAL_C2_PROP_MAIN(SnapShotConfigProp)
#include "tst_SnapShotConfigProp.moc"
