# Miliarium — Functionality Specification

A reference of intended **user-facing behavior**, written so each item can be
translated directly into a UI test (`XCUITest`) or a pure-logic unit test
(`XCTest`). Implementation details — Firestore schemas, document parsing,
batch writes, listener wiring — are intentionally omitted; those are
verified by the code, not by user-facing tests.

Each section is one feature area. Each subsection is:

- **Behavior** — what the user sees / can do
- **Expectations** — atomic assertions, phrased so they become test names
- **Edge cases** — boundary conditions worth covering

Test scope tags:
- 🖼 **UI** — screen interactions, navigation, state transitions (`XCUITest`)
- 🧩 **Logic** — pure in-app logic (form validation, state derivation) (`XCTest`)

---

## 1. Authentication

### 1.1 Sign in 🖼

**Behavior**
- A signed-out user sees an email + password form with a "Sign In" action.

**Expectations**
- Tapping "Sign In" with valid credentials moves the user into the main tab view.
- Invalid credentials surface an inline error message.
- Fields cannot be edited while a sign-in request is in flight.
- A spinner / busy indicator appears while the request is in flight.

**Edge cases**
- Empty email or password keeps the action disabled (or surfaces an error).
- Network failure surfaces a readable error string, not a crash.

### 1.2 Sign out 🖼

**Behavior**
- A signed-in user can sign out from the Profile tab.

**Expectations**
- After sign-out, the auth gate returns to the sign-in form.
- All tabs that depend on a signed-in user reset to their empty state on next visit.

---

## 2. Profile

### 2.1 View profile 🖼

**Behavior**
- The Profile tab shows the user's email, user ID, and current display name (if any).

**Expectations**
- Email matches the email used to sign in.
- User ID is displayed verbatim (read-only).
- When no name has been set, the field is empty and shows the "Your name" placeholder.

### 2.2 Edit display name 🖼 🧩

**Behavior**
- The user types a name into a TextField and taps "Save" on the same row.
- The header shows a `current/40` character counter.
- A 40-character cap is enforced silently — additional input is truncated.

**Expectations**
- "Save" is disabled when the name is unchanged from what's already stored.
- "Save" is disabled while a save is in flight.
- After a successful save, a transient "Saved" confirmation appears next to the button.
- The character counter turns orange when the field is at the 40-char limit.
- Typing past 40 characters truncates the input — the field never exceeds 40 characters.
- A pasted string longer than 40 characters is truncated to 40.

**Edge cases**
- Saving an empty / whitespace-only name clears the stored name and falls the display back to the user's email.

---

## 3. Progress Items

### 3.1 Create a progress 🖼

