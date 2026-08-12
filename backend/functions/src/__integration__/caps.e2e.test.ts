/**
 * LIVE end-to-end tests for the two cap features, run against the REAL deployed
 * `api` function with REAL signed-in accounts (no emulator, no mocks):
 *
 *   1. A user can own at most MAX_PROGRESS_ITEMS (2) progresses.
 *   2. A single progress can have at most MAX_PROGRESS_MEMBERS (2) people.
 *
 * Auth: each test account is signed in through the Firebase Identity Toolkit
 * REST API (`accounts:signInWithPassword`) using the project's public Web API
 * key, exactly like the real app's Firebase Auth. The resulting ID token is
 * sent as `Authorization: Bearer …`, so this exercises the full stack:
 * verifyIdToken → routing → membership/ownership → the cap logic.
 *
 * Credentials live in the gitignored `credentials.e2e.json` (copy
 * `credentials.e2e.example.json`). When it's absent or still has placeholders,
 * the whole suite skips itself — so it never fails a machine without secrets.
 *
 * Account roles are kept DISJOINT so tests don't contaminate each other's cap
 * state (owner-link cleanup on delete is an async cascade on the real backend):
 *   - `owner`        : the only progress-owner in the progress-cap test.
 *   - `collaborator` : hosts the progress in the member-cap test.
 *   - `outsider`     : hosts the progress in the edge-case test.
 * Every test deletes the progresses it creates.
 *
 * Run: `npm run test:e2e`
 */

import * as fs from "fs";
import * as path from "path";

// --- Credentials ------------------------------------------------------------

interface Account {
  email: string;
  password: string;
}
interface Creds {
  apiBaseUrl: string;
  webApiKey: string;
  accounts: { owner: Account; collaborator: Account; outsider: Account };
}

function loadCreds(): Creds | null {
  try {
    const raw = fs.readFileSync(path.join(__dirname, "credentials.e2e.json"), "utf8");
    const c = JSON.parse(raw) as Creds;
    const accts = c?.accounts ? Object.values(c.accounts) : [];
    const placeholder =
      !c.apiBaseUrl ||
      !c.webApiKey ||
      c.webApiKey.includes("YOUR_") ||
      c.apiBaseUrl.includes("YOUR_PROJECT") ||
      accts.length < 3 ||
      accts.some((a) => !a?.email || !a?.password || a.password === "CHANGE_ME");
    return placeholder ? null : c;
  } catch {
    return null;
  }
}

const creds = loadCreds();
const BASE = (creds?.apiBaseUrl ?? "").replace(/\/+$/, "");

// Skip the entire suite (with a visible note) when creds aren't configured.
const describeLive = creds ? describe : describe.skip;
if (!creds) {
  // eslint-disable-next-line no-console
  console.warn(
    "\n[caps.e2e] Skipping live e2e tests — fill in " +
      "src/__integration__/credentials.e2e.json (see credentials.e2e.example.json).\n"
  );
}

// --- HTTP helpers ------------------------------------------------------------

/** Signs an account in via the Identity Toolkit REST API → ID token + uid. */
async function signIn(acc: Account): Promise<{ token: string; uid: string }> {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${creds!.webApiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: acc.email, password: acc.password, returnSecureToken: true }),
    }
  );
  const data: any = await res.json();
  if (!data.idToken) {
    throw new Error(`Sign-in failed for ${acc.email}: ${JSON.stringify(data.error ?? data)}`);
  }
  return { token: data.idToken, uid: data.localId };
}

