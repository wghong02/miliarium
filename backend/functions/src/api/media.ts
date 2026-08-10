/**
 * Media handlers. Large binaries never pass through a function: the client asks
 * for a short-lived V4 signed upload URL, PUTs the bytes straight to Cloud
 * Storage, then commits the metadata doc here (which the server writes with the
 * authoritative object size). Deletes remove the doc; the `onMediaDeleted`
 * trigger cleans up the Storage object.
 *
 * NOTE: signing V4 URLs from a deployed function requires the function's service
 * account to have the "Service Account Token Creator" role on itself (so the
 * Admin SDK can call IAM signBlob). See backend/README.md.
 */

import { randomUUID } from "node:crypto";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { RequestContext, requireString, optionalString, badRequest } from "./http";
import { assertProgressMember } from "./auth";
import { serializeMedia, compact } from "./serialize";

const db = getFirestore();
const storage = getStorage();

const MAX_MEDIA_BYTES = 20 * 1024 * 1024; // 20 MB per file
const MAX_MEDIA_PER_ACTIVITY = 20;
// 1 hour — long enough for a background upload that starts while backgrounded.
const UPLOAD_URL_TTL_MS = 60 * 60 * 1000;

function mediaCollectionRef(pid: string, aid: string) {
  return db
    .collection("progressItems")
    .doc(pid)
    .collection("activities")
    .doc(aid)
    .collection("media");
}

function mediaRef(pid: string, aid: string, mediaId: string) {
  return mediaCollectionRef(pid, aid).doc(mediaId);
}

/** GET /progress/:pid/activities/:aid/media — media for an activity (newest first). */
export async function listMedia(ctx: RequestContext): Promise<{ media: unknown[] }> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  const snap = await mediaCollectionRef(pid, aid)
    .orderBy("uploadedAt", "desc")
    .get();
  return { media: compact(snap.docs.map(serializeMedia)) };
}

/** A short, safe file extension (alphanumeric, ≤5 chars). */
function sanitizeExt(ext: string): string {
  const cleaned = ext.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 5);
  return cleaned || "bin";
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/**
 * POST /progress/:pid/activities/:aid/media/upload-url — mint signed PUT URLs
 * for the full-size object and a JPEG thumbnail (uploaded separately by the
 * client). Body: `{ contentType, ext }`.
 */
export async function createUploadURL(ctx: RequestContext): Promise<{
  mediaId: string;
  storagePath: string;
  uploadURL: string;
  thumbnailStoragePath: string;
  thumbnailUploadURL: string;
}> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);

  const contentType = requireString(ctx.body, "contentType");
  const ext = sanitizeExt(requireString(ctx.body, "ext"));
  const mediaId = randomUUID();
  const storagePath = `activities/${pid}/${aid}/${mediaId}.${ext}`;
  const thumbnailStoragePath = `activities/${pid}/${aid}/${mediaId}_thumb.jpg`;

  const bucket = storage.bucket();
  const expires = Date.now() + UPLOAD_URL_TTL_MS;
  const [uploadURL] = await bucket.file(storagePath).getSignedUrl({
    version: "v4",
    action: "write",
    expires,
    contentType,
  });
  const [thumbnailUploadURL] = await bucket.file(thumbnailStoragePath).getSignedUrl({
    version: "v4",
    action: "write",
    expires,
    contentType: "image/jpeg",
  });

  return { mediaId, storagePath, uploadURL, thumbnailStoragePath, thumbnailUploadURL };
}

/**
 * POST /progress/:pid/activities/:aid/media — commit the metadata doc after the
 * client has uploaded to the signed URL.
 * Body: `{ mediaId, storagePath, type, width?, height?, durationSeconds? }`.
 */
export async function commitMedia(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);

  const mediaId = requireString(ctx.body, "mediaId");
  const storagePath = requireString(ctx.body, "storagePath");
  const type = requireString(ctx.body, "type");
  if (type !== "image" && type !== "video") throw badRequest("Invalid media type.");

  // The path must belong to this activity and match the media id (defense
  // against a member pointing a doc at someone else's object).
  const prefix = `activities/${pid}/${aid}/`;
  if (
    !storagePath.startsWith(prefix) ||
    !storagePath.slice(prefix.length).startsWith(`${mediaId}.`)
  ) {
    throw badRequest("Invalid storage path.");
  }

  const file = storage.bucket().file(storagePath);
  const [exists] = await file.exists();
  if (!exists) throw badRequest("Upload not found. Please retry.");

  const [meta] = await file.getMetadata();
  const size = Number(meta.size ?? 0);
  if (size > MAX_MEDIA_BYTES) {
    await file.delete().catch(() => undefined);
    throw badRequest("Each file must be 20 MB or smaller.");
  }

  // Cap the number of media per activity. Counting excludes the doc we're about
  // to write (it doesn't exist yet).
  const count = (await mediaCollectionRef(pid, aid).count().get()).data().count;
  if (count >= MAX_MEDIA_PER_ACTIVITY) {
    await file.delete().catch(() => undefined);
    throw badRequest(`An activity can have at most ${MAX_MEDIA_PER_ACTIVITY} files.`);
  }

  const doc: Record<string, unknown> = {
    type,
    storagePath,
    uploadedBy: ctx.uid,
    uploadedAt: FieldValue.serverTimestamp(),
    sizeBytes: size,
  };
  const width = numberOrUndefined(ctx.body.width);
  const height = numberOrUndefined(ctx.body.height);
  const durationSeconds = numberOrUndefined(ctx.body.durationSeconds);
  if (width !== undefined) doc.width = width;
  if (height !== undefined) doc.height = height;
  if (durationSeconds !== undefined) doc.durationSeconds = durationSeconds;

  // Record the thumbnail only if it actually made it to Storage — a failed
  // thumbnail upload just means the client falls back to the full image.
  const thumb = optionalString(ctx.body, "thumbnailStoragePath");
  if (thumb && thumb.startsWith(prefix)) {
    const [thumbExists] = await storage.bucket().file(thumb).exists();
    if (thumbExists) doc.thumbnailStoragePath = thumb;
  }

  await mediaRef(pid, aid, mediaId).set(doc);
  return { ok: true };
}

/**
 * DELETE /progress/:pid/activities/:aid/media/:mid — delete the metadata doc;
 * the `onMediaDeleted` trigger removes the Storage object.
 */
export async function deleteMedia(ctx: RequestContext): Promise<{ ok: true }> {
  const { pid, aid, mid } = ctx.params;
  await assertProgressMember(ctx.uid, pid);
  await mediaRef(pid, aid, mid).delete();
  return { ok: true };
}
