// A thread's browser tabs (ThreadPreviews) against a fake MC
// (tests/native/features/FakeMc) that keeps every thread's tabs, changes them
// and says so with `preview` events, and holds each answer (`preview.list`,
// `preview.close`, `preview.open`) until a step answers it, in any order, or
// refuses it. A list is read when it is asked for, so one answered late is
// older than the events sent since. The user switches threads, hides and shows
// the tab, reloads, closes tabs and opens new ones; the MC can restart. t2 lives
// on another MC of the cluster, so a link the user opens for it (openAddress)
// goes through a tab of its and the connected MC's forward (`preview.forward`,
// held too), unless the connected MC is on another machine.
//
// After each step the rows are all of the thread shown, each once, and
// QAbstractItemModelTester finds nothing wrong with the row signals; a row that
// stayed the same is not redrawn, and nothing resets for no change. Once every
// answer is in, a shown list that loaded is the MC's tabs of the thread. Every
// page the browser opens is a link the user opened, at its address or at the
// forward of a port the thread's MC granted; once every answer is in, each link
// has opened or said why not.

#include "Prop.h"

#include <QAbstractItemModelTester>
#include <QHostAddress>
#include <QJsonArray>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadPreviews.h"

namespace {

const QString kEnvironment = QStringLiteral("env-a");
const QString kMc = QStringLiteral("mc-a");
const QString kRemote = QStringLiteral("env-b");
const QString kRemoteMc = QStringLiteral("mc-b");
const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2")};
const QStringList kTabs{QStringLiteral("tab-1"), QStringLiteral("tab-2"), QStringLiteral("tab-3"), QStringLiteral("tab-4")};
const QStringList kUrls{QString(), QStringLiteral("http://localhost:3000/"), QStringLiteral("http://localhost:5173/")};
const QStringList kLinks{QStringLiteral("http://localhost:3000/"), QStringLiteral("http://127.0.0.1:5173/app?q=1#top"),
                         QStringLiteral("http://[::1]:3000/"), QStringLiteral("https://example.com/")};
constexpr int kMaxTabs = 6;

// t2 is on the cluster's other MC.
QString environmentOf(const QString& thread) {
  return thread == QLatin1String("t2") ? kRemote : kEnvironment;
}

QString mcOf(const QString& thread) {
  return thread == QLatin1String("t2") ? kRemoteMc : kMc;
}

int portOf(const QUrl& url) {
  return url.port(url.scheme() == QLatin1String("https") ? 443 : 80);
}

bool loopback(const QUrl& url) {
  return url.host() == QLatin1String("localhost") || QHostAddress(url.host()).isLoopback();
}

// Where the connected MC forwards a port: elsewhere, as when the port is taken here.
int forwardPortOf(int port) {
  return port + 10000;
}

QString pick(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

// What the user chose: the thread shown and whether the tab is.
struct Model {
  QString thread;
  bool active = false;
};

int modelTestFailures = 0;
QtMessageHandler previousHandler = nullptr;

void countModelTestFailures(QtMsgType type, const QMessageLogContext& context, const QString& message) {
  if (context.category && qstrcmp(context.category, "qt.modeltest") == 0 && type >= QtWarningMsg) ++modelTestFailures;
  previousHandler(type, context, message);
}

// What a row reads for a tab snapshot of the MC's.
struct Row {
  QString tabId;
  QString url;
  QString title;
  QString status;
  QString problem;
  bool operator==(const Row&) const = default;
};

void showValue(const Row& row, std::ostream& os) {
  os << row.tabId.toStdString() << "(" << row.status.toStdString();
  if (!row.url.isEmpty()) os << " " << row.url.toStdString();
  if (row.title != row.url) os << " title=" << row.title.toStdString();
  if (!row.problem.isEmpty()) os << " problem=" << row.problem.toStdString();
  os << ")";
}

Row rowOf(const QJsonObject& tab) {
  const QJsonObject nav = tab.value(QLatin1String("navStatus")).toObject();
  const QString tag = nav.value(QLatin1String("_tag")).toString();
  Row row{tab.value(QLatin1String("tabId")).toString(), nav.value(QLatin1String("url")).toString()};
  row.title = nav.value(QLatin1String("title")).toString();
  if (row.title.isEmpty()) row.title = row.url.isEmpty() ? QStringLiteral("New tab") : row.url;
  row.status = tag == QLatin1String("Loading")      ? QStringLiteral("loading")
               : tag == QLatin1String("Success")    ? QStringLiteral("loaded")
               : tag == QLatin1String("LoadFailed") ? QStringLiteral("failed")
                                                    : QStringLiteral("idle");
  if (tag == QLatin1String("LoadFailed")) row.problem = nav.value(QLatin1String("description")).toString();
  return row;
}

struct Sut {
  // An answer the MC holds: the call, and for a list what it read when asked.
  struct Held {
    FakeMc::Rpc rpc;
    QJsonObject list;
  };
  // A link the user opened for a thread, not yet in the browser. One that
  // `forwards` was a loopback address of a thread on another MC while the
  // connected MC was here: it waits on the MC, and opens as it is only if the
  // connected MC is no longer here once the last answer comes. Any other
  // opens as it is at once.
  struct Link {
    QString thread;
    QUrl url;
    bool forwards = false;
  };
  struct Forward {
    QString thread;
    int port = 0;
  };

  FakeMc mc;
  std::unique_ptr<McClient> client;
  std::unique_ptr<ThreadPreviews> previews;
  std::unique_ptr<QAbstractItemModelTester> tester;
  QObject barrierContext;
  // The MC's tabs, oldest first, and every tab's thread ever.
  QList<QJsonObject> tabs;
  QHash<QString, QString> threadOf;
  QString epoch = QStringLiteral("epoch-1");
  qint64 revision = 0;
  int opened = 0;
  QList<Held> held;
  // Whether the connected MC is on this machine.
  bool here = true;
  QList<Link> links;
  QList<Forward> granted;
  // Links that said why they did not open; calls sent to an MC other than the thread's
  // (or a forward to one other than the connected one); pages opened for no link.
  int linkErrors = 0;
  QStringList misrouted;
  QList<QUrl> stray;
  // Since the step began: rows redrawn (by tab), resets, count signals.
  QList<QString> redrawn;
  int resets = 0;
  int countSignals = 0;
  QList<Row> before;

  Sut() {
    mc.environmentId = kEnvironment;
    mc.name = kMc;
    mc.onShape(QStringLiteral("preview"), [](int, const QJsonObject&) {});
    mc.onShape(QStringLiteral("localServers"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("localServers")}, {QStringLiteral("id"), id},
               {QStringLiteral("list"), QJsonObject{{QStringLiteral("servers"), QJsonArray()}}}});
    });
    mc.onRpc(QStringLiteral("prop.barrier"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, true); });
    mc.onRpc(QStringLiteral("preview.list"), [this](const FakeMc::Rpc& rpc) {
      QJsonArray sessions;
      for (const QJsonObject& tab : std::as_const(tabs)) {
        if (tab.value(QLatin1String("threadId")) == rpc.payload.value(QLatin1String("threadId"))) sessions.append(tab);
      }
      held.append({rpc, {{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), epoch}, {QStringLiteral("revision"), revision}}});
    });
    for (const QString& method : {QStringLiteral("preview.close"), QStringLiteral("preview.open"), QStringLiteral("preview.forward")}) {
      mc.onRpc(method, [this](const FakeMc::Rpc& rpc) { held.append({rpc, {}}); });
    }
    client = std::make_unique<McClient>();
    client->setRetryDelays({20});
    client->open(mc.origin(), QStringLiteral("token"));
    RC_ASSERT(halc2::prop::until([this] { return client->isReady(); }));
    previews = std::make_unique<ThreadPreviews>(
        client.get(),
        [this](const QString&, const QString& title, const QString&) {
          if (title == QLatin1String("Could not open the page")) ++linkErrors;
        },
        [this](const QUrl& url) { browsed(url); });
    previews->setConnectedHere([this] { return here; });
    tester = std::make_unique<QAbstractItemModelTester>(previews.get(), QAbstractItemModelTester::FailureReportingMode::Warning);
    QObject::connect(previews.get(), &QAbstractItemModel::dataChanged, previews.get(),
                     [this](const QModelIndex& top, const QModelIndex& bottom) {
                       for (int row = top.row(); row <= bottom.row(); ++row) redrawn.append(rows().value(row).tabId);
                     });
    QObject::connect(previews.get(), &QAbstractItemModel::modelReset, previews.get(), [this] { ++resets; });
    QObject::connect(previews.get(), &ThreadPreviews::countChanged, previews.get(), [this] { ++countSignals; });
  }

  ~Sut() {
    tester.reset();
    previews.reset();
    client.reset();
  }

  // Every frame each side sent before this has been read by the other.
  void barrier() {
    bool answered = false;
    client->call(&barrierContext, kEnvironment, QStringLiteral("prop.barrier"), QJsonObject(),
                 [&answered](const QJsonValue&, const std::optional<QString>&) { answered = true; });
    RC_ASSERT(halc2::prop::until([&] { return answered; }));
  }

  QList<Row> rows() const {
    QList<Row> rows;
    for (int at = 0; at < previews->rowCount(); ++at) {
      const QModelIndex index = previews->index(at);
      rows.append({index.data(ThreadPreviews::TabIdRole).toString(), index.data(ThreadPreviews::UrlRole).toString(),
                   index.data(ThreadPreviews::TitleRole).toString(), index.data(ThreadPreviews::StatusRole).toString(),
                   index.data(ThreadPreviews::ProblemRole).toString()});
    }
    return rows;
  }

  void begin() {
    before = rows();
    redrawn.clear();
    resets = 0;
    countSignals = 0;
    modelTestFailures = 0;
  }

  // A PreviewEvent to every watcher, as preview.ex emit/4.
  void emitEvent(const QJsonObject& tab, const QString& type, QJsonObject fields = {}) {
    fields.insert(QStringLiteral("type"), type);
    fields.insert(QStringLiteral("threadId"), tab.value(QLatin1String("threadId")));
    fields.insert(QStringLiteral("tabId"), tab.value(QLatin1String("tabId")));
    fields.insert(QStringLiteral("serverEpoch"), epoch);
    fields.insert(QStringLiteral("revision"), ++revision);
    for (const int id : mc.subscribers(QStringLiteral("preview"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("preview")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), fields}});
    }
  }

  int indexOf(const QString& tabId) const {
    for (qsizetype at = 0; at < tabs.size(); ++at) {
      if (tabs.at(at).value(QLatin1String("tabId")).toString() == tabId) return int(at);
    }
    return -1;
  }

  QJsonObject newTab(const QString& thread, const QString& url) {
    const QString id = QStringLiteral("tab-%1").arg(++opened);
    threadOf.insert(id, thread);
    QJsonObject nav{{QStringLiteral("_tag"), url.isEmpty() ? QStringLiteral("Idle") : QStringLiteral("Success")}};
    if (!url.isEmpty()) nav.insert(QStringLiteral("url"), url);
    QJsonObject tab{{QStringLiteral("threadId"), thread}, {QStringLiteral("tabId"), id}, {QStringLiteral("navStatus"), nav}};
    tabs.append(tab);
    emitEvent(tab, QStringLiteral("opened"), {{QStringLiteral("snapshot"), tab}});
    return tab;
  }

  // Whether one of the thread's tabs on the MC is at a loopback address at the port,
  // which preview_forward.ex's grant asks.
  bool tabAt(const QString& thread, int port) const {
    for (const QJsonObject& tab : tabs) {
      const QUrl at(tab.value(QLatin1String("navStatus")).toObject().value(QLatin1String("url")).toString());
      if (tab.value(QLatin1String("threadId")).toString() == thread && loopback(at) && portOf(at) == port) return true;
    }
    return false;
  }

  // Answers the held call, or refuses it.
  void answer(int at, bool ok) {
    const Held call = held.takeAt(at);
    const QString method = call.rpc.method;
    const QJsonObject payload = call.rpc.payload;
    const QString thread = payload.value(QLatin1String("threadId")).toString();
    if (method == QLatin1String("preview.forward") ? call.rpc.environment != kEnvironment || payload.value(QLatin1String("environmentId")).toString() != environmentOf(thread)
                                                   : call.rpc.environment != environmentOf(thread)) {
      misrouted.append(method + QLatin1Char(' ') + thread + QStringLiteral(" at ") + call.rpc.environment);
    }
    const int port = payload.value(QLatin1String("port")).toInt();
    if (!ok || (method == QLatin1String("preview.open") && tabs.size() >= kMaxTabs) ||
        (method == QLatin1String("preview.forward") && !tabAt(thread, port))) {
      mc.refuse(call.rpc, QStringLiteral("no"));
      return;
    }
    if (method == QLatin1String("preview.list")) {
      mc.reply(call.rpc, call.list);
    } else if (method == QLatin1String("preview.close")) {
      const int index = indexOf(payload.value(QLatin1String("tabId")).toString());
      if (index >= 0) emitEvent(tabs.takeAt(index), QStringLiteral("closed"));
      mc.reply(call.rpc, QJsonValue::Null);
    } else if (method == QLatin1String("preview.forward")) {
      granted.append({thread, port});
      mc.reply(call.rpc, QJsonObject{{QStringLiteral("port"), forwardPortOf(port)}});
    } else {
      mc.reply(call.rpc, newTab(thread, payload.value(QLatin1String("url")).toString()));
    }
  }

  // The browser opens `url`: a waiting link it is. One that does not forward
  // opens as it is; one that does, through a forward granted for its thread
  // at its port (at 127.0.0.1 for an address), or as it is when the connected
  // MC is not here now, as ThreadPreviews asks again on the answer that opens
  // it. A link opened at once is taken first, so a waiting one is not taken
  // for it.
  void browsed(const QUrl& url) {
    const auto fits = [&](const Link& link) {
      if (url == link.url && (!link.forwards || !here)) return true;
      if (!link.forwards) return false;
      QUrl forwarded = link.url;
      forwarded.setPort(forwardPortOf(portOf(link.url)));
      if (!QHostAddress(forwarded.host()).isNull()) forwarded.setHost(QStringLiteral("127.0.0.1"));
      return url == forwarded && std::any_of(granted.cbegin(), granted.cend(), [&](const Forward& forward) {
               return forward.thread == link.thread && forward.port == portOf(link.url);
             });
    };
    for (const bool waiting : {false, true}) {
      for (qsizetype at = 0; at < links.size(); ++at) {
        if (links.at(at).forwards == waiting && fits(links.at(at))) {
          links.removeAt(at);
          return;
        }
      }
    }
    stray.append(url);
  }

  void check(const Model& model) {
    barrier();
    const QList<Row> now = rows();
    RC_ASSERT(modelTestFailures == 0);
    RC_ASSERT(misrouted.isEmpty());
    RC_ASSERT(stray.isEmpty());
    RC_ASSERT(std::all_of(links.cbegin(), links.cend(), [](const Link& link) { return link.forwards; }));
    // Once nothing is held, every link opened or said why not.
    if (held.isEmpty()) {
      RC_ASSERT(int(links.size()) == linkErrors);
      links.clear();
      linkErrors = 0;
    }
    RC_ASSERT(previews->property("count").toInt() == now.size());
    RC_ASSERT(now.size() == before.size() || countSignals > 0);
    RC_ASSERT(resets == 0 || now != before);  // a reset for nothing
    QSet<QString> ids;
    QString empty;
    for (const Row& row : now) {
      RC_ASSERT(threadOf.value(row.tabId) == model.thread);
      RC_ASSERT(!ids.contains(row.tabId));
      ids.insert(row.tabId);
      if (empty.isEmpty() && row.url.isEmpty()) empty = row.tabId;
      const auto was = std::find_if(before.cbegin(), before.cend(), [&](const Row& old) { return old.tabId == row.tabId; });
      if (was != before.cend() && *was == row) RC_ASSERT(!redrawn.contains(row.tabId));  // a repaint for nothing
    }
    RC_ASSERT(previews->emptyTab() == empty);
    if (!held.isEmpty() || !model.active || model.thread.isEmpty()) return;
    RC_ASSERT(previews->status() != QStringLiteral("loading"));
    if (previews->status() != QStringLiteral("ready")) return;
    QList<Row> want;
    for (const QJsonObject& tab : std::as_const(tabs)) {
      if (tab.value(QLatin1String("threadId")).toString() == model.thread) want.append(rowOf(tab));
    }
    RC_ASSERT(now == want);
  }
};

