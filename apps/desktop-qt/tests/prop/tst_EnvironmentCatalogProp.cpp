// The saved environments (EnvironmentCatalog) as the user and the system change
// them: environments saved and forgotten, a keyring that refuses and comes
// back, cannot be read, or loses a credential, the record file damaged as a crash leaves it,
// a disk that stops taking writes, and the app starting again. It lists what
// was saved and nothing a refusing keyring or disk kept from it, and one not
// saved keeps the credential it had; a damaged file is set aside and the app starts with
// none; connecting gives the credential, or says what is missing; and no
// credential is ever on disk.

#include "Prop.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>

#include <map>
#include <memory>

#include "EnvironmentCatalog.h"
#include "SecretStore.h"

namespace {

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

const std::vector<std::string> kIds{"studio", "laptop", "pi"};

struct Saved {
  std::string label;
  bool located = true;     // the record says where the environment is
  std::string credential;  // what the keyring was given for it
  bool operator==(const Saved&) const = default;
};

struct Model {
  // What the catalog lists, in the order saved.
  std::vector<std::pair<std::string, Saved>> listed;
  // What the keyring holds, whatever the record file says.
  std::map<std::string, std::string> keyring;
  bool refusing = false;
  // The keyring takes writes but gives nothing back.
  bool unreadable = false;
  // The record file's directory takes no writes.
  bool locked = false;
  // The record file was damaged since the catalog last wrote it.
  bool damagedOnDisk = false;
  // Damaged files set aside so far.
  int setAside = 0;

  const Saved* find(const std::string& id) const {
    for (const auto& [key, saved] : listed) {
      if (key == id) return &saved;
    }
    return nullptr;
  }
};

struct Sut {
  QTemporaryDir dir;
  std::shared_ptr<MemorySecretStore::Keys> keys = std::make_shared<MemorySecretStore::Keys>();
  std::unique_ptr<MemorySecretStore> store;
  std::unique_ptr<EnvironmentCatalog> catalog;
  QStringList asides;  // every damaged file the catalog set aside, oldest first

  Sut() {
    QDir().mkpath(records());
    start();
  }
  ~Sut() { lock(false); }
  QString records() const { return dir.filePath(QStringLiteral("records")); }
  QString path() const { return QDir(records()).filePath(QStringLiteral("saved-environments.json")); }
  void lock(bool locked) const {
    QFile::setPermissions(records(), locked ? QFile::ReadOwner | QFile::ExeOwner : QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
  }
  // As the app starts: a store on the same keyring, the record file read.
  void start() {
    catalog.reset();
    store = std::make_unique<MemorySecretStore>(keys);
    catalog = std::make_unique<EnvironmentCatalog>(path(), store.get());
    catalog->load();
    if (!catalog->damaged().isEmpty()) asides.append(catalog->damaged());
  }
};

void expectSame(const Model& model, Sut& sut) {
  const QList<SavedEnvironment> listed = sut.catalog->environments();
  RC_ASSERT(listed.size() == qsizetype(model.listed.size()));
  for (qsizetype i = 0; i < listed.size(); ++i) {
    const auto& [id, saved] = model.listed.at(size_t(i));
    RC_ASSERT(listed.at(i).id == q(id));
    RC_ASSERT(listed.at(i).label == q(saved.label));
    RC_ASSERT(listed.at(i).complete() == saved.located);
  }
  RC_ASSERT(sut.keys->secrets.size() == qsizetype(model.keyring.size()));
  for (const auto& [id, credential] : model.keyring) RC_ASSERT(sut.keys->secrets.value(q(id)) == q(credential));
  RC_ASSERT(sut.asides.size() == model.setAside);
  // No credential is in any file the catalog wrote or set aside.
  QDirIterator files(sut.dir.path(), QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
  while (files.hasNext()) {
    QFile file(files.next());
    RC_ASSERT(file.open(QIODevice::ReadOnly));
    RC_ASSERT(!file.readAll().contains("c0ffee"));
  }
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(model, sut);
    expectSame(next, sut);
  }
};

struct Save : Step<Save> {
  std::string id = *rc::gen::elementOf(kIds);
  std::string label = *rc::gen::element<std::string>("Studio", "", "Pi");
  bool located = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  // A credential no one can guess, so finding it on disk is finding a leak.
  std::string credential = "secret-" + std::to_string(*rc::gen::inRange(0, 1000000)) + "-c0ffee";

