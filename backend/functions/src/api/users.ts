/**
 * User profile handlers.
 *
 * The `users/{uid}` doc is created by the `onAuthUserCreated` auth trigger
 * (accountCreation.ts), so the API only handles profile edits.
 */

import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";
import { RequestContext, optionalString } from "./http";
import { LIMITS, clampText } from "./limits";

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
