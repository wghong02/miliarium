/**
 * Miliarium Cascade Deletes — server-owned relational cleanup that runs when
 * a progress, collection, activity, or user document is deleted. The client
 * only ever deletes the single top-level document; these Firestore triggers
 * fan out to everything that referenced it, so the client needs no broad
 * multi-collection delete permission and can never leave the graph
 * half-deleted.
 *
 * Triggers:
 *   onProgressDeleted           — a progressItems/{id} doc was deleted; wipe
 *                                 its activities + collections subtrees, plus
 *                                 every invitation and progressLink that
 *                                 pointed at it (owner + collaborators).
 *   onCollectionDeleted         — unlink the deleted collection from every
 *                                 activity that listed it in `collectionIds`.
 *   onActivityUnlinkCollections — unlink the deleted activity from every
 *                                 collection that listed it in `activityIds`.
 *   onUserDeleted               — a users/{uid} doc was deleted (account
 *                                 deletion); wipe the user's subtree
 *                                 (deviceTokens, progressLinks, ...) and every
 *                                 progress they owned (which re-fires
 *                                 onProgressDeleted for each).
 *
 * Storage cleanup for media/activities lives in mediaCleanup.ts and fires
 * independently as those docs get deleted here.
 *
 * Two functions (this file's onActivityUnlinkCollections and mediaCleanup's
 * onActivityDeleted) intentionally share the activity-deleted trigger path,
 * keeping relational and Storage cleanup as separate concerns.
 *
 * All failures are logged, never re-thrown — the source doc is already gone
 * by the time these run, so there is nothing to roll back or retry.
 */

import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

const db = getFirestore();

export const onProgressDeleted = onDocumentDeleted(
  "progressItems/{progressItemId}",
  async (event) => {
    const { progressItemId } = event.params;
    logger.info("onProgressDeleted: cascading", { progressItemId });

    const progressRef = db.collection("progressItems").doc(progressItemId);

    await Promise.allSettled([
      // activities + collections subcollections (each activity's media subtree
      // included). Deleting an activity doc re-fires onActivityDeleted, so the
      // Storage cleanup in mediaCleanup.ts still runs for its files.
      recursiveDelete(progressRef, `progress ${progressItemId} subtree`),
      // Invitations are a top-level collection keyed by progressItemId.
      deleteQuery(
        db.collection("invitations").where("progressItemId", "==", progressItemId),
        `invitations for ${progressItemId}`
      ),
      // Every user's link to this progress (owner + collaborators). Requires a
      // collection-group index on `progressLinks.progressItemId`.
      deleteQuery(
        db
          .collectionGroup("progressLinks")
          .where("progressItemId", "==", progressItemId),
        `progressLinks for ${progressItemId}`
      ),
    ]);
  }
);

export const onCollectionDeleted = onDocumentDeleted(
  "progressItems/{progressItemId}/collections/{collectionId}",
  async (event) => {
    const { progressItemId, collectionId } = event.params;
    const activityIds =
      (event.data?.data()?.activityIds as string[] | undefined) ?? [];
    if (activityIds.length === 0) return;

    await unlink({
      progressItemId,
      sub: "activities",
      ids: activityIds,
      field: "collectionIds",
      value: collectionId,
      label: `collection ${collectionId}`,
    });
  }
);

export const onActivityUnlinkCollections = onDocumentDeleted(
  "progressItems/{progressItemId}/activities/{activityId}",
  async (event) => {
    const { progressItemId, activityId } = event.params;
    const collectionIds =
      (event.data?.data()?.collectionIds as string[] | undefined) ?? [];
    if (collectionIds.length === 0) return;

    await unlink({
      progressItemId,
      sub: "collections",
      ids: collectionIds,
      field: "activityIds",
      value: activityId,
      label: `activity ${activityId}`,
    });
  }
);

export const onUserDeleted = onDocumentDeleted(
  "users/{userId}",
  async (event) => {
    const { userId } = event.params;
    logger.info("onUserDeleted: cascading", { userId });

    const userRef = db.collection("users").doc(userId);

    await Promise.allSettled([
      // deviceTokens + progressLinks + any other user subcollection.
      recursiveDelete(userRef, `user ${userId} subtree`),
      // Every progress this user owned; each delete re-fires onProgressDeleted.
      deleteQuery(
        db.collection("progressItems").where("ownerUserId", "==", userId),
        `progresses owned by ${userId}`
      ),
    ]);
  }
);

// --- helpers --------------------------------------------------------------

/** Deletes a document and its entire subtree. Logs, never throws. */
async function recursiveDelete(
  ref: FirebaseFirestore.DocumentReference,
  label: string
): Promise<void> {
  try {
    await db.recursiveDelete(ref);
    logger.info(`cascade: recursiveDelete done (${label})`);
  } catch (error) {
    logger.warn(`cascade: recursiveDelete failed (${label})`, {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/** Deletes every doc a query returns, chunked to Firestore's 500/batch cap. */
async function deleteQuery(
  query: FirebaseFirestore.Query,
  label: string
): Promise<void> {
  try {
    const snapshot = await query.get();
    if (snapshot.empty) return;

    const docs = snapshot.docs;
    for (let i = 0; i < docs.length; i += 500) {
      const batch = db.batch();
      docs.slice(i, i + 500).forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
    }
    logger.info(`cascade: deleted ${docs.length} docs (${label})`);
  } catch (error) {
    logger.warn(`cascade: deleteQuery failed (${label})`, {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/**
 * Removes `value` from the array `field` on every doc named by `ids` in the
 * `progressItems/{progressItemId}/{sub}` subcollection — keeping the
 * activity↔collection cross-references consistent when one side is deleted.
 *
 * `update` (not `set`) is deliberate: it must not resurrect a doc that was
 * also deleted (e.g. during a full-progress cascade). An update against an
 * already-deleted doc fails that batch, which is caught and logged — expected,
 * harmless noise, since those docs are on their way out anyway.
 */
async function unlink(args: {
  progressItemId: string;
  sub: string;
  ids: string[];
  field: string;
  value: string;
  label: string;
}): Promise<void> {
  const { progressItemId, sub, ids, field, value, label } = args;
  try {
    const col = db
      .collection("progressItems")
      .doc(progressItemId)
      .collection(sub);
    const now = FieldValue.serverTimestamp();

    for (let i = 0; i < ids.length; i += 500) {
      const batch = db.batch();
      ids.slice(i, i + 500).forEach((id) =>
        batch.update(col.doc(id), {
          [field]: FieldValue.arrayRemove(value),
          updatedAt: now,
        })
      );
      await batch.commit();
    }
    logger.info(`cascade: unlinked ${ids.length} docs (${label})`);
  } catch (error) {
    logger.warn(`cascade: unlink failed (${label})`, {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
