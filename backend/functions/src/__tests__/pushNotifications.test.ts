/**
 * Unit tests for the push-dispatch triggers.
 *
 * Strategy: mock `firebase-admin/firestore` and `firebase-admin/messaging` so
 * no real Firebase is touched, then invoke each trigger through its v2 `.run()`
 * method with a hand-built event. The mock factories capture stable `jest.fn`
 * instances that the source grabs once at import (`const db = getFirestore()`),
 * so reconfiguring them per-test steers the handler.
 */

// --- Mocks (factories capture stable jest.fn instances) -------------------

jest.mock("firebase-admin/firestore", () => {
  const collection = jest.fn();
  const collectionGroup = jest.fn();
  const batch = jest.fn();
  return { getFirestore: () => ({ collection, collectionGroup, batch }) };
});

jest.mock("firebase-admin/messaging", () => {
  const sendEachForMulticast = jest.fn();
  return { getMessaging: () => ({ sendEachForMulticast }) };
});

import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions/v2";
import { onInvitationCreated, onActivityCreated } from "../pushNotifications";

// Handles to the same fn instances the source module captured.
const fs = (getFirestore as unknown as () => any)();
const messaging = (getMessaging as unknown as () => any)();

// --- Fixtures / helpers ---------------------------------------------------

type UserFixture = { name?: string; email?: string; tokens?: string[] };

/** A batch whose deletes we can inspect. */
function makeBatch() {
  return { delete: jest.fn(), commit: jest.fn().mockResolvedValue(undefined) };
}

/**
 * Wires `fs.collection("users")` to serve the given users: each user doc
 * answers `.get()` (for display-name lookup) and
 * `.collection("deviceTokens").get()` (for token fan-out). Token doc refs are
 * tagged so we can assert exactly which tokens a batch deleted.
 */
function setupUsers(users: Record<string, UserFixture>) {
  fs.collection.mockImplementation((name: string) => {
    if (name !== "users") throw new Error(`unexpected collection: ${name}`);
    return {
      doc: (uid: string) => ({
        get: async () => ({
          exists: users[uid] !== undefined,
          data: () =>
            users[uid]
              ? { name: users[uid].name, email: users[uid].email }
              : undefined,
        }),
        collection: (sub: string) => {
          if (sub !== "deviceTokens") {
            throw new Error(`unexpected subcollection: ${sub}`);
          }
          return {
            get: async () => ({
              docs: (users[uid]?.tokens ?? []).map((t) => ({ id: t })),
            }),
            doc: (t: string) => ({ __token: { uid, t } }),
          };
        },
      }),
    };
  });
}

/** Wires the collection-group query used to find a progress's collaborators. */
function setupProgressLinks(userIds: string[]) {
  fs.collectionGroup.mockImplementation((name: string) => {
    if (name !== "progressLinks") {
      throw new Error(`unexpected collectionGroup: ${name}`);
    }
    return {
      where: () => ({
        get: async () => ({
          docs: userIds.map((uid) => ({
            ref: { parent: { parent: { id: uid } } },
          })),
        }),
      }),
    };
  });
}

function invitationEvent(data: Record<string, unknown>) {
  return { params: { invitationId: "inv1" }, data: { data: () => data } };
}

function activityEvent(data: Record<string, unknown>) {
  return {
    params: { progressItemId: "prog1", activityId: "act1" },
    data: { data: () => data },
  };
}

beforeAll(() => {
  // Silence structured logs during the run (implementations survive clearMocks).
  jest.spyOn(logger, "info").mockImplementation(() => {});
  jest.spyOn(logger, "warn").mockImplementation(() => {});
  jest.spyOn(logger, "error").mockImplementation(() => {});
});

// --- onInvitationCreated --------------------------------------------------

