# Accessibility

The accessibility work is code, not commentary: every item below names the
widget/file where it is implemented. The theme-level contract
(`lib/core/theme/app_theme.dart`) plus per-widget semantics make the app
usable with TalkBack/VoiceOver, keyboard/switch access, and at large text
scales.

## Touch targets — 48 dp minimum on interactive elements

**Where:**

- `TaskListItem` (`lib/presentation/widgets/task_list_item.dart`): the
  completion checkbox is a 48×48 dp `SizedBox` wrapping a centered
  `Checkbox` inside an `InkWell` — the *tap area* is 48 dp even though the
  visible glyph is smaller.
- `TaskEditorScreen`: buttons use
  `minimumSize: const Size.fromHeight(52)` (FilledButton style) — above
  the 48 dp minimum.
- `AppTheme` component themes encode generous minimum sizes/padding for
  buttons, chips and list rows, so every consumer inherits the contract.

**Why it matters:** WCAG 2.5.8 / Material guidance — small visible
controls with small hit areas are the single most common mobile a11y
failure. Enlarging the *target*, not the glyph, keeps the design clean.

## State-following semantics labels

**Where:**

- `TaskListItem`'s checkbox:

  ```dart
  final checkboxLabel = task.isCompleted
      ? "Mark task '${task.title}' as not complete"
      : "Mark task '${task.title}' as complete";

  Semantics(
    label: checkboxLabel, checked: task.isCompleted, button: true,
    onTap: toggle,
    child: ExcludeSemantics(child: …Checkbox…),
  )
  ```

  The label updates with state, the `checked` flag carries the current
  value, and the inner checkbox's default semantics are excluded to avoid
  a double announcement ("checkbox, checkbox").
- `SyncStatusIcon` (`status_icon.dart`): every queue state
  (`synced/pending/syncing/failed`) maps to a distinct semantic label
  ("Synced", "Waiting to sync", "Syncing", "Sync failed") — the icon is
  informative but never interactive, so it needs a label, not a target.
- `DueDateChip` (`due_date_chip.dart`) and `PriorityChip`
  (`priority_chip.dart`): chips carry `Semantics` labels; overdue state is
  conveyed by color **and** label text.
- `ProjectsScreen` progress indicators carry count labels
  (e.g. "2 of 5 done") — never a bare bar.
- `SettingsScreen` sync row exposes the queue state as labeled
  semantics, not just an icon.

## Announcing errors — `errorText` + live regions

**Where:**

- Form validation follows the Flutter `FormField` contract:
  `Validators.taskTitle` / `projectName` return user-facing messages,
  the editor controllers put them into state
  (`TaskEditorState.titleError`), and the `TextFormField`s render them as
  `errorText:` — which the framework announces and associates with the
  field for assistive tech.
- Submission/storage failures are **live regions**: the task editor's
  error banner and the project editor dialog wrap their messages in
  `Semantics(liveRegion: true, …)` (`task_editor_screen.dart:379`,
  `project_editor_dialog.dart:160`), so a failed save is *announced*
  without the user having to find it.
- `ErrorView` (`error_view.dart`): the full-area error state is a
  `Semantics(liveRegion: true)` block with a retry button.
- `SyncStatusBanner` (`sync_status_banner.dart`): the message is a
  `liveRegion` — transitions from offline → syncing → synced (or failed)
  are announced as they happen, which is the whole point of a *visible*
  sync pipeline.

## Text scaling to 2.0× — reflow, never clip

**Strategy:** no fixed heights on content; layouts that reflow.

- `TaskListItem`'s meta line (due date, priority, project label) is a
  `Wrap` — at 2.0× the chips flow onto additional lines instead of
  overflowing the row. The title is `Expanded` with `maxLines: 2` +
  ellipsis.
- `TaskFilterBar` rows are `Wrap`s per chip row — the filter bar grows
  vertically instead of clipping.
- Every screen body is `Column` + `Expanded` (list inside) or
  `SingleChildScrollView` (editors) — no `SizedBox(height: …)` boxes
  around text.
- The priority selector is a horizontally scrollable `SegmentedButton`
  rather than a fixed-width row, and the project picker is a
  `DropdownButtonFormField` inside a `Form` — both reflow gracefully.
- `AppTheme` never clamps text (`maxLines` only where ellipsis is the
  intended behavior) and uses `TextScaler`-friendly spacing.

## Focus order & keyboard operability

- **Logical DOM order = logical reading order**: list rows are single
    `InkWell`s with the checkbox as a nested `Semantics(button:)`
  target — focus walks row → checkbox naturally.
- **All icon-only buttons have tooltips** (`tooltip: 'New project'`,
  edit/delete menu items, banner actions) — tooltips surface as
  accessibility labels for icon buttons with no visible text.
- Standard Material widgets throughout (`Checkbox`, `ChoiceChip`,
  `SegmentedButton`, `FilledButton`, `TextFormField`, `Switch`): switch
  access and keyboard traversal come from the framework components
  rather than custom gesture-only widgets.
- The editor uses a `Form` with validators — submitting with errors
  focuses the invalid field path (framework behavior) and announces via
  `errorText`.

## Filter chips semantics

- `TaskFilterBar` uses standard Material `ChoiceChip`s — selected state,
  "filter chip" role and label come built-in; each chip's label is the
  full human text ("Due today", "Urgent"), never an icon alone.
- The due-window chips (Any / Due today / Due this week / Overdue) and
  completion/priority chips compose with the shared filter state — the
  semantics stay consistent between the tasks screen and project detail
  pages because both render the *same* widget.

## Skeletons and loading states

- `ListSkeleton` wraps rows in `ExcludeSemantics` and announces one
  label ("Loading tasks") at the container level — a screen reader
  hears a single loading statement, not 8 unlabeled gray boxes.

## Dialogs and destructive actions

- `showConfirmDeleteDialog` (`confirm_delete_dialog.dart`) requires an
  explicit confirm button; the message explains the offline-first
  consequence ("deletions are stored locally and queued for the server")
  so screen-reader users are not surprised by async deletion behavior.
- Dialogs use standard `AlertDialog` buttons (barrier-dismissable,
  focus-trapped by the framework).

## Color contrast

- All colors come from the Material 3 scheme (one deep-green seed,
  light + dark in `AppTheme`) — container/on-container pairs meet
  contrast by construction, and the app supports the system dark mode
  (which also helps low-vision and situational readability).
- Error/overdue states use the `error`/`errorContainer` roles, never raw
  reds; sync-failure uses the same error roles as other failures for
  consistency.
- Information is never color-only: overdue = color + label text;
  priority = chip label + color; sync status = icon + semantic label.
