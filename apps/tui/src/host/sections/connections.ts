import type { AuthAccessStreamEvent, AuthClientSession, AuthPairingLink } from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, plural } from "./shared.ts";

/** A linked environment, as `hal-c2.environmentLinks` lists it. */
interface WireLink {
  readonly environment?: { readonly environmentId?: string; readonly label?: string };
  readonly origin?: string;
  readonly online?: boolean;
  readonly problem?: string;
}

const clientLabel = (session: AuthClientSession): string =>
  session.client.label ??
  [session.client.browser, session.client.os].filter(Boolean).join(" on ") ??
  session.subject;

/** The access list after one stream event. */
export function applyAccessEvent(
  access: { links: ReadonlyArray<AuthPairingLink>; clients: ReadonlyArray<AuthClientSession> },
  event: AuthAccessStreamEvent,
): { links: ReadonlyArray<AuthPairingLink>; clients: ReadonlyArray<AuthClientSession> } {
  switch (event.type) {
    case "snapshot":
      return { links: event.payload.pairingLinks, clients: event.payload.clientSessions };
    case "pairingLinkUpserted":
      return {
        ...access,
        links: [...access.links.filter((link) => link.id !== event.payload.id), event.payload],
      };
    case "pairingLinkRemoved":
      return { ...access, links: access.links.filter((link) => link.id !== event.payload.id) };
    case "clientUpserted":
      return {
        ...access,
        clients: [
          ...access.clients.filter((client) => client.sessionId !== event.payload.sessionId),
          event.payload,
        ],
      };
    case "clientRemoved":
      return {
        ...access,
        clients: access.clients.filter((client) => client.sessionId !== event.payload.sessionId),
      };
  }
}

/**
 * Connection settings: the environments this machine's MC is linked to (add
 * one with its pairing link, remove one), and who may reach this machine: its
 * unused pairing links and its paired clients, followed live and revocable.
 */
