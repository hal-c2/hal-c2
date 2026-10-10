# Android notifications

The relay sends Firebase Cloud Messaging (FCM) data messages directly through FCM HTTP v1. No Expo Push account is needed. The phone client does not register for push yet (`@backlog @mobile` in [`features/mobile/notifications.feature`](../../features/mobile/notifications.feature)), so this page covers the relay side: the Firebase setup, the delivery queue, and the scripts that check delivery to a device.

## Firebase

1. Create a Firebase project and register the Android application identifier of the client you intend to build.
2. Create a service-account key with permission to send FCM messages for that Firebase project. Keep this private JSON outside the repository and the app bundle.
3. Enable the Firebase Cloud Messaging API in the Google project if it is not already enabled.
4. For hosted delivery, set the relay's `FCM_SERVICE_ACCOUNT` secret to the service-account JSON. For deployment through GitHub Actions, add it to the `production` environment's secrets; the relay workflow passes it to Alchemy ([releases](./release.md#hal-c2-connect-relay)).

A client's `google-services.json` selects the Firebase project it receives from, so changing the relay secret alone cannot move an installed app to another Firebase project.

## Focused delivery check

[`infra/relay/scripts/android-push-smoke.ts`](../../infra/relay/scripts/android-push-smoke.ts) sends a message through the production FCM client implementation without provisioning the relay's database, Clerk integration, or Cloudflare queues. It verifies only Firebase-to-device delivery.

Provide a private device JSON file containing the app's native FCM `token`, registered `deviceId`, signed-in `userId`, and Android `packageName`. An optional `deepLink` can target an existing thread for tap verification. From `infra/relay`:

```sh
vp run push:android:smoke /path/service-account.json /path/device.json running
vp run push:android:smoke /path/service-account.json /path/device.json approval
vp run push:android:smoke /path/service-account.json /path/device.json completed
```

Supported states are `running`, `approval`, `input`, `completed`, `failed`, and `end`. Firebase acceptance is not proof that a device displayed the message. Check the actual notification, background the app, and test a notification tap. Also test dismissal, token rotation, and delivery after the app process has exited. Android Settings **Force stop** intentionally prevents delivery until the app is opened again.

[`android-push-watch.ts`](../../infra/relay/scripts/android-push-watch.ts) subscribes to one paired environment's shell stream, uses the shared agent-awareness projection, and sends updates through the same FCM client. It holds transient state in memory and needs no hosted database or Clerk secret. Create a private `connection.json` containing `wsUrl` (the environment's `/ws` URL) and `bearerToken` (a normal paired environment access token, separate from your other clients'), then run from `infra/relay`:

```sh
vp run push:android:watch /path/service-account.json /path/device.json /path/connection.json
```

This watcher is a development transport: it observes all unarchived threads in its paired environment, enables all alert types, keeps no durable queue, and must stay running. It does not register Android devices with the hosted relay.

## Hosted delivery

The Alchemy deployment ([relay README](../../infra/relay/README.md#deployment-ci)) provisions Cloudflare Workers, delivery queues, Hyperdrive, tunnel/DNS resources, PlanetScale Postgres, and Axiom observability. It requires credentials for the enabled services and private Clerk configuration. Set `APNS_ENABLED=false` in an Android-only development relay to skip Apple delivery and its credential requirements. APNs remains enabled by default.

A maintainer with access to the existing Alchemy state and deployment credentials can deploy a personal stage with `vp run --filter hal-c2-relay deploy -- --stage <name> --env-file <file> --dry-run` and again without `--dry-run`. Non-production stages reference the retained database and DNS zones owned by the `prod` stage, create a separate PlanetScale branch, and apply migrations to that branch, so a personal stage is not a standalone deployment into an unrelated account. Leave `RELAY_DOMAIN` unset so the deployment derives a hostname for the personal stage. A fully independent deployment needs its own initial Cloudflare stack, PostgreSQL database, Firebase project, and a Clerk instance the operator can configure.

Android delivery uses `RelayFcmDeliveryQueue` and a separate dead-letter queue. Failed requests are retried; messages expire after five minutes. Before sending, the consumer rechecks the device token, current preferences, environment links, and current thread state. `UNREGISTERED` responses invalidate only the matching device token. OAuth tokens are cached within the FCM service and refreshed after an authorization failure.
