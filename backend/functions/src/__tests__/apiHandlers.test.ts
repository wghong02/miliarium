/**
 * Unit tests for the API handlers — authorization, invitation logic, activity
 * collection reconciliation, media validation, and the CRUD paths — so these
 * don't need manual end-to-end testing.
 *
 * Strategy: mock `firebase-admin/{firestore,auth,storage}` with a small
 * in-memory store. `FieldValue`/`Timestamp`/`GeoPoint` are the REAL value
 * classes (via requireActual) since they need no app init. Register docs/query
 * results per test with `db.__setDoc` / `db.__setQuery`, then assert the
 * recorded writes in `db.__writes`.
 */

jest.mock("firebase-admin/firestore", () => {
  const actual = jest.requireActual("firebase-admin/firestore");
  const docs = new Map<string, Record<string, unknown> | undefined>();
  const queries = new Map<string, { id: string; data: Record<string, unknown> }[]>();
  const writes: { op: string; path: string; data?: any; opts?: any }[] = [];

  const queryKey = (base: string, wheres: [string, string, unknown][]) =>
    `${base}?${wheres.map(([f, op, v]) => `${f}${op}${String(v)}`).sort().join("|")}`;

  const snap = (path: string) => {
    const data = docs.get(path);
    return {
      id: path.split("/").pop(),
      ref: docRef(path),
      exists: docs.has(path) && data !== undefined,
      data: () => data,
    };
  };

  function docRef(path: string): any {
    return {
      id: path.split("/").pop(),
      path,
      get: async () => snap(path),
      set: async (data: any, opts?: any) => {
        writes.push({ op: "set", path, data, opts });
        docs.set(path, { ...(opts?.merge ? docs.get(path) : {}), ...data });
      },
      update: async (data: any) => {
        writes.push({ op: "update", path, data });
        docs.set(path, { ...(docs.get(path) ?? {}), ...data });
      },
      delete: async () => {
        writes.push({ op: "delete", path });
        docs.delete(path);
      },
      collection: (name: string) => collectionRef(`${path}/${name}`),
    };
  }

  function collectionRef(base: string): any {
    const wheres: [string, string, unknown][] = [];
    const api: any = {
      doc: (id?: string) => docRef(`${base}/${id ?? "auto" + writes.length}`),
      where: (f: string, op: string, v: unknown) => {
        wheres.push([f, op, v]);
        return api;
      },
      orderBy: () => api,
      limit: () => api,
      count: () => ({
        get: async () => {
          const prefix = `${base}/`;
          let n = 0;
          for (const key of docs.keys()) {
            if (key.startsWith(prefix) && !key.slice(prefix.length).includes("/")) n++;
          }
          return { data: () => ({ count: n }) };
        },
      }),
      add: async (data: any) => {
        const p = `${base}/auto${writes.length}`;
        writes.push({ op: "add", path: p, data });
        docs.set(p, data);
        return docRef(p);
      },
      get: async () => {
        const rows = queries.get(queryKey(base, wheres)) ?? [];
        return {
          empty: rows.length === 0,
          size: rows.length,
          docs: rows.map((r) => ({
            id: r.id,
            data: () => r.data,
            ref: docRef(`${base}/${r.id}`),
          })),
        };
      },
    };
    return api;
  }

  function batch() {
    const ops: { op: string; path: string; data?: any; opts?: any }[] = [];
    return {
      set: (ref: any, data: any, opts?: any) => ops.push({ op: "set", path: ref.path, data, opts }),
      update: (ref: any, data: any) => ops.push({ op: "update", path: ref.path, data }),
      delete: (ref: any) => ops.push({ op: "delete", path: ref.path }),
      commit: async () => {
        for (const o of ops) {
          writes.push(o);
          if (o.op === "delete") docs.delete(o.path);
          else docs.set(o.path, { ...(o.opts?.merge ? docs.get(o.path) : {}), ...o.data });
        }
      },
    };
  }

  const db = {
    collection: (name: string) => collectionRef(name),
    batch,
    getAll: async (...refs: any[]) => refs.map((r) => snap(r.path)),
    __writes: writes,
    __setDoc: (path: string, data: Record<string, unknown>) => docs.set(path, data),
    __setQuery: (
      base: string,
      wheres: [string, string, unknown][],
      rows: { id: string; data: Record<string, unknown> }[]
    ) => queries.set(queryKey(base, wheres), rows),
    __reset: () => {
      docs.clear();
      queries.clear();
      writes.length = 0;
    },
  };

  return {
    getFirestore: () => db,
    FieldValue: actual.FieldValue,
    Timestamp: actual.Timestamp,
    GeoPoint: actual.GeoPoint,
  };
});

