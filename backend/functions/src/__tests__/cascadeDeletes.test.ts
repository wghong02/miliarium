/**
 * Unit tests for the relational cascade-delete triggers.
 *
 * Mocks `firebase-admin/firestore`, then drives each trigger via its v2
 * `.run()` method with hand-built events — same approach as mediaCleanup.test.
 */

jest.mock("firebase-admin/firestore", () => {
  const recursiveDelete = jest.fn().mockResolvedValue(undefined);
  const collection = jest.fn();
  const collectionGroup = jest.fn();
  const batch = jest.fn();
  const arrayRemove = jest.fn((v: unknown) => ({ __arrayRemove: v }));
  const serverTimestamp = jest.fn(() => ({ __serverTimestamp: true }));
  return {
    getFirestore: () => ({
      collection,
      collectionGroup,
      batch,
      recursiveDelete,
    }),
    FieldValue: { arrayRemove, serverTimestamp },
  };
});

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import {
  onProgressDeleted,
  onCollectionDeleted,
  onActivityUnlinkCollections,
  onUserDeleted,
} from "../cascadeDeletes";

const fs = (getFirestore as unknown as () => any)();

function makeBatch() {
  return {
    delete: jest.fn(),
    update: jest.fn(),
    commit: jest.fn().mockResolvedValue(undefined),
  };
}

/** A Query stand-in whose `.where()` chains and whose `.get()` resolves docs. */
function queryReturning(docs: unknown[]) {
  const q: any = {
    where: jest.fn(() => q),
    get: jest.fn().mockResolvedValue({ empty: docs.length === 0, docs }),
  };
  return q;
}

beforeAll(() => {
  jest.spyOn(logger, "info").mockImplementation(() => undefined as any);
  jest.spyOn(logger, "warn").mockImplementation(() => undefined as any);
});

beforeEach(() => {
  jest.clearAllMocks();
});

// --- onProgressDeleted ----------------------------------------------------

describe("onProgressDeleted", () => {
  it("recursiveDeletes the subtree and deletes invitations + progressLinks", async () => {
    const progressRef = { id: "prog1" };
    const invitations = queryReturning([{ ref: "inv1" }]);
    const links = queryReturning([{ ref: "lnk1" }, { ref: "lnk2" }]);

    fs.collection.mockImplementation((name: string) => {
      if (name === "progressItems") return { doc: () => progressRef };
      if (name === "invitations") return invitations;
      throw new Error(`unexpected collection ${name}`);
    });
    fs.collectionGroup.mockImplementation((name: string) => {
      if (name === "progressLinks") return links;
      throw new Error(`unexpected group ${name}`);
    });
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);

    await (onProgressDeleted as any).run({ params: { progressItemId: "prog1" } });

    expect(fs.recursiveDelete).toHaveBeenCalledWith(progressRef);
    // invitations (1) + progressLinks (2) deleted across the shared batch mock.
    expect(batch.delete).toHaveBeenCalledTimes(3);
    expect(batch.commit).toHaveBeenCalled();
  });

  it("still recursiveDeletes when there are no invitations/links", async () => {
    fs.collection.mockImplementation((name: string) => {
      if (name === "progressItems") return { doc: () => ({ id: "prog1" }) };
      if (name === "invitations") return queryReturning([]);
      throw new Error(name);
    });
    fs.collectionGroup.mockReturnValue(queryReturning([]));
    fs.batch.mockReturnValue(makeBatch());

    await (onProgressDeleted as any).run({ params: { progressItemId: "prog1" } });

    expect(fs.recursiveDelete).toHaveBeenCalledTimes(1);
  });
});

// --- onCollectionDeleted --------------------------------------------------

describe("onCollectionDeleted", () => {
  it("unlinks the deleted collection from every member activity", async () => {
    const activities = { doc: jest.fn((id: string) => ({ id })) };
    fs.collection.mockImplementation((name: string) => {
      if (name === "progressItems") {
        return {
          doc: () => ({
            collection: (sub: string) => {
              expect(sub).toBe("activities");
              return activities;
            },
          }),
        };
      }
      throw new Error(name);
    });
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);

    await (onCollectionDeleted as any).run({
      params: { progressItemId: "prog1", collectionId: "col1" },
      data: { data: () => ({ activityIds: ["a1", "a2"] }) },
    });

    expect(activities.doc).toHaveBeenCalledWith("a1");
    expect(activities.doc).toHaveBeenCalledWith("a2");
    expect(batch.update).toHaveBeenCalledTimes(2);
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });

  it("does nothing when the collection had no activities", async () => {
    await (onCollectionDeleted as any).run({
      params: { progressItemId: "prog1", collectionId: "col1" },
      data: { data: () => ({ activityIds: [] }) },
    });
    expect(fs.batch).not.toHaveBeenCalled();
  });
});

// --- onActivityUnlinkCollections ------------------------------------------

describe("onActivityUnlinkCollections", () => {
  it("unlinks the deleted activity from every collection it belonged to", async () => {
    const collections = { doc: jest.fn((id: string) => ({ id })) };
    fs.collection.mockImplementation((name: string) => {
      if (name === "progressItems") {
        return {
          doc: () => ({
            collection: (sub: string) => {
              expect(sub).toBe("collections");
              return collections;
            },
          }),
        };
      }
      throw new Error(name);
    });
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);

    await (onActivityUnlinkCollections as any).run({
      params: { progressItemId: "prog1", activityId: "act1" },
      data: { data: () => ({ collectionIds: ["c1"] }) },
    });

    expect(collections.doc).toHaveBeenCalledWith("c1");
    expect(batch.update).toHaveBeenCalledTimes(1);
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });

  it("does nothing when the activity belonged to no collection", async () => {
    await (onActivityUnlinkCollections as any).run({
      params: { progressItemId: "prog1", activityId: "act1" },
      data: { data: () => ({}) },
    });
    expect(fs.batch).not.toHaveBeenCalled();
  });
});

// --- onUserDeleted --------------------------------------------------------

describe("onUserDeleted", () => {
  it("recursiveDeletes the user subtree and deletes every owned progress", async () => {
    const userRef = { id: "u1" };
    const owned = queryReturning([{ ref: "p1" }, { ref: "p2" }]);
    fs.collection.mockImplementation((name: string) => {
      if (name === "users") return { doc: () => userRef };
      if (name === "progressItems") return owned;
      throw new Error(name);
    });
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);

    await (onUserDeleted as any).run({ params: { userId: "u1" } });

    expect(fs.recursiveDelete).toHaveBeenCalledWith(userRef);
    expect(batch.delete).toHaveBeenCalledTimes(2);
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });
});
