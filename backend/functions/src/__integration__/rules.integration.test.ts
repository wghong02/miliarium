/**
 * Security-rules tests for firestore.rules — validates the client READ model
 * (owner/collaborator membership, no enumeration, all client writes denied)
 * against the Firestore emulator with the CLIENT SDK, before the rules are wired
 * into firebase.json. Runs under `npm run test:integration`.
 */

import { readFileSync } from "fs";
import { resolve } from "path";
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, collection, getDocs, query, where } from "firebase/firestore";

let env: RulesTestEnvironment;

beforeAll(async () => {
  const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080").split(":");
  env = await initializeTestEnvironment({
    projectId: "demo-miliarium-rules",
    firestore: {
      host,
      port: Number(port),
      rules: readFileSync(resolve(__dirname, "../../../firestore.rules"), "utf8"),
    },
  });
});

afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
});

/** Seed data bypassing rules. */
async function seed(fn: (db: any) => Promise<void>) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await fn(ctx.firestore());
  });
}

describe("firestore rules", () => {
  it("denies unauthenticated reads", async () => {
    await seed(async (db) => {
      await setDoc(doc(db, "progressItems/P"), { ownerUserId: "alice" });
    });
    const anon = env.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(anon, "progressItems/P")));
    await assertFails(getDoc(doc(anon, "users/alice")));
  });

  it("progress: owner/collaborator read, strangers denied, no client writes", async () => {
    await seed(async (db) => {
      await setDoc(doc(db, "progressItems/P"), { ownerUserId: "alice" });
      await setDoc(doc(db, "progressItems/P/activities/A"), { title: "x" });
    });
    const alice = env.authenticatedContext("alice").firestore();
    const bob = env.authenticatedContext("bob").firestore();

    await assertSucceeds(getDoc(doc(alice, "progressItems/P")));
    await assertSucceeds(getDoc(doc(alice, "progressItems/P/activities/A")));
    await assertSucceeds(getDocs(collection(alice, "progressItems/P/activities")));
    await assertFails(getDoc(doc(bob, "progressItems/P")));

    // bob becomes a collaborator (server writes the link) → gains access
    await seed(async (db) => {
      await setDoc(doc(db, "users/bob/progressLinks/P"), { role: "collaborator" });
    });
    await assertSucceeds(getDoc(doc(bob, "progressItems/P")));

    // no client writes anywhere in the tree
    await assertFails(setDoc(doc(alice, "progressItems/P2"), { ownerUserId: "alice" }));
    await assertFails(setDoc(doc(alice, "progressItems/P/activities/A2"), { title: "y" }));
    await assertFails(getDocs(collection(alice, "progressItems"))); // no top-level list
  });

  it("users: get by id allowed, list/enumeration denied, writes denied", async () => {
    await seed(async (db) => {
      await setDoc(doc(db, "users/bob"), { userId: "bob", email: "b@x.com" });
    });
    const alice = env.authenticatedContext("alice").firestore();

    await assertSucceeds(getDoc(doc(alice, "users/bob")));
    await assertFails(getDocs(collection(alice, "users")));
    await assertFails(getDocs(query(collection(alice, "users"), where("email", "==", "b@x.com"))));
    await assertFails(setDoc(doc(alice, "users/alice"), { name: "hax" }));
  });

  it("user subcollections: owner-only read, never client-writable", async () => {
    await seed(async (db) => {
      await setDoc(doc(db, "users/alice/progressLinks/P"), { role: "owner" });
      await setDoc(doc(db, "users/alice/blockedUsers/x"), { blockedUserId: "x" });
    });
    const alice = env.authenticatedContext("alice").firestore();
    const bob = env.authenticatedContext("bob").firestore();

    await assertSucceeds(getDoc(doc(alice, "users/alice/progressLinks/P")));
    await assertSucceeds(getDoc(doc(alice, "users/alice/blockedUsers/x")));
    await assertFails(getDoc(doc(bob, "users/alice/progressLinks/P")));
    await assertFails(setDoc(doc(alice, "users/alice/progressLinks/P2"), { role: "owner" }));
    await assertFails(setDoc(doc(alice, "users/alice/blockedUsers/y"), { blockedUserId: "y" }));
  });

  it("invitations: participants read, queries must be scoped, no client writes", async () => {
    await seed(async (db) => {
      await setDoc(doc(db, "invitations/INV"), {
        fromUserId: "alice",
        toUserId: "bob",
        progressItemId: "P",
      });
    });
    const alice = env.authenticatedContext("alice").firestore();
    const bob = env.authenticatedContext("bob").firestore();
    const carol = env.authenticatedContext("carol").firestore();

    await assertSucceeds(getDoc(doc(alice, "invitations/INV")));
    await assertSucceeds(getDoc(doc(bob, "invitations/INV")));
    await assertFails(getDoc(doc(carol, "invitations/INV")));

    // scoped list queries pass; unscoped / other-user queries fail
    await assertSucceeds(getDocs(query(collection(bob, "invitations"), where("toUserId", "==", "bob"))));
    await assertSucceeds(
      getDocs(query(collection(alice, "invitations"), where("fromUserId", "==", "alice")))
    );
    await assertSucceeds(
      getDocs(
        query(
          collection(alice, "invitations"),
          where("fromUserId", "==", "alice"),
          where("progressItemId", "==", "P")
        )
      )
    );
    await assertFails(getDocs(collection(carol, "invitations")));
    await assertFails(getDocs(query(collection(carol, "invitations"), where("toUserId", "==", "bob"))));

    await assertFails(
      setDoc(doc(alice, "invitations/INV2"), { fromUserId: "alice", toUserId: "bob", progressItemId: "P" })
    );
  });

  it("reports: not client-readable or writable", async () => {
    const alice = env.authenticatedContext("alice").firestore();
    await assertFails(setDoc(doc(alice, "reports/R"), { reporterId: "alice" }));
    await assertFails(getDocs(collection(alice, "reports")));
  });
});
