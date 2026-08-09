/**
 * Miliarium Cloud Functions — entry point.
 *
 * All exported names from this file become deployable functions. Group
 * related triggers into separate files under `src/` and re-export them
 * here as your codebase grows.
 *
 * Everything is Gen 2 (`firebase-functions/v2/*`). Account creation/deletion is
 * handled by the HTTPS API (POST /me/ensure, DELETE /me/account) rather than
 * Gen 1 Auth triggers, so the whole codebase can run on a modern runtime.
 */

import { initializeApp } from "firebase-admin/app";

// Initialize the Admin SDK once. All triggers in this codebase share this
// instance — calling `initializeApp()` again would throw.
initializeApp();

// Push notification triggers (activities).
export * from "./pushNotifications";

// Cascade Storage cleanup on media/activity deletion.
export * from "./mediaCleanup";

// Cascade relational cleanup on progress/collection/activity/user deletion.
export * from "./cascadeDeletes";

// HTTPS API: fronts every client mutation + read (writes go through the backend),
// and owns account lifecycle (ensure on sign-in, delete account).
export * from "./api";
