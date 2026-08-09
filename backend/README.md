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

## Day-to-day

All commands below are run from `functions/`.

| Command            | What it does                                                                |
| ------------------ | --------------------------------------------------------------------------- |
| `npm run build`    | Compiles `src/` → `lib/` via `tsc`. Required before any deploy.             |
| `npm run build:watch` | Recompiles on save — pair with the emulator for fast iteration.          |
| `npm test`         | Runs the Jest unit-test suite once (no emulator/network needed).            |
| `npm run test:watch` | Re-runs affected tests on save.                                           |
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

## Next steps

Planned triggers (see app spec / chat history):

- **`onDocumentCreated invitations/{id}`** → send push to recipient.
- **`onDocumentDeleted progressItems/{id}`** → cascade-delete all
  `activities/`, `collections/`, cross-user `progressLinks/`, and
  `invitations/` referencing that progress.
- **`onDocumentCreated progressItems/{id}/activities/{id}`** → notify
  collaborators (everyone with a `progressLinks/{id}` doc except the
  writer).

Each goes in its own file under `src/`, exported from `index.ts`.
