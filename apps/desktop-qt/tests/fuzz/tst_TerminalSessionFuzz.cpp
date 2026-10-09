// A terminal the drawer shows (TerminalSession, TerminalController.h) fed any
// sequence of `terminal` frames while the Terminal writes and resizes: the
// attach's snapshot, output, clears, restarts, exits, errors and the MC
// closing it, with any fields. It must not crash, and its transcript, which
// lets a Terminal made later catch up, must stay what was shown, capped.
// Writes against a live MC (WritesKeepPairs) must arrive whole, in order,
// with no UTF-16 surrogate pair split across two calls.

#include "Fuzz.h"
#include "Reach.h"

#include <QDeadlineTimer>
#include <QEventLoop>
#include <QPointer>
#include <QSignalSpy>
#include <QSize>

#include <algorithm>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

#include "../native/features/FakeMc.h"
#include "McClient.h"
#include "TerminalController.h"

namespace halc2::fuzz {
struct TerminalOnFrame {
  using type = void (TerminalSession::*)(const QJsonObject&);
  friend type reach(TerminalOnFrame);
};
template struct Reach<TerminalOnFrame, &TerminalSession::onFrame>;
}  // namespace halc2::fuzz

using namespace halc2;

namespace {

// TerminalController.cpp's.
constexpr qsizetype kMaxWrite = 65536;
constexpr qsizetype kMaxTranscript = 512 * 1024;

// U+1F600 as UTF-16 code units (little endian): a pair, its high half, its low half.
const std::string kPair("\x3d\xd8\x00\xde", 4), kHigh("\x3d\xd8", 2), kLow("\x00\xde", 2);

const std::vector<std::string> kKeys{"t", "id", "event", "type", "snapshot", "history", "data", "message", "reason",
                                     "threadId", "terminalId", "status", "cwd", "pid", "cols", "rows", "exitCode", "label"};
const std::vector<std::string> kTexts{"terminal", "error", "snapshot", "restarted", "output", "cleared", "exited",
                                      "closed", "started", "running", "hello\r\n", "\x1b[31mred\x1b[0m", "\x1b[2J\x1b[H",
                                      "\xf0\x9f\x98\x80", "\xed\xa0\xbd", "terminal-1", "t1", "boom", "Unknown terminal"};

TerminalPlace place() {
  TerminalPlace result;
  result.environmentId = QStringLiteral("env-a");
  result.threadId = QStringLiteral("t1");
  result.cwd = QStringLiteral("/work/p1");
  return result;
}

// What each step of a run does: a frame from the MC, then the Terminal's own
// calls. `inflate` is the length of an `output` frame made of one character,
// to carry the transcript past its cap; cols and rows are any ints.
using Step = std::tuple<fuzz::JsonSteps, std::string, int, int, std::uint32_t>;

QString Chars(qsizetype length) { return QString(length, QLatin1Char('x')); }

void FramesFold(const std::vector<Step>& steps, bool settleEach, int attachAt) {
  McClient client;
  TerminalSession session(&client, place(), QStringLiteral("terminal-1"), QSize(80, 24));
  const auto onFrame = reach(fuzz::TerminalOnFrame{});
  // What the Terminal was shown since its screen was last replaced.
  QStringList shown;
  QObject::connect(&session, &TerminalSession::output, &session, [&shown](const QString& data) { shown.append(data); });
  QObject::connect(&session, &TerminalSession::replaced, &session, [&shown](const QString& history) {
    shown.clear();
    if (!history.isEmpty()) shown.append(history);
  });
  qsizetype last = -1;
  int index = 0;
  for (const Step& step : steps) {
    if (index++ == attachAt) {
      (session.*onFrame)({{QStringLiteral("t"), QStringLiteral("terminal")},
                          {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")},
                                                                {QStringLiteral("snapshot"), QJsonObject{{QStringLiteral("history"), QStringLiteral("$ ")}}}}}});
    }
    const QJsonObject frame = fuzz::object(std::get<0>(step));
    fuzz::print(frame);
    (session.*onFrame)(frame);
    session.write(fuzz::utf16(std::get<1>(step)));
    session.resize(std::get<2>(step), std::get<3>(step));
    if (const std::uint32_t inflate = std::get<4>(step); inflate > 0) {
      (session.*onFrame)({{QStringLiteral("t"), QStringLiteral("terminal")},
                          {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("output")},
                                                                {QStringLiteral("data"), Chars(inflate)}}}});
    }
    if (settleEach) fuzz::settle();
    // The transcript is what was shown from the last replacement, its oldest
    // pieces let go once it passes the cap, and never past it but for one piece.
    const QString transcript = session.transcript();
    last = transcript.size();
    ASSERT_TRUE(last <= kMaxTranscript || (!shown.isEmpty() && shown.last() == transcript)) << last;
    bool suffix = false;
    for (qsizetype from = 0; from <= shown.size() && !suffix; ++from) {
      suffix = QStringList(shown.mid(from)).join(QString()) == transcript;
    }
    ASSERT_TRUE(suffix) << "the transcript is not the tail of what was shown";
  }
  fuzz::settle();
  session.size();
  session.transcript();
}
FUZZ_TEST(TerminalSession, FramesFold)
    .WithDomains(fuzztest::VectorOf(fuzztest::TupleOf(fuzz::Json(kKeys, kTexts, 48), fuzz::Text({"a", kPair, kHigh}),
                                                      fuzztest::Arbitrary<int>(), fuzztest::Arbitrary<int>(),
                                                      fuzztest::InRange<std::uint32_t>(0, 300000)))
                     .WithMaxSize(8),
                 fuzztest::Arbitrary<bool>(), fuzztest::InRange(-1, 8))
    .WithSeeds([] {
      const auto frames = [](std::initializer_list<std::string_view> json) {
        std::vector<Step> all;
        for (std::string_view one : json) all.emplace_back(fuzz::steps(one), std::string(), 100, 30, 0);
        return all;
      };
      std::vector<Step> typing = frames({R"j({"t":"terminal","id":1,"event":{"type":"snapshot","snapshot":{"threadId":"t1","terminalId":"terminal-1","status":"running","cwd":"/work/p1","pid":42,"history":"$ ls\r\n"}}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"output","data":"a.txt\r\n$ "}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"cleared"}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"restarted","snapshot":{"history":"new\r\n"}}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"error","message":"boom"}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"exited","exitCode":0}})j",
                                         R"j({"t":"terminal","id":1,"event":{"type":"closed"}})j"});
      std::get<1>(typing[1]) = kPair;
      std::get<4>(typing[1]) = 300000;
      std::get<4>(typing[2]) = 300000;
      std::vector<Step> refused = frames({R"j({"t":"error","id":1,"reason":"Unknown terminal"})j"});
      return std::vector<std::tuple<std::vector<Step>, bool, int>>{{typing, true, -1}, {typing, false, 2}, {refused, true, -1}};
    });

