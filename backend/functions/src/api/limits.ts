/**
 * Server-side text caps, mirroring the client's `TextLimits` (ios App/TextLimits.swift).
 * The backend is now the authority, so it must enforce these regardless of what
 * the client sends.
 */
export const LIMITS = {
  /** Short identifier-like strings: profile name, titles, invitation email. */
  name: 40,
  /** Progress summary free-form paragraph. */
  summary: 120,
} as const;

/**
 * Default cap on how many progresses a single user may own (create). Stored on
 * the user doc at registration (`ensureProfile`) and read back on create, so the
 * limit travels with the account and can be raised per-user later.
 */
export const MAX_PROGRESS_ITEMS = 2;

/**
 * Cap on how many people (owner + collaborators) a single progress may have.
 * Enforced when an invitation is accepted (authoritative) and, for early
 * feedback, when a new invitation is sent.
 */
export const MAX_PROGRESS_MEMBERS = 2;

/** Trims and hard-truncates a string to `max` characters. */
export function clampText(value: string, max: number): string {
  return value.trim().slice(0, max);
}
