// The phone's push inbox (src/push/PushInbox) against a model of what it must
// show: MC messages that arrive late, early, twice, out of order, while the
// app is open or the system forbids notifications, with the user dismissing
// the activity card and turning live activity off and on, as time passes.
// An alert shows once, only when it is fresh, allowed and the app is away;
// the card follows the newest activity, stays away once dismissed until a run
// starts again, and goes when its lifetime ends.

#include "Prop.h"

#include <QSet>

#include <optional>

#include "push/PushInbox.h"

namespace {

constexpr qint64 kMinute = 60 * 1000;
constexpr qint64 kStart = 1'790'000'000'000;

struct Model {
  qint64 now = kStart;
  QSet<QString> seen;
  qint64 lastUpdate = 0;
  bool lastActive = false;
  bool dismissed = false;
  bool live = true;
  // The card on screen: whether it is for work in progress, and until when.
  std::optional<std::pair<bool, qint64>> card;
};

struct Sut {
  QTemporaryDir dir{QDir::tempPath() + QStringLiteral("/push-inbox-XXXXXX")};
  push::Inbox inbox{dir.path()};
  qint64 now = kStart;
  // What the system shows, as the effects say.
  std::optional<std::pair<QJsonObject, qint64>> card;
  QJsonObject lastAlert;

  void show(const QJsonObject& effects) {
    RC_ASSERT(effects.value(QLatin1String("channels")).toArray().size() == 2);
    lastAlert = effects.value(QLatin1String("alert")).toObject();
    if (effects.value(QLatin1String("cancelCard")).toBool()) card.reset();
    const QJsonObject shown = effects.value(QLatin1String("card")).toObject();
    if (!shown.isEmpty()) card = std::pair{shown, now};
  }

  void check(const Model& m) const {
    const bool visible = card && now < card->second + qint64(card->first.value(QLatin1String("timeoutMs")).toDouble());
    const bool expected = m.card && now < m.card->second;
    RC_ASSERT(visible == expected);
    if (visible) RC_ASSERT(card->first.value(QLatin1String("ongoing")).toBool() == m.card->first);
  }
};

using Command = rc::state::Command<Model, Sut>;

// When a message was sent, from where the phone's clock is.
enum class Sent { Now, Earlier, Later, Stale, Future };

qint64 sentAt(Sent sent, qint64 now) {
  switch (sent) {
    case Sent::Now: return now;
    case Sent::Earlier: return now - kMinute;
    case Sent::Later: return now + 30 * 1000;
    case Sent::Stale: return now - 11 * kMinute;
    case Sent::Future: return now + 60 * kMinute;
  }
  return now;
}

bool fresh(Sent sent) { return sent != Sent::Stale && sent != Sent::Future; }

const char* name(Sent sent) {
  switch (sent) {
    case Sent::Now: return "now";
    case Sent::Earlier: return "a minute ago";
    case Sent::Later: return "30 s ahead";
    case Sent::Stale: return "11 min ago";
    case Sent::Future: return "an hour ahead";
  }
  return "?";
}

rc::Gen<Sent> anySent() { return rc::gen::element(Sent::Now, Sent::Now, Sent::Earlier, Sent::Later, Sent::Stale, Sent::Future); }

// An alert the MC pushed, one of a few so that repeats happen.
struct Alert : Command {
  QString id = QStringLiteral("env-a:thread-%1:completed:run-1").arg(*rc::gen::inRange(1, 4));
  Sent sent = *anySent();
  bool foreground = *rc::gen::element(false, false, true);
  bool permitted = *rc::gen::element(true, true, true, false);
  explicit Alert(const Model&) {}

