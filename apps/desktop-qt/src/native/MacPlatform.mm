// macOS's half of Snap Shot (MacPlatform.h). Built only on Apple, with ARC.
//
// Both-keys shortcuts poll the keyboard's device flags in this process: that
// takes no permission and no helper app, so nothing else shows in the Dock.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>

#include <QDir>
#include <QHash>
#include <QPointer>
#include <QProcess>
#include <QTemporaryDir>
#include <QTimer>

#include <memory>

#include "MacPlatform.h"

MacPlatform* createNativeMacPlatform(QObject* parent);

namespace {

// Device-dependent bits of CGEventFlags (IOLLEvent.h's NX_DEVICE*KEYMASK).
struct PairMask {
  CGEventFlags left;
  CGEventFlags right;
};

const QHash<QString, PairMask>& pairMasks() {
  static const QHash<QString, PairMask> masks{{QStringLiteral("shift"), {0x2, 0x4}},
                                              {QStringLiteral("control"), {0x1, 0x2000}},
                                              {QStringLiteral("alt"), {0x20, 0x40}},
                                              {QStringLiteral("meta"), {0x8, 0x10}}};
  return masks;
}

constexpr int kPairPollMs = 50;
constexpr int kCaptureTimeoutMs = 15000;
// Upstream's SNAP_SHOT_ACCESSIBLE_TEXT_MAX_CHARS.
constexpr int kAccessibleTextMax = 32000;
constexpr float kAccessibilityTimeoutSeconds = 3.0f;
constexpr int kAccessibilityMaxDepth = 12;
constexpr int kAccessibilityMaxNodes = 4000;

UInt32 virtualKey(const QString& key) {
  static const QHash<QString, UInt32> keys{
      {QStringLiteral("a"), kVK_ANSI_A},   {QStringLiteral("b"), kVK_ANSI_B},   {QStringLiteral("c"), kVK_ANSI_C},
      {QStringLiteral("d"), kVK_ANSI_D},   {QStringLiteral("e"), kVK_ANSI_E},   {QStringLiteral("f"), kVK_ANSI_F},
      {QStringLiteral("g"), kVK_ANSI_G},   {QStringLiteral("h"), kVK_ANSI_H},   {QStringLiteral("i"), kVK_ANSI_I},
      {QStringLiteral("j"), kVK_ANSI_J},   {QStringLiteral("k"), kVK_ANSI_K},   {QStringLiteral("l"), kVK_ANSI_L},
      {QStringLiteral("m"), kVK_ANSI_M},   {QStringLiteral("n"), kVK_ANSI_N},   {QStringLiteral("o"), kVK_ANSI_O},
      {QStringLiteral("p"), kVK_ANSI_P},   {QStringLiteral("q"), kVK_ANSI_Q},   {QStringLiteral("r"), kVK_ANSI_R},
      {QStringLiteral("s"), kVK_ANSI_S},   {QStringLiteral("t"), kVK_ANSI_T},   {QStringLiteral("u"), kVK_ANSI_U},
      {QStringLiteral("v"), kVK_ANSI_V},   {QStringLiteral("w"), kVK_ANSI_W},   {QStringLiteral("x"), kVK_ANSI_X},
      {QStringLiteral("y"), kVK_ANSI_Y},   {QStringLiteral("z"), kVK_ANSI_Z},   {QStringLiteral("0"), kVK_ANSI_0},
      {QStringLiteral("1"), kVK_ANSI_1},   {QStringLiteral("2"), kVK_ANSI_2},   {QStringLiteral("3"), kVK_ANSI_3},
      {QStringLiteral("4"), kVK_ANSI_4},   {QStringLiteral("5"), kVK_ANSI_5},   {QStringLiteral("6"), kVK_ANSI_6},
      {QStringLiteral("7"), kVK_ANSI_7},   {QStringLiteral("8"), kVK_ANSI_8},   {QStringLiteral("9"), kVK_ANSI_9},
      {QStringLiteral("f1"), kVK_F1},      {QStringLiteral("f2"), kVK_F2},      {QStringLiteral("f3"), kVK_F3},
      {QStringLiteral("f4"), kVK_F4},      {QStringLiteral("f5"), kVK_F5},      {QStringLiteral("f6"), kVK_F6},
      {QStringLiteral("f7"), kVK_F7},      {QStringLiteral("f8"), kVK_F8},      {QStringLiteral("f9"), kVK_F9},
      {QStringLiteral("f10"), kVK_F10},    {QStringLiteral("f11"), kVK_F11},    {QStringLiteral("f12"), kVK_F12},
      {QStringLiteral("space"), kVK_Space}};
  return keys.value(key.toLower(), UInt32(0xFFFF));
}

QString qt(CFStringRef text) {
  return text ? QString::fromNSString((__bridge NSString*)text) : QString();
}

// The window at the front of the normal layer, as CGWindowList says: nullopt
// when it would not say, no id when there is no window.
struct FrontWindow {
  CGWindowID id = kCGNullWindowID;
  pid_t pid = 0;
  QString app;
  QString title;
};

std::optional<FrontWindow> frontWindow() {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!list) return std::nullopt;
  FrontWindow found;
  NSArray* windows = CFBridgingRelease(list);
  for (NSDictionary* window in windows) {
    if ([window[(__bridge NSString*)kCGWindowLayer] intValue] != 0) continue;
    FrontWindow front;
    front.id = [window[(__bridge NSString*)kCGWindowNumber] unsignedIntValue];
    front.pid = [window[(__bridge NSString*)kCGWindowOwnerPID] intValue];
    front.app = QString::fromNSString(window[(__bridge NSString*)kCGWindowOwnerName]);
    front.title = QString::fromNSString(window[(__bridge NSString*)kCGWindowName]);
    found = front;
    break;
  }
  return found;
}