using Command = rc::state::Command<Model, Sut>;

// A step: what it does to the client or the MC, then the checks.
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    act(next, sut);
    sut.check(next);
  }
  virtual void act(const Model& model, Sut& sut) const = 0;
};

// The user opens a thread (or the one shown moves on).
struct SetThread : Step {
  QString thread = pick(kThreads);
  void apply(Model& model) const override { model.thread = thread; }
  void act(const Model&, Sut& sut) const override { sut.previews->setThread(environmentOf(thread), thread, mcOf(thread)); }
  void show(std::ostream& os) const override { os << "SetThread(" << thread.toStdString() << ")"; }
};

struct SetActive : Step {
  bool active = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.active = active; }
  void act(const Model&, Sut& sut) const override { sut.previews->setActive(active); }
  void show(std::ostream& os) const override { os << "SetActive(" << active << ")"; }
};

struct Reload : Step {
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override { sut.previews->reload(); }
  void show(std::ostream& os) const override { os << "Reload"; }
};

struct UserClose : Step {
  QString tab = pick(kTabs);
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override { sut.previews->close(tab); }
  void show(std::ostream& os) const override { os << "UserClose(" << tab.toStdString() << ")"; }
};

struct UserNewTab : Step {
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override { sut.previews->newTab(); }
  void show(std::ostream& os) const override { os << "UserNewTab"; }
};

