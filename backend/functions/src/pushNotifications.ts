/**
 * Miliarium Push Notifications — Firestore-triggered push dispatch.
 *
 * Listens for new activities on shared progress and notifies the other
 * collaborators via Firebase Cloud Messaging. (Invitations do not send a
 * push — they surface in-app via the recipient's invitations listener.)
 *
 * Device tokens are stored in Firestore at:
 *   users/{userId}/deviceTokens/{tokenHexString}
 *
 * Uses the Firebase Admin SDK's Cloud Messaging API.
 */

import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

const db = getFirestore();
const messaging = getMessaging();

/**
 * Whether an FCM send error means the token itself is dead and should be
 * removed from Firestore. Only these two codes indicate an unusable token.
 *
 * Crucially, transient/auth errors (e.g. `messaging/authentication-error`,
 * `messaging/server-unavailable`, `messaging/internal-error`) must NOT
 * delete the token — the token is fine, the *send* failed. Deleting on
 * those would silently wipe valid device tokens on every misconfiguration.
 */
function isDeadTokenError(code: string | undefined): boolean {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token" ||
    code === "messaging/invalid-argument"
  );
}

/**
 * Looks up a user's display name from their `users/{userId}` doc.
 * Returns the `name` field if set, otherwise `email`, otherwise "Someone".
 */
async function resolveDisplayName(userId: string): Promise<string> {
  try {
    const userDoc = await db.collection("users").doc(userId).get();
    const data = userDoc.data();
    if (data?.name && typeof data.name === "string" && data.name.trim()) {
      return data.name.trim();
    }
    if (data?.email && typeof data.email === "string" && data.email.trim()) {
      return data.email.trim();
    }
  } catch (error) {
    logger.warn("resolveDisplayName: failed to fetch user", { userId, error });
  }
  return "Someone";
}

/**
 * Sends a push notification to all collaborators when a new activity is created.
 *
 * Trigger path: `progressItems/{progressItemId}/activities/{activityId}`
 * Expected document fields:
 *   - createdBy: string (user ID of the activity creator)
 *   - title: string (activity title)
 *
 * Flow:
 * 1. Fetch the progress item to get its collaborators
 * 2. Find all users with `progressLinks/{progressItemId}` to this progress
 * 3. Exclude the creator from notifications
 * 4. Send multicast message to all collaborators' device tokens
 * 5. Clean up any failed tokens
 */
export const onActivityCreated = onDocumentCreated(
  "progressItems/{progressItemId}/activities/{activityId}",
  async (event) => {
    const activity = event.data?.data();
    const activityId = event.params.activityId;
    const progressItemId = event.params.progressItemId;

    if (!activity) {
      logger.warn("onActivityCreated: activity doc is empty", {
        progressItemId,
        activityId,
      });
      return;
    }

    const creatorUserId = activity.createdBy;
    const activityTitle = activity.title;

    if (!creatorUserId || !activityTitle) {
      logger.warn("onActivityCreated: missing required fields", {
        progressItemId,
        activityId,
        createdBy: creatorUserId,
        title: activityTitle,
      });
      return;
    }

    logger.info("onActivityCreated: processing activity", {
      progressItemId,
      activityId,
      creatorUserId,
    });

    try {
      // Fetch creator's display name and collaborators in parallel
      const [creatorName, progressLinksSnapshot] = await Promise.all([
        resolveDisplayName(creatorUserId),
        db
          .collectionGroup("progressLinks")
          .where("progressItemId", "==", progressItemId)
          .get(),
      ]);

      const collaboratorUserIds = progressLinksSnapshot.docs
        .map((doc) => doc.ref.parent.parent?.id) // Extract userId from path: users/{userId}/progressLinks/{progressItemId}
        .filter((id): id is string => id !== undefined && id !== creatorUserId); // Exclude creator

      if (collaboratorUserIds.length === 0) {
        logger.info("onActivityCreated: no other collaborators", {
          progressItemId,
          creatorUserId,
        });
        return;
      }

      logger.info("onActivityCreated: found collaborators", {
        progressItemId,
        collaboratorCount: collaboratorUserIds.length,
      });

      // Fetch every collaborator's device tokens in parallel — one Firestore
      // round-trip per user, all in flight at once rather than sequentially,
      // so latency no longer scales linearly with collaborator count.
      const tokenLists = await Promise.all(
        collaboratorUserIds.map(async (userId) => {
          const tokensSnapshot = await db
            .collection("users")
            .doc(userId)
            .collection("deviceTokens")
            .get();
          return tokensSnapshot.docs.map((doc) => ({ token: doc.id, userId }));
        })
      );
      const allTokens: Array<{ token: string; userId: string }> =
        tokenLists.flat();

      if (allTokens.length === 0) {
        logger.info("onActivityCreated: no device tokens for collaborators", {
          progressItemId,
          collaboratorCount: collaboratorUserIds.length,
        });
        return;
      }

      const tokens = allTokens.map((t) => t.token);
      const body = `${creatorName} added "${activityTitle}"`;

      // Send the notification. Uses sendEachForMulticast (HTTP/2 per-token)
      // because the legacy /batch endpoint that sendMulticast relied on was
      // retired by Google in 2024.
      const response = await messaging.sendEachForMulticast({
        tokens,
        notification: {
          title: "New Activity",
          body,
        },
        android: {
          priority: "high",
          notification: {
            channelId: "activities",
            sound: "default",
          },
        },
        apns: {
          payload: {
            aps: {
              alert: {
                title: "New Activity",
                body,
              },
              sound: "default",
            },
          },
        },
        data: {
          progressItemId,
          activityId,
          type: "activity",
          action: "open_progress",
        },
      });

      logger.info("onActivityCreated: push sent", {
        progressItemId,
        activityId,
        successCount: response.successCount,
        failureCount: response.failureCount,
        tokenCount: tokens.length,
      });

      // Clean up failed tokens
      if (response.failureCount > 0) {
        const failedTokens: string[] = [];
        response.responses.forEach((resp, index) => {
          if (!resp.success) {
            logger.warn("onActivityCreated: token failed", {
              tokenPrefix: tokens[index].substring(0, 8),
              errorCode: resp.error?.code,
              error: resp.error?.message,
              errorDetail: JSON.stringify(resp.error),
            });
            // Only purge genuinely dead tokens; keep tokens that failed for
            // transient/auth reasons (the token itself is still valid).
            if (isDeadTokenError(resp.error?.code)) {
              failedTokens.push(tokens[index]);
            }
          }
        });

        // Delete failed tokens in batch
        if (failedTokens.length > 0) {
          const batch = db.batch();
          failedTokens.forEach((token) => {
            // Find which user this token belonged to
            const tokenInfo = allTokens.find((t) => t.token === token);
            if (tokenInfo) {
              const tokenDocRef = db
                .collection("users")
                .doc(tokenInfo.userId)
                .collection("deviceTokens")
                .doc(token);
              batch.delete(tokenDocRef);
            }
          });
          await batch.commit();
          logger.info("onActivityCreated: removed failed tokens", {
            failedTokenCount: failedTokens.length,
          });
        }
      }
    } catch (error) {
      logger.error("onActivityCreated: error sending push", {
        progressItemId,
        activityId,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  }
);
