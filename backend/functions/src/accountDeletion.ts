/**
 * Miliarium Account Deletion — server-owned trigger that fires when a Firebase
 * Auth user is deleted.
 *
 * The in-app "Delete account" flow (AuthViewModel.deleteAccount) now deletes
 * ONLY the Auth account. This trigger reacts to that deletion and removes the
 * user's `users/{uid}` profile doc, which in turn fires the `onUserDeleted`
 * Firestore cascade (cascadeDeletes.ts) that wipes the rest of their data
 * (deviceTokens, progressLinks, owned progresses, ...).
 *
 * Why the ordering matters: the client used to delete the profile doc *before*
 * the Auth account was gone. Deleting that doc fires the destructive cascade
 * immediately, so if the subsequent Auth deletion then failed (network drop,
 * requires-recent-login, transient error) the account stayed alive while all
 * its data had already been irreversibly destroyed — silent, catastrophic data
 * loss. By cascading off the Auth deletion instead, nothing is destroyed unless
 * the account itself is actually gone.
 *
 * Auth triggers are only available in the Gen 1 SDK (`firebase-functions/v1`)
 * for projects on standard Firebase Authentication; the rest of this codebase
 * uses Gen 2. Mixing generations in one codebase is supported.
 */

import * as functionsV1 from "firebase-functions/v1";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

const db = getFirestore();

export const onAuthUserDeleted = functionsV1.auth
  .user()
  .onDelete(async (user) => {
    const userId = user.uid;
    logger.info("onAuthUserDeleted: removing profile doc", { userId });
    try {
      await db.collection("users").doc(userId).delete();
      logger.info(
        "onAuthUserDeleted: profile doc deleted (onUserDeleted cascade follows)",
        { userId }
      );
    } catch (error) {
      // Deleting an already-missing doc is a no-op in Firestore, so the only
      // failures here are transient. Log and move on — the account is already
      // gone; there is nothing to roll back.
      logger.warn("onAuthUserDeleted: failed to delete profile doc", {
        userId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });
