/**
 * Unit tests for the read serializers — the wire contract the iOS models decode
 * against. Timestamp/GeoPoint are constructed directly (no app init needed).
 */

import { Timestamp, GeoPoint } from "firebase-admin/firestore";
import {
  serializeActivity,
  serializeCollection,
  serializeMedia,
  serializeInvitation,
  serializeUser,
} from "../api/serialize";

// Minimal DocumentSnapshot stand-in.
function doc(id: string, data: Record<string, unknown> | undefined) {
  return { id, data: () => data } as unknown as FirebaseFirestore.DocumentSnapshot;
}
const T = (iso: string) => Timestamp.fromDate(new Date(iso));

describe("serializeActivity", () => {
  it("flattens location, strips ms, omits absent optionals", () => {
    const out = serializeActivity(
      doc("a1", {
        title: "Run",
        isAllDay: false,
        collectionIds: ["c1"],
        location: new GeoPoint(1.5, -2.5),
        timestamp: T("2026-08-09T10:00:00.123Z"),
        createdAt: T("2026-08-09T09:00:00.000Z"),
        updatedAt: T("2026-08-09T09:30:00.000Z"),
        createdBy: "u1",
      })
    )!;
    expect(out).toMatchObject({
      id: "a1",
      title: "Run",
      isAllDay: false,
      collectionIds: ["c1"],
      latitude: 1.5,
      longitude: -2.5,
      createdBy: "u1",
      timestamp: "2026-08-09T10:00:00Z", // fractional seconds stripped
      createdAt: "2026-08-09T09:00:00Z",
    });
    expect(out).not.toHaveProperty("notes");
    expect(out).not.toHaveProperty("location");
  });

  it("returns null when required fields are missing", () => {
    expect(serializeActivity(doc("a", { title: "x" }))).toBeNull(); // no dates
    expect(serializeActivity(doc("a", undefined))).toBeNull();
  });
});

describe("serializeCollection", () => {
  it("nests stats with ISO dates", () => {
    const out = serializeCollection(
      doc("c1", {
        name: "Cities",
        isFavorite: true,
        activityIds: ["a1", "a2"],
        stats: {
          total: 2,
          completedCount: 1,
          locationCount: 2,
          timeCount: 1,
          firstAt: T("2026-01-01T00:00:00Z"),
          lastAt: T("2026-02-01T00:00:00Z"),
        },
        statsUpdatedAt: T("2026-02-02T00:00:00Z"),
        createdAt: T("2026-01-01T00:00:00Z"),
        updatedAt: T("2026-02-02T00:00:00Z"),
      })
    )!;
    expect(out.stats).toEqual({
      total: 2,
      completedCount: 1,
      locationCount: 2,
      timeCount: 1,
      firstAt: "2026-01-01T00:00:00Z",
      lastAt: "2026-02-01T00:00:00Z",
    });
    expect(out.isFavorite).toBe(true);
  });

  it("defaults empty stats/activityIds when absent", () => {
    const out = serializeCollection(
      doc("c", {
        name: "X",
        createdAt: T("2026-01-01T00:00:00Z"),
        updatedAt: T("2026-01-01T00:00:00Z"),
      })
    )!;
    expect(out.stats).toEqual({
      total: 0,
      completedCount: 0,
      locationCount: 0,
      timeCount: 0,
    });
    expect(out.activityIds).toEqual([]);
  });
});

describe("serializeMedia", () => {
  it("maps type + optional dimensions", () => {
    const out = serializeMedia(
      doc("m1", {
        type: "video",
        storagePath: "activities/p/a/m.mov",
        uploadedBy: "u1",
        uploadedAt: T("2026-08-09T00:00:00Z"),
        sizeBytes: 123,
        width: 1920,
        height: 1080,
        durationSeconds: 12.5,
      })
    )!;
    expect(out).toEqual({
      id: "m1",
      type: "video",
      storagePath: "activities/p/a/m.mov",
      uploadedBy: "u1",
      uploadedAt: "2026-08-09T00:00:00Z",
      sizeBytes: 123,
      width: 1920,
      height: 1080,
      durationSeconds: 12.5,
    });
  });

  it("returns null when required fields are missing", () => {
    expect(serializeMedia(doc("m", { type: "image" }))).toBeNull();
  });
});

describe("serializeInvitation", () => {
  it("serializes all fields", () => {
    const out = serializeInvitation(
      doc("i1", {
        fromUserId: "a",
        toUserId: "b",
        progressItemId: "p",
        progressItemTitle: "Goal",
        status: "pending",
        createdAt: T("2026-08-09T00:00:00Z"),
        updatedAt: T("2026-08-09T00:00:00Z"),
      })
    )!;
    expect(out).toMatchObject({
      id: "i1",
      fromUserId: "a",
      toUserId: "b",
      status: "pending",
      progressItemTitle: "Goal",
    });
  });
});

describe("serializeUser", () => {
  it("falls back to doc id for userId and displayName for name", () => {
    const out = serializeUser(
      doc("u1", {
        displayName: "Alice",
        email: "a@x.com",
        createdAt: T("2026-08-09T00:00:00Z"),
      })
    )!;
    expect(out).toMatchObject({ id: "u1", userId: "u1", name: "Alice", email: "a@x.com" });
    expect(out.updatedAt).toBe(out.createdAt); // updatedAt defaults to createdAt
  });
});
