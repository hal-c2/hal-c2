#include "QrCode.h"

#include <QPainter>

#include <stdexcept>

#include <qrcodegen.hpp>

namespace qr {

Code encode(const QString& text) {
  if (text.isEmpty()) return {};
  try {
    const qrcodegen::QrCode generated = qrcodegen::QrCode::encodeText(text.toUtf8().constData(), qrcodegen::QrCode::Ecc::MEDIUM);
    Code code;
    code.size = generated.getSize();
    code.modules.resize(code.size * code.size);
    for (int y = 0; y < code.size; ++y) {
      for (int x = 0; x < code.size; ++x) code.modules.setBit(y * code.size + x, generated.getModule(x, y));
    }
    return code;
  } catch (const std::length_error&) {
    // Longer than the largest QR code holds.
    return {};
  }
}

QString path(const Code& code) {
  QString path;
  for (int y = 0; y < code.size; ++y) {
    for (int x = 0; x < code.size; ++x) {
      if (!code.dark(x, y)) continue;
      int run = 1;
      while (x + run < code.size && code.dark(x + run, y)) ++run;
      path += QStringLiteral("M%1 %2h%3v1h-%3z").arg(x).arg(y).arg(run);
      x += run - 1;
    }
  }
  return path;
}

QImage image(const Code& code, int scale) {
  if (code.isNull() || scale <= 0) return {};
  constexpr int kQuiet = 4;
  const int side = (code.size + 2 * kQuiet) * scale;
  QImage image(side, side, QImage::Format_RGB32);
  image.fill(Qt::white);
  QPainter painter(&image);
  for (int y = 0; y < code.size; ++y) {
    for (int x = 0; x < code.size; ++x) {
      if (code.dark(x, y)) painter.fillRect((x + kQuiet) * scale, (y + kQuiet) * scale, scale, scale, Qt::black);
    }
  }
  return image;
}

}  // namespace qr
