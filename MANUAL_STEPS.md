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

## 5. 🟡 Deploy the security rules

`backend/firestore.rules` + `backend/storage.rules` enforce "backend owns all
writes, client reads gated by membership." They're now **wired into
`firebase.json` and validated** by `rules.integration.test.ts` (see
`npm run test:integration`), so just deploy them:

```bash
cd backend
firebase deploy --only firestore:rules,storage
```

Note the target is `storage`, not `storage:rules` (that `:rules` form is only
valid for `firestore`). The `storage` half needs the bucket from step 6 — if it
errors on a missing bucket, do step 6 first, or ship just
`firebase deploy --only firestore:rules` now and storage after.

Until this is done, whatever rules are in the console still apply (so an
authenticated user could read/write another user's data if those are permissive).

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

- Backend logic is unit-tested (`cd backend/functions && npm test`, 59 tests):
  authorization (owner/collaborator/self), account lifecycle, invitation
  send/dedup/accept/revoke, activity↔collection reconciliation, media
  path-injection + size validation, the read serializers, and routing.
- Integration tests (`npm run test:integration`, 18 tests) run against the
  emulator: handler flows against Firestore, an HTTP layer hitting the `api`
  function with an Auth-emulator token (routing, `verifyIdToken`, membership,
  envelopes), and **security-rules tests** (`rules.integration.test.ts`) that
  validate the read model with the client SDK. These need a **Java runtime**; if
  `java -version` fails, install a JDK/JRE 11+ first.
- iOS `PrivacyInfo.xcprivacy` (required-reason API manifest).
- Legal pages hosted at `wghong02.github.io/apps/{policy,terms,support}/miliarium`
  and referenced from the app.
- All client writes + one-shot reads routed through the backend; realtime
  listeners kept client-side.
- Invitation email resolution moved server-side (no client user-enumeration).