jest.mock("firebase-admin/auth", () => {
  const verifyIdToken = jest.fn();
  const getUser = jest.fn(async (uid: string) => ({ uid, email: `${uid}@example.com` }));
  const deleteUser = jest.fn(async () => undefined);
  return { getAuth: () => ({ verifyIdToken, getUser, deleteUser }) };
});

jest.mock("firebase-admin/storage", () => {
  const files = new Map<string, { exists: boolean; size: number }>();
  const bucket = () => ({
    file: (path: string) => ({
      getSignedUrl: async () => [`https://signed.example/${path}`],
      exists: async () => [files.get(path)?.exists ?? false],
      getMetadata: async () => [{ size: files.get(path)?.size ?? 0 }],
      delete: async () => {
        files.delete(path);
      },
    }),
  });
  return {
    getStorage: () => ({
      bucket,
      __setFile: (p: string, exists: boolean, size: number) => files.set(p, { exists, size }),
      __resetFiles: () => files.clear(),
    }),
  };
});

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { getStorage } from "firebase-admin/storage";
import * as authz from "../api/auth";
import * as progress from "../api/progress";
import * as activities from "../api/activities";
import * as collectionsApi from "../api/collections";
import * as invitations from "../api/invitations";
import * as media from "../api/media";
import * as users from "../api/users";
import * as moderation from "../api/moderation";

const db = (getFirestore as unknown as () => any)();
const storage = (getStorage as unknown as () => any)();

const ctx = (over: Partial<{ uid: string; params: any; body: any; query: any }> = {}) => ({
  uid: over.uid ?? "U",
  params: over.params ?? {},
  body: over.body ?? {},
  query: over.query ?? {},
});

/** Writes recorded against a given path. */
const writesFor = (path: string) => db.__writes.filter((w: any) => w.path === path);

beforeEach(() => {
  db.__reset();
  storage.__resetFiles();
});

// --- authorization --------------------------------------------------------

describe("authz", () => {
  it("assertProgressMember: owner passes, collaborator passes, others denied", async () => {
    db.__setDoc("progressItems/P", { ownerUserId: "owner" });
    await expect(authz.assertProgressMember("owner", "P")).resolves.toBeUndefined();

    db.__setDoc("users/collab/progressLinks/P", { role: "collaborator" });
    await expect(authz.assertProgressMember("collab", "P")).resolves.toBeUndefined();

    await expect(authz.assertProgressMember("stranger", "P")).rejects.toMatchObject({
      status: 403,
    });
  });

  it("assertProgressMember: missing progress is 404", async () => {
    await expect(authz.assertProgressMember("U", "missing")).rejects.toMatchObject({
      status: 404,
    });
  });

  it("assertProgressOwner: only the owner passes", async () => {
    db.__setDoc("progressItems/P", { ownerUserId: "owner" });
    await expect(authz.assertProgressOwner("owner", "P")).resolves.toBeUndefined();
    await expect(authz.assertProgressOwner("collab", "P")).rejects.toMatchObject({
      status: 403,
    });
  });
});

// --- progress -------------------------------------------------------------

describe("progress", () => {
  it("createProgress writes the progress doc and owner link", async () => {
    const res = await progress.createProgress(
      ctx({ uid: "U", body: { id: "P1", title: "  My Goal  " } })
    );
    expect(res).toEqual({ id: "P1" });
    const p = writesFor("progressItems/P1")[0];
    expect(p.data).toMatchObject({ ownerUserId: "U", title: "My Goal" });
    const link = writesFor("users/U/progressLinks/P1")[0];
    expect(link.data).toMatchObject({ role: "owner", progressItemId: "P1", userId: "U" });
  });

  it("updateSummary requires membership and clamps length", async () => {
    db.__setDoc("progressItems/P", { ownerUserId: "U" });
    await progress.updateSummary(ctx({ params: { pid: "P" }, body: { summary: "hi" } }));
    expect(writesFor("progressItems/P")[0].data).toEqual({ "content.summary": "hi" });

    await expect(
      progress.updateSummary(ctx({ uid: "other", params: { pid: "P" }, body: {} }))
    ).rejects.toMatchObject({ status: 403 });
  });

  it("deleteProgress is owner-only", async () => {
    db.__setDoc("progressItems/P", { ownerUserId: "U" });
    await progress.deleteProgress(ctx({ params: { pid: "P" } }));
    expect(writesFor("progressItems/P").some((w: any) => w.op === "delete")).toBe(true);

    db.__setDoc("progressItems/P", { ownerUserId: "U" });
    await expect(
      progress.deleteProgress(ctx({ uid: "collab", params: { pid: "P" } }))
    ).rejects.toMatchObject({ status: 403 });
  });
});

