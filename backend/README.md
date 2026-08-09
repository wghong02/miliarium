# miliariumBackend

Cloud Functions backend for the **Miliarium** iOS app. Hosts Firestore
triggers, push-notification dispatch, and cascade-cleanup work that needs
to outlive any single client session.

The iOS client (`/Users/wghong/apps/miliarium`) continues to talk to
Firestore directly for CRUD and live listeners — this repo only owns work
that has to run server-side.

## Stack

- **Node.js 24** (matches the Firebase Functions runtime)
- **TypeScript 5** (strict mode)
- **Firebase Functions v7 SDK** (Gen 2 triggers by default)
- **Firebase Admin SDK v12**

## Layout

```
miliariumBackend/
├── firebase.json           Firebase project config (functions + emulators)
├── .firebaserc             Created by `firebase use --add` (ignored from this template)
└── functions/
    ├── package.json
    ├── tsconfig.json
    └── src/
        └── index.ts        Entry point — exports become deployable functions
```

As the codebase grows, split related triggers into their own files
(`src/invitations.ts`, `src/cascadeDelete.ts`, etc.) and re-export from
`index.ts`.

## One-time setup

1. **Install the Firebase CLI** if you haven't:
   ```bash
   npm install -g firebase-tools
   firebase login
   ```

2. **Link this repo to your Firebase project** (creates `.firebaserc`):
   ```bash
   firebase use --add
   ```
   Pick the same project your iOS app's `GoogleService-Info.plist` points
   at, and give it the alias `default`.

3. **Install dependencies**:
   ```bash
   cd functions
   npm install
   ```

4. **Make sure the project is on the Blaze plan.** Cloud Functions cannot
   deploy on Spark (free) — Blaze is pay-as-you-go with a generous free
   tier. Upgrade at <https://console.firebase.google.com/project/_/usage/details>.

## The `api` function (client mutations)

All client writes go through a single Gen2 HTTPS function, `api`
(`src/api/`). The iOS app calls it with the user's Firebase ID token in an
`Authorization: Bearer` header; handlers verify the token, enforce
ownership/membership with the Admin SDK, and perform the writes. Reads and
realtime listeners still run client-side (this is a writes-only migration).

**Signed media uploads.** Media isn't proxied through the function: `POST
.../media/upload-url` returns a short-lived V4 signed URL, the client PUTs the
bytes straight to Cloud Storage, then commits the metadata doc. Signing V4 URLs
from a deployed function requires the function's runtime **service account to
have the "Service Account Token Creator" role on itself** (so the Admin SDK can
call IAM `signBlob`). Grant it once:

```bash
SA="$(gcloud iam service-accounts list --format='value(email)' --filter='displayName:Default compute service account')"
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --member="serviceAccount:$SA" --role="roles/iam.serviceAccountTokenCreator"
```

## Security rules (⚠️ drafts — not yet deployed)

`firestore.rules` and `storage.rules` are **drafts** and are intentionally **not**
referenced by `firebase.json` yet. Now that the backend owns all writes, the
model is simple: **client reads** are gated by owner/collaborator membership and
**all client writes are denied**. Until these are wired in, the console rules
still apply.

Before enabling them:

1. Add rules unit tests with `@firebase/rules-unit-testing` covering the client
   READ queries listed at the bottom of `firestore.rules`.
2. Validate against the emulator: `firebase emulators:start --only firestore,storage`.
3. Apply the remaining **companion change** in the header of `firestore.rules`
   (constrain the owner "Invited Users" invitations query by `fromUserId`).
4. Wire them in — add to `firebase.json`:
   ```json
   "firestore": { "rules": "firestore.rules" },
   "storage":   { "rules": "storage.rules" }
   ```
   then `firebase deploy --only firestore:rules,storage:rules`.

## Day-to-day

All commands below are run from `functions/`.

| Command            | What it does                                                                |
| ------------------ | --------------------------------------------------------------------------- |
| `npm run build`    | Compiles `src/` → `lib/` via `tsc`. Required before any deploy.             |
| `npm run build:watch` | Recompiles on save — pair with the emulator for fast iteration.          |
| `npm test`         | Runs the Jest unit-test suite once (no emulator/network needed).            |
| `npm run test:watch` | Re-runs affected tests on save.                                           |
| `npm run test:integration` | Runs API handlers against the Firestore emulator (needs Java).      |
| `npm run serve`    | Builds and starts the Functions emulator at `http://localhost:5001`.        |
| `npm run shell`    | Interactive REPL for invoking functions locally without HTTP.               |
| `npm run deploy`   | Builds then deploys all functions to the linked Firebase project.           |
| `npm run logs`     | Tails the Cloud Logging stream for deployed functions.                      |

