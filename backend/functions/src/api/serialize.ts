/**
 * Serializers: Firestore doc → the JSON shape the iOS models decode (their
 * Swift `Codable` synthesis — flat lat/lng, ISO-8601 dates, nested stats).
 * Read endpoints return these so the client can `JSONDecoder.decode` straight
 * into `AppUser` / `Activity` / `ActivityCollection` / `ActivityMedia` /
 * `Invitation`. Returns `null` for a doc that fails the model's required-field
 * checks (mirroring the client's failable `init?(document:)`).
 */

import { Timestamp, GeoPoint } from "firebase-admin/firestore";

type Doc = FirebaseFirestore.DocumentSnapshot;

/**
 * ISO-8601 with NO fractional seconds — Swift's `JSONDecoder.iso8601` strategy
 * uses `ISO8601DateFormatter` defaults, which reject the milliseconds that
 * `toISOString()` emits. Stripping them keeps both sides in sync.
 */
function iso(ts: unknown): string | undefined {
  if (!(ts instanceof Timestamp)) return undefined;
  return ts.toDate().toISOString().replace(/\.\d+Z$/, "Z");
}

export function serializeUser(doc: Doc): Record<string, unknown> | null {
  const d = doc.data();
  if (!d) return null;
  const createdAt = iso(d.createdAt);
  if (!createdAt) return null;
  const out: Record<string, unknown> = {
    id: doc.id,
    userId: typeof d.userId === "string" ? d.userId : doc.id,
    createdAt,
    updatedAt: iso(d.updatedAt) ?? createdAt,
  };
  if (typeof d.email === "string") out.email = d.email;
  const name =
    typeof d.name === "string"
      ? d.name
      : typeof d.displayName === "string"
        ? d.displayName
        : undefined;
  if (name) out.name = name;
  return out;
}

export function serializeActivity(doc: Doc): Record<string, unknown> | null {
  const d = doc.data();
  if (!d) return null;
  const createdAt = iso(d.createdAt);
  const updatedAt = iso(d.updatedAt);
  if (typeof d.title !== "string" || !createdAt || !updatedAt) return null;

  const out: Record<string, unknown> = {
    id: doc.id,
    title: d.title,
    isAllDay: d.isAllDay === true,
    collectionIds: Array.isArray(d.collectionIds) ? d.collectionIds : [],
    createdAt,
    updatedAt,
  };
  if (typeof d.notes === "string") out.notes = d.notes;
  const t = iso(d.timestamp);
  if (t) out.timestamp = t;
  const e = iso(d.endTimestamp);
  if (e) out.endTimestamp = e;
  if (d.location instanceof GeoPoint) {
    out.latitude = d.location.latitude;
    out.longitude = d.location.longitude;
  }
  if (typeof d.locationName === "string") out.locationName = d.locationName;
  if (typeof d.isCompleted === "boolean") out.isCompleted = d.isCompleted;
  if (typeof d.reminderMinutesBefore === "number") {
    out.reminderMinutesBefore = d.reminderMinutesBefore;
  }
  if (typeof d.createdBy === "string") out.createdBy = d.createdBy;
  return out;
}

export function serializeCollection(doc: Doc): Record<string, unknown> | null {
  const d = doc.data();
  if (!d) return null;
  const createdAt = iso(d.createdAt);
  const updatedAt = iso(d.updatedAt);
  if (typeof d.name !== "string" || !createdAt || !updatedAt) return null;

  const s = d.stats && typeof d.stats === "object" ? d.stats : {};
  const stats: Record<string, unknown> = {
    total: typeof s.total === "number" ? s.total : 0,
    completedCount: typeof s.completedCount === "number" ? s.completedCount : 0,
    locationCount: typeof s.locationCount === "number" ? s.locationCount : 0,
    timeCount: typeof s.timeCount === "number" ? s.timeCount : 0,
  };
  const firstAt = iso(s.firstAt);
  if (firstAt) stats.firstAt = firstAt;
  const lastAt = iso(s.lastAt);
  if (lastAt) stats.lastAt = lastAt;

  const out: Record<string, unknown> = {
    id: doc.id,
    name: d.name,
    isFavorite: d.isFavorite === true,
    activityIds: Array.isArray(d.activityIds) ? d.activityIds : [],
    stats,
    createdAt,
    updatedAt,
  };
  if (typeof d.notes === "string") out.notes = d.notes;
  const su = iso(d.statsUpdatedAt);
  if (su) out.statsUpdatedAt = su;
  return out;
}

export function serializeMedia(doc: Doc): Record<string, unknown> | null {
  const d = doc.data();
  if (!d) return null;
  const uploadedAt = iso(d.uploadedAt);
  if (
    typeof d.type !== "string" ||
    typeof d.storagePath !== "string" ||
    typeof d.uploadedBy !== "string" ||
    !uploadedAt
  ) {
    return null;
  }
  const out: Record<string, unknown> = {
    id: doc.id,
    type: d.type,
    storagePath: d.storagePath,
    uploadedBy: d.uploadedBy,
    uploadedAt,
  };
  if (typeof d.sizeBytes === "number") out.sizeBytes = d.sizeBytes;
  if (typeof d.width === "number") out.width = d.width;
  if (typeof d.height === "number") out.height = d.height;
  if (typeof d.durationSeconds === "number") out.durationSeconds = d.durationSeconds;
  return out;
}

export function serializeInvitation(doc: Doc): Record<string, unknown> | null {
  const d = doc.data();
  if (!d) return null;
  const createdAt = iso(d.createdAt);
  const updatedAt = iso(d.updatedAt);
  if (
    typeof d.fromUserId !== "string" ||
    typeof d.toUserId !== "string" ||
    typeof d.progressItemId !== "string" ||
    typeof d.progressItemTitle !== "string" ||
    typeof d.status !== "string" ||
    !createdAt ||
    !updatedAt
  ) {
    return null;
  }
  return {
    id: doc.id,
    fromUserId: d.fromUserId,
    toUserId: d.toUserId,
    progressItemId: d.progressItemId,
    progressItemTitle: d.progressItemTitle,
    status: d.status,
    createdAt,
    updatedAt,
  };
}

/** Drops nulls from a serialized list. */
export function compact<T>(items: (T | null)[]): T[] {
  return items.filter((x): x is T => x !== null);
}