describe("onInvitationCreated", () => {
  it("sends a push to every recipient token with the sender's display name", async () => {
    setupUsers({
      recipient: { tokens: ["tokA", "tokB"] },
      sender: { name: "Alice" },
    });
    messaging.sendEachForMulticast.mockResolvedValue({
      successCount: 2,
      failureCount: 0,
      responses: [{ success: true }, { success: true }],
    });

    await (onInvitationCreated as any).run(
      invitationEvent({
        toUserId: "recipient",
        fromUserId: "sender",
        progressItemTitle: "My Goal",
      })
    );

    expect(messaging.sendEachForMulticast).toHaveBeenCalledTimes(1);
    const payload = messaging.sendEachForMulticast.mock.calls[0][0];
    expect(payload.tokens).toEqual(["tokA", "tokB"]);
    expect(payload.notification.body).toBe(
      'Alice invited you to collaborate on "My Goal"'
    );
  });

  it("falls back to email, then 'Someone', for the sender name", async () => {
    setupUsers({
      recipient: { tokens: ["tokA"] },
      sender: { email: "bob@example.com" },
    });
    messaging.sendEachForMulticast.mockResolvedValue({
      successCount: 1,
      failureCount: 0,
      responses: [{ success: true }],
    });

    await (onInvitationCreated as any).run(
      invitationEvent({
        toUserId: "recipient",
        fromUserId: "sender",
        progressItemTitle: "Goal",
      })
    );

    const body = messaging.sendEachForMulticast.mock.calls[0][0].notification.body;
    expect(body).toBe('bob@example.com invited you to collaborate on "Goal"');
  });

  it("does nothing when a required field is missing", async () => {
    await (onInvitationCreated as any).run(
      invitationEvent({ toUserId: "recipient", fromUserId: "sender" }) // no title
    );
    expect(messaging.sendEachForMulticast).not.toHaveBeenCalled();
  });

  it("does not send when the recipient has no device tokens", async () => {
    setupUsers({ recipient: { tokens: [] }, sender: { name: "Alice" } });
    await (onInvitationCreated as any).run(
      invitationEvent({
        toUserId: "recipient",
        fromUserId: "sender",
        progressItemTitle: "Goal",
      })
    );
    expect(messaging.sendEachForMulticast).not.toHaveBeenCalled();
  });

  it("purges dead tokens but keeps tokens that failed for auth reasons", async () => {
    setupUsers({
      recipient: { tokens: ["deadTok", "authTok"] },
      sender: { name: "Alice" },
    });
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);
    messaging.sendEachForMulticast.mockResolvedValue({
      successCount: 0,
      failureCount: 2,
      responses: [
        {
          success: false,
          error: { code: "messaging/registration-token-not-registered" },
        },
        // Transient/auth failure — token is still valid, must be kept.
        { success: false, error: { code: "messaging/third-party-auth-error" } },
      ],
    });

    await (onInvitationCreated as any).run(
      invitationEvent({
        toUserId: "recipient",
        fromUserId: "sender",
        progressItemTitle: "Goal",
      })
    );

    expect(batch.delete).toHaveBeenCalledTimes(1);
    expect(batch.delete.mock.calls[0][0]).toEqual({
      __token: { uid: "recipient", t: "deadTok" },
    });
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });
});

// --- onActivityCreated ----------------------------------------------------

describe("onActivityCreated", () => {
  it("notifies collaborators (excluding the creator) with the creator's name", async () => {
    setupProgressLinks(["creator", "collab1", "collab2"]);
    setupUsers({
      creator: { name: "Bob", tokens: ["tCreator"] },
      collab1: { tokens: ["t1"] },
      collab2: { tokens: ["t2"] },
    });
    messaging.sendEachForMulticast.mockResolvedValue({
      successCount: 2,
      failureCount: 0,
      responses: [{ success: true }, { success: true }],
    });

    await (onActivityCreated as any).run(
      activityEvent({ createdBy: "creator", title: "New Task" })
    );

    expect(messaging.sendEachForMulticast).toHaveBeenCalledTimes(1);
    const payload = messaging.sendEachForMulticast.mock.calls[0][0];
    expect(payload.tokens).toEqual(["t1", "t2"]); // creator's token excluded
    expect(payload.tokens).not.toContain("tCreator");
    expect(payload.notification.body).toBe('Bob added "New Task"');
  });

  it("does nothing when the creator is the only collaborator", async () => {
    setupProgressLinks(["creator"]);
    setupUsers({ creator: { name: "Bob", tokens: ["tCreator"] } });

    await (onActivityCreated as any).run(
      activityEvent({ createdBy: "creator", title: "Solo Task" })
    );

    expect(messaging.sendEachForMulticast).not.toHaveBeenCalled();
  });

  it("does nothing when required fields are missing", async () => {
    await (onActivityCreated as any).run(
      activityEvent({ title: "No creator" }) // no createdBy
    );
    expect(messaging.sendEachForMulticast).not.toHaveBeenCalled();
  });
});