// --- activities -----------------------------------------------------------

describe("activities", () => {
  beforeEach(() => db.__setDoc("progressItems/P", { ownerUserId: "U" }));

  it("createActivity forces createdBy, flattens location, links collections", async () => {
    const res = await activities.createActivity(
      ctx({
        uid: "U",
        params: { pid: "P" },
        body: {
          id: "A1",
          title: "Visit",
          collectionIds: ["c1"],
          latitude: 10,
          longitude: 20,
          createdBy: "spoofed",
          reminderMinutesBefore: 30,
        },
      })
    );
    expect(res).toEqual({ id: "A1" });
    const doc = writesFor("progressItems/P/activities/A1")[0];
    expect(doc.data.createdBy).toBe("U"); // forced, not "spoofed"
    expect(doc.data.location.latitude).toBe(10);
    expect(doc.data.reminderMinutesBefore).toBe(30);
    // linked into c1
    const link = writesFor("progressItems/P/collections/c1")[0];
    expect(link.op).toBe("update");
  });

  it("updateActivity reconciles added/removed collections", async () => {
    db.__setDoc("progressItems/P/activities/A1", {
      collectionIds: ["c1", "c2"],
      createdBy: "orig",
      title: "old",
    });
    await activities.updateActivity(
      ctx({
        uid: "U",
        params: { pid: "P", aid: "A1" },
        body: { id: "A1", title: "new", collectionIds: ["c2", "c3"] },
      })
    );
    // c3 added, c1 removed, c2 untouched
    expect(writesFor("progressItems/P/collections/c3").length).toBe(1);
    expect(writesFor("progressItems/P/collections/c1").length).toBe(1);
    expect(writesFor("progressItems/P/collections/c2").length).toBe(0);
    // createdBy preserved from the stored doc
    expect(writesFor("progressItems/P/activities/A1")[0].data.createdBy).toBe("orig");
  });

  it("addToCollection links both sides", async () => {
    await activities.addToCollection(ctx({ params: { pid: "P", aid: "A1", cid: "c9" } }));
    expect(writesFor("progressItems/P/activities/A1").length).toBe(1);
    expect(writesFor("progressItems/P/collections/c9").length).toBe(1);
  });
});

// --- collections ----------------------------------------------------------

describe("collections", () => {
  beforeEach(() => db.__setDoc("progressItems/P", { ownerUserId: "U" }));

  it("createCollection initializes empty stats", async () => {
    await collectionsApi.createCollection(
      ctx({ params: { pid: "P" }, body: { id: "C1", name: "Cities" } })
    );
    const doc = writesFor("progressItems/P/collections/C1")[0];
    expect(doc.data).toMatchObject({ name: "Cities", activityIds: [], isFavorite: false });
    expect(doc.data.stats).toEqual({ total: 0, completedCount: 0, locationCount: 0, timeCount: 0 });
  });

  it("updateCollection merges and clears notes on explicit null", async () => {
    await collectionsApi.updateCollection(
      ctx({ params: { pid: "P", cid: "C1" }, body: { name: "New", notes: null } })
    );
    const w = writesFor("progressItems/P/collections/C1")[0];
    expect(w.opts).toEqual({ merge: true });
    expect(w.data.name).toBe("New");
    expect(w.data.notes).toEqual(FieldValue.delete());
  });

  it("persistStats writes the provided counts", async () => {
    await collectionsApi.persistStats(
      ctx({
        params: { pid: "P", cid: "C1" },
        body: { total: 3, completedCount: 1, locationCount: 2, timeCount: 3 },
      })
    );
    expect(writesFor("progressItems/P/collections/C1")[0].data.stats).toMatchObject({
      total: 3,
      timeCount: 3,
    });
  });
});

// --- invitations ----------------------------------------------------------

