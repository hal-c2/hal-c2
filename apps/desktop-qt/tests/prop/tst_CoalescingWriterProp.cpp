// The shell's coalescing file writer (src/native/CoalescingWriter) against a
// model of what it was given: edits and removals in bursts, the delay running
// out while a write is on its way, flushes, writes that must land at once, a
// disk that refuses writes for a while, and the app quitting. The file never
// goes back to an older state than one it held, and once the writes are done
// (or flushed, or the app quit) it holds the latest.

#include "Prop.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <memory>
#include <optional>

#include "CoalescingWriter.h"

namespace {

struct Model {
  // The latest version given, and whether it is the file or its removal.
  int latest = 0;
  bool present = false;
  // A file sits where the file's folder goes: every write fails.
  bool blocked = false;
  // Nothing failed since the writer was last given something, or flushed.
  bool sure = true;
};

struct Sut {
  QTemporaryDir dir{QDir::tempPath() + QStringLiteral("/writer-XXXXXX")};
  std::unique_ptr<CoalescingWriter> writer;
  int delay = 0;
  // The newest version the file was seen holding.
  int floor = 0;

  QString folder() const { return dir.filePath(QStringLiteral("sub")); }
  QString aside() const { return dir.filePath(QStringLiteral("aside")); }
  QString path() const { return dir.filePath(QStringLiteral("sub/kept.json")); }

  void open() {
    writer = std::make_unique<CoalescingWriter>();
    writer->setDelay(delay);
    writer->setPath(path());
  }

  // The version the file holds, or nothing when there is none.
  std::optional<int> read() const {
    QFile file(path());
    if (!file.open(QIODevice::ReadOnly)) return std::nullopt;
    const QByteArray bytes = file.readAll();
    RC_ASSERT(bytes.startsWith('v'));
    return bytes.mid(1).toInt();
  }

  // Never older than what it held before.
  void observe(const Model& model) {
    if (model.blocked) return;
    const auto version = read();
    if (!version) return;
    RC_ASSERT(*version >= floor);
    floor = *version;
  }

  // What the file holds is the model's latest.
  void expectLatest(const Model& model) {
    const auto version = read();
    if (model.present) {
      RC_ASSERT(version.has_value());
      RC_ASSERT(*version == model.latest);
      floor = *version;
    } else {
      RC_ASSERT(!version.has_value());
      floor = model.latest;
    }
  }

  void waitForLanding() { RC_ASSERT(halc2::prop::until([this] { return !writer->writing(); })); }
};

QByteArray bytesOf(int version) { return "v" + QByteArray::number(version); }

using Command = rc::state::Command<Model, Sut>;

struct Edit : Command {
  explicit Edit(const Model&) {}
  void apply(Model& model) const override {
    model.latest += 1;
    model.present = true;
    if (!model.blocked) model.sure = true;
  }
  void run(const Model& model, Sut& sut) const override {
    sut.writer->write(bytesOf(model.latest + 1));
    sut.observe(model);
  }
  void show(std::ostream& os) const override { os << "Edit"; }
};

// The same bytes again, as a save with nothing changed.
struct Again : Command {
  explicit Again(const Model& model) { RC_PRE(model.present); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.present); }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    sut.writer->write(bytesOf(model.latest));
    sut.observe(model);
  }
  void show(std::ostream& os) const override { os << "Again"; }
};

struct Remove : Command {
  explicit Remove(const Model&) {}
  void apply(Model& model) const override {
    model.latest += 1;
    model.present = false;
    if (!model.blocked) model.sure = true;
  }
  void run(const Model& model, Sut& sut) const override {
    sut.writer->remove();
    sut.observe(model);
  }
  void show(std::ostream& os) const override { os << "Remove"; }
};

// The event loop runs a little: delays run out, writes land, others start.
struct Spin : Command {
  int rounds;
  explicit Spin(const Model&) : rounds(*rc::gen::inRange(1, 4)) {}
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    for (int i = 0; i < rounds; ++i) {
      QCoreApplication::processEvents(QEventLoop::AllEvents, 2);
      sut.observe(model);
    }
  }
  void show(std::ostream& os) const override { os << "Spin(" << rounds << ")"; }
};

