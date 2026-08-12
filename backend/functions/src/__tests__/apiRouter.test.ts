/**
 * Unit tests for the API path router — especially the same-length routes that
 * must stay disambiguated by their literal segments (media vs collections).
 */

import { matchRoute, Route } from "../api/router";

const noop = () => ({});

const routes: Route[] = [
  { method: "POST", pattern: "/progress", handler: noop },
  { method: "PATCH", pattern: "/progress/:pid", handler: noop },
  { method: "DELETE", pattern: "/progress/:pid", handler: noop },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/media/upload-url", handler: noop },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/media", handler: noop },
  { method: "DELETE", pattern: "/progress/:pid/activities/:aid/media/:mid", handler: noop },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/collections/:cid", handler: noop },
  { method: "DELETE", pattern: "/progress/:pid/activities/:aid/collections/:cid", handler: noop },
  { method: "PUT", pattern: "/me/blocked-users/:id", handler: noop },
  { method: "POST", pattern: "/invitations/:id/accept", handler: noop },
];

describe("matchRoute", () => {
  it("extracts a single param", () => {
    expect(matchRoute(routes, "PATCH", "/progress/abc")?.params).toEqual({ pid: "abc" });
  });

  it("returns undefined on method mismatch", () => {
    expect(matchRoute(routes, "GET", "/progress/abc")).toBeUndefined();
  });

  it("returns undefined on segment-count mismatch", () => {
    expect(matchRoute(routes, "POST", "/progress/abc/activities")).toBeUndefined();
  });

  it("disambiguates media/upload-url from collections/:cid (same length)", () => {
    expect(
      matchRoute(routes, "POST", "/progress/P/activities/A/media/upload-url")?.params
    ).toEqual({ pid: "P", aid: "A" });
    expect(
      matchRoute(routes, "POST", "/progress/P/activities/A/collections/C")?.params
    ).toEqual({ pid: "P", aid: "A", cid: "C" });
  });

  it("disambiguates delete media vs delete collection", () => {
    expect(
      matchRoute(routes, "DELETE", "/progress/P/activities/A/media/M")?.params
    ).toEqual({ pid: "P", aid: "A", mid: "M" });
    expect(
      matchRoute(routes, "DELETE", "/progress/P/activities/A/collections/C")?.params
    ).toEqual({ pid: "P", aid: "A", cid: "C" });
  });

  it("matches the shorter commitMedia route", () => {
    expect(
      matchRoute(routes, "POST", "/progress/P/activities/A/media")?.params
    ).toEqual({ pid: "P", aid: "A" });
  });

  it("decodes percent-encoded params", () => {
    expect(matchRoute(routes, "PUT", "/me/blocked-users/user%20one")?.params).toEqual({
      id: "user one",
    });
  });

  it("matches nested action routes", () => {
    expect(matchRoute(routes, "POST", "/invitations/xyz/accept")?.params).toEqual({
      id: "xyz",
    });
  });
});