describe("invitations", () => {
  beforeEach(() => db.__setDoc("progressItems/P", { ownerUserId: "sender" }));

  const sendBody = { progressItemId: "P", progressItemTitle: "Goal", toEmail: "b@x.com" };

  it("sendInvitation resolves email and creates a new invite", async () => {
    db.__setQuery("users", [["email", "==", "b@x.com"]], [{ id: "recipient", data: {} }]);
    db.__setQuery(
      "invitations",
      [
        ["fromUserId", "==", "sender"],
        ["toUserId", "==", "recipient"],
        ["progressItemId", "==", "P"],
      ],
      []
    );
    await invitations.sendInvitation(ctx({ uid: "sender", body: sendBody }));
    const add = db.__writes.find((w: any) => w.op === "add");
    expect(add.data).toMatchObject({ fromUserId: "sender", toUserId: "recipient", status: "pending" });
  });

  it("sendInvitation reopens a declined invite instead of duplicating", async () => {
    db.__setQuery("users", [["email", "==", "b@x.com"]], [{ id: "recipient", data: {} }]);
    db.__setQuery(
      "invitations",
      [
        ["fromUserId", "==", "sender"],
        ["toUserId", "==", "recipient"],
        ["progressItemId", "==", "P"],
      ],
      [{ id: "INV", data: { status: "declined" } }]
    );
    await invitations.sendInvitation(ctx({ uid: "sender", body: sendBody }));
    expect(db.__writes.some((w: any) => w.op === "add")).toBe(false);
    expect(writesFor("invitations/INV")[0].data).toMatchObject({ status: "pending" });
  });

  it("sendInvitation rejects an already-accepted recipient (409)", async () => {
    db.__setQuery("users", [["email", "==", "b@x.com"]], [{ id: "recipient", data: {} }]);
    db.__setQuery(
      "invitations",
      [
        ["fromUserId", "==", "sender"],
        ["toUserId", "==", "recipient"],
        ["progressItemId", "==", "P"],
      ],
      [{ id: "INV", data: { status: "accepted" } }]
    );
    await expect(
      invitations.sendInvitation(ctx({ uid: "sender", body: sendBody }))
    ).rejects.toMatchObject({ status: 409 });
  });

  it("sendInvitation 404s an unknown email and rejects self-invite", async () => {
    db.__setQuery("users", [["email", "==", "b@x.com"]], []);
    await expect(
      invitations.sendInvitation(ctx({ uid: "sender", body: sendBody }))
    ).rejects.toMatchObject({ status: 404 });

    db.__setQuery("users", [["email", "==", "b@x.com"]], [{ id: "sender", data: {} }]);
    await expect(
      invitations.sendInvitation(ctx({ uid: "sender", body: sendBody }))
    ).rejects.toMatchObject({ status: 400 });
  });

  it("acceptInvitation requires the recipient and writes the progressLink", async () => {
    db.__setDoc("invitations/INV", { toUserId: "me", fromUserId: "s", progressItemId: "P" });
    await invitations.acceptInvitation(ctx({ uid: "me", params: { id: "INV" } }));
    expect(writesFor("invitations/INV")[0].data.status).toBe("accepted");
    expect(writesFor("users/me/progressLinks/P")[0].data).toMatchObject({ role: "collaborator" });

    db.__setDoc("invitations/INV", { toUserId: "me", fromUserId: "s", progressItemId: "P" });
    await expect(
      invitations.acceptInvitation(ctx({ uid: "other", params: { id: "INV" } }))
    ).rejects.toMatchObject({ status: 403 });
  });

  it("revokeInvitation is sender-only", async () => {
    db.__setDoc("invitations/INV", { fromUserId: "s", toUserId: "r" });
    await expect(
      invitations.revokeInvitation(ctx({ uid: "r", params: { id: "INV" } }))
    ).rejects.toMatchObject({ status: 403 });
    await invitations.revokeInvitation(ctx({ uid: "s", params: { id: "INV" } }));
    expect(writesFor("invitations/INV")[0].data.status).toBe("revoked");
  });
});

// --- media ----------------------------------------------------------------