// The user opens a link for the thread shown, from a reply or the address bar.
struct OpenLink : Step {
  QString url = pick(kLinks);
  void apply(Model&) const override {}
  void act(const Model& model, Sut& sut) const override {
    if (model.thread.isEmpty()) return;
    const bool remote = environmentOf(model.thread) != kEnvironment;
    sut.links.append({model.thread, QUrl(url), remote && loopback(QUrl(url)) && sut.here});
    sut.previews->openAddress(url);
  }
  void show(std::ostream& os) const override { os << "OpenLink(" << url.toStdString() << ")"; }
};

// The connected MC is on this machine, or on another (as one reached over the network).
struct SetHere : Step {
  bool here = *rc::gen::arbitrary<bool>();
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    sut.here = here;
  }
  void show(std::ostream& os) const override { os << "SetHere(" << here << ")"; }
};

// The MC answers one held call (the `at`th, wrapping), or refuses it.
struct Answer : Step {
  int at = *rc::gen::inRange(0, 4);
  bool ok = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    if (!sut.held.isEmpty()) sut.answer(at % int(sut.held.size()), ok);
  }
  void show(std::ostream& os) const override { os << "Answer(" << at << (ok ? "" : ", refused") << ")"; }
};

// The MC answers everything it holds, and what those answers make the client ask.
struct AnswerAll : Step {
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    for (int round = 0; round < 8 && !sut.held.isEmpty(); ++round) {
      while (!sut.held.isEmpty()) sut.answer(0, true);
      sut.barrier();
    }
  }
  void show(std::ostream& os) const override { os << "AnswerAll"; }
};

