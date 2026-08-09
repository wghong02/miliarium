/**
 * Miliarium Account Creation — creates the `users/{uid}` profile doc when a
 * Firebase Auth account is created, replacing the client-side `ensureUserExists`
 * write (UserService). Mirrors `onAuthUserDeleted` in accountDeletion.ts.
 *
 * Auth triggers are Gen 1 only (`firebase-functions/v1`) for projects on
 * standard Firebase Authentication.
 */

import * as functionsV1 from "firebase-functions/v1";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

const db = getFirestore();

export const onAuthUserCreated = functionsV1.auth
  .user()
  .onCreate(async (user) => {
    const { uid, email } = user;
    logger.info("onAuthUserCreated: creating profile doc", { uid });
    try {
      const now = Timestamp.now();
      const data: Record<string, unknown> = {
        userId: uid,
        createdAt: now,
        updatedAt: now,
      };
      if (email) data.email = email;
      // `merge` so we never clobber a doc that already exists (e.g. a re-created
      // account reusing a uid).
      await db.collection("users").doc(uid).set(data, { merge: true });
      logger.info("onAuthUserCreated: profile doc created", { uid });
    } catch (error) {
      logger.warn("onAuthUserCreated: failed to create profile doc", {
        uid,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });
