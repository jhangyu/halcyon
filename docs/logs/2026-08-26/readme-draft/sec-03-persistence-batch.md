## Persistence, resume and batch actions

### A culling session is never lost

Close Halcyon mid-folder, reopen the same folder later, and it comes back on the same
photo with every star and trash mark intact. Marks are not held only in memory: each
mutation is written to a status file next to the photos, and the last-viewed photo is
restored on the next open.

#### The status file

Every folder Halcyon opens gets its own `.halcyon_status.json`, written at the folder
root next to the photos it describes.
<!-- evidence: lib/services/library/photo_status_store.dart:22-24 -->
It is a flat JSON object: each photo id (its filename) maps to `"starred"` or
`"trashed"` — unmarked photos are simply absent, not written as `"unmarked"` — plus two
reserved keys, `_last_viewed_id` for resume and `_rename_rule` for the folder's saved
rename pattern.
<!-- evidence: lib/services/library/photo_status_store.dart:18,132-148 -->
Plain JSON was chosen over a database so the file sits directly in the photo folder,
travels with it when copied to another machine or backed up, and is human-readable in
a diff.
<!-- evidence: memory.md AD-004 -->

Because the file lives inside the folder rather than in a central app database, each
folder's marks are self-contained: opening a second folder starts a second, independent
`.halcyon_status.json`, and shoots never bleed marks into each other.
<!-- evidence: lib/services/library/photo_status_store.dart:22-24 -->

A corrupt or unreadable status file degrades to an empty set of marks rather than
blocking the folder from opening at all — losing marks is recoverable, losing access to
the photos is not.
<!-- evidence: lib/services/library/photo_status_store.dart:34-53 -->

#### Resume on reopen

On reopening a folder, Halcyon restores the previously selected photo: if no explicit
selection target is given, it falls back to the id stored under `_last_viewed_id`,
provided that photo still exists in the freshly scanned folder.
<!-- evidence: lib/providers/app_state.dart:291-316 -->
The pointer is saved five seconds after navigation settles on a photo, debounced so
that rapid arrow-key browsing does not write on every keystroke.
<!-- evidence: lib/providers/app_state.dart:342-343,394-400 -->

#### Durability: atomic writes, one writer at a time

Two independent timers in the app can each want to write this file — one for star/trash
marks, one for the last-viewed pointer — and both do a read-modify-write. Serializing
every write through a single queue means a save that started earlier can never finish
later and clobber a change the other timer already wrote.
<!-- evidence: memory.md G-019 -->
<!-- evidence: lib/services/library/photo_status_store.dart:55-66 -->
Every write itself lands via a temp-file-then-rename, so pulling the memory card or a
crash mid-write can never leave a half-written status file behind — the folder always
has either the old complete file or the new complete file, never a torn one.
<!-- evidence: lib/services/library/photo_status_store.dart:68-76 -->

#### Read-only folders are detected honestly

Directory permission bits are unreliable on some mounts — an exFAT card can report a
writable-looking mode while its physical write-lock switch makes every write fail.
Halcyon does not trust the bits: it probes writability by actually creating and
deleting a small file in the folder, and only then surfaces a one-time warning if the
folder turns out to be read-only.
<!-- evidence: lib/services/library/photo_status_store.dart:78-91 -->
<!-- evidence: memory.md AD-009 -->
<!-- evidence: memory.md G-006 -->

#### Renaming and marks

Marks are keyed by filename, not by any other identity. If photos are renamed by a
tool that does not go through Halcyon's own rename feature, the marks tied to their old
filenames are silently orphaned — they stop matching any photo in the folder.
Halcyon's own rename feature avoids this by remapping every key in the status file to
the new filename as part of the rename operation, so stars, trash marks and the resume
pointer all survive a rename performed inside the app.
<!-- evidence: memory.md G-011 -->
<!-- evidence: lib/services/library/photo_status_store.dart:185-203 -->

### Batch actions

#### Copy and move starred photos

