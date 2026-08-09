/**
 * Unit tests for the Storage cleanup triggers.
 *
 * Mocks `firebase-admin/storage` and `firebase-admin/firestore`, then drives
 * each trigger via its v2 `.run()` method with hand-built events.
 */

jest.mock("firebase-admin/storage", () => {
  const fileDelete = jest.fn();
  const file = jest.fn(() => ({ delete: fileDelete }));
  const getFiles = jest.fn();
  const bucket = jest.fn(() => ({ file, getFiles }));
  return { getStorage: () => ({ bucket }) };
});

jest.mock("firebase-admin/firestore", () => {
  const collection = jest.fn();
  const batch = jest.fn();
  return { getFirestore: () => ({ collection, batch }) };
});

import { getStorage } from "firebase-admin/storage";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onMediaDeleted, onActivityDeleted } from "../mediaCleanup";

const storage = (getStorage as unknown as () => any)();
const bucket = storage.bucket();
const fs = (getFirestore as unknown as () => any)();

function makeBatch() {
  return { delete: jest.fn(), commit: jest.fn().mockResolvedValue(undefined) };
}

function mediaEvent(data: Record<string, unknown> | undefined) {
  return {
    params: { progressItemId: "prog1", activityId: "act1", mediaId: "m1" },
    data: data ? { data: () => data } : undefined,
  };
}

beforeAll(() => {
  jest.spyOn(logger, "info").mockImplementation(() => {});
  jest.spyOn(logger, "warn").mockImplementation(() => {});
  jest.spyOn(logger, "error").mockImplementation(() => {});
});

// --- onMediaDeleted -------------------------------------------------------

describe("onMediaDeleted", () => {
  it("deletes the Storage binary named by the doc's storagePath", async () => {
    bucket.getFiles.mockResolvedValue([[]]);
    const path = "activities/prog1/act1/m1.jpg";

    await (onMediaDeleted as any).run(mediaEvent({ storagePath: path }));

    expect(bucket.file).toHaveBeenCalledWith(path);
    expect(bucket.file(path).delete).toHaveBeenCalled();
  });

  it("does nothing when the doc has no storagePath", async () => {
    await (onMediaDeleted as any).run(mediaEvent({}));
    expect(bucket.file).not.toHaveBeenCalled();
  });

  it("swallows a 404 from Storage (already-deleted file)", async () => {
    const err: any = new Error("Not Found");
    err.code = 404;
    bucket.file().delete.mockRejectedValueOnce(err);

    await expect(
      (onMediaDeleted as any).run(
        mediaEvent({ storagePath: "activities/prog1/act1/m1.jpg" })
      )
    ).resolves.toBeUndefined();
  });
});

// --- onActivityDeleted ----------------------------------------------------

describe("onActivityDeleted", () => {
  function setupMediaDocs(refs: unknown[]) {
    // db.collection("progressItems").doc().collection("activities").doc()
    //   .collection("media").get()
    const mediaCol = {
      get: async () => ({ empty: refs.length === 0, docs: refs.map((r) => ({ ref: r })) }),
    };
    fs.collection.mockImplementation((name: string) => {
      if (name !== "progressItems") throw new Error(`unexpected: ${name}`);
      return {
        doc: () => ({
          collection: () => ({
            doc: () => ({ collection: () => mediaCol }),
          }),
        }),
      };
    });
  }

  function activityEvent() {
    return { params: { progressItemId: "prog1", activityId: "act1" }, data: undefined };
  }

  it("deletes every media doc and every Storage file under the prefix", async () => {
    setupMediaDocs(["ref1", "ref2"]);
    const batch = makeBatch();
    fs.batch.mockReturnValue(batch);

    const f1 = { name: "f1", delete: jest.fn().mockResolvedValue(undefined) };
    const f2 = { name: "f2", delete: jest.fn().mockResolvedValue(undefined) };
    bucket.getFiles.mockResolvedValue([[f1, f2]]);

    await (onActivityDeleted as any).run(activityEvent());

    expect(batch.delete).toHaveBeenCalledTimes(2);
    expect(batch.commit).toHaveBeenCalledTimes(1);
    expect(bucket.getFiles).toHaveBeenCalledWith({
      prefix: "activities/prog1/act1/",
    });
    expect(f1.delete).toHaveBeenCalled();
    expect(f2.delete).toHaveBeenCalled();
  });

  it("is a no-op on Storage when the prefix has no files", async () => {
    setupMediaDocs([]);
    fs.batch.mockReturnValue(makeBatch());
    bucket.getFiles.mockResolvedValue([[]]);

    await expect(
      (onActivityDeleted as any).run(activityEvent())
    ).resolves.toBeUndefined();
  });
});
