/**
 * Progress handlers. A progress + its owner `progressLink` are created together;
 * deletion is owner-only and fans out via the `onProgressDeleted` cascade.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { RequestContext, requireString, optionalString } from "./http";
import { assertProgressMember, assertProgressOwner } from "./auth";
import { LIMITS, clampText } from "./limits";

const db = getFirestore();

/** POST /progress — create a progress and the caller's owner link. */
export async function createProgress(ctx: RequestContext): Promise<{ id: string }> {
  const id = requireString(ctx.body, "id");
  const title = clampText(requireString(ctx.body, "title"), LIMITS.name);

  const progressRef = db.collection("progressItems").doc(id);
  const linkRef = db
    .collection("users")
    .doc(ctx.uid)
    .collection("progressLinks")
    .doc(id);
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