Starred photos can be copied or moved as a batch to a chosen destination folder.
<!-- evidence: lib/services/library/photo_file_actions.dart:50-87 -->
A RAW file and its same-named JPG sibling travel together as one unit — the item, not
the individual file, is what carries the starred mark — and an AppleDouble sidecar file
that macOS creates on some volumes (exFAT, network mounts) is cleaned up alongside it
rather than left behind at the destination.
<!-- evidence: lib/services/library/photo_file_actions.dart:63-84 -->
<!-- evidence: memory.md G-006 -->
By default an existing file at the destination is left untouched (skipped, not
overwritten); the batch does not stop on one failure — every remaining file is still
attempted, and every failure is collected and shown to the user rather than being
silently swallowed.
<!-- evidence: lib/services/library/photo_file_actions.dart:56-70,28-36 -->

#### Social-media export

Starred photos can also be exported as resized JPEGs for social media, one file per
item, decoded, resized and re-encoded entirely in Dart. The long edge is capped at
`2048` px, aspect ratio preserved, and the output is encoded at JPEG quality `90`.
<!-- evidence: lib/services/library/photo_export_service.dart:82,126,141 -->
Core EXIF fields — camera make/model, capture date, artist, exposure time, f-number,
focal length, lens model, ISO and GPS coordinates — are re-read from the original
source file and reattached to the resized output; this is a curated set of tags, not a
full metadata block copy.
<!-- evidence: lib/services/library/photo_export_service.dart:144-216 -->
Up to `4` exports run concurrently, a ceiling chosen because a full RAW decode can hold
hundreds of megabytes in flight and letting every starred item decode at once on a
large batch risks running out of memory.
<!-- evidence: lib/services/library/photo_export_service.dart:218-223,287-288 -->

#### Two deletion paths

Halcyon offers two distinct ways to delete, and they are genuinely different products:

| Path | What it does | Platform |
|---|---|---|
| System Trash | Moves the file to the OS trash via a native bridge | macOS, Windows |
| Recycle mode (in-folder) | Moves the file into a `.trash` subfolder inside the photo folder | Any platform |

The system Trash path is backed by a `halcyon/trash` method channel. On macOS it is
registered in `AppDelegate.swift` and calls `FileManager.default.trashItem`; on Windows
it is registered in `windows/runner/halcyon_channels.cpp`.
<!-- evidence: macos/Runner/AppDelegate.swift:23-24 -->
<!-- evidence: windows/runner/halcyon_channels.cpp:49-51 -->
<!-- evidence: memory.md AD-008 -->
Grepping the Android, iOS, Linux and web runner directories for `halcyon/trash` finds
no registration, so the system Trash path is macOS- and Windows-only. Recycle mode is a
user-toggleable, per-folder default (and is switched on automatically for folders that
contain RAW+JPG sibling pairs) rather than an automatic fallback; on a platform without
the native channel, choosing direct system-Trash delete throws a `TrashException`
instead of silently doing nothing.
<!-- evidence: lib/providers/app_state.dart:130,166,287,498-515 -->
<!-- evidence: lib/services/platform/trash_service.dart:9-19 -->

Recycle mode moves every file of a trashed item — including its RAW sibling and any
AppleDouble sidecar — into a `.trash` subfolder next to the photos, rather than through
the OS. It is a same-volume rename, so it works even on cards where the system Trash
API is unavailable, and it is instant because no data is copied.
<!-- evidence: lib/services/library/photo_file_actions.dart:114-155 -->
<!-- evidence: memory.md AD-013 -->
A filename collision with an earlier recycle batch is never overwritten: the mover
appends `-1`, `-2`, and so on until it finds a free name.
<!-- evidence: lib/services/library/photo_file_actions.dart:157-171 -->

Batch delete failures block: any failed file produces a dialog listing exactly which
files failed and why, because a delete that silently did nothing looks identical to a
broken app. A successful recycle-mode batch instead posts a transient status-line
message with the moved count, as a reminder the files are still on disk in `.trash` and
were not permanently removed.
<!-- evidence: lib/views/batch_delete_feedback.dart:12-40 -->
