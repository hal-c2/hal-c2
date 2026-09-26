import { copyLegacyStorageKeys } from "./legacyStorage";
import { showBootError } from "./lib/bootError";

// Runs before main loads, so stores read the copied keys on their first load.
try {
  copyLegacyStorageKeys(window.localStorage);
} catch {
  // Storage can be blocked or full; the app then starts from defaults.
}

// Bundled dev can move UI code into shared chunks. Load it only after this
// entry runs the React refresh preamble, and catch failures before React mounts.
void import("./main").then(({ startup }) => startup).catch(showBootError);
