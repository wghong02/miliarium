/**
 * Activity handlers, including the many-to-many back-reference reconciliation
 * with collections (an activity's `collectionIds` ↔ a collection's
 * `activityIds`), performed atomically in a batch — mirroring the client's old
 * behavior. All routes require membership of the enclosing progress.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { RequestContext, requireString, notFound } from "./http";
import { assertProgressMember } from "./auth";
import { activityDocFromBody } from "./encode";
import { serializeActivity, compact } from "./serialize";

const db = getFirestore();

const activitiesRef = (pid: string) =>
  db.collection("progressItems").doc(pid).collection("activities");
const collectionsRef = (pid: string) =>
  db.collection("progressItems").doc(pid).collection("collections");

/**
 * GET /progress/:pid/activities — all activities (newest first). With
 * `?withTime=1`, only those that have a `timestamp`, ordered ascending (for the
 * Calendar view). Map/location filtering is done client-side on the full list.
 */
export async function listActivities(
  ctx: RequestContext
): Promise<{ activities: unknown[] }> {
  const pid = ctx.params.pid;
  await assertProgressMember(ctx.uid, pid);

  const q =
    ctx.query.withTime === "1"
      ? activitiesRef(pid).orderBy("timestamp", "asc")
      : activitiesRef(pid).orderBy("createdAt", "desc");
  const snap = await q.get();
  return { activities: compact(snap.docs.map(serializeActivity)) };
}

/** GET /progress/:pid/activities/:aid — a single activity (null if missing). */
export async function getActivity(ctx: RequestContext): Promise<unknown> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  return serializeActivity(await activitiesRef(pid).doc(aid).get());
}

/** POST /progress/:pid/activities — create; link into each collection. */
export async function createActivity(ctx: RequestContext): Promise<{ id: string }> {
  const pid = ctx.params.pid;
  await assertProgressMember(ctx.uid, pid);

  const id = requireString(ctx.body, "id");
  const { doc, collectionIds } = activityDocFromBody(ctx.body, ctx.uid);
  doc.createdAt = FieldValue.serverTimestamp();

  const ref = activitiesRef(pid).doc(id);
  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  batch.set(ref, doc);
  for (const cid of collectionIds) {
    batch.update(collectionsRef(pid).doc(cid), {
      activityIds: FieldValue.arrayUnion(id),
      updatedAt: now,
    });
  }
  await batch.commit();
  return { id };
}

/** PATCH /progress/:pid/activities/:aid — full replace + reconcile membership. */
export async function updateActivity(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);

  const ref = activitiesRef(pid).doc(aid);
  const existing = await ref.get();
  if (!existing.exists) throw notFound("Activity not found.");
  const prev = existing.data() ?? {};
  const oldCollectionIds: string[] = Array.isArray(prev.collectionIds)
    ? prev.collectionIds
    : [];

  const { doc, collectionIds: newCollectionIds } = activityDocFromBody(ctx.body, ctx.uid);
  // Preserve creation metadata across edits.
  doc.createdAt = prev.createdAt ?? FieldValue.serverTimestamp();
  if (typeof prev.createdBy === "string") doc.createdBy = prev.createdBy;

  const now = FieldValue.serverTimestamp();
  const oldSet = new Set(oldCollectionIds);
  const newSet = new Set(newCollectionIds);

  const batch = db.batch();
  batch.set(ref, doc);
  for (const cid of newCollectionIds) {
    if (!oldSet.has(cid)) {
      batch.update(collectionsRef(pid).doc(cid), {
        activityIds: FieldValue.arrayUnion(aid),
        updatedAt: now,
      });
    }
  }
  for (const cid of oldCollectionIds) {
    if (!newSet.has(cid)) {
      batch.update(collectionsRef(pid).doc(cid), {
        activityIds: FieldValue.arrayRemove(aid),
        updatedAt: now,
      });
    }
  }
  await batch.commit();
  return { ok: true };
}

/** DELETE /progress/:pid/activities/:aid — cascade unlinks + cleans media. */
export async function deleteActivity(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  await activitiesRef(pid).doc(aid).delete();
  return { ok: true };
}

/** POST /progress/:pid/activities/:aid/collections/:cid — link. */
export async function addToCollection(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid, cid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  batch.update(activitiesRef(pid).doc(aid), {
    collectionIds: FieldValue.arrayUnion(cid),
    updatedAt: now,
  });
  batch.update(collectionsRef(pid).doc(cid), {
    activityIds: FieldValue.arrayUnion(aid),
    updatedAt: now,
  });
  await batch.commit();
  return { ok: true };
}

/** DELETE /progress/:pid/activities/:aid/collections/:cid — unlink. */
export async function removeFromCollection(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid, cid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  const now = FieldValue.serverTimestamp();
  const batch = db.batch();
  batch.update(activitiesRef(pid).doc(aid), {
    collectionIds: FieldValue.arrayRemove(cid),
    updatedAt: now,
  });
  batch.update(collectionsRef(pid).doc(cid), {
    activityIds: FieldValue.arrayRemove(aid),
    updatedAt: now,
  });
  await batch.commit();
  return { ok: true };
}