export function connectionsSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let links: ReadonlyArray<WireLink> | null = null;
  let linksError: string | null = null;
  let access: {
    links: ReadonlyArray<AuthPairingLink>;
    clients: ReadonlyArray<AuthClientSession>;
  } | null = null;
  let accessError: string | null = null;
  let unsubscribe: (() => void) | null = null;
  let generation = 0;

  const loadLinks = () => {
    const asked = ++generation;
    void host.track(
      client.mcCall<ReadonlyArray<WireLink>>("hal-c2.environmentLinks", {}).then(
        (next) => {
          if (asked !== generation) return;
          links = Array.isArray(next) ? next : [];
          linksError = null;
          host.refresh();
        },
        (cause: unknown) => {
          if (asked !== generation) return;
          links = [];
          linksError = errorText(cause);
          host.refresh();
        },
      ),
    );
  };

  const change = (call: Promise<unknown>, done: string, failed: string, after?: () => void) => {
    void host.track(
      call.then(
        () => {
          host.status(done, "success");
          after?.();
        },
        (cause: unknown) => host.status(`${failed}: ${errorText(cause)}`, "error"),
      ),
    );
  };

  const linkItems = (): SectionItem[] => {
    const items: SectionItem[] = [{ kind: "heading", text: "Linked environments" }];
    if (linksError !== null) items.push({ kind: "note", text: linksError, tone: "error" });
    if (links === null) items.push({ kind: "note", text: "Reading links…" });
    else if (links.length === 0 && linksError === null) {
      items.push({
        kind: "note",
        text: "None. A link lets this machine reach an environment outside its cluster.",
      });
    }
    for (const link of links ?? []) {
      const id = link.environment?.environmentId;
      if (!id) continue;
      const label = link.environment?.label ?? id;
      items.push({
        kind: "row",
        id: `link-${id}`,
        label,
        value: `linked · ${link.online ? "online" : (link.problem ?? "offline")} · Enter removes`,
        tone: link.online ? "success" : "warning",
        run: () =>
          host.confirm(
            `Remove the link to ${label}? This machine stops reaching it; ${label} itself is not changed.`,
            () =>
              change(
                client.mcCall("hal-c2.unlinkEnvironment", { environmentId: id }),
                `Unlinked ${label}.`,
                "Failed to remove the link",
                loadLinks,
              ),
          ),
      });
    }
    items.push({
      kind: "row",
      id: "link-add",
      label: "+ Link an environment",
      tone: "accent",
      run: () =>
        host.ask(
          { label: "Pairing link", placeholder: "the pairing link from the other environment" },
          (pairingUrl) => {
            if (pairingUrl === "") return;
            host.status("Linking…", "busy");
            void host.track(
              client.mcCall<{ label?: string }>("hal-c2.linkEnvironment", { pairingUrl }).then(
                (descriptor) => {
                  host.status(`Linked ${descriptor?.label ?? "the environment"}.`, "success");
                  loadLinks();
                },
                (cause: unknown) =>
                  host.status(`Failed to link the environment: ${errorText(cause)}`, "error"),
              ),
            );
          },
        ),
    });
    return items;
  };

  const accessItems = (): SectionItem[] => {
    const items: SectionItem[] = [{ kind: "heading", text: "Access to this machine" }];
    if (accessError !== null) {
      items.push({ kind: "note", text: accessError, tone: "warning" });
      return items;
    }
    if (access === null) {
      items.push({ kind: "note", text: "Reading access…" });
      return items;
    }
    items.push({ kind: "note", text: plural(access.links.length, "pairing link") });
    for (const link of access.links) {
      items.push({
        kind: "row",
        id: `pairing-${link.id}`,
        label: link.label ?? link.id,
        value: "pairing link · not used yet · Enter revokes",
        run: () =>
          host.confirm(`Revoke the pairing link "${link.label ?? link.id}"?`, () =>
            change(
              client.mcCall("hal-c2.revokePairingLink", { id: link.id }),
              "Pairing link revoked.",
              "Failed to revoke the pairing link",
            ),
          ),
      });
    }
    items.push({ kind: "note", text: plural(access.clients.length, "paired client") });
    const others = access.clients.filter((session) => !session.current);
    for (const session of access.clients) {
      const label = clientLabel(session);
      items.push({
        kind: "row",
        id: `client-${session.sessionId}`,
        label,
        value: session.current
          ? "this client"
          : `${session.connected ? "connected" : "not connected"} · Enter revokes`,
        ...(session.current
          ? {}
          : {
              run: () =>
                host.confirm(`Revoke ${label}? It will have to pair again to connect.`, () =>
                  change(
                    client.mcCall("hal-c2.revokeClient", { sessionId: session.sessionId }),
                    `Revoked ${label}.`,
                    "Failed to revoke the client",
                  ),
                ),
            }),
      });
    }
    if (others.length > 0) {
      items.push({
        kind: "row",
        id: "revoke-others",
        label: "Revoke every other client",
        tone: "error",
        run: () =>
          host.confirm(
            `Revoke ${plural(others.length, "other client")}? Only this client stays paired.`,
            () =>
              change(
                client.mcCall("hal-c2.revokeOtherClients", {}),
                "Revoked every other client.",
                "Failed to revoke the other clients",
              ),
          ),
      });
    }
    return items;
  };

  return {
    id: "connections",
    commands: () => [
      {
        id: "section.connections",
        title: "Connections",
        keywords: "links linked environments pairing remote settings",
        action: "section.open",
        payload: { id: "connections" },
      },
      {
        id: "section.connections.access",
        title: "Access management",
        keywords: "pairing links paired clients devices sessions revoke",
        action: "section.open",
        payload: { id: "connections", access: true },
      },
    ],
    open: (payload) => {
      links = null;
      linksError = null;
      loadLinks();
      unsubscribe ??= client.subscribeAuthAccess(
        (event) => {
          access = applyAccessEvent(access ?? { links: [], clients: [] }, event);
          accessError = null;
          host.refresh();
        },
        (message) => {
          accessError = `This session cannot manage access: ${message}`;
          host.refresh();
        },
      );
      if ((payload as { readonly access?: unknown } | undefined)?.access === true) {
        host.select("revoke-others");
      }
    },
    close: () => {
      generation += 1;
      unsubscribe?.();
      unsubscribe = null;
      access = null;
      accessError = null;
    },
    page: () => ({
      title: "connections",
      items: [...linkItems(), { kind: "blank" }, ...accessItems()],
    }),
  };
}
