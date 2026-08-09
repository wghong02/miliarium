/**
 * Collection handlers. Stats are computed client-side (a read of the progress's
 * activities) and persisted here — the backend only writes what it's given.
 * Membership (`activityIds`) is reconciled by the activity handlers, so the
 * create/update paths here never touch it beyond initialization.
 */

import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { RequestContext, requireString, optionalString, badRequest } from "./http";
import { assertProgressMember } from "./auth";
import { LIMITS, clampText } from "./limits";

const db = getFirestore();
const NOTES_MAX = 5000;

const collectionsRef = (pid: string) =>
  db.collection("progressItems").doc(pid).collection("collections");

/** POST /progress/:pid/collections — create (client supplies the id). */
export async function createCollection(ctx: RequestContext): Promise<{ id: string }> {
  const pid = ctx.params.pid;
  await assertProgressMember(ctx.uid, pid);

  const id = requireString(ctx.body, "id");
  const now = FieldValue.serverTimestamp();
  const doc: Record<string, unknown> = {
    name: clampText(requireString(ctx.body, "name"), LIMITS.name),
    isFavorite: ctx.body.isFavorite === true,
    activityIds: [],
    stats: { total: 0, completedCount: 0, locationCount: 0, timeCount: 0 },
    createdAt: now,
    updatedAt: now,
  };
  const notes = optionalString(ctx.body, "notes");
  if (notes && notes.trim().length > 0) doc.notes = notes.slice(0, NOTES_MAX);

  await collectionsRef(pid).doc(id).set(doc);
  return { id };
}

/**
 * PATCH /progress/:pid/collections/:cid — edit name/notes/isFavorite only.
 * Uses a merge so it never clobbers `activityIds`/`stats` (which are managed by
 * the activity handlers and the stats endpoint).
 */
export async function updateCollection(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, cid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);

  const updates: Record<string, unknown> = { updatedAt: FieldValue.serverTimestamp() };
  if (typeof ctx.body.name === "string") {
    updates.name = clampText(ctx.body.name, LIMITS.name);
  }
  if (typeof ctx.body.isFavorite === "boolean") {
    updates.isFavorite = ctx.body.isFavorite;
  }
  if ("notes" in ctx.body) {
    const notes = optionalString(ctx.body, "notes");
    updates.notes =
      notes && notes.trim().length > 0 ? notes.slice(0, NOTES_MAX) : FieldValue.delete();
  }

  await collectionsRef(pid).doc(cid).set(updates, { merge: true });
  return { ok: true };
}

/**
 * POST /progress/:pid/collections/:cid/stats — persist client-computed stats.
 * Body: `{ total, firstAt?, lastAt?, completedCount, locationCount, timeCount }`.
 */
export async function persistStats(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, cid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);

  const num = (field: string): number => {
    const v = ctx.body[field];
    if (typeof v !== "number" || !Number.isFinite(v)) {
      throw badRequest(`Invalid stat: ${field}`);
    }
    return v;
  };
  const date = (field: string): Timestamp | undefined => {
    const v = ctx.body[field];
    if (typeof v !== "string") return undefined;
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? undefined : Timestamp.fromDate(d);
  };

  const stats: Record<string, unknown> = {
    total: num("total"),
    completedCount: num("completedCount"),
    locationCount: num("locationCount"),
    timeCount: num("timeCount"),
  };
  const firstAt = date("firstAt");
  const lastAt = date("lastAt");
  if (firstAt) stats.firstAt = firstAt;
  if (lastAt) stats.lastAt = lastAt;

  await collectionsRef(pid).doc(cid).set(
    {
      stats,
      statsUpdatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  return { ok: true };
}

/** DELETE /progress/:pid/collections/:cid — cascade unlinks member activities. */
export async function deleteCollection(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, cid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  await collectionsRef(pid).doc(cid).delete();
  return { ok: true };
}