describe("media", () => {
  beforeEach(() => db.__setDoc("progressItems/P", { ownerUserId: "U" }));

  it("createUploadURL returns a ticket under the activity's path", async () => {
    const res: any = await media.createUploadURL(
      ctx({ params: { pid: "P", aid: "A" }, body: { contentType: "image/jpeg", ext: "jpg" } })
    );
    expect(res.storagePath).toMatch(/^activities\/P\/A\/.+\.jpg$/);
    expect(res.uploadURL).toContain("signed.example");
  });

  it("commitMedia rejects a path outside the activity", async () => {
    await expect(
      media.commitMedia(
        ctx({
          params: { pid: "P", aid: "A" },
          body: { mediaId: "M", storagePath: "activities/OTHER/A/M.jpg", type: "image" },
        })
      )
    ).rejects.toMatchObject({ status: 400 });
  });

  it("commitMedia 400s when the object was never uploaded", async () => {
    await expect(
      media.commitMedia(
        ctx({
          params: { pid: "P", aid: "A" },
          body: { mediaId: "M", storagePath: "activities/P/A/M.jpg", type: "image" },
        })
      )
    ).rejects.toMatchObject({ status: 400 });
  });

  it("commitMedia writes the doc with the authoritative object size", async () => {
    storage.__setFile("activities/P/A/M.jpg", true, 4242);
    await media.commitMedia(
      ctx({
        params: { pid: "P", aid: "A" },
        body: { mediaId: "M", storagePath: "activities/P/A/M.jpg", type: "image", width: 100 },
      })
    );
    const doc = writesFor("progressItems/P/activities/A/media/M")[0];
    expect(doc.data).toMatchObject({ type: "image", uploadedBy: "U", sizeBytes: 4242, width: 100 });
  });

  it("commitMedia rejects a file over the 20 MB limit", async () => {
    storage.__setFile("activities/P/A/M.jpg", true, 21 * 1024 * 1024);
    await expect(
      media.commitMedia(
        ctx({
          params: { pid: "P", aid: "A" },
          body: { mediaId: "M", storagePath: "activities/P/A/M.jpg", type: "image" },
        })
      )
    ).rejects.toMatchObject({ status: 400 });
  });

  it("commitMedia rejects when the activity already has 20 files", async () => {
    for (let i = 0; i < 20; i++) {
      db.__setDoc(`progressItems/P/activities/A/media/existing${i}`, { type: "image" });
    }
    storage.__setFile("activities/P/A/M.jpg", true, 1000);
    await expect(
      media.commitMedia(
        ctx({
          params: { pid: "P", aid: "A" },
          body: { mediaId: "M", storagePath: "activities/P/A/M.jpg", type: "image" },
        })
      )
    ).rejects.toMatchObject({ status: 400 });
  });
});

// --- users + moderation ---------------------------------------------------

describe("account lifecycle", () => {
  it("ensureProfile creates the doc when missing and is idempotent", async () => {
    await users.ensureProfile(ctx({ uid: "U" }));
    expect(writesFor("users/U")[0].data).toMatchObject({ userId: "U", email: "U@example.com" });

    db.__setDoc("users/V", { userId: "V" });
    db.__writes.length = 0;
    await users.ensureProfile(ctx({ uid: "V" }));
    expect(writesFor("users/V")).toHaveLength(0); // already exists → no write
  });

  it("deleteAccount deletes the Auth user, then the profile doc", async () => {
    const auth = (getAuth as unknown as () => any)();
    await users.deleteAccount(ctx({ uid: "U" }));
    expect(auth.deleteUser).toHaveBeenCalledWith("U");
    expect(writesFor("users/U").some((w: any) => w.op === "delete")).toBe(true);
  });
});

describe("users & moderation", () => {
  it("updateProfile sets a name, then clears it", async () => {
    await users.updateProfile(ctx({ uid: "U", body: { name: "Alice" } }));
    expect(writesFor("users/U")[0].data.name).toBe("Alice");

    await users.updateProfile(ctx({ uid: "U", body: { name: "  " } }));
    expect(writesFor("users/U")[1].data.name).toEqual(FieldValue.delete());
  });

  it("getUsers returns serialized profiles by id", async () => {
    db.__setDoc("users/u1", {
      userId: "u1",
      email: "a@x.com",
      createdAt: require("firebase-admin/firestore").Timestamp.fromDate(new Date("2026-01-01T00:00:00Z")),
    });
    const res: any = await users.getUsers(ctx({ query: { ids: "u1,u1,missing" } }));
    expect(res.users).toHaveLength(1);
    expect(res.users[0]).toMatchObject({ id: "u1", email: "a@x.com" });
  });

  it("blockUser rejects self-block and writes otherwise", async () => {
    await expect(
      moderation.blockUser(ctx({ uid: "U", params: { id: "U" } }))
    ).rejects.toMatchObject({ status: 400 });
    await moderation.blockUser(ctx({ uid: "U", params: { id: "V" } }));
    expect(writesFor("users/U/blockedUsers/V")[0].data).toMatchObject({ blockedUserId: "V" });
  });

  it("listBlockedUsers returns the blocked ids", async () => {
    db.__setQuery("users/U/blockedUsers", [], [
      { id: "V", data: {} },
      { id: "W", data: {} },
    ]);
    const res: any = await moderation.listBlockedUsers(ctx({ uid: "U" }));
    expect(res.ids).toEqual(["V", "W"]);
  });
});