  explicit Save(const Model&) {}
  void apply(Model& model) const override {
    if (model.refusing) return;
    if (model.locked) {
      // Not saved: the keyring is put back as the catalog read it, and a
      // credential the record names stays when there was nothing to put back.
      const auto had = model.keyring.find(id);
      if (!model.unreadable && had != model.keyring.end()) return;
      if (model.find(id)) {
        model.keyring[id] = credential;
      } else {
        model.keyring.erase(id);
      }
      return;
    }
    model.keyring[id] = credential;
    std::erase_if(model.listed, [&](const auto& entry) { return entry.first == id; });
    model.listed.emplace_back(id, Saved{label, located, credential});
    model.damagedOnDisk = false;
  }
  void act(const Model& model, Sut& sut) const {
    const SavedEnvironment environment{q(id), q(label), located ? QUrl(QStringLiteral("http://%1.local:3773").arg(q(id))) : QUrl(), {}};
    const std::optional<QString> refused = sut.catalog->save(environment, q(credential));
    // Refused exactly when the keyring or the disk is, and saying who could not be saved.
    RC_ASSERT(refused.has_value() == (model.refusing || model.locked));
    if (refused) RC_ASSERT(refused->startsWith(label.empty() ? q(id) : q(label)));
  }
  void show(std::ostream& os) const override { os << "Save(" << id << ", \"" << label << "\"" << (located ? "" : ", no origin") << ")"; }
};

struct Forget : Step<Forget> {
  std::string id = *rc::gen::elementOf(kIds);

  explicit Forget(const Model&) {}
  // One forgotten on a disk that takes no writes is back at the next start (#1096).
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.locked); }
  void apply(Model& model) const override {
    model.keyring.erase(id);
    if (std::erase_if(model.listed, [&](const auto& entry) { return entry.first == id; }) > 0) model.damagedOnDisk = false;
  }
  void act(const Model&, Sut& sut) const { sut.catalog->forget(q(id)); }
  void show(std::ostream& os) const override { os << "Forget(" << id << ")"; }
};

// The system's secure storage stops, or starts again, letting the app in.
struct Refuse : Step<Refuse> {
  bool refusing = *rc::gen::arbitrary<bool>();

  explicit Refuse(const Model&) {}
  void apply(Model& model) const override { model.refusing = refusing; }
  void act(const Model&, Sut& sut) const { sut.keys->refusing = refusing; }
  void show(std::ostream& os) const override { os << "Refuse(" << (refusing ? "on" : "off") << ")"; }
};

// The keyring stops, or starts again, giving back what it holds.
struct Unreadable : Step<Unreadable> {
  bool unreadable = *rc::gen::arbitrary<bool>();

  explicit Unreadable(const Model&) {}
  void apply(Model& model) const override { model.unreadable = unreadable; }
  void act(const Model&, Sut& sut) const { sut.keys->unreadable = unreadable; }
  void show(std::ostream& os) const override { os << "Unreadable(" << (unreadable ? "on" : "off") << ")"; }
};

// The keyring loses one credential (the user deleted it, or another app did).
struct LoseCredential : Step<LoseCredential> {
  std::string id = *rc::gen::elementOf(kIds);

  explicit LoseCredential(const Model&) {}
  void apply(Model& model) const override { model.keyring.erase(id); }
  void act(const Model&, Sut& sut) const { sut.keys->secrets.remove(q(id)); }
  void show(std::ostream& os) const override { os << "LoseCredential(" << id << ")"; }
};