// A live MC (FakeMc over a socket), shared by every input: the terminal shape
// is answered with a snapshot, and `terminal.write` is kept and answered.
struct Live {
  FakeMc mc;
  McClient client;
  QList<int> shapes;
  QStringList writes;
  Live() {
    mc.onShape(QStringLiteral("terminal"), [this](int id, const QJsonObject&) { shapes.append(id); });
    mc.onRpc(QStringLiteral("terminal.write"), [this](const FakeMc::Rpc& rpc) {
      writes.append(rpc.payload.value(QLatin1String("data")).toString());
      mc.reply(rpc, QJsonValue::Null);
    });
    client.open(mc.origin(), QStringLiteral("token"));
    spinUntil([this] { return client.isReady(); });
  }
  // Runs events until `done`, which a live MC on this machine answers at once;
  // the deadline is only for an MC that never does.
  template <class Done>
  bool spinUntil(Done done) {
    QDeadlineTimer deadline(30000);
    while (!done() && !deadline.hasExpired()) QCoreApplication::processEvents(QEventLoop::WaitForMoreEvents, 50);
    return done();
  }
};
Live& live() {
  static Live* instance = new Live;  // outlives the application object, as the process does
  return *instance;
}

// `text` written (in `parts` calls, never cut inside a pair) reaches the MC as
// the same text: in order, in calls of at most kMaxWrite units, none ending
// between the two halves of a surrogate pair.
void WritesKeepPairs(const std::string& piece, std::uint8_t pad, std::uint32_t repeat, std::uint8_t parts, bool beforeAttach) {
  Live& l = live();
  QString text = QString(pad, QLatin1Char('a'));
  const QString unit = fuzz::utf16(piece);
  if (unit.isEmpty()) return;
  for (std::uint32_t i = 0; i < repeat && text.size() < 3 * kMaxWrite; ++i) text += unit;
  // A lone surrogate may reach the MC as U+FFFD; the pairs are compared by where the calls cut.
  const auto plain = [](QString value) {
    for (QChar& unit : value) {
      if (unit.isSurrogate()) unit = QChar(0xFFFD);
    }
    return value;
  };
  const QString expected = plain(text);
  l.writes.clear();
  l.shapes.clear();
  TerminalSession session(&l.client, place(), QStringLiteral("terminal-1"), QSize(80, 24));
  ASSERT_TRUE(l.spinUntil([&l] { return !l.shapes.isEmpty(); }));
  const int id = l.shapes.last();
  const auto attach = [&] {
    QSignalSpy attached(&session, &TerminalSession::attached);
    l.mc.send({{QStringLiteral("t"), QStringLiteral("terminal")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")},
                                                     {QStringLiteral("snapshot"), QJsonObject{{QStringLiteral("history"), QString()}}}}}});
    ASSERT_TRUE(l.spinUntil([&attached] { return !attached.isEmpty(); }));
  };
  if (!beforeAttach) attach();
  // Parts cut where the text has no pair to cut.
  qsizetype from = 0;
  for (int part = 1; part <= std::max<int>(parts, 1); ++part) {
    qsizetype to = part == std::max<int>(parts, 1) ? text.size() : text.size() * part / std::max<int>(parts, 1);
    if (to > from && to < text.size() && text.at(to - 1).isHighSurrogate() && text.at(to).isLowSurrogate()) ++to;
    if (to > from) session.write(text.mid(from, to - from));
    from = std::max(from, to);
  }
  if (beforeAttach) attach();
  QString received;
  const bool arrived = l.spinUntil([&] {
    received = l.writes.join(QString());
    return received.size() >= expected.size();
  });
  ASSERT_TRUE(arrived) << "writes never reached the MC: " << received.size() << " of " << expected.size();
  fuzz::print(QString(unit));
  for (const QString& call : std::as_const(l.writes)) {
    ASSERT_LE(call.size(), kMaxWrite);
    ASSERT_FALSE(call.isEmpty());
  }
  ASSERT_EQ(received.size(), expected.size());
  // Text that is well-formed UTF-16 arrives as it is: a pair cut in two would
  // come out as two U+FFFD. With lone halves in it only the rest can be told.
  const bool wellFormed = text == QString::fromUtf8(text.toUtf8());
  ASSERT_TRUE(wellFormed ? received == text : plain(received) == expected) << "a write was cut inside a surrogate pair or reordered";
}
FUZZ_TEST(TerminalSession, WritesKeepPairs)
    .WithDomains(fuzz::Text({"a", kPair, kHigh, kLow}), fuzztest::Arbitrary<std::uint8_t>(),
                 fuzztest::InRange<std::uint32_t>(0, 70000), fuzztest::InRange<std::uint8_t>(0, 4), fuzztest::Arbitrary<bool>())
    .WithSeeds({{kPair, 1, 40000, 1, false},
                {kPair, 0, 40000, 1, false},
                {kPair, 1, 40000, 3, true},
                {std::string("a\x00", 2), 0, 70000, 2, false}});

}  // namespace
