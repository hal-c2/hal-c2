#pragma once

#include <QBitArray>
#include <QImage>
#include <QString>

// A text as a QR code, for what a phone's camera is to read off the screen (a
// pairing link). Nayuki's generator (cmake/QrCodeGen.cmake) does the encoding.
namespace qr {

struct Code {
  // Modules along a side; 0 when the text did not fit a QR code.
  int size = 0;
  // The dark modules, row by row.
  QBitArray modules;

  bool isNull() const { return size == 0; }
  bool dark(int x, int y) const { return modules.testBit(y * size + x); }
};

// Error correction M, which a screen needs no more than: the smallest
// version that holds `text` as bytes.
Code encode(const QString& text);

// The dark modules as an SVG path of unit squares ("M3 0h1v1h-1z…"), runs of
// them joined, for a Shape to fill at any size. Empty for a null code.
QString path(const Code& code);

// Black on white, `scale` pixels a module, with the quiet zone of four
// modules a reader wants around it.
QImage image(const Code& code, int scale);

}  // namespace qr
