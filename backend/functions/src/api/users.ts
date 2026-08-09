/**
 * User profile + account-lifecycle handlers. The `users/{uid}` doc is created
 * lazily on sign-in (`ensureProfile`), edited via `updateProfile`, and removed
 * with the whole account via `deleteAccount` — all here, so no Gen 1 Auth
 * triggers are needed.
 */

import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { RequestContext, optionalString } from "./http";
import { LIMITS, clampText } from "./limits";
import { serializeUser, compact } from "./serialize";

const db = getFirestore();

/**
 * POST /me/ensure — idempotently create the caller's `users/{uid}` profile doc.
 * Called on sign-in (replaces the old onAuthUserCreated auth trigger). The email
 * is read from the Auth record so collaborators can resolve/invite by email.
 */
export async function ensureProfile(ctx: RequestContext): Promise<{ ok: true }> {
  const ref = db.collection("users").doc(ctx.uid);
  if ((await ref.get()).exists) return { ok: true };

  let email: string | undefined;
  try {
    email = (await getAuth().getUser(ctx.uid)).email ?? undefined;
  } catch {
    // Best-effort — proceed without email if the lookup fails.
  }
  const now = Timestamp.now();
  const data: Record<string, unknown> = { userId: ctx.uid, createdAt: now, updatedAt: now };
  if (email) data.email = email;

  await ref.set(data, { merge: true });
  return { ok: true };
}

/**
 * DELETE /me/account — permanently delete the caller's account (App Store Review
 * Guideline 5.1.1(v)). Deletes the Auth account first (admin — reliable), then
 * the `users/{uid}` doc, which fires the `onUserDeleted` cascade that wipes the
 * rest. Auth-first means a failure never destroys data while the account lives.
 */
export async function deleteAccount(ctx: RequestContext): Promise<{ ok: true }> {
  await getAuth().deleteUser(ctx.uid);
  await db.collection("users").doc(ctx.uid).delete();
  return { ok: true };
}

/**
 * PATCH /me — set or clear the caller's display name.
 * Body: `{ name?: string }`. An absent/blank name clears it.
 */
export async function updateProfile(ctx: RequestContext): Promise<{ ok: true }> {
  const raw = optionalString(ctx.body, "name") ?? "";
  const name = clampText(raw, LIMITS.name);

  const updates: Record<string, unknown> = { updatedAt: Timestamp.now() };
  updates.name = name.length > 0 ? name : FieldValue.delete();

  await db.collection("users").doc(ctx.uid).set(updates, { merge: true });
  return { ok: true };
}

/** GET /users/:id — a single profile by id (null if missing). */
export async function getUser(ctx: RequestContext): Promise<unknown> {
  const doc = await db.collection("users").doc(ctx.params.id).get();
  return serializeUser(doc);
}

/** GET /users?ids=a,b,c — resolve up to 100 profiles by id. */
export async function getUsers(ctx: RequestContext): Promise<{ users: unknown[] }> {
  const ids = (ctx.query.ids ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const unique = [...new Set(ids)].slice(0, 100);
  if (unique.length === 0) return { users: [] };

  const refs = unique.map((id) => db.collection("users").doc(id));
  const snaps = await db.getAll(...refs);
  return { users: compact(snaps.map(serializeUser)) };
}
