/**
 * HTTP smoke test for the `api` function — the one layer the handler-level
 * integration tests skip. Runs the built function in the Functions emulator and
 * hits it over real HTTP with an ID token minted by the Auth emulator, so it
 * covers routing, `verifyIdToken`, membership enforcement, and the success/error
 * JSON envelopes end to end.
 *
 * Run via `npm run test:integration` (which builds, then boots the functions +
 * firestore + auth emulators). Requires a Java runtime.
 */

import { getFirestore } from "firebase-admin/firestore";

const PROJECT = process.env.GCLOUD_PROJECT ?? "demo-miliarium";
const FUNCTIONS_PORT = 5001; // matches backend/firebase.json
const API = `http://127.0.0.1:${FUNCTIONS_PORT}/${PROJECT}/us-central1/api`;
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";

let userCounter = 0;

/** Creates a fresh Auth-emulator user and returns an ID token + uid + email. */
async function signUp(): Promise<{ idToken: string; uid: string; email: string }> {
  const email = `user${Date.now()}_${userCounter++}@example.com`;
  const res = await fetch(
    `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password: "password123", returnSecureToken: true }),
    }
  );
  const data: any = await res.json();
  if (!data.idToken) throw new Error(`signUp failed: ${JSON.stringify(data)}`);
  return { idToken: data.idToken, uid: data.localId, email };
}

async function api(
  method: string,
  path: string,
  opts: { token?: string; body?: unknown } = {}
): Promise<{ status: number; json: any }> {
  const res = await fetch(`${API}${path}`, {
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

/** Waits for the function to be reachable (first hit can cold-start). */
async function waitForApi(): Promise<void> {
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch(API, { method: "GET" });
      if (typeof res.status === "number") return; // any response ⇒ up
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("api function did not become ready");
}

beforeAll(async () => {
  await waitForApi();
}, 30000);

describe("api HTTP layer", () => {
  it("rejects an unauthenticated request with a 401 envelope", async () => {
    const r = await api("PATCH", "/me", { body: { name: "x" } });
    expect(r.status).toBe(401);
    expect(r.json.error.code).toBe("unauthenticated");
  });

  it("404s an unknown route for an authenticated caller", async () => {
    const { idToken } = await signUp();
    const r = await api("GET", "/does-not-exist", { token: idToken });
    expect(r.status).toBe(404);
    expect(r.json.error).toBeDefined();
  });

  it("returns a structured 400 for a validation error", async () => {
    const { idToken } = await signUp();
    const r = await api("POST", "/progress", { token: idToken, body: { id: "P" } }); // no title
    expect(r.status).toBe(400);
    expect(r.json.error.code).toBe("invalid-argument");
  });

  it("verifies the token, then writes + reads back through HTTP + serialization", async () => {
    const { idToken } = await signUp();
    const pid = `P_${Date.now()}`;

    const create = await api("POST", "/progress", {
      token: idToken,
      body: { id: pid, title: "My Goal" },
    });
    expect(create.status).toBe(200);
    expect(create.json).toEqual({ id: pid });

    const addCol = await api("POST", `/progress/${pid}/collections`, {
      token: idToken,
      body: { id: "c1", name: "Cities" },
    });
    expect(addCol.status).toBe(200);

    const list = await api("GET", `/progress/${pid}/collections`, { token: idToken });
    expect(list.status).toBe(200);
    expect(list.json.collections).toHaveLength(1);
    expect(list.json.collections[0]).toMatchObject({ id: "c1", name: "Cities" });
    // serialized stats object round-trips
    expect(list.json.collections[0].stats).toMatchObject({ total: 0 });
  });

  it("ensures the profile lazily (with the account email), then deletes the account", async () => {
    const { idToken, uid, email } = await signUp();

    const ensure = await api("POST", "/me/ensure", { token: idToken });
    expect(ensure.status).toBe(200);

    const profile = await api("GET", `/users/${uid}`, { token: idToken });
    expect(profile.status).toBe(200);
    expect(profile.json).toMatchObject({ id: uid, email });

    const del = await api("DELETE", "/me/account", { token: idToken });
    expect(del.status).toBe(200);

    // Verified directly against Firestore: the profile doc is gone (which also
    // fired the onUserDeleted cascade).
    const doc = await getFirestore().collection("users").doc(uid).get();
    expect(doc.exists).toBe(false);
  });

  it("enforces membership over HTTP (a non-member gets 403)", async () => {
    const owner = await signUp();
    const stranger = await signUp();
    const pid = `P_${Date.now()}_m`;
    await api("POST", "/progress", { token: owner.idToken, body: { id: pid, title: "g" } });

    const r = await api("GET", `/progress/${pid}/collections`, { token: stranger.idToken });
    expect(r.status).toBe(403);
    expect(r.json.error.code).toBe("permission-denied");
  });
});
