#pragma once

#include <QImage>
#include <QStringList>

class QVideoFrame;

// Reading QR codes off a camera's picture (zxing-cpp, cmake/Scanner.cmake).
// The other half of the desktop's qr::encode.
namespace qr {

// What a frame shows as one byte of brightness a pixel, which is all a
// reader looks at. Most cameras' formats carry that as their first plane,
// which is copied as it is; any other frame's pixels are converted. Null for
// a frame that cannot be read.
QImage luminance(const QVideoFrame& frame);

// The text of every QR code in the picture, however it is turned and
// wherever it sits; none when there is none. Slow enough (some milliseconds
// a megapixel) to belong off the thread that draws.
QStringList read(const QImage& picture);

}  // namespace qr