## Testing

Unit tests live in `functions/src/__tests__/` and run with **Jest** (via
`ts-jest`). They mock the Firebase Admin SDK and invoke each Gen 2 trigger
through its `.run()` method, so they need **no emulator, no credentials, and
no network** — the whole suite finishes in a couple of seconds.

From `functions/`:

```bash
npm test            # run the suite once
npm run test:watch  # re-run on file changes
```

Target a single file or test by name:

```bash
npx jest pushNotifications           # one file (matches on path)
npx jest -t "excluding the creator"  # tests whose name matches
```

### Integration tests (Firestore emulator)

`functions/src/__integration__/*.integration.test.ts` exercise the `api`
handlers against a **real emulated Firestore** (Admin SDK, no mocks) — catching
query/`FieldValue`/read-after-write behavior the unit mocks can't. They run
under a separate Jest config and are excluded from the deploy build.

```bash
npm run test:integration
```

This wraps the run in `firebase emulators:exec --only firestore`, so it needs a
**Java runtime** (the Firestore emulator's dependency); install a JDK/JRE 11+ if
`java -version` fails. No real Firebase project is used (`--project
demo-miliarium` runs fully offline). Media handlers are covered by unit tests
only — signed-URL generation needs real IAM signing the Storage emulator lacks.

Notes:

- Tests are excluded from the deploy build (see `exclude` in `tsconfig.json`),
  so they never ship to `lib/`.
- When you add a trigger, drop a matching `*.test.ts` beside the others under
  `src/__tests__/`. Handler helpers that aren't exported are covered
  indirectly by exercising the trigger via `.run(event)`.

## Smoke-testing the setup

After `npm run deploy`, hit the printed `helloWorld` URL — it should
respond with `{"ok": true, "message": "miliarium backend is alive"}`.
Delete `helloWorld` once your real triggers are in place.

Locally, the same function is reachable via:

```bash
curl http://localhost:5001/<project-id>/us-central1/helloWorld
```

while `npm run serve` is running.

## Deployed functions

Each trigger lives in its own file under `src/` and is re-exported from
`index.ts`:

- **`api`** (`src/api/`) — HTTPS endpoint fronting every client mutation
  (progress, activities, collections, media, invitations, profile, device
  tokens, moderation). See "The `api` function" above.
- **`onActivityCreated`** (`pushNotifications.ts`) — notify collaborators
  (everyone with a `progressLinks/{id}` doc except the writer) when a new
  activity is added. Invitations intentionally do **not** send a push — they
  surface in-app via the recipient's invitations listener.
- **`onProgressDeleted` / `onCollectionDeleted` / `onActivityUnlinkCollections`
  / `onUserDeleted`** (`cascadeDeletes.ts`) — relational cascade cleanup.
- **`onMediaDeleted` / `onActivityDeleted`** (`mediaCleanup.ts`) — Storage
  cleanup for deleted media/activities.
- **`onAuthUserCreated` / `onAuthUserDeleted`** (`accountCreation.ts` /
  `accountDeletion.ts`) — create the `users/{uid}` doc on signup and delete it
  on account deletion (which fans out to the cascade above).
