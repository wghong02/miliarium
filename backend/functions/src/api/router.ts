/**
 * Tiny path router for the API. Matches `METHOD /a/:param/b` patterns against a
 * request path and extracts named parameters. Kept dependency-free and pure so
 * it can be unit-tested directly.
 */

import { Handler } from "./http";

export type Method = "GET" | "POST" | "PATCH" | "PUT" | "DELETE";

export interface Route {
  method: Method;
  /** e.g. `/progress/:pid/activities/:aid`. */
  pattern: string;
  handler: Handler;
}

export interface Matched {
  handler: Handler;
  params: Record<string, string>;
}

function segments(path: string): string[] {
  return path.split("/").filter((s) => s.length > 0);
}

/**
 * Finds the first route matching `method` + `path`, returning its handler and
 * the extracted path params. Returns `undefined` when nothing matches.
 */
export function matchRoute(
  routes: Route[],
  method: string,
  path: string
): Matched | undefined {
  const pathSegs = segments(path);
  for (const route of routes) {
    if (route.method !== method) continue;
    const patSegs = segments(route.pattern);
    if (patSegs.length !== pathSegs.length) continue;

    const params: Record<string, string> = {};
    let matched = true;
    for (let i = 0; i < patSegs.length; i++) {
      const pat = patSegs[i];
      if (pat.startsWith(":")) {
        params[pat.slice(1)] = decodeURIComponent(pathSegs[i]);
      } else if (pat !== pathSegs[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return { handler: route.handler, params };
  }
  return undefined;
}