// The disk stops, or starts again, taking writes.
struct Lock : Step<Lock> {
  bool locked = *rc::gen::arbitrary<bool>();

  explicit Lock(const Model&) {}
  void apply(Model& model) const override { model.locked = locked; }
  void act(const Model&, Sut& sut) const { sut.lock(locked); }
  void show(std::ostream& os) const override { os << "Lock(" << (locked ? "on" : "off") << ")"; }
};

// The record file is cut off, as a crash mid-write leaves it.
struct Damage : Step<Damage> {
  explicit Damage(const Model&) {}
  // A crash mid-write, so on a disk that takes writes.
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.locked); }
  void apply(Model& model) const override { model.damagedOnDisk = true; }
  void act(const Model&, Sut& sut) const {
    QFile file(sut.path());
    RC_ASSERT(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(R"({"version": 1, "environments": [{"id": "stu)");
  }
  void show(std::ostream& os) const override { os << "Damage"; }
};

// The app starts again and reads the record file.
struct Reload : Step<Reload> {
  explicit Reload(const Model&) {}
  // A damaged file is set aside by writing beside it.
  void checkPreconditions(const Model& model) const override {
    const bool stuck = model.locked && model.damagedOnDisk;
    RC_PRE(!stuck);
  }
  void apply(Model& model) const override {
    if (!model.damagedOnDisk) return;
    // Set aside, and none listed; the keyring keeps what it had.
    model.listed.clear();
    model.damagedOnDisk = false;
    ++model.setAside;
  }
  void act(const Model&, Sut& sut) const {
    const QStringList before = sut.asides;
    sut.start();
    if (sut.asides.size() == before.size()) return;
    // What was set aside is the damaged file, beside the one written in its place.
    QFile aside(sut.asides.last());
    RC_ASSERT(aside.open(QIODevice::ReadOnly));
    RC_ASSERT(aside.readAll().startsWith(R"({"version": 1, "environments": [{"id": "stu)"));
    RC_ASSERT(!before.contains(sut.asides.last()));
  }
  void show(std::ostream& os) const override { os << "Reload"; }
};

// The app connects to one: with its credential, or blocked with what is missing.
struct Connect : Step<Connect> {
  std::string id = *rc::gen::elementOf(kIds);

  explicit Connect(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model& model, Sut& sut) const {
    const EnvironmentCatalog::Connection connection = sut.catalog->connect(q(id));
    const Saved* saved = model.find(id);
    const auto kept = model.keyring.find(id);
    if (!saved || !saved->located) {
      RC_ASSERT(connection.blocked == EnvironmentCatalog::profileMissing(q(id)));
      RC_ASSERT(connection.credential.isEmpty());
    } else if (model.refusing || model.unreadable || kept == model.keyring.end()) {
      RC_ASSERT(connection.blocked == EnvironmentCatalog::credentialMissing(q(id)));
      RC_ASSERT(connection.credential.isEmpty());
    } else {
      RC_ASSERT(connection.blocked.isEmpty());
      RC_ASSERT(connection.credential == q(kept->second));
      RC_ASSERT(connection.environment.id == q(id));
    }
  }
  void show(std::ostream& os) const override { os << "Connect(" << id << ")"; }
};

}  // namespace

class EnvironmentCatalogProp : public QObject {
  Q_OBJECT

private slots:
  void keepsWhatWasSaved() {
    QVERIFY(rc::check("the catalog lists what was saved, sets a damaged file aside, and never writes a credential to disk", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Save, Save, Save, Forget, Refuse, Unreadable, Lock, LoseCredential, Damage, Reload, Reload,
                                                         Connect, Connect>());
    }));
  }
};

HAL_C2_PROP_MAIN(EnvironmentCatalogProp)
#include "tst_EnvironmentCatalogProp.moc"
