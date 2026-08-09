/**
 * Miliarium Cloud Functions — entry point.
 *
 * All exported names from this file become deployable functions. Group
 * related triggers into separate files under `src/` and re-export them
 * here as your codebase grows.
 *
 * Uses the Gen 2 SDK (`firebase-functions/v2/*`).
 */

import { initializeApp } from "firebase-admin/app";

// Initialize the Admin SDK once. All triggers in this codebase share this
// instance — calling `initializeApp()` again would throw.
initializeApp();

// Push notification triggers (invitations + activities).
export * from "./pushNotifications";

// Cascade Storage cleanup on media/activity deletion.
export * from "./mediaCleanup";
