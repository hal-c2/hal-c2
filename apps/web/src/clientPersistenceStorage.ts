import {
  ClientSettingsSchema,
  DEFAULT_CLIENT_SETTINGS,
  type ClientSettings,
} from "@hal-c2/contracts";

import { getLocalStorageItem, setLocalStorageItem } from "./hooks/useLocalStorage";

const CLIENT_SETTINGS_STORAGE_KEY = "hal-c2:client-settings:v2";
// v1 saved the whole snapshot, so `followUpBehavior: "queue"` there is the old
// default rather than a choice; it reads back as the current default once.
const CLIENT_SETTINGS_V1_STORAGE_KEY = "hal-c2:client-settings:v1";

function hasWindow(): boolean {
  return typeof window !== "undefined";
}

export function readBrowserClientSettings(): ClientSettings | null {
  if (!hasWindow()) {
    return null;
  }

  const settings = getLocalStorageItem(CLIENT_SETTINGS_STORAGE_KEY, ClientSettingsSchema);
  if (settings) return settings;
  const v1 = getLocalStorageItem(CLIENT_SETTINGS_V1_STORAGE_KEY, ClientSettingsSchema);
  return v1 && { ...v1, followUpBehavior: DEFAULT_CLIENT_SETTINGS.followUpBehavior };
}

export function writeBrowserClientSettings(settings: ClientSettings): void {
  if (!hasWindow()) {
    return;
  }

  setLocalStorageItem(CLIENT_SETTINGS_STORAGE_KEY, settings, ClientSettingsSchema);
}