// An agent opens a tab in a thread.
struct McOpen : Step {
  QString thread = pick(kThreads);
  QString url = pick(kUrls);
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    if (sut.tabs.size() < kMaxTabs) sut.newTab(thread, url);
  }
  void show(std::ostream& os) const override { os << "McOpen(" << thread.toStdString() << ", " << url.toStdString() << ")"; }
};

// A tab goes to a page (or the same one again), or its page names itself.
struct McNavigate : Step {
  QString tab = pick(kTabs);
  QString url = pick(kUrls.mid(1));
  QString title = pick({QString(), QStringLiteral("App")});
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    const int at = sut.indexOf(tab);
    if (at < 0) return;
    sut.tabs[at].insert(QStringLiteral("navStatus"),
                        QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), url}, {QStringLiteral("title"), title}});
    sut.emitEvent(sut.tabs.at(at), QStringLiteral("navigated"), {{QStringLiteral("snapshot"), sut.tabs.at(at)}});
  }
  void show(std::ostream& os) const override { os << "McNavigate(" << tab.toStdString() << ", " << url.toStdString() << ", " << title.toStdString() << ")"; }
};

// A tab's page does not load.
struct McFail : Step {
  QString tab = pick(kTabs);
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    const int at = sut.indexOf(tab);
    if (at < 0) return;
    const QJsonObject nav = sut.tabs.at(at).value(QLatin1String("navStatus")).toObject();
    const QString url = nav.value(QLatin1String("url")).toString();
    sut.tabs[at].insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("LoadFailed")},
                                                                 {QStringLiteral("url"), url},
                                                                 {QStringLiteral("description"), QStringLiteral("refused")}});
    sut.emitEvent(sut.tabs.at(at), QStringLiteral("failed"), {{QStringLiteral("url"), url}, {QStringLiteral("description"), QStringLiteral("refused")}});
  }
  void show(std::ostream& os) const override { os << "McFail(" << tab.toStdString() << ")"; }
};