// The writes are left to finish on their own.
struct Settle : Command {
  explicit Settle(const Model& model) { RC_PRE(!model.blocked && model.sure); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.blocked && model.sure); }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    RC_ASSERT(halc2::prop::until([&] { return sut.writer->idle(); }));
    sut.expectLatest(model);
  }
  void show(std::ostream& os) const override { os << "Settle"; }
};

struct Flush : Command {
  explicit Flush(const Model&) {}
  void apply(Model& model) const override {
    if (!model.blocked) model.sure = true;
  }
  void run(const Model& model, Sut& sut) const override {
    const bool ok = sut.writer->flush();
    if (model.blocked) return;
    RC_ASSERT(ok);
    sut.expectLatest(model);
  }
  void show(std::ostream& os) const override { os << "Flush"; }
};

// A change that is kept only if the disk has it. One the disk refuses is taken
// back, and never written later: its bytes would fail read().
struct WriteNow : Command {
  explicit WriteNow(const Model&) {}
  void apply(Model& model) const override {
    if (model.blocked) return;
    model.latest += 1;
    model.present = true;
    model.sure = true;
  }
  void run(const Model& model, Sut& sut) const override {
    if (model.blocked) {
      RC_ASSERT(!sut.writer->writeNow("x" + QByteArray::number(model.latest + 1)));
      return;
    }
    RC_ASSERT(sut.writer->writeNow(bytesOf(model.latest + 1)));
    Model next = model;
    apply(next);
    sut.expectLatest(next);
  }
  void show(std::ostream& os) const override { os << "WriteNow"; }
};

// Once what is on its way has landed, a file takes the folder's place.
struct Block : Command {
  explicit Block(const Model& model) { RC_PRE(!model.blocked); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.blocked); }
  void apply(Model& model) const override {
    model.blocked = true;
    model.sure = false;
  }
  void run(const Model& model, Sut& sut) const override {
    sut.waitForLanding();
    sut.observe(model);
    QDir().mkpath(sut.folder());
    RC_ASSERT(QDir().rename(sut.folder(), sut.aside()));
    QFile blocker(sut.folder());
    RC_ASSERT(blocker.open(QIODevice::WriteOnly));
  }
  void show(std::ostream& os) const override { os << "Block"; }
};

struct Unblock : Command {
  explicit Unblock(const Model& model) { RC_PRE(model.blocked); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.blocked); }
  void apply(Model& model) const override { model.blocked = false; }
  void run(const Model&, Sut& sut) const override {
    sut.waitForLanding();
    RC_ASSERT(QFile::remove(sut.folder()));
    RC_ASSERT(QDir().rename(sut.aside(), sut.folder()));
  }
  void show(std::ostream& os) const override { os << "Unblock"; }
};

// The app quits and starts again: what was pending is written on the way out.
struct Quit : Command {
  explicit Quit(const Model& model) { RC_PRE(!model.blocked); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.blocked); }
  void apply(Model& model) const override { model.sure = true; }
  void run(const Model& model, Sut& sut) const override {
    sut.writer.reset();
    sut.expectLatest(model);
    sut.open();
  }
  void show(std::ostream& os) const override { os << "Quit"; }
};

}  // namespace

class CoalescingWriterProp : public QObject {
  Q_OBJECT

 private slots:
  void fileHoldsTheLatest() {
    QVERIFY(rc::check("the file holds the latest state once written, flushed or quit, and never goes back to an older one", [] {
      Sut sut;
      RC_ASSERT(sut.dir.isValid());
      sut.delay = *rc::gen::inRange(0, 4);
      sut.open();
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Edit, Edit, Edit, Again, Remove, Spin, Spin, Settle, Flush, WriteNow, Block,
                                                         Unblock, Quit>());
    }));
  }
};

HAL_C2_PROP_MAIN(CoalescingWriterProp)
#include "tst_CoalescingWriterProp.moc"
