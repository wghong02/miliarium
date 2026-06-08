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
- The new progress starts with **no collections** — only the synthetic "All activities" row is shown until the user creates one.

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

### 3.4 Upcoming activity 🖼

**Behavior**
- The Home tab shows an "Upcoming activity" section below the progress title/summary.
- Lists every activity with a `timestamp` strictly in the future, sorted soonest-first, capped at 20 rows.
- The list is scrollable when it overflows its fixed maximum height.
- Each row shows the activity title, the formatted date/time, an optional location pin, and a notes preview line.

**Expectations**
- Activities without a `timestamp` (no time dimension) do NOT appear.
- Activities whose `timestamp` is in the past do NOT appear (they're history).
- Tapping a row opens the Edit Activity sheet for that activity.
- The list updates in real time as activities are added, edited, or have their time toggled.
- Empty state: "No upcoming activities".
- Section uses the same visual pattern as Sharing: leading divider, header with clock icon, no card background.

### 3.5 Delete progress 🖼

**Behavior**
- The owner taps "Delete Progress" → a system confirmation dialog (action sheet) appears with the title "Delete Progress?", a message explaining the action is irreversible, a destructive "Delete" button, and a "Cancel" button.
- While deletion is in flight, the "Delete Progress" button shows a spinner and is disabled.
- If deletion fails, a "Delete Failed" alert surfaces the error message with an "OK" dismiss button.

**Expectations**
- The Delete button only appears for the progress owner.
- Tapping "Cancel" in the confirmation dialog dismisses it without deleting anything.
- Confirming deletion removes the progress from the picker.
- A failed deletion surfaces an error alert (not a silent no-op).
- Collaborators do NOT see the Delete button.

---

## 4. Collections

### 4.1 List + filter 🖼

**Behavior**
- The Home tab shows a "Collections" section with a list of collections for the active progress.
- A **synthetic "All activities"** row is pinned to the top of the list when the filter is set to "All". It is NOT a real collection — it has no star, no swipe-delete, and no edit-details affordance. Tapping it opens §4.8.
- A filter row offers "All" vs "Favourites".
- Each real collection row has a star icon on the left: filled yellow star for favourites, unfilled star for non-favourites.
- Tapping the star icon toggles the collection's favourite status directly from the list (no need to open the edit sheet).

**Expectations**
- The "All activities" row is shown when filter = "All"; hidden when filter = "Favourites".
- Each collection row shows: star icon (filled if favourite, unfilled otherwise), collection name, and a stats line. There is no special "default" badge — every collection is equal.
- Tapping the star immediately persists the change; the icon updates when the listener reflects the write.
- The star is disabled while a toggle is in flight to prevent double-taps.
- Favourite collections sort first; others by creation order.
- Selecting "Favourites" hides non-favourite collections.
- Empty collections state (still shows the "All activities" row): "No collections yet · Tap + to create one".

### 4.2 Create a collection 🖼

**Behavior**
- The "+" button on the Collections section header opens the Create Collection sheet directly (no menu).
- The sheet has name (required), notes (optional), and a "Mark as favourite" toggle.

**Expectations**
- The Create button is disabled when the name is empty or whitespace-only.
- After save, the new collection appears in the list, with a filled star if marked as favourite.
- Adding an activity is handled by the Home tab's top-right toolbar button (§5.1), not from this section's header.

### 4.3 Collection detail sheet 🖼

**Behavior**
- Tapping a collection row (anywhere except the star) opens a **detail sheet**.
- The sheet title is the collection name (live — updates if renamed via Edit details).
- The first row is an **"Edit details"** row (blue slider icon + chevron). If the collection has notes, they are shown as a secondary line beneath "Edit details".
- Below that is a live **Activities** section listing every activity in the collection (newest first), with a count badge in the section header.
- The toolbar "+" opens Create Activity.

**Expectations**
- Tapping "Edit details" opens the Edit Collection sheet (§4.4).
- Tapping an activity row opens the Edit Activity sheet for that activity.
- Swipe left on an activity row → red "Remove" action. The activity is removed from the collection but **not deleted**.
- After a swipe-remove the row disappears; the activity still exists in other collections.
- Empty state ("No activities in this collection yet.") is shown when the collection has no members.
- A loading spinner appears while the activity list is being fetched.
- The sheet keeps the activity list in sync in real time — adding or removing activities elsewhere is reflected without closing and reopening the sheet.

**Edge cases**
- Removing the last activity from the collection shows the empty state without dismissing the sheet.

### 4.4 Edit collection metadata 🖼

**Behavior**
- Opened from the "Edit details" row inside the collection detail sheet (§4.3).
- Shows: name (required), notes (optional), favourite toggle, a Stats section, an Update button, and a Delete button.

**Expectations**
- The Update button is disabled when the name is empty or whitespace-only.
- Tapping Update saves and dismisses the edit sheet; the collection detail sheet reflects the new name/notes immediately (live listener).
- Toggling favourite re-sorts the home list (favourites move to the top) after the listener update.

### 4.5 Refresh stats 🖼

**Behavior**
- The Edit Collection sheet (§4.4) shows a Stats section: total, completed, with time, with location, first date, last date, and when the stats were last computed.
- A "Refresh stats" button recomputes from current activity membership.

**Expectations**
- Stats do NOT auto-update when activities are added/removed; the user must tap "Refresh stats".
- After tapping Refresh, the stats fields update in place and the "Updated" timestamp reflects "now".
- A spinner appears while the refresh is in flight; the button is disabled.

### 4.6 Delete a collection 🖼

**Behavior**
- The Edit Collection sheet (§4.4) offers a Delete button for every collection.

**Expectations**
- Tapping Delete shows a confirmation alert.
- Confirming dismisses both the edit sheet and the detail sheet, removing the collection from the home list.
- Activities that were in the collection still exist — they're just no longer listed under that collection. Activities orphaned by the delete still appear in the "All activities" view (§4.8).

### 4.7 Swipe-to-delete on rows 🖼

**Behavior**
- Swipe left on any collection row in the home list → red Delete action.
- The "All activities" row has no swipe action (it isn't a collection).

**Expectations**
- Swipe action triggers deletion (no extra confirmation needed for swipe).
- Swiping the synthetic "All activities" row reveals no actions.

### 4.8 All activities view 🖼

**Behavior**
- The synthetic "All activities" row at the top of the home list opens a sheet titled "All activities".
- The sheet lists every activity for the active progress (regardless of collection membership), newest first.
- A toolbar "+" opens Create Activity.
- Tapping a row opens the Edit Activity sheet.
- Swipe left on a row reveals a red **Delete** action that permanently removes the activity (it is also dropped from every collection it belonged to in the same atomic write).
- The list includes activities that belong to zero collections.

**Expectations**
- No "Edit details" row appears at the top — "All" is not a real collection.
- Swipe-to-delete is destructive: the activity is gone after a confirmed full swipe (no extra confirmation dialog, matching the Calendar tab's daily list).
- A failure to delete surfaces an inline red error message at the bottom of the list; the row remains visible.
- Adding or deleting an activity elsewhere is reflected in this list in real time.
- Empty state: `ContentUnavailableView` with title "No activities yet" and "Tap + to add your first activity."

---

## 5. Activities

### 5.1 Create activity 🖼

**Behavior**
- Multiple entry points open the same Create Activity sheet:
  - **Home tab** top-right `+` toolbar button — no pre-filled fields.
  - **Calendar tab** top-right `+` toolbar button — pre-fills the timestamp to the selected day at the current time of day.
  - **Map tab** top-right `+` toolbar button — no pre-filled fields.
  - **Map tab** purple preview pin (after selecting an Apple Maps search suggestion) — pre-fills latitude/longitude/locationName.
- The sheet has sections: Activity, Time, Location, Completion, Collections.
- The Create button lives in the top-right of the toolbar; Cancel is top-left.
- The Home top-right `+` is only shown when a progress is selected; the Calendar and Map `+` buttons are always shown (those tabs already require a selected progress to be useful).

**Expectations**
- The Create button is disabled until the title is non-empty (whitespace doesn't count).
- Collection selection is **optional**. Activities created with zero collections still appear in the "All activities" view (§4.8).
- Tapping Create shows a spinner in the toolbar in place of the button.
- On success, the sheet dismisses and the new activity is reflected in collection stats (after refresh) for any collections it was added to.
- The activity document includes a `createdBy` field set to the current user's ID. This is used by the push notification Cloud Function (§14.2) to attribute the notification and exclude the creator from receiving it.

### 5.2 Time dimension 🖼

**Behavior**
- The Time section is **always visible** — there is no top-level toggle that gates it. Four rows are shown by default:
  - **Start date** — placeholder `-/-/--` until filled, then a `DatePicker` + an "X" clear button.
  - **Start time** — placeholder `--:--` until filled. Hidden when "All day" is on.
  - **End date** — placeholder `-/-/--` until filled.
  - **End time** — placeholder `--:--` until filled. Hidden when "All day" is on.
- A single **"All day"** toggle sits at the top of the section. When enabled, time rows disappear and the saved `timestamp` / `endTimestamp` are normalized to start-of-day.
- Date and time are independently settable — the user can set a date only (treated as start-of-day) or a date AND a time.
- Tapping any placeholder marks that field as set and reveals the picker; tapping the X clears it back to the placeholder.

**Expectations**
- Activities with no date set save with `timestamp == nil` (no time dimension).
- Activities with only a start date set save with `timestamp == startOfDay(date)`.
- Activities with a start date + start time save with `timestamp` combining both.
- Same rules for end. An end date may be set independently — the time portion defaults to midnight if no end time is added.
- "All day" is persisted as `isAllDay: true` in Firestore; reads back as the original mode on Edit.
- Inline red **"End must be after start."** locks the action button when both are set and `end <= start`.
- Inline red **"Set a start date before adding an end."** locks the action button if the user tries to set only an end without a start.
- On Edit, the sheet splits the stored `timestamp` and `endTimestamp` back into independent date+time pairs and marks each field as set. All-day activities mark only the date fields as set.

**Display in Calendar daily list**
- All-day single day: `"All day"`.
- All-day cross-day: `"May 31 – Jun 2"`.
- Timed no end: `"9:00 AM"`.
- Timed same-day range: `"9:00 AM – 10:30 AM"`.
- Timed cross-day range: `"May 31, 9:00 AM – Jun 1, 2:00 PM"`.

**Edge cases**
- Existing activities (pre-`isAllDay`) parse with `isAllDay == false` — `Firestore.Bool ?? false` is the fallback.
- Removing all time data is a valid update — Firestore drops the `timestamp`, `endTimestamp`, and `isAllDay` fields on save.

### 5.3 Location dimension 🖼

**Behavior**
- The Location section is **always visible** — no top-level toggle. Three input rows are shown by default:
  - **Apple Maps search field** (with suggestion list) — empty placeholder until the user types.
  - **"Use current location"** button.
  - **Custom name** text field — placeholder "Enter custom name", never autofilled.
- A fourth row, the **selected-location display**, appears only once `latitude` AND `longitude` are set. It shows the resolved Apple Maps name (or "Current location" for a GPS-fetched coord), and an "X" button to clear everything back to the empty state.

**Expectations**
- Typing in the search field shows up to N suggestions.
- Tapping a suggestion fills `latitude`/`longitude`/`resolvedLocationName`, and the selected-location row appears.
- "Use current location" triggers a permission prompt on first use; on success the selected-location row shows "Current location".
- Clearing (X) removes the resolved name, coordinates, and any custom name — the section returns to its empty state but stays visible.
- An entered custom name takes precedence over the resolved name when the activity is saved.
- Saving with no location data leaves all location fields nil in Firestore.

**Edge cases**
- If location permission is denied or unavailable, the error message surfaces inline (not crash).
- Editing an existing activity with a location pre-fills the resolved name in the selected-location row; the custom name field starts empty so the user can override.

### 5.4 Completion dimension 🖼

**Behavior**
- The Completion section is **always visible** — no top-level toggle. It contains a single inline **menu picker** labelled "Status" with three options:
  - **Not tracked** (default) — the activity is not completion-tracked. Saves as `isCompleted == nil`.
  - **Pending** — the activity tracks completion but is not yet done. Saves as `false`.
  - **Completed** — the activity is done. Saves as `true`.
- The picker uses `.menu` style so the current choice is shown inline with a dropdown caret.

**Expectations**
- New activities default to "Not tracked".
- Picking "Pending" or "Completed" makes the activity show its check-circle icon in other UI (collection rows, map pins, calendar rows).
- Switching back to "Not tracked" removes the icon and saves `isCompleted == nil`.
- On Edit, the picker pre-fills with `CompletionChoice.from(activity.isCompleted)` — nil ⇒ "Not tracked", false ⇒ "Pending", true ⇒ "Completed".

### 5.5 Collection multi-select 🖼

**Behavior**
- A "Collections" section lists all collections for the current progress.
- Each row has a checkmark for selected collections.
- No row is pre-selected — the user explicitly picks zero or more collections.
- The header shows "N selected" when at least one is checked.
- The footer always reads: "Optional. Activities without a collection still appear in 'All activities'."

**Expectations**
- Tapping a row toggles its membership.
- Selecting zero collections is allowed; the activity becomes "unfiled" and only appears in the "All activities" view (§4.8).
- On save, the activity is reflected as a member of every selected collection (which may be the empty set).

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
- On map appear the app requests location permission (if not yet determined) and fetches the current device location.
- Initial camera priority: **1) device location** (city-level zoom, ~15 km span), **2) the next upcoming activity that has both a time AND a location** (city-level zoom on its pin), **3) the most recently added activity that has a location** (city-level zoom on its pin), **4) automatic** (no pins exist at all).
- "Next upcoming" means soonest by timestamp, restricted to the active collection filter, and only considers activities whose timestamp is in the future.
- "Most recently added" means the activity with the greatest `createdAt`, restricted to the active collection filter and to activities that have a location.
- If device location is obtained after the pins have already set the initial view, the camera still re-centers on the device location (location always wins for the first camera placement).
- A yellow warning banner is shown when location access is denied or restricted.
- A floating "scope" button in the bottom-right fits the camera to the bounding box of all visible pins on demand (clamped to 15–50 km span). This is the only path that uses the "fit-all" behavior — the initial-camera priority does not.
- Subsequent listener updates (new/removed pins) do NOT automatically re-center.

