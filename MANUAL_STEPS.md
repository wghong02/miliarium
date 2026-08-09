# Manual steps — backend migration go-live

The iOS app now talks to a backend `api` Cloud Function for **all writes and most
reads** (realtime listeners still read Firestore directly). Because of that, the
app **will not function until the backend is deployed** and the items below are
done. Work top to bottom.

> Legend: 🔴 required for the app to work · 🟡 required before App Store / for
> security · ⚪ optional / local dev.

---

## 1. 🔴 Deploy the backend

Prereqs: the Firebase project (`miliarium-68373`) must be on the **Blaze** plan
(Cloud Functions + signed URLs need it), and the Firebase CLI must be logged in
(`firebase login`).

```bash
cd backend/functions
npm install
npm run build
cd ..
firebase deploy --only functions
```

This deploys `api` plus the Firestore/Storage triggers (`onActivityCreated`,
cascade + media cleanup). Everything is Gen 2 (account lifecycle is handled by
the `api` function, not Auth triggers), so it runs on the `nodejs24` runtime.
First deploy also enables the required Google Cloud APIs (Cloud Run, Cloud
Build, Artifact Registry, Eventarc) — accept the prompts.

## 2. 🔴 Point the app at the deployed API

After deploy, confirm the function URL. The app defaults to:

```
https://us-central1-miliarium-68373.cloudfunctions.net/api
```

If the Firebase console shows a different host for `api` (Gen2 functions also get
a `*.run.app` URL), update `baseURL` in
`ios/miliarium/App/BackendConfig.swift` accordingly.

## 3. 🔴 Grant the signed-URL IAM role (media uploads)

Media uploads use V4 signed URLs, which require the function's runtime service
account to be able to sign blobs (call IAM `signBlob` on itself). Without this,
`POST …/media/upload-url` fails and photos/videos can't be attached.

```bash
PROJECT=miliarium-68373
SA="$(gcloud iam service-accounts list --project "$PROJECT" \
  --format='value(email)' --filter='displayName:Default compute service account')"
gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT" \
  --member="serviceAccount:$SA" --role="roles/iam.serviceAccountTokenCreator"
```

## 4. 🔴 Create the Firestore composite indexes

The required indexes are declared in `backend/firestore.indexes.json` and wired
into `firebase.json`, so just deploy them:

```bash
cd backend
firebase deploy --only firestore:indexes
```

(A full `firebase deploy` includes them too.) They cover the invitation
send-dedup, received/sent lists, the Invited Users panel query, and the
`progressLinks` collection-group query used by the cascade + activity push.
Building the indexes takes a few minutes; queries return
`FAILED_PRECONDITION` until they finish. If you ever see that error with a
"create it here" link in `firebase functions:log`, it means a query needs an
index not yet in the file — click the link, then add it to
`firestore.indexes.json`.

## 5. 🟡 Enable and lock down security rules

The drafted rules (`backend/firestore.rules`, `backend/storage.rules`) enforce
"backend owns all writes, client reads gated by membership." They are **not yet
wired** into `firebase.json`. The companion client change they needed (scoping
the Invited Users invitations query by `fromUserId`) is already applied.

1. Add rules unit tests (`@firebase/rules-unit-testing`) for the client READ
   queries listed at the bottom of `firestore.rules`.
2. Validate: `firebase emulators:start --only firestore,storage`.
3. Wire into `backend/firebase.json`:
   ```json
   "firestore": { "rules": "firestore.rules" },
   "storage":   { "rules": "storage.rules" }
   ```
4. Deploy: `firebase deploy --only firestore:rules,storage:rules`.

Until this is done, any authenticated user can still read/write another user's
data via whatever console rules exist.

## 6. 🟡 Cloud Storage bucket

Ensure the default Storage bucket is provisioned (Firebase console → Storage →
Get started) so media uploads/downloads have somewhere to live. The cleanup
triggers already tolerate a missing bucket, but uploads need it.

## 7. 🟡 Push notifications (APNs)

For the new-activity push (`onActivityCreated`) to reach iOS devices, upload an
**APNs authentication key** in Firebase console → Project settings → Cloud
Messaging. (Pre-existing requirement; unchanged by this migration.)

## 8. ⚪ Local development against the emulator

To run the app against a local backend instead of production:

```bash
cd backend/functions && npm run serve   # functions emulator
# or: firebase emulators:start --only functions,firestore,auth,storage
```

Launch the app with the `-backend-emulator` argument (Xcode scheme → Run →
Arguments) so `BackendConfig` targets `http://127.0.0.1:5001/…/api`.

Note: **signed upload URLs don't work against the Storage emulator** the same way
as production; test media upload against the real project (with step 3 done), or
skip media when running fully local.

---

## Already done (no action needed)

- Backend logic is unit-tested (`cd backend/functions && npm test`, 57 tests):
  authorization (owner/collaborator/self), invitation send/dedup/accept/revoke,
  activity↔collection reconciliation, media path-injection + size validation,
  the read serializers, and routing. No manual verification of these paths is
  needed — CI-style `npm test` covers them.
- Integration tests (`npm run test:integration`, 11 tests) run against the
  emulator: handler flows against Firestore, plus an HTTP layer that hits the
  `api` function in the Functions emulator with an Auth-emulator token (routing,
  `verifyIdToken`, membership, envelopes). These need a **Java runtime** for the
  emulators; if `java -version` fails, install a JDK/JRE 11+ first.
- iOS `PrivacyInfo.xcprivacy` (required-reason API manifest).
- Legal pages hosted at `wghong02.github.io/apps/{policy,terms,support}/miliarium`
  and referenced from the app.
- All client writes + one-shot reads routed through the backend; realtime
  listeners kept client-side.
- Invitation email resolution moved server-side (no client user-enumeration).