  bool counts() const { return fresh(sent) && permitted; }
  void apply(Model& m) const override {
    if (counts()) m.seen.insert(id);
  }
  void run(const Model& m, Sut& s) const override {
    const QJsonObject alert{{QStringLiteral("id"), id}, {QStringLiteral("kind"), QStringLiteral("completed")},
                            {QStringLiteral("title"), QStringLiteral("Fix checkout")}, {QStringLiteral("body"), QStringLiteral("Agent finished")},
                            {QStringLiteral("environmentId"), QStringLiteral("env-a")}, {QStringLiteral("threadId"), id.section(QLatin1Char(':'), 1, 1)}};
    s.show(s.inbox.deliver({{QStringLiteral("v"), 1}, {QStringLiteral("sentAt"), double(sentAt(sent, s.now))}, {QStringLiteral("alert"), alert}},
                           {s.now, foreground, permitted, 35}));
    const bool shows = counts() && !foreground && !m.seen.contains(id);
    RC_ASSERT(s.lastAlert.isEmpty() == !shows);
    if (shows) RC_ASSERT(s.lastAlert.value(QLatin1String("link")).toString() == QStringLiteral("hal-c2://threads/env-a/") + id.section(QLatin1Char(':'), 1, 1));
    Model next = m;
    apply(next);
    s.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Alert(" << id.toStdString() << ", sent " << name(sent) << (foreground ? ", app open" : "") << (permitted ? "" : ", not permitted") << ")";
  }
};

// The activity of one thread, working or done, as the MC (or the open app)
// pushes it.
struct Activity : Command {
  bool active = *rc::gen::arbitrary<bool>();
  Sent sent = *anySent();
  bool permitted = *rc::gen::element(true, true, true, false);
  explicit Activity(const Model&) {}

  QJsonObject activity(qint64 at) const {
    return push::activity({{active ? QStringLiteral("running") : QStringLiteral("completed"), QStringLiteral("Fix checkout"), QStringLiteral("shop"),
                            QStringLiteral("env-a"), QStringLiteral("thread-1"), at}},
                          at);
  }
  void apply(Model& m) const override {
    const qint64 at = sentAt(sent, m.now);
    if (!fresh(sent) || !permitted || at < m.lastUpdate) return;
    m.lastUpdate = at;
    const bool wasActive = std::exchange(m.lastActive, active);
    const qint64 until = qint64(activity(at).value(QLatin1String("expiresAt")).toDouble());
    if (until <= m.now || !m.live) {
      m.card.reset();
      m.dismissed = false;
      return;
    }
    if (active && !wasActive) m.dismissed = false;
    if (!m.dismissed) m.card = std::pair{active, until};
  }
  void run(const Model& m, Sut& s) const override {
    const qint64 at = sentAt(sent, s.now);
    s.show(s.inbox.deliver({{QStringLiteral("v"), 1}, {QStringLiteral("sentAt"), double(at)}, {QStringLiteral("activity"), activity(at)}},
                           {s.now, false, permitted, 35}));
    RC_ASSERT(s.lastAlert.isEmpty());
    Model next = m;
    apply(next);
    s.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Activity(" << (active ? "working" : "done") << ", sent " << name(sent) << (permitted ? "" : ", not permitted") << ")";
  }
};

struct Dismiss : Command {
  explicit Dismiss(const Model&) {}
  void apply(Model& m) const override {
    m.dismissed = true;
    m.card.reset();
  }
  void run(const Model& m, Sut& s) const override {
    s.show(s.inbox.dismiss());
    RC_ASSERT(s.inbox.dismissed());
    Model next = m;
    apply(next);
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Dismiss"; }
};

struct Live : Command {
  bool on = *rc::gen::arbitrary<bool>();
  explicit Live(const Model&) {}
  void apply(Model& m) const override {
    m.live = on;
    m.dismissed = false;
    if (!on) m.card.reset();
  }
  void run(const Model& m, Sut& s) const override {
    s.show(s.inbox.setLiveActivity(on));
    RC_ASSERT(s.inbox.liveActivity() == on);
    Model next = m;
    apply(next);
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Live(" << (on ? "on" : "off") << ")"; }
};

struct Wait : Command {
  qint64 ms = *rc::gen::element(qint64(1000), 5 * kMinute, 14 * kMinute, 16 * kMinute, 121 * kMinute);
  explicit Wait(const Model&) {}
  void apply(Model& m) const override { m.now += ms; }
  void run(const Model& m, Sut& s) const override {
    s.now += ms;
    Model next = m;
    apply(next);
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Wait(" << ms / 1000 << " s)"; }
};

}  // namespace

class PushInboxProp : public QObject {
  Q_OBJECT

private slots:
  void inbox() {
    QVERIFY(rc::check("the push inbox agrees with the model of what the phone shows", [] {
      Model model;
      Sut sut;
      RC_ASSERT(sut.dir.isValid());
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Alert, Alert, Activity, Activity, Activity, Dismiss, Live, Wait, Wait>());
    }));
  }
};

HAL_C2_PROP_MAIN(PushInboxProp)
#include "tst_PushInboxProp.moc"
