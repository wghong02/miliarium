/**
 * Integration-test bootstrap. Runs before each integration test file: points the
 * Admin SDK at the Firestore emulator (unless `firebase emulators:exec` already
 * set the host) and initializes a demo app. No real credentials are used.
 */

import { getApps, initializeApp } from "firebase-admin/app";

process.env.FIRESTORE_EMULATOR_HOST ??= "127.0.0.1:8080";
process.env.GCLOUD_PROJECT ??= "demo-miliarium";

if (getApps().length === 0) {
  initializeApp({ projectId: process.env.GCLOUD_PROJECT });
}
