#pragma once

// Reaching a private member function of the class under test, the one a
// network frame arrives at (ShellStore::onFrame, TerminalSession::onFrame,
// ThemeController::parseFile), without touching the sources. An explicit
// instantiation may name a private member, which is all this uses:
//
//   struct OnFrame { using type = void (ShellStore::*)(const QJsonObject&); friend type reach(OnFrame); };
//   template struct halc2::fuzz::Reach<OnFrame, &ShellStore::onFrame>;
//   (store.*reach(OnFrame{}))(frame);

namespace halc2::fuzz {

template <class Tag, typename Tag::type Member>
struct Reach {
  friend typename Tag::type reach(Tag) { return Member; }
};

}  // namespace halc2::fuzz
