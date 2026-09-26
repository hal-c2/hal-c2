import { afterEach, describe, expect, it, vi } from "vite-plus/test";

function memoryStorage(entries: Record<string, string>): Storage {
  const values = new Map(Object.entries(entries));
  return {
    get length() {
      return values.size;
    },
    key: (index) => [...values.keys()][index] ?? null,
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => void values.set(key, value),
    removeItem: (key) => void values.delete(key),
    clear: () => values.clear(),
  };
}

function snapshot(storage: Storage) {
  return Object.fromEntries(
    Array.from({ length: storage.length }, (_, index) => {
      const key = storage.key(index)!;
      return [key, storage.getItem(key)];
    }),
  );
}

describe("copyLegacyStorageKeys", () => {
  it("copies pre-rename keys to their new names and keeps the originals", async () => {
    const { copyLegacyStorageKeys } = await import("./legacyStorage");
    const storage = memoryStorage({
      "t3code:client-settings:v1": '{"a":1}',
      "t3code.renderTable": "true",
      "t3.pullRequests.preferences": "{}",
      unrelated: "x",
    });

    copyLegacyStorageKeys(storage);

    expect(snapshot(storage)).toEqual({
      "t3code:client-settings:v1": '{"a":1}',
      "t3code.renderTable": "true",
      "t3.pullRequests.preferences": "{}",
      unrelated: "x",
      "hal-c2:client-settings:v1": '{"a":1}',
      "hal-c2.renderTable": "true",
      "hal-c2.pullRequests.preferences": "{}",
    });
  });

  it("never overwrites a value already saved under the new name", async () => {
    const { copyLegacyStorageKeys } = await import("./legacyStorage");
    const storage = memoryStorage({ "t3code:theme": "grove", "hal-c2:theme": "ocean" });

    copyLegacyStorageKeys(storage);

    expect(storage.getItem("hal-c2:theme")).toBe("ocean");
  });
});

describe("resolveDatabaseName", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  async function resolveWith(existing: ReadonlyArray<string>, name: string) {
    vi.stubGlobal("indexedDB", {
      databases: async () => existing.map((databaseName) => ({ name: databaseName, version: 1 })),
    });
    const { resolveDatabaseName } = await import("./legacyStorage");
    return resolveDatabaseName(name);
  }

  it("keeps opening a database written before the rename", async () => {
    expect(await resolveWith(["t3code:connection-runtime"], "hal-c2:connection-runtime")).toBe(
      "t3code:connection-runtime",
    );
  });

  it("opens the new name once it exists or when there is nothing to keep", async () => {
    expect(
      await resolveWith(
        ["t3code:connection-runtime", "hal-c2:connection-runtime"],
        "hal-c2:connection-runtime",
      ),
    ).toBe("hal-c2:connection-runtime");
    vi.resetModules();
    expect(await resolveWith([], "hal-c2:cloud-auth")).toBe("hal-c2:cloud-auth");
  });
});