**Behavior**
- The user opens a "Create progress" sheet (from the Home tab's progress menu or the empty state) and enters a title.

**Expectations**
- The Create button is disabled when the title is empty or whitespace-only.
- After successful creation, the new progress is selected and visible on the Home tab.
- A "default collection" exists for the new progress (visible in the Collections section).

### 3.2 Switch between progresses 🖼

**Behavior**
- The user picks a progress from the top-left menu on the Home tab. (On Calendar and Map, the top-left is the collection filter — progress selection only happens on Home and is shared across all tabs.)
- The Home top-left menu label is a constant icon (`square.stack.fill` + a small chevron). It does NOT change to reflect the selected progress's title — selection is shown inside the menu via the SwiftUI `Picker` checkmark.

**Expectations**
- Selecting a different progress updates the displayed title, summary, collections, calendar contents, and map pins.
- The selection persists across tabs (Calendar and Map show the same progress as Home).
- The Home top-left label width is fixed regardless of progress name length.

### 3.3 Edit summary 🖼 🧩

**Behavior**
- The progress owner taps a pencil icon next to the title to open the Edit Summary sheet.
- A 120-character cap is enforced via character counter; the Update button locks when over the limit.

**Expectations**
- The pencil icon only appears for the progress owner.
- The character counter shows `current/120` and turns red when over the limit.
- The Update button is disabled when over the limit.
- A red warning icon appears next to the button when over the limit.
- After saving, the new summary appears in the Home tab immediately (no manual refresh).

**Edge cases**
- Saving an empty summary clears the displayed summary.

### 3.4 Delete progress 🖼

**Behavior**
- The owner taps "Delete Progress" → confirmation overlay slides up from the bottom.

**Expectations**
- The Delete button only appears for the progress owner.
- The confirmation overlay shows a warning icon, title, and explanatory text.
- Tapping outside the confirmation overlay dismisses it.
- Confirming deletion removes the progress from the picker.
- Collaborators do NOT see the Delete button.

---

## 4. Collections

### 4.1 List + filter 🖼

**Behavior**
- The Home tab shows a "Collections" section with a list of collections for the active progress.
- A filter row offers "All" vs "Favourites".

**Expectations**
- Each row shows: leading icon (star if favourite, folder otherwise), collection name, optional "default" badge, and a stats line.
- Favourite collections sort first; the default collection sorts next; others by creation order.
- Selecting "Favourites" hides non-favourite collections.
- Empty state: "No collections yet · Tap + to create one".

### 4.2 Create a collection 🖼

**Behavior**
- The "+" menu on the Collections section offers "Add activity" and "Add collection".
- "Add collection" opens a sheet with name (required), notes (optional), and a "Mark as favourite" toggle.

**Expectations**
- The Create button is disabled when the name is empty or whitespace-only.
- After save, the new collection appears in the list, with the favourite icon if selected.

### 4.3 Edit a collection 🖼

**Behavior**
- Tapping a collection row opens an edit sheet with name, notes, favourite, stats, and (optional) Delete.

**Expectations**
- The Update button is disabled when the name is empty.
- Toggling favourite re-sorts the home list (favourites move to the top).

### 4.4 Refresh stats 🖼

**Behavior**
- The edit sheet shows a Stats section: total, completed, with time, with location, first, last, updated time.
- A "Refresh stats" button recomputes from current activity membership.

**Expectations**
- Stats do NOT auto-update when activities are added/removed; user must tap "Refresh stats".
- After tapping Refresh, the stats fields update in place and the "Updated" timestamp reflects "now".
- A spinner appears while the refresh is in flight; the button is disabled.

### 4.5 Delete a collection 🖼

**Behavior**
- The edit sheet offers Delete for any non-default collection.
- Default collection cannot be deleted (the Delete section is hidden).

**Expectations**
- Tapping Delete shows a confirmation alert.
- Confirming dismisses the sheet and removes the collection from the home list.
- Activities that were in the collection still exist — they're just no longer listed under that collection.

### 4.6 Swipe-to-delete on rows 🖼

**Behavior**
- Swipe left on a non-default collection row → red Delete action.
- Default collection has no swipe action.

**Expectations**
- Swipe action triggers deletion (no extra confirmation needed for swipe).
- Swiping the default collection row reveals no destructive action.

---

## 5. Activities

### 5.1 Create activity 🖼

**Behavior**
- "Add activity" from the Collections "+" menu opens a sheet with sections: Activity, Time, Location, Completion, Collections.
- The Create button lives in the top-right of the toolbar; Cancel is top-left.

**Expectations**
- The Create button is disabled until: title is non-empty AND at least one collection is selected.
- Tapping Create shows a spinner in the toolbar in place of the button.
- On success, the sheet dismisses and the new activity is reflected in collection stats (after refresh).

### 5.2 Time dimension 🖼

**Behavior**
- Toggling "Has time" reveals a DatePicker (date + time).
- Toggling off hides the DatePicker — saved activity has no timestamp.

**Expectations**
- DatePicker is hidden when toggle is off.
- The chosen time is preserved through other field edits within the sheet.

### 5.3 Location dimension 🖼

**Behavior**
- Toggling "Has location" reveals: Apple Maps search, suggestion rows, "Use current location" button, custom name field, and a selected-location row.
- The custom name field placeholder is **"Enter custom name"** — it is never autofilled.
- The selected-location row shows the resolved Apple Maps name (e.g. "Eiffel Tower"), not coordinates.
- An "X" button on the selected-location row clears the location entirely.

**Expectations**
- Typing in the search field shows up to N suggestions.
- Tapping a suggestion replaces the selected-location row with that location's resolved name and clears the search field.
- The custom name field remains empty after selecting a search result.
- "Use current location" triggers a permission prompt on first use; on success the selected-location row shows "Current location".
- Clearing (X) removes the resolved name, coordinates, and any custom name.

**Edge cases**
- If location permission is denied or unavailable, the error message surfaces inline (not crash).
- An entered custom name takes precedence over the resolved name when the activity is saved.

### 5.4 Completion dimension 🖼

**Behavior**
- "Track completion" toggle reveals a "Completed" toggle.
- An activity without completion tracking has no checkbox shown elsewhere in the app.

**Expectations**
- Toggling off "Track completion" hides "Completed" and the saved activity has no completion state.

### 5.5 Collection multi-select 🖼

**Behavior**
- A "Collections" section lists all collections for the current progress.
- Each row has a checkmark for selected collections.
- The default collection is auto-selected when opening Create (not for Edit).
- The header shows "N selected" when at least one is checked.
- The footer warns "Select at least one collection." when none are checked.

**Expectations**
- Tapping a row toggles its membership.
- Create is disabled when zero collections are selected.
- On save, the activity is reflected as a member of every selected collection.

### 5.6 Edit activity 🖼

**Behavior**
- Tapping an activity (from collection detail, from calendar daily list, from a map pin's "Edit details") opens the Edit sheet.
- Edit pre-fills every field from the existing activity.
- A red Delete section with confirmation appears at the bottom.

**Expectations**
- Pre-filled state matches the persisted activity (title, notes, time, location, completion, collections).
- Removing all collections then saving is allowed (activity becomes "unfiled").
- Delete asks for confirmation and removes the activity from every list it appeared in.

---

## 6. Calendar tab

### 6.1 Month grid 🖼

**Behavior**
- Calendar tab shows a month grid with prev / next chevrons and the month/year + progress title.
- Days with activities have a blue dot indicator.
- Today has a blue outline; selected day has a filled blue background.

**Expectations**
- Chevrons navigate by ±1 month.
- Tapping a day selects it and reveals that day's activity list below.
- The dot indicator only appears on days that have at least one timed activity in the active progress.

### 6.2 Day's activity list 🖼

**Behavior**
- Below the grid, the selected day's activities are listed sorted by time.
- Each row shows title, time, and (when applicable) location + completion icons.

**Expectations**
- Tapping a row opens the Edit activity sheet.
- Swipe left on a row reveals a red Delete action.
- Empty day shows "No activities · Tap + to add one."

### 6.3 Add activity from calendar 🖼

**Behavior**
- The "+" toolbar button opens the Create Activity sheet.
- The time dimension is **pre-toggled on**, and the timestamp is **pre-filled to the selected day** at the current time of day.

**Expectations**
- Creating an activity with the default fields adds a dot to the selected day in the grid.
- The user can still toggle off time, in which case the activity won't appear in the calendar afterward.

### 6.4 Collection filter 🖼

**Behavior**
- The top-left toolbar shows a "collection filter" menu. Default selection is **"All collections"** (no filter).
- The menu lists every collection for the active progress, with "All collections" pinned at the top.
- The menu's label is a constant icon (`line.3.horizontal.decrease.circle` + a small chevron). It does NOT change to reflect the selected collection — the current selection is shown inside the menu.

**Expectations**
- When set to "All collections", both the month-grid dot indicators and the daily activities list include every timed activity for the active progress.
- Selecting a specific collection hides dots and rows for activities not in that collection.
- Switching to a different progress on the Home tab resets this filter to "All collections".
- Deleting the currently-selected collection elsewhere resets this filter to "All collections" automatically (no stale selection).
- The top-left label width is fixed regardless of collection name length.

---

## 7. Map tab

### 7.1 Pin display 🖼

**Behavior**
- The Map tab plots one pin per activity that has location data.
- Pin icon and color depend on completion / time status:
  - Completed: green checkmark
  - Pending (not completed but tracked): orange circle
  - Timed only: blue clock
  - Default: red pin

**Expectations**
- Activities without location coordinates do not produce a pin.
- The annotation's label uses the activity's `locationName` if set, otherwise the title.

### 7.2 Camera auto-fit + recenter 🖼

**Behavior**
- On first data load, the camera region auto-fits to contain all pins (with padding).
- A floating "scope" button in the bottom-right re-fits the camera to all pins on demand.
- Subsequent listener updates do NOT automatically re-center.

**Expectations**
- Auto-fit only fires once per appearance — adding new activities doesn't jolt the camera.
- Tapping the recenter button re-centers, regardless of where the user panned to.
- The recenter button is hidden when there are no pins.

### 7.3 Pin menu (collection assignment) 🖼

**Behavior**
- Tapping a pin opens a menu listing every collection for the current progress + an "Edit details" item.
- Each collection row has a checkmark when the activity already belongs to it.

**Expectations**
- Tapping a checked collection removes the activity from that collection.
- Tapping an unchecked collection adds it.
- "Edit details" opens the Edit Activity sheet for that pin.
- The menu shows "No collections yet" when the progress has zero collections.

### 7.4 Search bar 🖼

**Behavior**
- A search overlay sits at the top of the map.
- Typing shows up to 5 Apple Maps suggestions in a card below the field.
- An "X" button clears the query and dismisses suggestions.

**Expectations**
- Selecting a suggestion: camera pans to the location, a **purple "+"-style preview pin** drops at the location, the search query clears.
- Tapping the purple preview pin opens the Create Activity sheet pre-filled with the location (name + coords); the custom name field stays empty with the "Enter custom name" placeholder.
- Dismissing the Create sheet (save or cancel) removes the purple preview pin.

### 7.5 Add via toolbar `+` 🖼

**Behavior**
- The toolbar "+" opens Create Activity with the location dimension pre-toggled and the current device location auto-fetched on appear.

**Expectations**
- On first use the location permission prompt appears.
- After permission is granted, the selected-location row shows "Current location" and the coords are populated.

### 7.6 Empty state 🖼

**Behavior**
- When there are no pins and no active search, a top overlay shows "No locations yet · Tap + to add an activity, or search to drop a preview pin."

**Expectations**
- Empty state disappears as soon as at least one pin exists or a search is in progress.

### 7.7 Collection filter 🖼

**Behavior**
- The top-left toolbar shows a "collection filter" menu. Default selection is **"All collections"** (no filter).
- The menu lists every collection for the active progress, with "All collections" pinned at the top.
- The menu's label is a constant icon (`line.3.horizontal.decrease.circle` + a small chevron) — same symbol as the Calendar tab's filter for consistency. It does NOT change to reflect the selected collection.

**Expectations**
- When set to "All collections", every activity with a location is plotted.
- Selecting a specific collection hides pins that don't belong to that collection.
- The camera re-fits to the visible pins whenever the filter changes (so a small filtered set fills the screen).
- Switching to a different progress on the Home tab resets this filter to "All collections".
- Deleting the currently-selected collection elsewhere resets this filter to "All collections" automatically.
- The top-left label width is fixed regardless of collection name length.

---

## 8. Invitations

### 8.1 Send invitation (owner) 🖼

**Behavior**
- The owner opens "Send Invitation" sheet from the Home tab and types a recipient email.
- Lookup resolves the email to an existing user before sending.

**Expectations**
- The Send button is disabled when the email field is empty.
- A success message appears for ~1.5 seconds, then the sheet auto-dismisses.
- Sending to an email with no matching user surfaces "User with email X not found".
- Sending a second pending invitation to the same recipient for the same progress surfaces "You already sent an invitation to this user for this progress."

### 8.2 Receive / accept / decline (recipient) 🖼

**Behavior**
- The Activity tab shows pending invitations addressed to the current user.
- Each row shows progress title, sender display name (name OR email), and a status badge.
- Pending rows have Accept + Decline buttons.

**Expectations**
- Sender's display name shows the sender's `name` when set, otherwise their email.
- Accept dismisses the row (status moves to Accepted) and the new progress appears in the recipient's progress picker.
- Decline updates the row to "Declined" status and removes the action buttons.
- Non-pending invitations show only the status badge — no action buttons.

### 8.3 Revoke (owner-side) 🖼

**Behavior**
- The Invited Users panel (on Home, owner-only) lists each recipient the owner invited, with a status badge.
- Each Pending row has a red "Revoke" button.

**Expectations**
- Revoke updates the status badge to "Revoked" (gray); the row remains visible.
- Revoke button is hidden when status is Accepted, Declined, or Revoked.
- The recipient's view of the invitation reflects the new "Revoked" status on next refresh.

### 8.4 Status badges 🖼

**Behavior**
- All invitation views display a status badge per row.

**Expectations**
- Badge colors: Pending = orange, Accepted = green, Declined = red, Revoked = gray.
- Badge labels are exactly: "Pending", "Accepted", "Declined", "Revoked".

---

## 9. Roles and permissions

### 9.1 Owner-only UI 🖼

**Behavior**
- Certain UI on the Home tab is only visible to the progress owner.

**Expectations**
- The pencil (edit summary) icon is hidden for non-owners.
- The "Send Invitation" button is hidden for non-owners.
- The "Invited Users" panel is hidden for non-owners.
- The "Delete Progress" button is hidden for non-owners.

### 9.2 Collaborator visibility 🖼

**Behavior**
- An accepted collaborator can view and contribute to a shared progress.

**Expectations**
- After accepting an invitation, the progress appears in the collaborator's progress picker.
- The collaborator can add / edit / delete activities and collections (no UI gating on those).
- The collaborator cannot delete the progress itself, change the summary, or send their own invitations.

---

## 10. Navigation

### 10.1 Tab bar 🖼

**Behavior**
- Signed-in users see five tabs: Home, Calendar, Map, Activity, Profile.

**Expectations**
- Tabs are accessible in any order.
- The active tab persists across app foreground/background cycles.

### 10.2 Progress picker sync 🖼

**Behavior**
- Home, Calendar, and Map share a single "active progress" selection.

**Expectations**
- Switching progress in one tab updates the others' contents on next visit.
- An empty progress list shows the matching empty state in each tab (e.g. "Create a progress item in the Home tab to get started").

---

## 11. Cross-cutting input validation 🧩

**Behavior**
- Forms across the app share a common pattern: a Save / Create / Update button is disabled until required fields are valid.

**Expectations** (one test per form)
- The action button is disabled when its required text field is empty or whitespace-only.
- The action button is disabled while a save is in flight.
- A character-limit counter appears wherever a cap is enforced. Two styles:
  - **Truncating** — input is silently truncated at the cap; the counter goes **orange** at the cap. Used for short identifier-like fields (name, title, recipient, custom location name).
  - **Locking** — input may exceed the cap and the form locks its action; the counter goes **red** when over the cap. Used for the long-form summary field.

Forms with explicit character limits (all `name`-style limits share one constant — `TextLimits.name = 40`):

| Form | Field | Limit | Style | Counter position |
|---|---|---|---|---|
| Edit Summary | Summary | 120 (`TextLimits.summary`) | Locking | Section header (top right) |
| Edit Profile | Display name | 40 (`TextLimits.name`) | Truncating | Section header (top right) |
| Create Progress | Progress name | 40 | Truncating | Section header (top right) |
| Send Invitation | Recipient email | 40 | Truncating | Section header (top right) |
| Create / Edit Activity | Title | 40 | Truncating | Section header (top right) |
| Create / Edit Activity | Location custom name | 40 | Truncating | Inline (right of field, same row) |
