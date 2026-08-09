/**
 * Shared HTTP plumbing for the Miliarium backend API (the `api` onRequest
 * function). Handlers are pure `(ctx) => result` functions — they never touch
 * `req`/`res` directly — so they stay unit-testable without HTTP.
 */

/** Everything a handler needs, resolved from the request by the API entrypoint. */
export interface RequestContext {
  /** Verified caller uid (from the Bearer ID token). */
  uid: string;
  /** Path parameters, e.g. `{ pid, aid }`. */
  params: Record<string, string>;
  /** Parsed JSON body (always an object; `{}` when absent). */
  body: Record<string, unknown>;
  /** Query-string parameters (string values only). */
  query: Record<string, string>;
}

export type Handler = (ctx: RequestContext) => Promise<unknown> | unknown;

/**
 * A handled error with an HTTP status. Anything else thrown from a handler is
 * treated as a 500. `code` mirrors the client's expectation of a short slug.
 */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export const badRequest = (message: string, code = "invalid-argument"): ApiError =>
  new ApiError(400, code, message);
export const unauthorized = (message = "Authentication required"): ApiError =>
  new ApiError(401, "unauthenticated", message);
export const forbidden = (message = "You don't have access to this."): ApiError =>
  new ApiError(403, "permission-denied", message);
export const notFound = (message = "Not found."): ApiError =>
  new ApiError(404, "not-found", message);
export const conflict = (message: string): ApiError =>
  new ApiError(409, "already-exists", message);

/** Reads a required non-empty string field from a JSON body, or throws 400. */
export function requireString(
  body: Record<string, unknown>,
  field: string
): string {
  const value = body[field];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw badRequest(`Missing or empty field: ${field}`);
  }
  return value;
}

/** Reads an optional string field (undefined/null → undefined). */
export function optionalString(
  body: Record<string, unknown>,
  field: string
): string | undefined {
  const value = body[field];
  return typeof value === "string" ? value : undefined;
}
