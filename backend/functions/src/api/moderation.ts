/**
 * Moderation handlers (Guideline 1.2): report content and block/unblock users.
 * Reports are write-only from clients; blocks live at
 * `users/{uid}/blockedUsers/{blockedId}`.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { RequestContext, requireString, optionalString, badRequest } from "./http";

const db = getFirestore();

/**
 * POST /reports — file a report about another user's content.
 * Body: `{ reportedUserId, context, details? }`.
 */
export async function createReport(ctx: RequestContext): Promise<{ ok: true }> {
  const reportedUserId = requireString(ctx.body, "reportedUserId");
  const context = requireString(ctx.body, "context");
  const details = optionalString(ctx.body, "details");

  const data: Record<string, unknown> = {
    reporterId: ctx.uid,
    reportedUserId,
    context,
    createdAt: FieldValue.serverTimestamp(),
  };
  if (details && details.trim()) data.details = details.trim();

  await db.collection("reports").add(data);
  return { ok: true };
}

/** PUT /me/blocked-users/:id — block a user. */
export async function blockUser(ctx: RequestContext): Promise<{ ok: true }> {
  const blockedUserId = ctx.params.id;
  if (!blockedUserId) throw badRequest("Missing user id.");
  if (blockedUserId === ctx.uid) throw badRequest("You can't block yourself.");

  await db
    .collection("users")
    .doc(ctx.uid)
    .collection("blockedUsers")
    .doc(blockedUserId)
    .set({ blockedUserId, createdAt: FieldValue.serverTimestamp() });
  return { ok: true };
}

/** DELETE /me/blocked-users/:id — unblock a user. */
export async function unblockUser(ctx: RequestContext): Promise<{ ok: true }> {
  const blockedUserId = ctx.params.id;
  if (!blockedUserId) throw badRequest("Missing user id.");

  await db
    .collection("users")
    .doc(ctx.uid)
    .collection("blockedUsers")
    .doc(blockedUserId)
    .delete();
  return { ok: true };
}
