/**
 * Miliarium Media Cleanup — keeps Storage in sync when media/activities are
 * deleted. Two triggers, both server-owned so the client never needs
 * Storage delete permission:
 *
 *   onMediaDeleted    — a single `media/{mediaId}` doc was deleted; remove
 *                       its one Storage binary. This is the path the client
 *                       uses: it deletes the doc, this reacts.
 *   onActivityDeleted — an entire activity was deleted; remove every doc in
 *                       its `media/` subcollection and sweep every file under
 *                       the prefix `activities/{progressItemId}/{activityId}/*`.
 *                       (Deleting those media docs also fans out to
 *                       onMediaDeleted; the prefix sweep is a belt-and-braces
 *                       catch for any orphaned files.)
 *
 * Without these, deletes would leave orphan files in Storage forever,
 * slowly accruing storage costs.
 *
 * Failures are logged but never re-thrown — the source doc is already gone
 * by the time these run, so retries can't restore anything.
 */

import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { getStorage } from "firebase-admin/storage";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

const db = getFirestore();
const storage = getStorage();

/**
 * Deletes the one Storage binary behind a media doc when that doc is
 * removed. The client deletes the doc directly (it has Firestore access);
 * this trigger owns the Storage side.
 */
export const onMediaDeleted = onDocumentDeleted(
  "progressItems/{progressItemId}/activities/{activityId}/media/{mediaId}",
  async (event) => {
    const { progressItemId, activityId, mediaId } = event.params;
    const storagePath = event.data?.data()?.storagePath as string | undefined;

    if (!storagePath) {
      logger.info("onMediaDeleted: no storagePath on doc, nothing to delete", {
        progressItemId,
        activityId,
        mediaId,
      });
      return;
    }

    try {
      await storage.bucket().file(storagePath).delete();
      logger.info("onMediaDeleted: removed storage file", { storagePath });
    } catch (error) {
      const code = (error as { code?: number }).code;
      const message = error instanceof Error ? error.message : String(error);
      if (code === 404 || isBucketMissing(message)) {
        logger.info("onMediaDeleted: storage object already gone", {
          storagePath,
        });
        return;
      }
      logger.warn("onMediaDeleted: storage delete failed", {
        storagePath,
        error: message,
      });
    }
  }
);

export const onActivityDeleted = onDocumentDeleted(
  "progressItems/{progressItemId}/activities/{activityId}",
  async (event) => {
    const { progressItemId, activityId } = event.params;

    logger.info("onActivityDeleted: cleaning up media", {
      progressItemId,
      activityId,
    });

    // Run both cleanups independently so a failure on one side doesn't
    // skip the other. Settled, not all — we want both to attempt.
    await Promise.allSettled([
      cleanupFirestoreMedia(progressItemId, activityId),
      cleanupStorageFiles(progressItemId, activityId),
    ]);
  }
);

/**
 * Removes every doc in the activity's `media/` subcollection.
 * Logs warnings on failure; never throws.
 */
async function cleanupFirestoreMedia(
  progressItemId: string,
  activityId: string
): Promise<void> {
  try {
    const mediaSnapshot = await db
      .collection("progressItems")
      .doc(progressItemId)
      .collection("activities")
      .doc(activityId)
      .collection("media")
      .get();

    if (mediaSnapshot.empty) {
      return;
    }

    // Firestore batches cap at 500; chunk just in case.
    const docs = mediaSnapshot.docs;
    for (let i = 0; i < docs.length; i += 500) {
      const batch = db.batch();
      docs.slice(i, i + 500).forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
    }
    logger.info("onActivityDeleted: removed media docs", {
      count: docs.length,
      progressItemId,
      activityId,
    });
  } catch (error) {
    logger.warn("onActivityDeleted: firestore cleanup failed", {
      progressItemId,
      activityId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * Deletes every file under the Storage prefix for this activity.
 * Tolerates the case where Storage hasn't been enabled at all
 * (bucket-does-not-exist is logged at info level, not as an error).
 */
async function cleanupStorageFiles(
  progressItemId: string,
  activityId: string
): Promise<void> {
  const prefix = `activities/${progressItemId}/${activityId}/`;
  try {
    const bucket = storage.bucket();
    const [files] = await bucket.getFiles({ prefix });

    if (files.length === 0) {
      return;
    }

    await Promise.all(
      files.map((file) =>
        file.delete().catch((err) => {
          logger.warn("onActivityDeleted: failed to delete file", {
            file: file.name,
            error: err instanceof Error ? err.message : String(err),
          });
        })
      )
    );
    logger.info("onActivityDeleted: removed storage files", {
      count: files.length,
      prefix,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (isBucketMissing(message)) {
      // Storage hasn't been enabled on this Firebase project yet, or no
      // default bucket has ever been provisioned. Nothing to clean up,
      // and definitely not an error worth alerting on.
      logger.info(
        "onActivityDeleted: storage bucket not provisioned, skipping",
        { prefix }
      );
      return;
    }
    logger.warn("onActivityDeleted: storage cleanup failed", {
      prefix,
      error: message,
    });
  }
}

function isBucketMissing(message: string): boolean {
  return (
    message.includes("specified bucket does not exist") ||
    message.includes("bucket not found") ||
    message.includes("storage.buckets.get")
  );
}
