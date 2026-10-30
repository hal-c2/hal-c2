# Phone notifications

The HAL-C2 phone app can tell you when an agent finishes, fails, needs approval,
or asks you a question, and can keep a card on the lock screen that follows the
agents' work. Alerts come from the machine you paired with, through a
[UnifiedPush](https://unifiedpush.org) distributor app on the phone such as
ntfy. No HAL-C2 service sits in between, and the distributor cannot read what
it carries.

## Turn on alerts

1. Install a UnifiedPush distributor on the phone (ntfy works) if you have none.
2. In the HAL-C2 app, open **Settings → Notifications** and turn on **Alerts on
   this device**. Allow notifications when Android asks.
3. If more than one distributor is installed, pick the one to use.

Alerts are not shown while the app is open in front of you. Reading a thread on
another device does not silence the phone. Tap an alert to open its thread.

To turn alerts off, use **Open system settings**: Android owns the permission.
If the system has blocked HAL-C2, the app says so and points to the same place;
it notices when you allow it again.

## Ongoing agent activity

With **Ongoing agent activity** on, the phone shows one card while agents work,
covering every thread at once. It shows which threads need you first, then
failures, then work in progress, and stays for up to 15 minutes after the work
ends. The card updates silently; alerts still make a sound. Dismissing the card
does not stop alerts, and it comes back when an agent starts a new turn.

On Android 16 the card shows as a live update with a short status chip;
**Live update settings** opens the system's controls for that. On older
versions it is an ongoing notification.

Android lists **Agent alerts** and **Ongoing agent activity** as separate
categories in the app's system notification settings, so you can change their
sound or turn either off there. If the phone hides sensitive content on the
lock screen, neither shows a thread's title or text there.

## Mute a thread or set quiet hours

Tap the bell at the top of a thread to mute its alerts, and again to unmute it.

**Quiet hours** in **Settings → Notifications** hold alerts between two times
of day (by the phone's clock) and deliver them when the quiet hours end. Turn
on **Let approval requests through** to be alerted about approvals anyway.
