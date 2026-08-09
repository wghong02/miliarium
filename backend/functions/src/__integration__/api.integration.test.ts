/**
 * Integration tests: exercise the API handlers against a REAL (emulated)
 * Firestore via the Admin SDK — no mocks. This catches what unit tests can't:
 * actual query behavior, batch commits, `FieldValue` transforms, GeoPoint
 * storage, and read-after-write serialization across handlers.
 *
 * Run: `npm run test:integration` (starts the Firestore emulator via
 * `firebase emulators:exec`). Requires a Java runtime for the emulator.
 *
 * Media is intentionally not covered here — signed-URL generation needs real
 * IAM signing, which the Storage emulator doesn't provide; the media handler
 * logic is covered by the unit tests instead.
 */

import { getFirestore } from "firebase-admin/firestore";
import * as progress from "../api/progress";
import * as activities from "../api/activities";
import * as collectionsApi from "../api/collections";
import * as invitations from "../api/invitations";

const db = getFirestore();

type Ctx = { uid: string; params: any; body: any; query: any };
const ctx = (o: Partial<Ctx>): Ctx => ({
  uid: o.uid ?? "U",
  params: o.params ?? {},
  body: o.body ?? {},
  query: o.query ?? {},
});

async function clearAll() {
  await Promise.all([
    db.recursiveDelete(db.collection("progressItems")),
    db.recursiveDelete(db.collection("users")),
    db.recursiveDelete(db.collection("invitations")),
  ]);
}

beforeEach(clearAll);
afterAll(clearAll);

describe("progress + activities", () => {
  it("create progress writes the doc + owner link; a member can add and list activities", async () => {
    await progress.createProgress(ctx({ uid: "U", body: { id: "P1", title: "  Goal  " } }));

    const p = await db.collection("progressItems").doc("P1").get();
    expect(p.data()!.ownerUserId).toBe("U");
    expect(p.data()!.title).toBe("Goal");
    const link = await db.doc("users/U/progressLinks/P1").get();
    expect(link.data()!.role).toBe("owner");

    await activities.createActivity(
      ctx({
        uid: "U",
        params: { pid: "P1" },
        body: { id: "A1", title: "Run", latitude: 1.5, longitude: 2.5, collectionIds: [] },
      })
    );

    const list: any = await activities.listActivities(ctx({ uid: "U", params: { pid: "P1" } }));
    expect(list.activities).toHaveLength(1);
    expect(list.activities[0]).toMatchObject({
      id: "A1",
      title: "Run",
      latitude: 1.5,
      longitude: 2.5,
      createdBy: "U",
    });
  });

  it("denies a non-member", async () => {
    await progress.createProgress(ctx({ uid: "owner", body: { id: "P2", title: "x" } }));
    await expect(
      activities.listActivities(ctx({ uid: "stranger", params: { pid: "P2" } }))
    ).rejects.toMatchObject({ status: 403 });
  });

  it("returns only timed activities under withTime, with dates round-tripping", async () => {
    await progress.createProgress(ctx({ uid: "U", body: { id: "P3", title: "g" } }));
    await activities.createActivity(
      ctx({ uid: "U", params: { pid: "P3" }, body: { id: "timed", title: "t", timestamp: "2026-08-09T10:00:00Z", collectionIds: [] } })
    );
    await activities.createActivity(
      ctx({ uid: "U", params: { pid: "P3" }, body: { id: "untimed", title: "u", collectionIds: [] } })
    );

    const timed: any = await activities.listActivities(ctx({ uid: "U", params: { pid: "P3" }, query: { withTime: "1" } }));
    expect(timed.activities.map((a: any) => a.id)).toEqual(["timed"]);
    expect(timed.activities[0].timestamp).toBe("2026-08-09T10:00:00Z");
  });
});

describe("activity ↔ collection reconciliation", () => {
  it("createActivity links, updateActivity moves it, and back-refs stay consistent", async () => {
    await progress.createProgress(ctx({ uid: "U", body: { id: "P", title: "g" } }));
    await collectionsApi.createCollection(ctx({ uid: "U", params: { pid: "P" }, body: { id: "c1", name: "A" } }));
    await collectionsApi.createCollection(ctx({ uid: "U", params: { pid: "P" }, body: { id: "c2", name: "B" } }));

    await activities.createActivity(
      ctx({ uid: "U", params: { pid: "P" }, body: { id: "A", title: "t", collectionIds: ["c1"] } })
    );
    expect((await db.doc("progressItems/P/collections/c1").get()).data()!.activityIds).toContain("A");

    await activities.updateActivity(
      ctx({ uid: "U", params: { pid: "P", aid: "A" }, body: { id: "A", title: "t", collectionIds: ["c2"] } })
    );
    expect((await db.doc("progressItems/P/collections/c1").get()).data()!.activityIds).not.toContain("A");
    expect((await db.doc("progressItems/P/collections/c2").get()).data()!.activityIds).toContain("A");
    expect((await db.doc("progressItems/P/activities/A").get()).data()!.collectionIds).toEqual(["c2"]);
  });
});

describe("invitations", () => {
  it("send resolves email → accept links the collaborator → resend 409s", async () => {
    await progress.createProgress(ctx({ uid: "sender", body: { id: "P", title: "g" } }));
    await db.collection("users").doc("recipient").set({ userId: "recipient", email: "r@x.com" });

    await invitations.sendInvitation(
      ctx({ uid: "sender", body: { progressItemId: "P", progressItemTitle: "g", toEmail: "r@x.com" } })
    );
    const received = (await db.collection("invitations").where("toUserId", "==", "recipient").get()).docs;
    expect(received).toHaveLength(1);
    const invId = received[0].id;
    expect(received[0].data().status).toBe("pending");

    await invitations.acceptInvitation(ctx({ uid: "recipient", params: { id: invId } }));
    const link = await db.doc("users/recipient/progressLinks/P").get();
    expect(link.exists).toBe(true);
    expect(link.data()!.role).toBe("collaborator");

    // The recipient is now a member and can read the progress's activities.
    await expect(
      activities.listActivities(ctx({ uid: "recipient", params: { pid: "P" } }))
    ).resolves.toBeDefined();

    // Re-inviting an accepted recipient is a 409.
    await expect(
      invitations.sendInvitation(
        ctx({ uid: "sender", body: { progressItemId: "P", progressItemTitle: "g", toEmail: "r@x.com" } })
      )
    ).rejects.toMatchObject({ status: 409 });
  });

  it("reopens a declined invite instead of creating a duplicate", async () => {
    await progress.createProgress(ctx({ uid: "sender", body: { id: "P", title: "g" } }));
    await db.collection("users").doc("recipient").set({ userId: "recipient", email: "r@x.com" });
    const body = { progressItemId: "P", progressItemTitle: "g", toEmail: "r@x.com" };

    await invitations.sendInvitation(ctx({ uid: "sender", body }));
    const invId = (await db.collection("invitations").where("toUserId", "==", "recipient").get()).docs[0].id;
    await invitations.declineInvitation(ctx({ uid: "recipient", params: { id: invId } }));

    await invitations.sendInvitation(ctx({ uid: "sender", body }));
    const all = await db.collection("invitations").where("fromUserId", "==", "sender").get();
    expect(all.size).toBe(1); // reopened, not duplicated
    expect(all.docs[0].data().status).toBe("pending");
  });
});
