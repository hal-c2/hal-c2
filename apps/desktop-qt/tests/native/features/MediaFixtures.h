#pragma once

#include <QByteArray>
#include <QString>

// Real, tiny media for the scenarios: what a player or Qt PDF opens has to be
// the thing itself. Empty for any other file.
inline QByteArray mediaFixture(const QString& path) {
  if (path.endsWith(QLatin1String(".mp4"))) {
    // One second of a 16x16 picture, from ffmpeg's lavfi "color" source.
    return QByteArray::fromBase64("AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA2dtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACknRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAgptZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAoAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAG1bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABdXN0YmwAAADpc3RzZAAAAAAAAAABAAAA2W1wNHYAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAEAAQAEgAAABIAAAAAAAAAAESTGF2YzYzLjEuMTAxIG1wZWc0AAAAAAAAAAAAAAAAAAAY//8AAABfZXNkcwAAAAADgICATgABAASAgIBAIBEAAAAAAw1AAAABgAWAgIAuAAABsAEAAAG1iRMAAAEAAAABIADEjYgALQCEAhRjAAABskxhdmM2My4xLjEwMQaAgIABAgAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAw1AAAABgAAAABhzdHRzAAAAAAAAAAEAAAAFAAAIAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAFAAAAAQAAAChzdHN6AAAAAAAAAAAAAAAFAAAAFAAAAAcAAAAHAAAABwAAAAcAAAAUc3RjbwAAAAAAAAABAAADkwAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDEAAAAIZnJlZQAAADhtZGF0AAABswAQBwAAAbYRgUYXG2GYI78AAAG2U8CNAAABtlWAjQAAAbZXwI0AAAG2WYCN");
  }
  if (path.endsWith(QLatin1String(".mp3"))) {
    // A second of silence as WAV: what a player reads by its bytes, not its name.
    constexpr int rate = 8000;
    QByteArray wav("RIFF");
    const auto number = [&wav](quint32 value, int size) {
      for (int byte = 0; byte < size; ++byte) wav.append(char((value >> (8 * byte)) & 0xFF));
    };
    number(36 + rate, 4);
    wav.append("WAVEfmt ");
    number(16, 4);
    number(1, 2);
    number(1, 2);
    number(rate, 4);
    number(rate, 4);
    number(1, 2);
    number(8, 2);
    wav.append("data");
    number(rate, 4);
    wav.append(QByteArray(rate, char(0x80)));
    return wav;
  }
  if (path.endsWith(QLatin1String(".pdf"))) {
    // Two blank pages. No cross-reference table: PDF readers rebuild one.
    return "%PDF-1.4\n"
           "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
           "2 0 obj<</Type/Pages/Kids[3 0 R 4 0 R]/Count 2>>endobj\n"
           "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n"
           "4 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\n"
           "trailer<</Root 1 0 R>>\n%%EOF\n";
  }
  return {};
}
