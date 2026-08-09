/**
 * Invitation handlers. Sending resolves the recipient by email server-side
 * (with the Admin SDK), so clients never query the `users` collection by email
 * — closing the account-enumeration vector. Status transitions are gated to the
 * right participant (recipient accepts/declines; sender revokes/deletes).
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import {
  RequestContext,
  requireString,
  notFound,
  forbidden,
  badRequest,
  conflict,
} from "./http";
import { assertProgressMember } from "./auth";
import { LIMITS, clampText } from "./limits";
import { serializeInvitation, compact } from "./serialize";

const db = getFirestore();

async function loadInvitation(id: string) {
  const snap = await db.collection("invitations").doc(id).get();
  if (!snap.exists) throw notFound("Invitation not found.");
  return snap;
}

/**
 * GET /invitations — the caller's invitations, always scoped to them:
 *   ?role=received (default)  → toUserId == me
 *   ?role=sent                → fromUserId == me
 *   ?progressItemId=X         → fromUserId == me AND progressItemId == X
 */
export async function listInvitations(
  ctx: RequestContext
): Promise<{ invitations: unknown[] }> {
  const { role, progressItemId } = ctx.query;
  let q: FirebaseFirestore.Query;
  if (progressItemId) {
    q = db
      .collection("invitations")
      .where("fromUserId", "==", ctx.uid)
      .where("progressItemId", "==", progressItemId);
  } else if (role === "sent") {
    q = db.collection("invitations").where("fromUserId", "==", ctx.uid);
  } else {
    q = db.collection("invitations").where("toUserId", "==", ctx.uid);
  }
  const snap = await q.orderBy("createdAt", "desc").get();
  return { invitations: compact(snap.docs.map(serializeInvitation)) };
}

/**
 * POST /invitations — send (or reopen) an invitation to a recipient email.
 * Body: `{ progressItemId, progressItemTitle, toEmail }`.
 */
export async function sendInvitation(ctx: RequestContext): Promise<{ ok: true }> {
  const uid = ctx.uid;
  const progressItemId = requireString(ctx.body, "progressItemId");
  await assertProgressMember(uid, progressItemId);
  const progressItemTitle = clampText(
    requireString(ctx.body, "progressItemTitle"),
    LIMITS.name
  );
  const toEmail = requireString(ctx.body, "toEmail").trim();

  // Resolve the recipient by email with admin privileges.
  const found = await db
    .collection("users")
    .where("email", "==", toEmail)
    .limit(1)
    .get();
  if (found.empty) throw notFound(`No Miliarium user found for ${toEmail}.`);
  const toUserId = found.docs[0].id;
  if (toUserId === uid) throw badRequest("You can't invite yourself.");

  // Dedup by (sender, recipient, progress): reopen an existing row rather than
  // creating a parallel one.
  const existing = await db
    .collection("invitations")
    .where("fromUserId", "==", uid)
    .where("toUserId", "==", toUserId)
    .where("progressItemId", "==", progressItemId)
    .limit(1)
    .get();

  if (!existing.empty) {
    const doc = existing.docs[0];
    if (doc.data().status === "accepted") {
      throw conflict("This user has already accepted access to this progress.");
    }
    await doc.ref.update({
      status: "pending",
      progressItemTitle,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { ok: true };
  }

  await db.collection("invitations").add({
    fromUserId: uid,
    toUserId,
    progressItemId,
    progressItemTitle,
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { ok: true };
}

/** POST /invitations/:id/accept — recipient accepts; creates their progressLink. */
export async function acceptInvitation(ctx: RequestContext): Promise<{ ok: true }> {
  const snap = await loadInvitation(ctx.params.id);
  const inv = snap.data()!;
  if (inv.toUserId !== ctx.uid) throw forbidden();

  const linkRef = db
    .collection("users")
    .doc(inv.toUserId)
    .collection("progressLinks")
    .doc(inv.progressItemId);

  const batch = db.batch();
  batch.update(snap.ref, {
    status: "accepted",
    updatedAt: FieldValue.serverTimestamp(),
  });
  batch.set(
    linkRef,
    {
      userId: inv.toUserId,
      progressItemId: inv.progressItemId,
      linkedAt: FieldValue.serverTimestamp(),
      role: "collaborator",
    },
    { merge: true }
  );
  await batch.commit();
  return { ok: true };
}

/** POST /invitations/:id/decline — recipient declines. */
export async function declineInvitation(ctx: RequestContext): Promise<{ ok: true }> {
  const snap = await loadInvitation(ctx.params.id);
  if (snap.data()!.toUserId !== ctx.uid) throw forbidden();
  await snap.ref.update({ status: "declined", updatedAt: FieldValue.serverTimestamp() });
  return { ok: true };
}

/** POST /invitations/:id/revoke — sender withdraws. */
export async function revokeInvitation(ctx: RequestContext): Promise<{ ok: true }> {
  const snap = await loadInvitation(ctx.params.id);
  if (snap.data()!.fromUserId !== ctx.uid) throw forbidden();
  await snap.ref.update({ status: "revoked", updatedAt: FieldValue.serverTimestamp() });
  return { ok: true };
}

/** DELETE /invitations/:id — sender hard-deletes. */
export async function deleteInvitation(ctx: RequestContext): Promise<{ ok: true }> {
  const snap = await loadInvitation(ctx.params.id);
  if (snap.data()!.fromUserId !== ctx.uid) throw forbidden();
  await snap.ref.delete();
  return { ok: true };
}
