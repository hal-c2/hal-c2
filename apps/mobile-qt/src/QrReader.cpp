#include "QrReader.h"

#include <QVideoFrame>
#include <QVideoFrameFormat>

#include <ReadBarcode.h>

namespace qr {

namespace {

// The formats whose first plane is the picture's brightness, a byte a pixel.
bool startsWithLuminance(QVideoFrameFormat::PixelFormat format) {
  switch (format) {
    case QVideoFrameFormat::Format_YUV420P:
    case QVideoFrameFormat::Format_YUV422P:
    case QVideoFrameFormat::Format_YV12:
    case QVideoFrameFormat::Format_NV12:
    case QVideoFrameFormat::Format_NV21:
    case QVideoFrameFormat::Format_IMC1:
    case QVideoFrameFormat::Format_IMC2:
    case QVideoFrameFormat::Format_IMC3:
    case QVideoFrameFormat::Format_IMC4:
    case QVideoFrameFormat::Format_Y8:
      return true;
    default:
      return false;
  }
}

}  // namespace

QImage luminance(const QVideoFrame& frame) {
  // Mapped first, converted only when that fails: a frame that is a texture
  // (Qt Multimedia's Android backend hands those out) maps to its pixels,
  // while toImage() draws it with a graphics context of its own that the
  // texture does not belong to, and gives a black picture.
  QVideoFrame mapped = frame;
  if (mapped.map(QVideoFrame::ReadOnly)) {
    QImage picture;
    if (startsWithLuminance(mapped.pixelFormat())) {
      // The copy outlives the mapping.
      picture = QImage(mapped.bits(0), mapped.width(), mapped.height(), mapped.bytesPerLine(0), QImage::Format_Grayscale8).copy();
    } else if (const QImage::Format pixels = QVideoFrameFormat::imageFormatFromPixelFormat(mapped.pixelFormat()); pixels != QImage::Format_Invalid) {
      picture = QImage(mapped.bits(0), mapped.width(), mapped.height(), mapped.bytesPerLine(0), pixels).convertToFormat(QImage::Format_Grayscale8);
    }
    mapped.unmap();
    if (!picture.isNull()) return picture;
  }
  return frame.toImage().convertToFormat(QImage::Format_Grayscale8);
}

QStringList read(const QImage& picture) {
  if (picture.isNull()) return {};
  const QImage gray = picture.format() == QImage::Format_Grayscale8 ? picture : picture.convertToFormat(QImage::Format_Grayscale8);
  QStringList texts;
  try {
    const ZXing::ImageView view(gray.constBits(), static_cast<int>(gray.sizeInBytes()), gray.width(), gray.height(), ZXing::ImageFormat::Lum,
                                static_cast<int>(gray.bytesPerLine()));
    const ZXing::ReaderOptions options = ZXing::ReaderOptions().formats(ZXing::BarcodeFormat::QRCode).maxNumberOfSymbols(4);
    for (const ZXing::Barcode& code : ZXing::ReadBarcodes(view, options)) {
      if (code.isValid()) texts.append(QString::fromStdString(code.text()));
    }
  } catch (const std::exception&) {
    // A picture it cannot take is one with no code in it.
  }
  return texts;
}

}  // namespace qr