// Gathers the text of one accessibility element and those under it.
void collectText(AXUIElementRef element, int depth, int& nodes, QStringList& lines, int& length) {
  if (depth > kAccessibilityMaxDepth || nodes >= kAccessibilityMaxNodes || length > kAccessibleTextMax) return;
  ++nodes;
  for (CFStringRef attribute : {kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute}) {
    CFTypeRef value = nullptr;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) continue;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
      const QString text = qt(static_cast<CFStringRef>(value)).trimmed();
      if (!text.isEmpty() && (lines.isEmpty() || lines.last() != text)) {
        lines.append(text);
        length += text.size() + 1;
      }
    }
    CFRelease(value);
  }
  CFTypeRef children = nullptr;
  if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) != kAXErrorSuccess || !children) return;
  if (CFGetTypeID(children) == CFArrayGetTypeID()) {
    const auto array = static_cast<CFArrayRef>(children);
    for (CFIndex i = 0; i < CFArrayGetCount(array); ++i) {
      collectText(static_cast<AXUIElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(array, i))), depth + 1, nodes, lines, length);
    }
  }
  CFRelease(children);
}

// The focused window's text as an attachment's source carries it; empty when
// the app gives none or the permission is not there.
QJsonObject accessibleContext(pid_t pid) {
  if (!AXIsProcessTrusted()) return {};
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  if (!app) return {};
  AXUIElementSetMessagingTimeout(app, kAccessibilityTimeoutSeconds);
  CFTypeRef window = nullptr;
  QStringList lines;
  int nodes = 0;
  int length = 0;
  if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &window) == kAXErrorSuccess && window) {
    collectText(static_cast<AXUIElementRef>(window), 0, nodes, lines, length);
    CFRelease(window);
  }
  CFRelease(app);
  QString text = lines.join(u'\n');
  if (text.isEmpty()) return {};
  const bool truncated = text.size() > kAccessibleTextMax || nodes >= kAccessibilityMaxNodes;
  text.truncate(kAccessibleTextMax);
  return {{QStringLiteral("accessibleText"), text},
          {QStringLiteral("accessibility"),
           QJsonObject{{QStringLiteral("format"), QStringLiteral("flat-text")}, {QStringLiteral("text"), text}, {QStringLiteral("truncated"), truncated}}}};
}

// A carbon hot key's press, for the one platform holding it.
class NativeMacPlatform;
NativeMacPlatform* g_holder = nullptr;
OSStatus onHotKey(EventHandlerCallRef, EventRef, void*);

}  // namespace

@interface HalC2PanelActions : NSObject <NSWindowDelegate, NSDraggingSource>
@property(nonatomic, copy) void (^reveal)(void);
@property(nonatomic, copy) void (^dismissed)(void);
@end

@implementation HalC2PanelActions
- (void)revealApp:(id)sender {
  (void)sender;
  if (self.reveal) self.reveal();
}
- (void)windowWillClose:(NSNotification*)notification {
  (void)notification;
  if (self.dismissed) self.dismissed();
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  (void)session;
  (void)context;
  return NSDragOperationCopy;
}
@end

// The app's icon: dragged into Privacy & Security's list.
@interface HalC2AppDragView : NSImageView
@property(nonatomic, weak) id<NSDraggingSource> source;
@end

@implementation HalC2AppDragView
- (void)mouseDown:(NSEvent*)event {
  NSURL* url = NSBundle.mainBundle.bundleURL;
  NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
  [item setDraggingFrame:self.bounds contents:self.image];
  [self beginDraggingSessionWithItems:@[ item ] event:event source:self.source];
}
@end

