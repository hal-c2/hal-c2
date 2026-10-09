// The QR codes pairing links are shown as (QrCode.h) for any text: encode, the
// SVG path of the dark modules, and the image at a small scale. Over-long text
// is no code rather than an exception, and what is drawn is exactly the code.

#include "Fuzz.h"
#include "QrCode.h"

#include <QRegularExpression>

#include <cstddef>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What a pairing link and the MC's own links are made of.
const std::vector<std::string> kTextWords{"https://", "hal-c2://pair?pairingUrl=", "pair", "#token=", "token=",
                                          "%", "&", ":", "/", "[", "]", "3797", "a", "\n", " "};

// Byte-mode capacity at error correction M, the one encode uses (version 40).
constexpr std::size_t kMaxBytesM = 2331;

// The modules `path` draws, as `M<x> <y>h<run>v1h-<run>z` runs; nothing else
// may be in it.
QBitArray drawn(const QString& path, int size, bool& wellFormed) {
  static const QRegularExpression run(QStringLiteral("M(\\d+) (\\d+)h(\\d+)v1h-\\3z"));
  QBitArray modules(size * size);
  qsizetype consumed = 0;
  auto it = run.globalMatch(path);
  while (it.hasNext()) {
    const QRegularExpressionMatch match = it.next();
    if (match.capturedStart() != consumed) wellFormed = false;
    consumed = match.capturedEnd();
    const int x = match.captured(1).toInt();
    const int y = match.captured(2).toInt();
    const int length = match.captured(3).toInt();
    if (x + length > size || y >= size) {
      wellFormed = false;
      return modules;
    }
    for (int i = 0; i < length; ++i) {
      if (modules.testBit(y * size + x + i)) wellFormed = false;
      modules.setBit(y * size + x + i);
    }
  }
  if (consumed != path.size()) wellFormed = false;
  return modules;
}

void EncodeRenders(const std::string& text, std::size_t pad, int scale) {
  const QString entered = fuzz::utf8(text + std::string(pad, 'a'));
  // A NUL byte ends the text where encode reads it (QrCode.cpp constData), so
  // what is encoded is a prefix and the laws below do not hold for it.
  if (entered.contains(QChar(0))) return;
  const qr::Code code = qr::encode(entered);
  const QString svg = qr::path(code);
  const QImage image = qr::image(code, scale);
  if (entered.isEmpty() || entered.toUtf8().size() > int(kMaxBytesM)) {
    // Too long for any code: no code, and nothing drawn, rather than a throw.
    EXPECT_TRUE(code.isNull()) << entered.toUtf8().size() << " bytes";
    EXPECT_TRUE(svg.isEmpty());
    EXPECT_TRUE(image.isNull());
    return;
  }
  ASSERT_FALSE(code.isNull()) << entered.toUtf8().size() << " bytes";
  // Version 1 to 40: 21 to 177 modules a side.
  ASSERT_TRUE(code.size >= 21 && code.size <= 177 && (code.size - 17) % 4 == 0) << code.size;
  ASSERT_EQ(code.modules.size(), code.size * code.size);

  bool wellFormed = true;
  const QBitArray modules = drawn(svg, code.size, wellFormed);
  EXPECT_TRUE(wellFormed) << "path: " << svg.toStdString();
  EXPECT_EQ(modules, code.modules) << "path draws other modules than the code's";

  ASSERT_FALSE(image.isNull());
  EXPECT_EQ(image.width(), (code.size + 8) * scale);
  EXPECT_EQ(image.height(), (code.size + 8) * scale);
  // The quiet zone is white; each module is black where dark, white otherwise.
  EXPECT_EQ(image.pixel(0, 0), 0xffffffffu);
  for (int y = 0; y < code.size; ++y) {
    for (int x = 0; x < code.size; ++x) {
      const QRgb pixel = image.pixel((x + 4) * scale, (y + 4) * scale);
      EXPECT_EQ(pixel, code.dark(x, y) ? 0xff000000u : 0xffffffffu) << "module " << x << "," << y;
    }
  }
}
FUZZ_TEST(QrCode, EncodeRenders)
    .WithDomains(fuzztest::Arbitrary<std::string>().WithMaxSize(128).WithDictionary(kTextWords), fuzztest::InRange<std::size_t>(0, 128),
                 fuzztest::InRange<int>(1, 4))
    .WithSeeds([] {
      return std::vector<std::tuple<std::string, std::size_t, int>>{
          {"https://devbox.tailnet.ts.net:3797/pair#token=abc123", 0, 1},
          {"hal-c2://pair?pairingUrl=https%3A%2F%2Fmc.example%3A3797%2Fpair%23token%3Dabc", 0, 4},
          {"", 0, 2},
          {"", 128, 3},
      };
    });

// Up to and past the largest code: what is too long is no code, with nothing
// drawn, and what fits is a code. Kept apart from EncodeRenders, since a
// largest code is slow to draw.
void OverLongIsNoCode(const std::string& text, std::size_t pad) {
  const QString entered = fuzz::utf8(text + std::string(pad, 'a'));
  if (entered.contains(QChar(0))) return;  // see EncodeRenders
  if (entered.isEmpty()) return;
  const qr::Code code = qr::encode(entered);
  if (entered.toUtf8().size() > int(kMaxBytesM)) {
    EXPECT_TRUE(code.isNull()) << entered.toUtf8().size() << " bytes";
    EXPECT_TRUE(qr::path(code).isEmpty());
    EXPECT_TRUE(qr::image(code, 2).isNull());
  } else {
    EXPECT_FALSE(code.isNull()) << entered.toUtf8().size() << " bytes";
  }
}
FUZZ_TEST(QrCode, OverLongIsNoCode)
    .WithDomains(fuzz::Text(kTextWords), fuzztest::InRange<std::size_t>(0, 2400))
    .WithSeeds([] {
      return std::vector<std::tuple<std::string, std::size_t>>{{"", 2331}, {"", 2332}, {"x", 2400}, {"https://mc.example/pair#token=x", 0}};
    });

}  // namespace
