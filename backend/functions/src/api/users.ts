/**
 * User profile handlers.
 *
 * The `users/{uid}` doc is created by the `onAuthUserCreated` auth trigger
 * (accountCreation.ts), so the API only handles profile edits.
 */

import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";
import { RequestContext, optionalString } from "./http";
import { LIMITS, clampText } from "./limits";
import { serializeUser, compact } from "./serialize";

const db = getFirestore();

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