**Expectations**
- The camera centers on the device's current location (with ~15 km span) whenever location is available.
- When location is unavailable but an upcoming-with-location activity exists, the camera centers on that activity's pin.
- When location is unavailable and no upcoming-with-location activity exists, the camera centers on the most recently added activity that has a location.
- The initial camera is never the "fit-all-pins" bounding box — only the explicit recenter button uses that.
- Adding new activities after initial load doesn't jolt the camera.
- Tapping the recenter button re-fits to all visible pins.
- The recenter button is hidden when there are no pins.
- Location warning banner appears when permission is denied; it does NOT appear for a GPS failure.

**Edge cases**
- Collection filter changes re-fit the camera to the newly visible subset of pins (this path still uses fit-all, since the user explicitly changed what's visible).
- An upcoming activity whose timestamp passes between listener updates is not "demoted" mid-session — the camera doesn't move; the priority only governs the *initial* camera placement.
- The fallback chain respects the active collection filter at every step: only pins in the currently-selected collection contribute to "next upcoming" and "most recently added".

### 7.3 Pin menu (collection assignment + delete) 🖼

**Behavior**
- Tapping a pin opens a menu listing every collection for the current progress, an "Edit details" item, and a destructive "Delete" item.
- Each collection row has a checkmark when the activity already belongs to it.
- Selecting "Delete" presents a confirmation dialog ("Delete this activity?") with a destructive Delete button and a Cancel button; the activity title is quoted in the message.

**Expectations**
- Tapping a checked collection removes the activity from that collection.
- Tapping an unchecked collection adds it.
- "Edit details" opens the Edit Activity sheet for that pin.
- "Delete" → confirmation dialog → confirming permanently removes the activity from the progress (and from every collection it belonged to in the same atomic write). Cancelling leaves the activity untouched.
- A failed delete surfaces an error message in the map's top overlay (not a silent no-op).
- The menu shows "No collections yet" when the progress has zero collections; the "Edit details" and "Delete" items remain available in that case.

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
- The toolbar "+" opens the standard Create Activity sheet with no pre-filled location.
- The user can manually toggle "Add a location" and pick a location from search or use the "Current location" button.

**Expectations**
- The Create Activity sheet opens with the location dimension toggled **off** (not pre-filled).
- Location permission is handled by the map tab on appear (§7.2), not on "+" tap.

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

---

## 12. Home-screen widgets

All widgets ship inside the main app's `.ipa`. The user adds them once from the home-screen widget gallery (long-press → `+` → search "Miliarium"). All snapshot data is written by the main app to a shared App Group container (`group.miliarium.shared`) and read by each widget's `TimelineProvider`. No network calls happen in the widget extension itself.

### 12.1 Upcoming activities (small) 🖼

**Behavior**
- `systemSmall` widget titled "Upcoming activities" in the gallery.
- Renders up to **3** activities, soonest first, across **all** the user's progresses (no collection filter).
- Each row shows the activity title + a relative time string ("in 2 hr").
- A small `mappin.circle.fill` glyph appears on rows whose activity has a location.

**Expectations**
- The widget reflects writes to *any* progress's activities within seconds of the main app being foreground when the change happens (the app calls `WidgetCenter.reloadAllTimelines()` after each snapshot rebuild).
- As each activity's timestamp passes, the row falls off the widget and the remaining ones roll up — this happens via pre-scheduled timeline entries, not refresh budget.
- Empty state copy: "Nothing scheduled".
- When the user signs out of the main app, the widget shows the empty state.

**Edge cases**
- An activity with no `timestamp` does not appear, even if marked completable.
- An activity whose timestamp is in the past does not appear.
- A progress the user is no longer linked to (revoked invitation, etc.) is excluded the next time the main app refreshes the snapshot.

### 12.2 Nearby activities (medium) 🖼

**Behavior**
- `systemMedium` widget titled "Nearby activities" in the gallery.
- Renders a `MapKit` map of up to **10** activities **that have a location AND are not marked complete**, sorted by distance from the user's last known device location.
- A floating capsule overlay in the top-left shows "Nearby · N" where N is the visible item count.
- A blue dot annotation marks the reference point (the user's last known location).
- Activity pins are red `mappin.circle.fill` markers.

**Expectations**
- "Not marked complete" means `isCompleted != true` — activities that don't track completion (`isCompleted == nil`) AND activities marked pending (`isCompleted == false`) both appear. Only `isCompleted == true` is excluded.
- "Nearby" is determined by straight-line distance (`CLLocation.distance(from:)`) from the cached device location.
- The reference point updates whenever `MapView` performs a successful GPS read.
- The map auto-fits to a bounding box of all visible pins + the user's location, clamped to a minimum span so a single nearby pin doesn't zoom to street level.

**Three render states**
1. **No reference point** — the user has never granted location or never opened the Map tab since install. Empty-state copy: "Open the app to share location."
2. **Reference point but no incomplete-located activities** — the map renders centered on the user with a "Nothing nearby to do" pill overlay.
3. **Reference point + incomplete-located activities** — the map renders all the pins plus the user dot.

**Edge cases**
- Marking an activity complete in the app removes it from the widget on the next snapshot rebuild.
- Removing the location dimension from an activity removes it from the widget.
- Signing out clears the reference point and resets the widget to state 1.

### 12.3 Snapshot pipeline (shared across widgets) 🧩

**Behavior**
- The main app's `WidgetSnapshotService` maintains one Firestore listener per accessible progress, mirroring the per-progress structure of `UpcomingActivityView`. On any listener fire (including the initial one) it rebuilds **every** snapshot file in the App Group container, then calls `WidgetCenter.reloadAllTimelines()`.
- `MapView` additionally calls `widgetSnapshotService.rebuildSnapshots()` after a successful GPS read so the nearby snapshot's reference point updates without waiting for an unrelated Firestore change.

**Expectations**
- Adding, editing, or deleting an activity in any progress refreshes both widgets within seconds.
- Signing out triggers a `stop()` that clears every snapshot file and tears down all listeners.
- A re-sign-in re-establishes listeners on the next `progressStore.progresses` change.

---

## 13. Onboarding

### 13.1 Welcome sheet 🖼

**Behavior**
- On the first authenticated launch where `UserDefaults` does not yet have the `hasSeenWelcome` flag set, a sheet appears with **3** paginated pages.
- Pages are: (1) "Welcome to Miliarium" intro, (2) "Start with a Progress" explainer, (3) "Activities & Collections" explainer.
- Each page shows a large hierarchical SF Symbol, title, and body text.
- A **Next** button advances to the next page; on the final page it becomes **Get started** and dismisses the sheet.
- A small **Skip** link in the top-right is visible on every page *except* the last.
- Sheet supports swipe-down dismissal.

**Expectations**
- Any dismissal path (Get started, Skip, or swipe-down) sets `hasSeenWelcome` in `UserDefaults` — the sheet never reappears on the same device.
- Signing out and signing back in does not re-present the sheet.
- Uninstalling and reinstalling the app *will* re-present it (UserDefaults is cleared).

### 13.2 Tutorial banner (Home tab) 🖼

**Behavior**
- After the welcome sheet is dismissed (and at any subsequent Home tab visit while the tutorial hasn't yet been dismissed), a small blue-tinted banner appears above the home content listing the user's current step.
- The banner shows: a step icon, "Step *N* of 3" label, the instruction text, and a small `xmark` button on the right to permanently dismiss the tutorial.
- The three steps in order:
  1. **Create your first progress** — instructs to use the top-left picker.
  2. **Create your first collection** — instructs to use the `+` on the Collections section.
  3. **Add your first activity** — instructs to use the `+` in the top-right toolbar.
- Step advancement is automatic via real-time Firestore listeners on the active progress's `collections` and `activities` sub-collections — no per-step "Next" button.
- The banner animates in/out (fade + slide from top) when the step changes or it disappears.

**Expectations**
- The banner is hidden whenever the computed step is `.done` (all three completed, OR user has tapped X, OR user is an existing user with pre-existing data).
- Tapping the X sets `hasDismissedTutorial` in `UserDefaults` and tears down the onboarding listeners — the banner never reappears even if the user later deletes everything.
- Completing all three steps without explicit dismissal does *not* set the dismissed flag — if the user later deletes everything and ends up with zero collections/activities on a new progress, the banner can reappear (rare case, accepted as a tradeoff).
- The step is recomputed against the *currently selected* progress's counts — switching to a different empty progress while the tutorial is active reverts the banner to step 2 or 3 as applicable.

**Edge cases**
- A user with existing data (e.g. migrating from a pre-onboarding version) sees the welcome sheet but the banner is immediately `.done` and never appears — their `progressCount > 0`, `collectionCount > 0`, `activityCount > 0` from the first listener fire.
- The Home banner does not appear on Calendar, Map, Activity, or Profile tabs — those tabs have their own one-time hint banners (§13.3).
- If the active progress has not yet been selected (e.g. just after sign-in, before the first listener fires), the banner can momentarily show step 1 even when progresses exist; it self-corrects on the next listener fire (under a second).

### 13.3 Per-tab hint banners 🖼

**Behavior**
- The first time the user opens **Calendar**, **Map**, or **Activity**, an informational banner appears at the top of that tab explaining what the tab is for. Each banner is dismissible via an `xmark` and is **independent** of the Home tab's step machine.
- Visually identical to the Home tutorial banner (same blue-tinted card style) so users learn one pattern.

**Calendar tab hint**
- Icon: `calendar`. Title: "Activities with a time".
- Body explains that activities with a date and time appear here as dots, and the `+` adds a new one pre-filled to the selected day.

**Map tab hint**
- Icon: `mappin.circle.fill`. Title: "Activities with a location".
- Body explains that located activities show up as pins, the search bar drops a preview pin, and tapping an existing pin lets the user move collections / edit / delete.
- Presented as a **modal sheet** (not a banner) that slides up from the bottom on the first Map tab visit. Uses a small detent (`~0.35`) so the map remains visible behind it, and `presentationBackgroundInteraction(.enabled)` so the map stays tappable. Sheet has a "Got it" CTA, a drag indicator at the top, and is dismissible by swipe-down — any dismissal path marks the hint as seen.

**Activity tab hint**
- Icon: `envelope.fill`. Title: "Invitations & collaboration".
- Body explains that invitations from people sharing their progress arrive here (accept to collaborate, decline to dismiss), and that future notification types will surface in the same place.

**Expectations**
- Each banner appears at most once per device — dismissal sets a separate `UserDefaults` flag (`hasSeenCalendarHint`, `hasSeenMapHint`, `hasSeenActivityHint`).
- The three flags are **independent** — dismissing the Calendar hint has no effect on the Map or Activity hints.
- Sign-out / sign-in does not re-present any of them.
- For Calendar and Activity, the hint stacks **above** the tab's main content (pushing the content down). For Map, the hint is a **bottom-detent modal sheet** so the map keeps the full screen — it auto-presents on first appear and is dismissed via "Got it" or swipe-down.

**Edge cases**
- Existing users (pre-onboarding) see each hint exactly once the first time they open the respective tab after updating.
- For tabs that require a selected progress to be useful (Calendar, Map), the hint still shows in the "no progress yet" empty state — it's tab-level guidance, not progress-scoped.

### 13.4 Show tutorial again (Profile tab) 🖼

**Behavior**
- The Profile tab has a "Help" section containing a single row: **"Show tutorial again"** (blue `questionmark.circle` icon).
- A footer beneath the row reads: "Resets the welcome sheet and the per-tab hint banners so they appear again."
- Tapping the row clears all six onboarding `UserDefaults` flags: `hasSeenWelcome`, `hasDismissedTutorial`, `hasSeenCalendarHint`, `hasSeenMapHint`, `hasSeenActivityHint`, `hasSeenActivitySheetHint`.

**Expectations**
- The welcome sheet (§13.1) reappears immediately — `ContentView` observes the `hasSeenWelcome` flip and presents the sheet over the current tab.
- The Home tab tutorial banner (§13.2) reappears the next time the user visits the Home tab (or immediately if they're already on it), starting from whichever step is currently incomplete (or staying hidden if all 3 steps are already done — resetting doesn't undo the user's real progress / collection / activity creation).
- The Calendar, Map, and Activity tab hints (§13.3) reappear the next time the user visits each respective tab.
- The action is a single tap — no confirmation alert, no destructive role — since it only changes UI flags and creates no risk of data loss.

### 13.5 Activity sheet hint 🖼

**Behavior**
- The first time the user opens **Create Activity** OR **Edit Activity**, a small blue-tinted hint Section appears at the top of the form.
- Title: **"Only the title is required"**. Body: *"Every other field is optional — tap any placeholder ("-/-/--", "--:--", "Enter custom name") to fill it in, or leave it empty. You can edit any of these later."*
- A dismiss `xmark` on the right marks `hasSeenActivitySheetHint` in `UserDefaults` and animates the section out.

**UI signals that fields are optional / required**
- **Title** field's placeholder reads **"Title (required)"** — visible until the user types. The Create / Update button is disabled when the title is empty.
- **Time** rows use dash placeholders (`-/-/--` for date, `--:--` for time). Tapping a placeholder marks the field as set and reveals a `DatePicker`. An X clears it back to the placeholder.
- **Location** placeholders: the search field is empty, "Use current location" is just a button, custom name shows "Enter custom name". The selected-location row only appears once coordinates are set.
- **Completion** defaults to a "Not tracked" menu choice — the alternative options ("Pending" / "Completed") are revealed via the picker.

**Expectations**
- The hint Section is shown once per device. Dismissing it (xmark) sets the flag; further opens of the sheet show the form without the hint.
- The same flag (`hasSeenActivitySheetHint`) is shared between Create and Edit — dismissing in one suppresses both.
- The flag is included in the "Show tutorial again" reset (§13.4) — resetting onboarding makes the hint reappear the next time either sheet is opened.

**Edge cases**
- Existing users (pre-feature) see the hint the next time they open either activity sheet, until they dismiss it.

---

## 14. Push Notifications

Push notifications are dispatched by Cloud Functions (Firebase Gen 2) hosted
in the `miliariumBackend` repository. The iOS app registers for remote
notifications, stores device tokens in Firestore, and receives push payloads
via APNs. No in-app notification UI is defined — the system notification
center handles display.

### 14.1 Device token lifecycle

**Behavior**
- On sign-in (or app launch when already signed in), the app requests
  notification permission from the user. If granted, iOS registers for
  remote notifications and delivers an APNs device token.
- The token is stored in Firestore at `users/{userId}/deviceTokens/{tokenHexString}`
  with metadata: `token`, `userId`, `platform`, `appVersion`, `osVersion`,
  `createdAt` (first write only), `lastSeenAt` (every sync).
- On sign-out, the device's token document is deleted from the previous
  user so they no longer receive pushes on this device.
- Multiple devices per account are naturally supported — each device writes
  its own token document.

**Expectations**
- A fresh sign-in on a new device creates a new token document.
- Re-launching the app on the same device updates `lastSeenAt` and
  `appVersion`/`osVersion` without overwriting `createdAt`.
- Sign-out removes exactly one token document (this device), leaving other
  devices unaffected.
- If the user denies notification permission, no token is stored and the
  app remains fully functional without push.

**Edge cases**
- If iOS delivers a token before the user has signed in, it is cached
  in memory and synced to Firestore as soon as sign-in completes.
- Stale or invalid tokens are cleaned up server-side by the Cloud
  Functions after a failed send attempt (§14.2, §14.3).

### 14.2 Invitation notification (Cloud Function: `onInvitationCreated`)

**Behavior**
- When an invitation document is created in `invitations/{invitationId}`,
  a Cloud Function sends a push notification to the recipient.
- The notification reads: **"[Sender name] invited you to collaborate on
  '[progress title]'"**, where sender name is resolved from
  `users/{fromUserId}` (`name` field, falling back to `email`, then
  "Someone").

**Expectations**
- Only the recipient (`toUserId`) receives the notification.
- The sender does not receive a notification about their own invitation.
- The notification includes a data payload with `invitationId` and
  `type: "invitation"` for potential deep linking.
- If the recipient has multiple devices, all receive the notification.
- If the recipient has no registered device tokens, the function exits
  silently (no error).
- Failed/invalid tokens are deleted from Firestore after a send failure
  so subsequent notifications skip stale devices.

### 14.3 Activity notification (Cloud Function: `onActivityCreated`)

**Behavior**
- When a new activity document is created at
  `progressItems/{progressItemId}/activities/{activityId}`, a Cloud
  Function sends a push notification to all other collaborators on that
  progress.
- The notification reads: **"[Creator name] added '[activity title]'"**,
  where creator name is resolved from `users/{createdBy}` (`name` field,
  falling back to `email`, then "Someone").
- Collaborators are identified by querying the `progressLinks` collection
  group for documents with `progressItemId` matching the activity's parent
  progress.

**Expectations**
- The activity creator (`createdBy`) is excluded from the notification.
- All other users with a `progressLinks` document for that progress
  receive the notification.
- The notification includes a data payload with `progressItemId`,
  `activityId`, and `type: "activity"` for potential deep linking.
- If no other collaborators exist (solo progress), the function exits
  silently.
- Failed/invalid tokens are cleaned up server-side after send failures.
