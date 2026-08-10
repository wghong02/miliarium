/**
 * Helpers to turn a client JSON payload (an Activity/Collection encoded via its
 * Swift `Codable` shape — flat lat/lng, ISO-8601 dates) into the Firestore doc
 * shape the app expects (GeoPoint `location`, `Timestamp`s). Mirrors the client
 * `asFirestoreMap()` methods so reads keep parsing docs unchanged.
 */

import { GeoPoint, Timestamp, FieldValue } from "firebase-admin/firestore";
import { badRequest, requireString, optionalString } from "./http";
import { LIMITS, clampText } from "./limits";

/** Generous cap for free-form notes (client has no explicit limit). */
const NOTES_MAX = 5000;

function parseDate(value: unknown, field: string): Timestamp {
  if (typeof value !== "string") throw badRequest(`Invalid date for ${field}.`);
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw badRequest(`Invalid date for ${field}.`);
  return Timestamp.fromDate(d);
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? (value.filter((x) => typeof x === "string") as string[])
    : [];
}

/**
 * Builds the Firestore doc for an activity from the client payload. Returns the
 * doc (without `createdAt` — the caller sets/preserves it) and the parsed
 * `collectionIds` for back-reference reconciliation. `createdBy` is forced to
 * the caller. `updatedAt` is a server timestamp.
 */
export function activityDocFromBody(
  body: Record<string, unknown>,
  createdBy: string
): { doc: Record<string, unknown>; collectionIds: string[] } {
  const collectionIds = stringArray(body.collectionIds);
  const doc: Record<string, unknown> = {
    title: clampText(requireString(body, "title"), LIMITS.name),
    collectionIds,
    createdBy,
    updatedAt: FieldValue.serverTimestamp(),
  };

  const notes = optionalString(body, "notes");
  if (notes && notes.trim().length > 0) doc.notes = notes.slice(0, NOTES_MAX);

  if (body.timestamp !== undefined && body.timestamp !== null) {
    doc.timestamp = parseDate(body.timestamp, "timestamp");
  }
  if (body.endTimestamp !== undefined && body.endTimestamp !== null) {
    doc.endTimestamp = parseDate(body.endTimestamp, "endTimestamp");
  }
  if (body.isAllDay === true) doc.isAllDay = true;

  const lat = typeof body.latitude === "number" ? body.latitude : undefined;
  const lng = typeof body.longitude === "number" ? body.longitude : undefined;
  if (lat !== undefined && lng !== undefined) doc.location = new GeoPoint(lat, lng);

  const locationName = optionalString(body, "locationName");
  if (locationName && locationName.trim().length > 0) {
    doc.locationName = clampText(locationName, LIMITS.name);
  }

  if (typeof body.isCompleted === "boolean") doc.isCompleted = body.isCompleted;

  if (
    typeof body.reminderMinutesBefore === "number" &&
    Number.isFinite(body.reminderMinutesBefore) &&
    body.reminderMinutesBefore >= 0
  ) {
    doc.reminderMinutesBefore = Math.floor(body.reminderMinutesBefore);
  }

  return { doc, collectionIds };
}