async function api(
  method: string,
  route: string,
  opts: { token?: string; body?: unknown } = {}
): Promise<{ status: number; json: any }> {
  const res = await fetch(`${BASE}${route}`, {
    method,
    headers: {
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
      ...(opts.body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  let json: any;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = text;
  }
  return { status: res.status, json };
}

/** Retries `fn` until it returns something defined (or times out). */
async function poll<T>(
  fn: () => Promise<T | undefined>,
  { tries = 20, delayMs = 1000 } = {}
): Promise<T | undefined> {
  for (let i = 0; i < tries; i++) {
    const v = await fn();
    if (v !== undefined) return v;
    await new Promise((r) => setTimeout(r, delayMs));
  }
  return undefined;
}

/** The id of a pending invitation the signed-in user received for `pid`. */
async function receivedInviteId(token: string, pid: string): Promise<string | undefined> {
  const r = await api("GET", "/invitations?role=received", { token });
  const list: any[] = r.json?.invitations ?? [];
  return list.find((i) => i.progressItemId === pid && i.status === "pending")?.id;
}

// --- Suite ------------------------------------------------------------------

describeLive("live caps e2e", () => {
  let owner: { token: string; uid: string };
  let collaborator: { token: string; uid: string };
  let outsider: { token: string; uid: string };

  // Progresses created during the run, mapped to the owner token that can
  // delete them. Cleaned up after each test.
  const created: { id: string; token: string }[] = [];
  const track = (id: string, token: string) => created.push({ id, token });

  beforeAll(async () => {
    [owner, collaborator, outsider] = await Promise.all([
      signIn(creds!.accounts.owner),
      signIn(creds!.accounts.collaborator),
      signIn(creds!.accounts.outsider),
    ]);
    // Ensure every account has a profile doc (with its email) so invitations
    // can resolve recipients by email.
    await Promise.all([
      api("POST", "/me/ensure", { token: owner.token }),
      api("POST", "/me/ensure", { token: collaborator.token }),
      api("POST", "/me/ensure", { token: outsider.token }),
    ]);
  }, 30000);

  afterEach(async () => {
    for (const { id, token } of created) {
      await api("DELETE", `/progress/${id}`, { token }).catch(() => undefined);
    }
    created.length = 0;
  });

  // --- Feature 1: at most 2 owned progresses -------------------------------

  describe("progress ownership cap (max 2 per user)", () => {
    it("allows 2 progresses then rejects the 3rd with limit-reached", async () => {
      const stamp = Date.now();
      const a = `e2e_cap_${stamp}_a`;
      const b = `e2e_cap_${stamp}_b`;
      const c = `e2e_cap_${stamp}_c`;

      const r1 = await api("POST", "/progress", { token: owner.token, body: { id: a, title: "Cap A" } });
      expect(r1.status).toBe(200);
      track(a, owner.token);

      const r2 = await api("POST", "/progress", { token: owner.token, body: { id: b, title: "Cap B" } });
      expect(r2.status).toBe(200);
      track(b, owner.token);

      // Third create is over the cap.
      const r3 = await api("POST", "/progress", { token: owner.token, body: { id: c, title: "Cap C" } });
      expect(r3.status).toBe(409);
      expect(r3.json.error.code).toBe("limit-reached");
    });

    it("frees a slot after deleting an owned progress", async () => {
      const stamp = Date.now();
      const a = `e2e_free_${stamp}_a`;
      const b = `e2e_free_${stamp}_b`;
      const c = `e2e_free_${stamp}_c`;

      expect((await api("POST", "/progress", { token: owner.token, body: { id: a, title: "A" } })).status).toBe(200);
      track(a, owner.token);
      expect((await api("POST", "/progress", { token: owner.token, body: { id: b, title: "B" } })).status).toBe(200);
      track(b, owner.token);

      // At the cap: the next create fails.
      expect((await api("POST", "/progress", { token: owner.token, body: { id: c, title: "C" } })).status).toBe(409);

      // Delete one; the owner link is removed by an async cascade, so poll the
      // create until the freed slot is visible.
      expect((await api("DELETE", `/progress/${a}`, { token: owner.token })).status).toBe(200);
      created.splice(created.findIndex((x) => x.id === a), 1);

      const freed = await poll(async () => {
        const r = await api("POST", "/progress", { token: owner.token, body: { id: c, title: "C" } });
        return r.status === 200 ? c : undefined;
      });
      expect(freed).toBe(c);
      track(c, owner.token);
    }, 30000);

    it("rejects an unauthenticated create with 401", async () => {
      const r = await api("POST", "/progress", { body: { id: "nope", title: "x" } });
      expect(r.status).toBe(401);
      expect(r.json.error.code).toBe("unauthenticated");
    });
  });

  // --- Feature 2: at most 2 people per progress ----------------------------

  describe("progress membership cap (max 2 people)", () => {
    it("blocks a 3rd person from joining, at both accept and send time", async () => {
      const host = collaborator; // uses a distinct account as owner
      const pid = `e2e_mem_${Date.now()}`;
      expect(
        (await api("POST", "/progress", { token: host.token, body: { id: pid, title: "Team" } })).status
      ).toBe(200);
      track(pid, host.token);

      // Host (1 member) invites BOTH others while still under the cap → allowed.
      const inv1 = await api("POST", "/invitations", {
        token: host.token,
        body: { progressItemId: pid, progressItemTitle: "Team", toEmail: creds!.accounts.outsider.email },
      });
      expect(inv1.status).toBe(200);
      const inv2 = await api("POST", "/invitations", {
        token: host.token,
        body: { progressItemId: pid, progressItemTitle: "Team", toEmail: creds!.accounts.owner.email },
      });
      expect(inv2.status).toBe(200);

      // Outsider accepts → progress now has 2 people (host + outsider).
      const outsiderInvite = await poll(() => receivedInviteId(outsider.token, pid));
      expect(outsiderInvite).toBeDefined();
      const acc1 = await api("POST", `/invitations/${outsiderInvite}/accept`, { token: outsider.token });
      expect(acc1.status).toBe(200);

      // Accept-time cap: owner tries to accept the still-pending invite → 409.
      const ownerInvite = await poll(() => receivedInviteId(owner.token, pid));
      expect(ownerInvite).toBeDefined();
      const acc2 = await api("POST", `/invitations/${ownerInvite}/accept`, { token: owner.token });
      expect(acc2.status).toBe(409);
      expect(acc2.json.error.code).toBe("limit-reached");

      // Send-time cap: re-inviting a non-member when full → 409.
      const inv3 = await api("POST", "/invitations", {
        token: host.token,
        body: { progressItemId: pid, progressItemTitle: "Team", toEmail: creds!.accounts.owner.email },
      });
      expect(inv3.status).toBe(409);
      expect(inv3.json.error.code).toBe("limit-reached");
    }, 30000);
  });

  // --- Invitation edge cases ------------------------------------------------

  describe("invitation edge cases", () => {
    let pid: string;
    beforeEach(async () => {
      pid = `e2e_edge_${Date.now()}`;
      await api("POST", "/progress", { token: outsider.token, body: { id: pid, title: "Edge" } });
      track(pid, outsider.token);
    });

    it("rejects inviting yourself with 400", async () => {
      const r = await api("POST", "/invitations", {
        token: outsider.token,
        body: { progressItemId: pid, progressItemTitle: "Edge", toEmail: creds!.accounts.outsider.email },
      });
      expect(r.status).toBe(400);
    });

    it("404s an email that maps to no user", async () => {
      const r = await api("POST", "/invitations", {
        token: outsider.token,
        body: {
          progressItemId: pid,
          progressItemTitle: "Edge",
          toEmail: `nobody_${Date.now()}@example.invalid`,
        },
      });
      expect(r.status).toBe(404);
    });

    it("403s a non-member trying to invite to someone else's progress", async () => {
      // `owner` is not a member of outsider's progress.
      const r = await api("POST", "/invitations", {
        token: owner.token,
        body: { progressItemId: pid, progressItemTitle: "Edge", toEmail: creds!.accounts.collaborator.email },
      });
      expect(r.status).toBe(403);
      expect(r.json.error.code).toBe("permission-denied");
    });

    it("403s accepting an invitation addressed to a different user", async () => {
      // Outsider invites collaborator…
      const sent = await api("POST", "/invitations", {
        token: outsider.token,
        body: { progressItemId: pid, progressItemTitle: "Edge", toEmail: creds!.accounts.collaborator.email },
      });
      expect(sent.status).toBe(200);
      const inviteId = await poll(() => receivedInviteId(collaborator.token, pid));
      expect(inviteId).toBeDefined();

      // …but `owner` (the wrong recipient) tries to accept it → 403.
      const r = await api("POST", `/invitations/${inviteId}/accept`, { token: owner.token });
      expect(r.status).toBe(403);
    });
  });
});
