# The browser

On desktop, a thread's web pages open in the app: each is a **Browser** tab in
the right panel, or in the centre beside the conversation (see
[Tabs in the centre](./stage.md)). A thread's browser tabs are the same ones its
agent drives, so you watch the agent's page and it sees where you go.

The phone and the terminal client have no browser of their own; a page opened
there goes to the system's browser.

## Open a page

- Click a link to a dev server (`localhost`, `127.0.0.1`, `[::1]`) in a reply.
  It opens in a browser tab, or shows the tab already at it. Right-click a link
  for **Open in system browser** instead.
- Add a **Browser** tab from the right panel's Add menu and type an address, or
  pick a server running on the thread's machine.
- **Previews** stays the overview: every browser tab of the thread and the
  servers its machine runs.

Closing a browser tab closes it for the agent too.

## In a tab

- `mod+r` reloads, `mod+l` goes to the address bar, `mod+=` and `mod+-` zoom
  the page and `mod+0` resets it. The page's zoom is its own: the app's zoom
  leaves pages at their size.
- **Device size** shows the page at a phone, tablet or desktop size, scaled
  down to fit.
- **Devices** shows the page in several device sizes side by side at once.
  Pick which sizes from its menu, and optionally show phones and tablets on a
  3D body instead of a flat frame. The sizes shown and the 3D toggle are
  remembered.
- **DevTools** opens the developer tools below the page; **More** docks them to
  the right instead. Drag the divider to size them. The dock and size are
  remembered.
- **More** also sets the page light or dark, mutes it, and opens it in the
  system's browser.

A page that cannot load says why, with a button to try again.

The browser is part of HAL-C2 builds made with QtWebEngine; without it, links
open in the system's browser and Previews lists the tabs.
