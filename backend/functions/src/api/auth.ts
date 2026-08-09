/**
 * Authentication + authorization helpers for the API.
 *
 * `requireAuth` verifies the caller's Firebase ID token (sent as an
 * `Authorization: Bearer <token>` header) and returns their uid. The `assert*`
 * helpers enforce ownership/membership using the Admin SDK — the single source
 * of truth now that clients no longer write to Firestore.
 */

import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { forbidden, notFound, unauthorized } from "./http";

const auth = getAuth();
const db = getFirestore();

/** Verifies the Bearer ID token from the Authorization header → uid, or 401. */
export async function requireAuth(
  authorizationHeader: string | undefined
): Promise<string> {
  if (!authorizationHeader || !authorizationHeader.startsWith("Bearer ")) {
    throw unauthorized("Missing bearer token.");
  }
  const idToken = authorizationHeader.slice("Bearer ".length).trim();
  try {
    const decoded = await auth.verifyIdToken(idToken);
    return decoded.uid;
  } catch {
    throw unauthorized("Invalid or expired session. Please sign in again.");
  }
}

/** Caller may only act on their own user-scoped resources. */
export function assertSelf(uid: string, targetUserId: string): void {
  if (uid !== targetUserId) throw forbidden();
}

/** Loads a progress doc, throwing 404 if it doesn't exist. */
export async function getProgressOrThrow(
  pid: string
): Promise<FirebaseFirestore.DocumentSnapshot> {
  const snap = await db.collection("progressItems").doc(pid).get();
  if (!snap.exists) throw notFound("Progress not found.");
  return snap;
}

/** Throws 403 unless `uid` owns the progress. */
export async function assertProgressOwner(uid: string, pid: string): Promise<void> {
  const snap = await getProgressOrThrow(pid);
  if (snap.data()?.ownerUserId !== uid) {
    throw forbidden("Only the owner can perform this action.");
  }
}

/**
 * Throws 403 unless `uid` is the owner or a linked collaborator of the progress.
 * Membership is authoritative because `progressLinks` are now written only by
 * the backend.
 */
export async function assertProgressMember(uid: string, pid: string): Promise<void> {
  const snap = await getProgressOrThrow(pid);
  if (snap.data()?.ownerUserId === uid) return;
  const link = await db
    .collection("users")
    .doc(uid)
    .collection("progressLinks")
    .doc(pid)
    .get();
  if (!link.exists) throw forbidden("You don't have access to this progress.");
}
