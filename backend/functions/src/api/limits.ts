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

/** Trims and hard-truncates a string to `max` characters. */
export function clampText(value: string, max: number): string {
  return value.trim().slice(0, max);
}
