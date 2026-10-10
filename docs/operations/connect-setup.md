# HAL-C2 Connect setup

Deployment and MC configuration for HAL-C2 Connect. The [architecture note](../internals/hal-c2-connect.md)
explains the trust boundaries; the [relay README](../../infra/relay/README.md#deployment) owns relay
provisioning instructions.

## Public application configuration

HAL-C2 Connect is disabled in a fresh clone. HAL-C2 has no public deployment of its own, so the
repository-root [`.env.example`](../../.env.example) carries no values.

For your own deployment, set these values in the environment the MC starts with. The MC does not
read a `.env` file itself, so export them or put them in the service's environment:

```dotenv
HAL_C2_CLERK_PUBLISHABLE_KEY=<publishable key>
HAL_C2_CLERK_CLI_OAUTH_CLIENT_ID=<public OAuth application client ID>
HAL_C2_RELAY_URL=https://relay.example.com
```

These values are public identifiers. `CLERK_SECRET_KEY` belongs only in the relay's secrets, never
in the MC's configuration.

Copy `infra/relay/.env.example` to `infra/relay/.env` for relay deployment settings.
Deploy `prod` before personal stages because it owns the retained database that their branches
depend on. The stack's `PublishClientConfig` action writes the resulting relay URL back to the root `.env`.

## Operator OAuth application

In Clerk's OAuth applications settings:

1. Create a public OAuth application for the operator's sign-in (`mix hal_c2.connect`), using authorization-code exchange with PKCE.
2. Allow the redirect URI `http://127.0.0.1:34338/callback`.
3. Enable the `openid`, `profile`, `email`, and `offline_access` scopes.
4. Enable **Device authorization grant** on the application. Headless and SSH authorization use
   it, and Clerk only advertises the device endpoint once it is on. The feature is in beta and
   Clerk enables it per account on request.
5. Set `HAL_C2_CLERK_CLI_OAUTH_CLIENT_ID` to the generated public client ID in local and release
   build environments.

## JWT template

Create a Clerk JWT template named `hal-c2-relay` with claims:

```json
{ "aud": "hal-c2-relay" }
```

Set `CLERK_JWT_AUDIENCE=hal-c2-relay` for the relay. The production relay deployment environment
also defines `CLERK_JWT_TEMPLATE`. The audience stays the same across relay stages; the relay
URL selects the deployment.

## Restricting sign-ups

Use Clerk's allowlist for permitted email addresses or domains, or Restricted mode for invitation-only
sign-up. An enabled empty allowlist blocks all new sign-ups.

Sign-up restrictions do not revoke an existing account's access. Ban the account in Clerk when
its active sessions and future sign-ins must be disabled.
