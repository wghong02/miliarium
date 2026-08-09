/**
 * Device-token handlers — the per-device FCM token used for push dispatch,
 * stored at `users/{uid}/deviceTokens/{token}`.
 *
 * The token is carried in the body (not the path) because FCM tokens contain
 * characters that are awkward in a URL path segment.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { RequestContext, requireString, optionalString } from "./http";

const db = getFirestore();

function tokenRef(uid: string, token: string) {
  return db.collection("users").doc(uid).collection("deviceTokens").doc(token);
}

/**
 * PUT /me/device-tokens — upsert this device's token. `createdAt` is set only on
 * first write; `lastSeenAt` is refreshed every time.
 * Body: `{ token, appVersion?, osVersion? }`.
 */
export async function upsertDeviceToken(ctx: RequestContext): Promise<{ ok: true }> {
  const token = requireString(ctx.body, "token");
  const ref = tokenRef(ctx.uid, token);
  const snap = await ref.get();

  const data: Record<string, unknown> = {
    token,
    userId: ctx.uid,
    platform: "ios",
    lastSeenAt: FieldValue.serverTimestamp(),
  };
  const appVersion = optionalString(ctx.body, "appVersion");
  const osVersion = optionalString(ctx.body, "osVersion");
  if (appVersion) data.appVersion = appVersion;
  if (osVersion) data.osVersion = osVersion;
  if (!snap.exists) data.createdAt = FieldValue.serverTimestamp();

  await ref.set(data, { merge: true });
  return { ok: true };
}

/**
 * POST /me/device-tokens/remove — delete this device's token (sign-out / FCM
 * rotation). Deleting a missing doc is a no-op.
 * Body: `{ token }`.
 */
export async function removeDeviceToken(ctx: RequestContext): Promise<{ ok: true }> {
  const token = requireString(ctx.body, "token");
  await tokenRef(ctx.uid, token).delete();
  return { ok: true };
}