// An agent closes a tab.
struct McClose : Step {
  QString tab = pick(kTabs);
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    const int at = sut.indexOf(tab);
    if (at >= 0) sut.emitEvent(sut.tabs.takeAt(at), QStringLiteral("closed"));
  }
  void show(std::ostream& os) const override { os << "McClose(" << tab.toStdString() << ")"; }
};

// The MC starts again: the connection drops with what it held unanswered, and
// the client reconnects to a new epoch, revisions from the start, its browser's
// tabs gone (or, `keep`, some still open in another MC's browser).
struct McRestart : Step {
  bool keep = *rc::gen::arbitrary<bool>();
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const override {
    QSignalSpy ready(sut.client.get(), &McClient::readyChanged);
    RC_ASSERT(sut.mc.connected());
    sut.mc.drop();
    sut.held.clear();
    sut.epoch = QStringLiteral("epoch-%1").arg(sut.epoch.mid(6).toInt() + 1);
    sut.revision = 0;
    if (!keep) sut.tabs.clear();
    RC_ASSERT(halc2::prop::until([&] { return !ready.isEmpty() && ready.last().first().toBool(); }, 1000));
  }
  void show(std::ostream& os) const override { os << "McRestart(" << (keep ? "tabs kept" : "tabs gone") << ")"; }
};

}  // namespace

class TimelinePreviewsProp : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { previousHandler = qInstallMessageHandler(countModelTestFailures); }
  void cleanupTestCase() { qInstallMessageHandler(previousHandler); }

  void previews() {
    QVERIFY(rc::check("the previews list is the MC's tabs of the thread shown, redrawn only where they changed, and a link opens where it should", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<SetThread, SetActive, Reload, UserClose, UserNewTab, OpenLink, OpenLink, SetHere,
                                                         Answer, Answer, AnswerAll, McOpen, McOpen, McNavigate, McFail, McClose, McRestart>());
    }));
  }
};

HAL_C2_PROP_MAIN(TimelinePreviewsProp)
#include "tst_TimelinePreviewsProp.moc"
