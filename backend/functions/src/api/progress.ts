/**
 * Progress handlers. A progress + its owner `progressLink` are created together;
 * deletion is owner-only and fans out via the `onProgressDeleted` cascade.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { RequestContext, requireString, optionalString, limitReached } from "./http";
import { assertProgressMember, assertProgressOwner } from "./auth";
import { LIMITS, MAX_PROGRESS_ITEMS, clampText } from "./limits";

const db = getFirestore();

/** POST /progress — create a progress and the caller's owner link. */
export async function createProgress(ctx: RequestContext): Promise<{ id: string }> {
  const id = requireString(ctx.body, "id");
  const title = clampText(requireString(ctx.body, "title"), LIMITS.name);

  const userRef = db.collection("users").doc(ctx.uid);
  const linksRef = userRef.collection("progressLinks");

  // Enforce the per-account cap on owned progresses. The limit lives on the
  // user doc (set at registration); fall back to the default if unset.
  const userSnap = await userRef.get();
  const rawMax = userSnap.data()?.maxProgressItems;
  const max = typeof rawMax === "number" && rawMax >= 0 ? rawMax : MAX_PROGRESS_ITEMS;
  const owned = await linksRef.where("role", "==", "owner").count().get();
  if (owned.data().count >= max) {
    throw limitReached(`You can have at most ${max} progresses.`);
  }

  const progressRef = db.collection("progressItems").doc(id);
  const linkRef = linksRef.doc(id);
  const now = FieldValue.serverTimestamp();

  const batch = db.batch();
  batch.set(progressRef, {
    title,
    ownerUserId: ctx.uid,
    content: { summary: "", body: "" },
    createdAt: now,
  });
  batch.set(linkRef, {
    userId: ctx.uid,
    progressItemId: id,
    linkedAt: now,
    role: "owner",
  });
  await batch.commit();

  return { id };
}

/** PATCH /progress/:pid — update the summary (any member). */
export async function updateSummary(ctx: RequestContext): Promise<{ ok: true }> {
  const pid = ctx.params.pid;
  await assertProgressMember(ctx.uid, pid);
  const summary = clampText(optionalString(ctx.body, "summary") ?? "", LIMITS.summary);
  await db.collection("progressItems").doc(pid).update({ "content.summary": summary });
  return { ok: true };
}

/** DELETE /progress/:pid — owner only; the cascade cleans up everything else. */
export async function deleteProgress(ctx: RequestContext): Promise<{ ok: true }> {
  const pid = ctx.params.pid;
  await assertProgressOwner(ctx.uid, pid);
  await db.collection("progressItems").doc(pid).delete();
  return { ok: true };
}