namespace {

class NativeMacPlatform final : public MacPlatform {
public:
  explicit NativeMacPlatform(QObject* parent) : MacPlatform(parent) {
    m_pairPoll.setInterval(kPairPollMs);
    QObject::connect(&m_pairPoll, &QTimer::timeout, this, [this] { pollPair(); });
  }

  ~NativeMacPlatform() override {
    letGo();
    closeHelper();
  }

  QString appName() const override {
    NSString* name = NSRunningApplication.currentApplication.localizedName;
    return name ? QString::fromNSString(name) : MacPlatform::appName();
  }

  std::optional<Permissions> permissions() override {
    return Permissions{CGPreflightScreenCaptureAccess(), bool(AXIsProcessTrusted())};
  }

  void request(const QString& permission) override {
    if (permission == kScreenRecording) {
      CGRequestScreenCaptureAccess();
    } else if (permission == kAccessibility) {
      NSDictionary* options = @{(__bridge NSString*)kAXTrustedCheckOptionPrompt : @YES};
      AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
  }

  void openSettings(const QString& permission) override {
    NSString* url = permission == kScreenRecording ? @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                                                   : @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
  }

  bool watchPair(const QString& modifier) override {
    letGo();
    const auto mask = pairMasks().constFind(modifier);
    if (mask == pairMasks().constEnd()) return false;
    m_pair = *mask;
    m_pairDown = true;  // Until seen up: keys held now are not a press.
    m_pairPoll.start();
    return true;
  }

  bool holdChord(const QJsonObject& shortcut) override {
    letGo();
    const UInt32 key = virtualKey(shortcut.value(QLatin1String("key")).toString());
    if (key == 0xFFFF) return false;
    UInt32 modifiers = 0;
    if (shortcut.value(QLatin1String("metaKey")).toBool() || shortcut.value(QLatin1String("modKey")).toBool()) modifiers |= cmdKey;
    if (shortcut.value(QLatin1String("ctrlKey")).toBool()) modifiers |= controlKey;
    if (shortcut.value(QLatin1String("shiftKey")).toBool()) modifiers |= shiftKey;
    if (shortcut.value(QLatin1String("altKey")).toBool()) modifiers |= optionKey;
    static bool installed = false;
    if (!installed) {
      const EventTypeSpec spec{kEventClassKeyboard, kEventHotKeyPressed};
      if (InstallApplicationEventHandler(&onHotKey, 1, &spec, nullptr, nullptr) != noErr) return false;
      installed = true;
    }
    const EventHotKeyID id{'HalC', 1};
    if (RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &m_hotKey) != noErr) {
      m_hotKey = nullptr;
      return false;
    }
    g_holder = this;
    return true;
  }

  void letGo() override {
    m_pairPoll.stop();
    if (m_hotKey) UnregisterEventHotKey(m_hotKey);
    m_hotKey = nullptr;
    if (g_holder == this) g_holder = nullptr;
  }

  void hotKeyPressed() { emit pressed(); }

  void capture(bool includeText, std::function<void(const Capture&)> done) override {
    const auto front = frontWindow();
    if (!front) {
      Capture failure;
      failure.step = QStringLiteral("find-window");
      failure.status = QStringLiteral("failed");
      done(failure);
      return;
    }
    if (front->id == kCGNullWindowID) {
      Capture failure;
      failure.step = QStringLiteral("find-window");
      failure.status = QStringLiteral("missing");
      done(failure);
      return;
    }
    auto folder = std::make_shared<QTemporaryDir>();
    const QString path = folder->filePath(QStringLiteral("snapshot.png"));
    Capture result;
    result.app = front->app;
    result.title = front->title;
    if (includeText) result.context = accessibleContext(front->pid);

    auto* process = new QProcess(this);
    auto* timeout = new QTimer(process);
    timeout->setSingleShot(true);
    timeout->setInterval(kCaptureTimeoutMs);
    auto timedOut = std::make_shared<bool>(false);
    QObject::connect(timeout, &QTimer::timeout, process, [process, timedOut] {
      *timedOut = true;
      process->kill();
    });
    QObject::connect(process, &QProcess::finished, this, [process, folder, path, result, done, timedOut](int code, QProcess::ExitStatus status) mutable {
      process->deleteLater();
      if (*timedOut || status != QProcess::NormalExit || code != 0) {
        result.step = QStringLiteral("capture-window");
        result.status = *timedOut ? QStringLiteral("timed-out") : QStringLiteral("exited");
        result.exitCode = code;
      } else {
        result.image.load(path);
      }
      done(result);
    });
    QObject::connect(process, &QProcess::errorOccurred, this, [process, result, done](QProcess::ProcessError error) mutable {
      if (error != QProcess::FailedToStart) return;
      process->deleteLater();
      result.step = QStringLiteral("capture-window");
      result.status = QStringLiteral("failed");
      done(result);
    });
    timeout->start();
    process->start(QStringLiteral("/usr/sbin/screencapture"),
                   {QStringLiteral("-l"), QString::number(front->id), QStringLiteral("-o"), QStringLiteral("-x"), QStringLiteral("-t"),
                    QStringLiteral("png"), path});
  }

