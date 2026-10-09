// The pairing link readers (PairingExchange.h) against any text: readLink, what
// the user types into the connection dialog, and readInvitation, what a camera
// or another app hands over. Besides not crashing, what they accept must be
// something the exchange can use: origins that are http(s) addresses which
// read back as they were, a token, and an invitation whose address names the
// MC without a user name.

#include "Fuzz.h"
#include "PairingExchange.h"

#include <cstddef>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What the link readers look for: schemes, the parts of an MC's link, and
// the characters that make a link invalid (a user name, a port, brackets).
const std::vector<std::string> kLinkWords{"hal-c2://", "pair", "pairingUrl=", "http://", "https://", "#", "?", "token=",
                                          "&", "%", "/", ":", "@", "[", "]", "+", "=", "3797", "devbox.tailnet.ts.net"};

// readInvitation's limit (PairingExchange.cpp kLongest).
constexpr qsizetype kLongest = 2048;

QString wrapped(const QString& link) {
  return QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(link));
}

bool isHttp(const QUrl& url) {
  return url.scheme() == QLatin1String("http") || url.scheme() == QLatin1String("https");
}

void LinkOriginsAreHttp(const std::string& text) {
  const std::optional<pairing::Link> link = pairing::readLink(fuzz::utf8(text));
  if (!link) return;
  ASSERT_TRUE(link->origins.size() == 1 || link->origins.size() == 2) << link->origins.size() << " origins for " << text;
  ASSERT_FALSE(link->token.isEmpty()) << text;
  EXPECT_EQ(link->token, link->token.trimmed()) << text;
  // A link with its scheme keeps it; one without is tried over HTTPS, then HTTP.
  if (link->origins.size() == 2) {
    EXPECT_EQ(link->origins.at(0).scheme(), QLatin1String("https")) << text;
    EXPECT_EQ(link->origins.at(1).scheme(), QLatin1String("http")) << text;
  }
  for (const QUrl& origin : link->origins) {
    EXPECT_TRUE(origin.isValid()) << origin.toString().toStdString() << " from " << text;
    EXPECT_TRUE(isHttp(origin)) << origin.toString().toStdString() << " from " << text;
    EXPECT_FALSE(origin.host().isEmpty()) << text;
    // The origin is what the exchange requests, so it reads back as it was.
    const QUrl back(origin.toString());
    EXPECT_EQ(back.scheme(), origin.scheme()) << text;
    EXPECT_EQ(back.host(), origin.host()) << origin.toString().toStdString() << " from " << text;
    EXPECT_EQ(back.port(), origin.port()) << origin.toString().toStdString() << " from " << text;
  }
}
FUZZ_TEST(Pairing, LinkOriginsAreHttp)
    .WithDomains(fuzz::Text(kLinkWords))
    .WithSeeds({{"https://devbox.tailnet.ts.net:3797/pair#token=abc123"},
                {"http://127.0.0.1:3797/pair?token=xyz"},
                {"192.168.1.5:3797#token=t0k3n"},
                {"mc.example/pair#token=a%2Bb%3D"},
                {"//mc.example#token=x"},
                {"  https://[::1]/#token=x  "},
                {"hal-c2://pair?pairingUrl=https%3A%2F%2Fmc.example%3A3797%2Fpair%23token%3Dabc"},
                {"https://mc.example/pair#token="}});

// readInvitation on a text of any shape, with `pad` characters appended to it
// (a longer token, or a longer pairingUrl), so the engine can probe the
// 2048-character limit from both sides of a valid link.
void InvitationIsPairingLink(const std::string& text, std::size_t pad) {
  const QString received = fuzz::utf8(text + std::string(pad, 'a'));
  const std::optional<pairing::Invitation> invitation = pairing::readInvitation(received);
  if (received.trimmed().size() > kLongest) {
    ASSERT_FALSE(invitation) << "accepted " << received.trimmed().size() << " characters";
    return;
  }
  if (!invitation) return;
  fuzz::print(received);
  EXPECT_FALSE(invitation->link.isEmpty());
  // The address is the scheme, host and port of the link's one origin: no
  // user name, no path, http or https.
  const QUrl address(invitation->address);
  EXPECT_TRUE(isHttp(address)) << invitation->address.toStdString();
  EXPECT_TRUE(address.userInfo().isEmpty()) << invitation->address.toStdString();
  EXPECT_TRUE(address.path().isEmpty()) << invitation->address.toStdString();
  // The link pairs with the address it shows, as readLink reads it.
  const std::optional<pairing::Link> link = pairing::readLink(invitation->link);
  ASSERT_TRUE(link) << invitation->link.toStdString();
  EXPECT_EQ(link->origins.first().toString(QUrl::FullyEncoded), invitation->address) << invitation->link.toStdString();
  // The app's own link to it reads the same, as long as that link fits the limit.
  const QString own = wrapped(invitation->link);
  if (own.size() > kLongest) return;
  const std::optional<pairing::Invitation> again = pairing::readInvitation(own);
  ASSERT_TRUE(again) << own.toStdString();
  EXPECT_EQ(again->link, invitation->link);
  EXPECT_EQ(again->address, invitation->address);
}
FUZZ_TEST(Pairing, InvitationIsPairingLink)
    .WithDomains(fuzz::Text(kLinkWords), fuzztest::InRange<std::size_t>(0, 4096))
    .WithSeeds([] {
      return std::vector<std::tuple<std::string, std::size_t>>{
          {"", 0},
          {"https://devbox.tailnet.ts.net:3797/pair#token=abc123", 0},
          {"hal-c2://pair?pairingUrl=https%3A%2F%2Fmc.example%3A3797%2Fpair%23token%3Dabc", 0},
          {"hal-c2://pair?pairingUrl=https%3A%2F%2Fmc.example%3A3797%2Fpair%23token%3Dabc&pairingUrl=x", 0},
          {"hal-c2://pair?pairingUrl=hal-c2%3A%2F%2Fpair%3FpairingUrl%3Dx", 0},
          {"https://user@mc.example/pair#token=x", 0},
          {"http://mc.example/pair#token=", 0},
          {"https://mc.example/pair#token=x", 1900},
          {"hal-c2://pair?pairingUrl=https%3A%2F%2Fmc.example%3A3797%2Fpair%23token%3Dabc", 2100},
      };
    });

}  // namespace
