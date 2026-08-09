/**
 * Miliarium backend API — a single Gen2 `onRequest` function (`api`) that fronts
 * every client mutation. Clients no longer write to Firestore/Storage directly;
 * they call these endpoints with their Firebase ID token, and the handlers
 * enforce authorization and perform the writes with the Admin SDK.
 *
 * Reads and realtime listeners still run client-side (Phase 1 moves writes only).
 *
 * Handlers live in per-domain modules and are pure `(ctx) => result` functions;
 * this file is the only place that touches HTTP.
 */

import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { ApiError, RequestContext } from "./http";
import { matchRoute, Route } from "./router";
import { requireAuth } from "./auth";
import * as users from "./users";
import * as deviceTokens from "./deviceTokens";
import * as moderation from "./moderation";
import * as progress from "./progress";
import * as activities from "./activities";
import * as collections from "./collections";
import * as invitations from "./invitations";
import * as media from "./media";

/** The route table. Add new endpoints here as domains are migrated. */
const routes: Route[] = [
  // Users + account lifecycle
  { method: "POST", pattern: "/me/ensure", handler: users.ensureProfile },
  { method: "DELETE", pattern: "/me/account", handler: users.deleteAccount },
  { method: "PATCH", pattern: "/me", handler: users.updateProfile },
  { method: "GET", pattern: "/users", handler: users.getUsers },
  { method: "GET", pattern: "/users/:id", handler: users.getUser },

  // Device tokens (push)
  { method: "PUT", pattern: "/me/device-tokens", handler: deviceTokens.upsertDeviceToken },
  { method: "POST", pattern: "/me/device-tokens/remove", handler: deviceTokens.removeDeviceToken },

  // Moderation
  { method: "GET", pattern: "/me/blocked-users", handler: moderation.listBlockedUsers },
  { method: "POST", pattern: "/reports", handler: moderation.createReport },
  { method: "PUT", pattern: "/me/blocked-users/:id", handler: moderation.blockUser },
  { method: "DELETE", pattern: "/me/blocked-users/:id", handler: moderation.unblockUser },

  // Progress
  { method: "POST", pattern: "/progress", handler: progress.createProgress },
  { method: "PATCH", pattern: "/progress/:pid", handler: progress.updateSummary },
  { method: "DELETE", pattern: "/progress/:pid", handler: progress.deleteProgress },

  // Media
  { method: "GET", pattern: "/progress/:pid/activities/:aid/media", handler: media.listMedia },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/media/upload-url", handler: media.createUploadURL },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/media", handler: media.commitMedia },
  { method: "DELETE", pattern: "/progress/:pid/activities/:aid/media/:mid", handler: media.deleteMedia },

  // Activities
  { method: "GET", pattern: "/progress/:pid/activities", handler: activities.listActivities },
  { method: "GET", pattern: "/progress/:pid/activities/:aid", handler: activities.getActivity },
  { method: "POST", pattern: "/progress/:pid/activities", handler: activities.createActivity },
  { method: "PATCH", pattern: "/progress/:pid/activities/:aid", handler: activities.updateActivity },
  { method: "DELETE", pattern: "/progress/:pid/activities/:aid", handler: activities.deleteActivity },
  { method: "POST", pattern: "/progress/:pid/activities/:aid/collections/:cid", handler: activities.addToCollection },
  { method: "DELETE", pattern: "/progress/:pid/activities/:aid/collections/:cid", handler: activities.removeFromCollection },

  // Collections
  { method: "GET", pattern: "/progress/:pid/collections", handler: collections.listCollections },
  { method: "GET", pattern: "/progress/:pid/collections/:cid", handler: collections.getCollection },
  { method: "POST", pattern: "/progress/:pid/collections", handler: collections.createCollection },
  { method: "PATCH", pattern: "/progress/:pid/collections/:cid", handler: collections.updateCollection },
  { method: "POST", pattern: "/progress/:pid/collections/:cid/stats", handler: collections.persistStats },
  { method: "DELETE", pattern: "/progress/:pid/collections/:cid", handler: collections.deleteCollection },

  // Invitations
  { method: "GET", pattern: "/invitations", handler: invitations.listInvitations },
  { method: "POST", pattern: "/invitations", handler: invitations.sendInvitation },
  { method: "POST", pattern: "/invitations/:id/accept", handler: invitations.acceptInvitation },
  { method: "POST", pattern: "/invitations/:id/decline", handler: invitations.declineInvitation },
  { method: "POST", pattern: "/invitations/:id/revoke", handler: invitations.revokeInvitation },
  { method: "DELETE", pattern: "/invitations/:id", handler: invitations.deleteInvitation },
];

export const api = onRequest(async (req, res) => {
  // Normalize the path: when reached via the cloudfunctions.net/<name> URL the
  // function name prefix ("/api") is included; strip it so routes are declared
  // from root and both URL forms work.
  const path = (req.path || "/").replace(/^\/api(?=\/|$)/, "") || "/";

  try {
    const uid = await requireAuth(req.headers.authorization);

    const matched = matchRoute(routes, req.method, path);
    if (!matched) {
      res
        .status(404)
        .json({ error: { code: "not-found", message: `No route for ${req.method} ${path}` } });
      return;
    }

    const body =
      req.body && typeof req.body === "object" && !Array.isArray(req.body)
        ? (req.body as Record<string, unknown>)
        : {};
    const query: Record<string, string> = {};
    for (const [key, value] of Object.entries(req.query ?? {})) {
      if (typeof value === "string") query[key] = value;
    }

    const ctx: RequestContext = { uid, params: matched.params, body, query };
    const result = await matched.handler(ctx);
    // Pass `null` through (a "not found" read returns null, not {}).
    res.status(200).json(result === undefined ? {} : result);
  } catch (err) {
    if (err instanceof ApiError) {
      res.status(err.status).json({ error: { code: err.code, message: err.message } });
      return;
    }
    logger.error("api: unhandled error", {
      method: req.method,
      path,
      error: err instanceof Error ? err.message : String(err),
    });
    res.status(500).json({ error: { code: "internal", message: "Something went wrong." } });
  }
});