  std::optional<SettingsWindow> settingsWindow() override {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return std::nullopt;
    NSArray* windows = CFBridgingRelease(list);
    NSArray<NSRunningApplication*>* running = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systempreferences"];
    SettingsWindow settings;
    if (running.count == 0) return settings;
    const pid_t pid = running.firstObject.processIdentifier;
    for (NSDictionary* window in windows) {
      if ([window[(__bridge NSString*)kCGWindowOwnerPID] intValue] != pid) continue;
      if ([window[(__bridge NSString*)kCGWindowLayer] intValue] != 0) continue;
      CGRect bounds;
      if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString*)kCGWindowBounds], &bounds)) continue;
      settings.open = true;
      settings.bounds = QRect(int(bounds.origin.x), int(bounds.origin.y), int(bounds.size.width), int(bounds.size.height));
      break;
    }
    settings.frontmost = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == pid;
    return settings;
  }

  void showHelper(const QRect& bounds, const QString& text) override {
    // CGWindowList's origin is the top left of the main screen; AppKit's its bottom left.
    const CGFloat screenHeight = NSScreen.screens.firstObject.frame.size.height;
    const NSRect frame = NSMakeRect(bounds.x(), screenHeight - bounds.y() - bounds.height(), bounds.width(), bounds.height());
    if (!m_panel) makePanel();
    m_label.stringValue = text.toNSString();
    [m_panel setFrame:frame display:YES];
    [m_panel orderFrontRegardless];
  }

  void hideHelper() override { [m_panel orderOut:nil]; }

  void closeHelper() override {
    if (!m_panel) return;
    // Closed from here, so it is not the user dismissing it.
    m_actions.dismissed = nil;
    [m_panel close];
    m_panel = nil;
    m_label = nil;
    m_actions = nil;
  }

  bool helperFocused() override { return m_panel && m_panel.isKeyWindow; }

  void revealApp() override { [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ NSBundle.mainBundle.bundleURL ]]; }

  void focusApp() override { [NSApp activateIgnoringOtherApps:YES]; }

private:
  void pollPair() {
    const CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    const bool down = (flags & m_pair.left) && (flags & m_pair.right);
    if (down && !m_pairDown) emit pressed();
    m_pairDown = down;
  }

  void makePanel() {
    QPointer<NativeMacPlatform> self(this);
    m_actions = [[HalC2PanelActions alloc] init];
    m_actions.reveal = ^{
      if (self) emit self->helperRevealRequested();
    };
    m_actions.dismissed = ^{
      // From a timer: the panel is still closing here, and this closes it.
      if (self) QTimer::singleShot(0, self.data(), [self] { if (self) emit self->helperDismissed(); });
    };

    m_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 140)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    m_panel.releasedWhenClosed = NO;
    m_panel.floatingPanel = YES;
    m_panel.hidesOnDeactivate = NO;
    m_panel.level = NSFloatingWindowLevel;
    m_panel.delegate = m_actions;

    NSImage* icon = [NSWorkspace.sharedWorkspace iconForFile:NSBundle.mainBundle.bundlePath];
    HalC2AppDragView* drag = [[HalC2AppDragView alloc] init];
    drag.image = icon;
    drag.source = m_actions;
    [drag.widthAnchor constraintEqualToConstant:48].active = YES;
    [drag.heightAnchor constraintEqualToConstant:48].active = YES;

    m_label = [NSTextField labelWithString:@""];
    NSButton* reveal = [NSButton buttonWithTitle:@"Show in Finder" target:m_actions action:@selector(revealApp:)];

    NSStackView* row = [NSStackView stackViewWithViews:@[ drag, m_label, reveal ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 12;
    row.edgeInsets = NSEdgeInsetsMake(12, 16, 12, 16);
    m_panel.contentView = row;
  }

  QTimer m_pairPoll;
  PairMask m_pair{0, 0};
  bool m_pairDown = false;
  EventHotKeyRef m_hotKey = nullptr;
  NSPanel* m_panel = nil;
  NSTextField* m_label = nil;
  HalC2PanelActions* m_actions = nil;
};

OSStatus onHotKey(EventHandlerCallRef, EventRef, void*) {
  if (g_holder) g_holder->hotKeyPressed();
  return noErr;
}

}  // namespace

MacPlatform* createNativeMacPlatform(QObject* parent) {
  return new NativeMacPlatform(parent);
}
