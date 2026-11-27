# The phone's Android side

`src/io/github/halc2/mobile/` is the Qt phone's Java, carried
unchanged: `Push.java` renders the push inbox's effects as system
notifications and asks the UnifiedPush distributor for an
endpoint, `PushReceiver.java` and `DismissReceiver.java` are its
broadcast receivers. They call the Rust inbox through the JNI
entries `PushReceiver.receive`, `PushReceiver.endpoint` and
`DismissReceiver.dismiss`, whose Rust halves are
`apps/mobile-ljos/src/push_receiver.rs`.

They wait for Ljós's Android template slot for app-supplied Java
sources and manifest receivers (hal-c2/ljos-ui#616): until it
lands nothing compiles them, and the JNI shims that will bind
them are written with it. Posting the notifications needs
`POST_NOTIFICATIONS` on API 33+; asking for it is the Android
PushSystem's `request_permission` (the Ljós-dialect permission
type coming under #616), which `Notifications` already goes
through — no other place asks.
