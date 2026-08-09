/**
 * Miliarium Push Notifications — Firestore-triggered push dispatch.
 *
 * Listens to document creation events in Firestore (invitations, activities, etc.)
 * and sends push notifications to relevant users via Firebase Cloud Messaging.
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
 * Sends a push notification to the recipient when an invitation is created.
 *
 * Trigger path: `invitations/{invitationId}`
 * Expected document fields:
 *   - toUserId: string (recipient's user ID)
 *   - fromUserId: string (sender's user ID)
 *   - progressItemTitle: string (name of the progress being shared)
 *
 * Flow:
 * 1. Extract recipient's user ID from the invitation
 * 2. Fetch all device tokens for that user from `users/{toUserId}/deviceTokens/*`
 * 3. Send a multicast message to all tokens
 * 4. Clean up any failed/invalid tokens
 */
export const onInvitationCreated = onDocumentCreated(
  "invitations/{invitationId}",
  async (event) => {
    const invitation = event.data?.data();
    const invitationId = event.params.invitationId;

    if (!invitation) {
      logger.warn("onInvitationCreated: invitation doc is empty", {
        invitationId,
      });
      return;
    }

    const recipientUserId = invitation.toUserId;
    const senderUserId = invitation.fromUserId;
    const progressTitle = invitation.progressItemTitle;

    if (!recipientUserId || !senderUserId || !progressTitle) {
      logger.warn("onInvitationCreated: missing required fields", {
        invitationId,
        toUserId: recipientUserId,
        fromUserId: senderUserId,
        progressItemTitle: progressTitle,
      });
      return;
    }

    logger.info("onInvitationCreated: processing invitation", {
      invitationId,
      recipientUserId,
      senderUserId,
    });

    try {
      // Fetch sender's display name and recipient's device tokens in parallel
      const [senderName, tokensSnapshot] = await Promise.all([
        resolveDisplayName(senderUserId),
        db
          .collection("users")
          .doc(recipientUserId)
          .collection("deviceTokens")
          .get(),
      ]);

      const tokens = tokensSnapshot.docs.map((doc) => doc.id);

      if (tokens.length === 0) {
        logger.info("onInvitationCreated: no device tokens for recipient", {
          recipientUserId,
        });
        return;
      }

      const body = `${senderName} invited you to collaborate on "${progressTitle}"`;

      // Prepare the notification payload. Uses sendEachForMulticast (HTTP/2
      // per-token) because the legacy /batch endpoint that sendMulticast
      // relied on was retired by Google in 2024.
      const response = await messaging.sendEachForMulticast({
        tokens,
        notification: {
          title: "New Collaboration Invite",
          body,
        },
        // Android-specific options
        android: {
          priority: "high",
          notification: {
            channelId: "invitations",
            sound: "default",
          },
        },
        // APNs-specific options (iOS)
        apns: {
          payload: {
            aps: {
              alert: {
                title: "New Collaboration Invite",
                body,
              },
              sound: "default",
              badge: 1,
            },
          },
        },
        // Custom data payload
        data: {
          invitationId,
          type: "invitation",
          action: "open_invitation",
        },
      });

      logger.info("onInvitationCreated: push sent", {
        invitationId,
        successCount: response.successCount,
        failureCount: response.failureCount,
        tokenCount: tokens.length,
      });

      // Clean up any failed/invalid tokens
      if (response.failureCount > 0) {
        const failedTokens: string[] = [];
        response.responses.forEach((resp, index) => {
          if (!resp.success) {
            logger.warn(
              "onInvitationCreated: token failed",
              {
                tokenPrefix: tokens[index].substring(0, 8),
                errorCode: resp.error?.code,
                error: resp.error?.message,
                errorDetail: JSON.stringify(resp.error),
              }
            );
            // Only purge tokens that are genuinely dead; keep tokens that
            // failed for transient/auth reasons (the token is still valid).
            if (isDeadTokenError(resp.error?.code)) {
              failedTokens.push(tokens[index]);
            }
          }
        });

        // Delete failed tokens in batch
        if (failedTokens.length > 0) {
          const batch = db.batch();
          failedTokens.forEach((token) => {
            const tokenDocRef = db
              .collection("users")
              .doc(recipientUserId)
              .collection("deviceTokens")
              .doc(token);
            batch.delete(tokenDocRef);
          });
          await batch.commit();
          logger.info("onInvitationCreated: removed failed tokens", {
            failedTokenCount: failedTokens.length,
            recipientUserId,
          });
        }
      }
    } catch (error) {
      logger.error("onInvitationCreated: error sending push", {
        invitationId,
        recipientUserId,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error; // Re-throw so Cloud Functions knows this execution failed
    }
  }
);

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

      // Fetch all device tokens for all collaborators
      const allTokens: Array<{ token: string; userId: string }> = [];

      for (const userId of collaboratorUserIds) {
        const tokensSnapshot = await db
          .collection("users")
          .doc(userId)
          .collection("deviceTokens")
          .get();

        tokensSnapshot.docs.forEach((doc) => {
          allTokens.push({ token: doc.id, userId });
        });
      }

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
              badge: 1,
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
