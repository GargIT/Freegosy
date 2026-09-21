# Save-state sync (PCSX2)

Freegosy can sync **PCSX2 save states** between your machines through your RomM
server. Save states are the emulator snapshots you make with the quick-save keys
(`SERIAL (CRC).01.p2s` and so on). They are **not** the in-game memory-card
saves: those keep syncing through RomM's saves API exactly as before, and the
two never mix.

This page describes the feature and how it behaves.

## At a glance

| | |
|---|---|
| Emulators | PCSX2 only for now. Every other emulator shows the toggle disabled with "Not supported yet". |
| Default | **Off.** Turn it on per emulator. |
| Where | Settings → Emulators → PCSX2 → "Sync save states"; "Sync Save States" button on a game's page. |
| Auto-load | A second, separate opt-in switch, "Auto-load resume state on launch", right under the sync switch. **Off** by default. See [Auto-load on launch](#auto-load-on-launch). |
| RomM API | `/api/states` (separate from `/api/saves`). Works on any RomM that has the states API. |
| Privacy | States belong to your RomM user and stay private. Freegosy never shares them. |

## Using it

1. Open **Settings → Emulators** and switch on **Sync save states** for PCSX2.
2. Play as usual. Before the game launches, Freegosy downloads states that are
   missing or newer on RomM. After you quit, it uploads the states you changed
   during that session.
3. To sync without launching, open the game's page and press
   **Sync Save States**. It pulls, then pushes, and asks you about any conflict.

Both machines should run the **same PCSX2 build**. A save state is tied to the
emulator version, and Freegosy does not check or tag it. A state that PCSX2 can't
load simply fails to load inside PCSX2; nothing is corrupted.

## What is synced

- Files in the PCSX2 states folder named `SERIAL (CRC8).NN.p2s` (numbered slots)
  and `SERIAL (CRC8).resume.p2s` (the resume slot), for **the game being
  launched** only. The serial is read from the ROM.
- Ignored: `.p2s.backup` files, states of other games, and files smaller than
  100 bytes (treated as aborted writes).
- The file name on RomM is the same as the local file name.

States folder: `<PCSX2 folder>/sstates` for a portable install (the folder that
contains `memcards`), `~/.config/PCSX2/sstates` on a standard Linux install,
`~/Library/Application Support/PCSX2/sstates` on macOS, and `<root parent>/states`
for EmuDeck layouts. It uses the same folder detection as memory-card sync.

## When it runs

| Moment | What happens |
|---|---|
| Before launch | Awaited, with a "Checking save states..." toast. Skipped while RomM is offline. The server list call is bounded to 20 s, a download gives up after 30 s without receiving data (a slow download that keeps making progress finishes), and the pull stops at the first failed download, so a stalling server costs about that long at most. A failure never blocks the launch. |
| After the emulator exits | Uploads the states modified during the session. A failure never breaks the backup or play-session report that follow. |
| **Sync Save States** button | Pull, resolve conflicts, push, resolve conflicts. Fails fast with "RomM offline" when RomM is offline, and says "Sync already running" when another sync for the game is still going (for example the push after you quit). |
| Headless CLI | Push after exit only (no dialogs, so conflicts stay flagged until you resolve them in the app). |

Only one sync operation runs per game at a time. If another is already running
for that game, the new one does nothing (the **Sync Save States** button tells
you so instead of reporting a sync that did not happen; the pre-launch pull just
carries on and launches).

## Auto-load on launch

A second switch, **Auto-load resume state on launch**, sits directly under
**Sync save states** for PCSX2 (other emulators show it disabled with "Not
supported yet"). It is **off** by default and works on its own: you do not need
state sync, and it also works with purely local states.

When it is on, Freegosy looks in the PCSX2 states folder for the game's resume
state, `SERIAL (CRC).resume.p2s`, and starts PCSX2 with it through PCSX2's
`-statefile` option, so the game boots straight into where you last quit. The
launch arguments become `-batch -fullscreen -statefile <path>` followed by the
ROM. This applies to the app and to the headless CLI.

- **Resume slot only.** Numbered quick-save slots (`SERIAL (CRC).NN.p2s`) are
  never auto-loaded. If several resume files match the game's serial (different
  CRCs), the newest by modified time is used. `.p2s.backup` files, other games'
  states and files smaller than 100 bytes are ignored.
- **No resume file, normal launch.** If the game has no resume state (or the
  serial can't be read, or the states folder is missing), PCSX2 starts as usual
  with no extra arguments.
- **The resume file only exists if PCSX2 writes it.** PCSX2 only writes the
  resume file when its save-state-on-shutdown option (the `SaveStateOnShutdown`
  setting) is on; Freegosy does not change PCSX2 settings. Turn that option on in
  PCSX2 if you want a resume state to exist.
- **With sync on**, the app's awaited pre-launch pull runs before the game
  launches, so a resume state made on another machine is downloaded first and is
  what loads. The headless CLI has no pre-launch pull (see "When it runs"), so it
  loads whatever resume state is already on that machine.

Caveats:

- It resumes exactly where you quit. Whether the memory card and the state
  agree with each other is up to you (for example, a resume state can be older
  than the last in-game save on the memory card).
- A resume state from a different PCSX2 build fails to load inside PCSX2; nothing
  is corrupted.
- Flatpak and AppImage installs of PCSX2 may not be able to read the state path
  Freegosy passes.

## Conflicts and safety

Freegosy keeps a small record per state file (server id, hash of the bytes at the
last sync, and RomM's `updated_at` used only as a "did it change" marker). From
that it decides what to do:

| Situation | Result |
|---|---|
| State only on RomM | Downloaded (first sync on a new machine). |
| You deleted it locally, RomM still has it | **Not** re-downloaded. |
| Changed on RomM, unchanged locally | Downloaded; the old local file is backed up first. |
| Changed locally, unchanged on RomM | Uploaded after you exit. |
| Same name on both sides, never synced, different bytes | **Conflict.** |
| Changed on both sides | **Conflict.** |

A **conflict** is never resolved silently. You get a dialog with
*Use Local Version* or *Use Cloud Version*. Cancel keeps your local file and
leaves the slot flagged; a flagged slot is skipped by uploads until you resolve
it. A conflict found after you quit is reported in an orange warning toast that
stays on screen until you dismiss it, with a **Resolve** button that runs the
same sync and shows the dialog; **Sync Save States** on the game page and the
next launch show the dialog too. If the server copy of a flagged slot has been
removed, the local state is uploaded again: there is nothing left to conflict
with.

Safety rules that always apply:

- A local state is only ever replaced through a temp file + rename, and only
  after a `.bak` copy exists (`.bak`, `.bak1`, `.bak2` rotate beside the state, so
  expect up to a few extra copies per slot). If the backup can't be made, the
  state is left untouched.
- Downloads must be non-trivial and start with the zip header PCSX2 states use.
- "Keep local" validates the local file before uploading, so a truncated state
  can never overwrite a good copy on RomM.
- Server-supplied names are checked to be plain file names (no path separators,
  `.` or `..`).

## Known limitations

- PCSX2 only; other emulators can opt in later.
- Deleting a state does not delete it on RomM, and deletes are not propagated
  between machines.
- One RomM account per Freegosy install. After switching accounts, states you had
  already synced can be downloaded again or show up as a conflict once, because
  the new account has its own copies.
- Older cloud saves that still contain states are now ignored when restored:
  states sync only through this feature.
- States are typically tens of MB, so the first sync on a new machine can take a
  while.

## Troubleshooting

- **A switch is greyed out** — the emulator doesn't support that feature yet
  (state sync and auto-load are separate switches).
- **Nothing syncs** — check the toggle is on, RomM is reachable, and that the
  game's serial can be read (a renamed ROM works; an unreadable disc image does
  not). The next entry shows how to see what state sync actually did.
- **How do I tell what state sync did?** — open the log: **Settings**, in the
  **Storage** card under **Troubleshooting**, press **View Logs** (the **System
  Logs** window). Leave the filter on **ALL** (the **ERROR** filter only shows
  the failure lines). State sync lines start with `[StateSync]` and auto-load lines
  with `[AutoLoad]`. Select the text to copy it. The log is kept in memory
  only: the last 500 lines since Freegosy started (the trash-sweep icon with the
  tooltip **Clear Logs** empties it), so an older sync may have scrolled out. IP
  addresses are masked. The same lines also print to the console in a debug run.
  The window prefixes each line with the time, `[HH:MM:SS]`. A normal launch and
  exit looks like this (without the time prefix):

  ```
  [StateSync] pull Ico (rom 42, emulator pcsx2): states folder C:\PCSX2\sstates
  [StateSync] pull: RomM lists 1 state(s), 1 match this game
  [StateSync] downloaded SCUS-97113 (A1B2C3D4).01.p2s
  [StateSync] pull done: downloaded=1 restamped=0 conflicts=0
  [AutoLoad] will load C:\PCSX2\sstates\SCUS-97113 (A1B2C3D4).resume.p2s
  [StateSync] post-exit push for Ico (emulator pcsx2)
  [StateSync] push Ico (rom 42): 2 of 2 local state(s) eligible (modified since 2026-01-01T20:00:00.000, at least 100 bytes)
  [StateSync] unchanged SCUS-97113 (A1B2C3D4).01.p2s
  [StateSync] uploaded SCUS-97113 (A1B2C3D4).resume.p2s (POST, id 2)
  [StateSync] push done: uploaded=1 conflicts=0
  ```

  A state is only counted as eligible for upload when it was modified since the
  session started and is at least 100 bytes. Per state file you also see
  `linked` (same bytes on both sides), `kept local` (changed here, uploaded
  after exit) and `conflict`. `restamped` means RomM changed a state's
  `updated_at` (or id) but the bytes are the same, so nothing was written. It
  is normal after a rescan on RomM; if it shows up after every upload of your
  own, RomM's upload response and its listing disagree on `updated_at`. If
  nothing ran, the line says why:
  - `not running for <game>: <reason>` at launch or on a manual sync, where the
    reason is `state sync is off for 'pcsx2': switch it on in Settings >
    Emulators` (the toggle is off) or `no state-sync support for emulator
    '...'` (the emulator has none). A pull or push that is started anyway logs
    the same reason as `<game>: <reason>`.
  - `<game>: cannot identify the game — skipping` (the serial could not be read),
    or `cannot set up state sync for <game>: ...` (the states folder could not
    be found).
  - `RomM is offline — skipping the pre-launch state pull` at launch, or
    `manual sync skipped for <game>: RomM is offline` for Sync Save States.
  - `push: nothing to upload (no matching state of at least 100 bytes was
    modified this session)`.
  - `post-exit push skipped: state sync service not available` (no RomM
    connection was set up).
  - `[AutoLoad] off for 'pcsx2'`, `not supported by ...` or `no resume state for
    <game>` (why auto-load did not start a state).
- **A conflict keeps coming back** — you cancelled it. Press **Sync Save States**
  and choose a side.
- **A state won't load in PCSX2** — the two machines are on different PCSX2
  versions.
- **Auto-load does nothing** — check the switch is on, that PCSX2's
  save-state-on-shutdown option (the `SaveStateOnShutdown` setting) is on
  (otherwise no resume state is written), and that the game's
  `SERIAL (CRC).resume.p2s` exists in the states folder.

## For contributors

- Code: `lib/core/save/state_sync_service.dart` (pull, push, resolve),
  `state_sync_capable.dart` (what an emulator provides), `state_sync_record.dart`
  (records), `RommService` states client in `lib/core/romm/`.
- To add an emulator: implement the `StateSyncCapable` mixin on its save
  strategy (`stateDirectory`, `stateFileMatcher`, optionally
  `looksLikeValidState`) and return `true` from
  `EmulatorStrategy.supportsStateSync`. A unit test fails if the two disagree.
- To add auto-load for an emulator: override `StateSyncCapable.autoLoadState` on
  its save strategy, and on its `EmulatorStrategy` return `true` from
  `supportsStateAutoLoad` and the command-line arguments that load a state from
  `stateLoadArgs`. `GameLaunchService.launch` resolves the state path per
  launch and passes the arguments to the base `launchWithExtraArgs` /
  `launchWithHandleAndExtraArgs` methods; nothing is stored on the shared
  strategy (launches of the same emulator can overlap). Do not override
  `launch` / `launchWithHandle` on an auto-load emulator in a way that skips
  the base implementation; override the `...ExtraArgs` variants instead. A unit
  test checks the two sides agree.
- Tests: `test/unit/state_sync_*`, with an in-memory fake RomM in
  `test/helpers/fake_romm_states_api.dart`. `test/mock_romm_server.py` also
  serves `/api/states` for manual runs.
- Verified by hand on a real RomM and PCSX2:
  - a two-machine round trip in both directions (a state made on one PC is
    synced down and continued from on the other, and back again), which also
    shows RomM accepts the `.p2s` name and size;
  - after an upload (a `PUT` on exit), the next launch's pull reports the state
    as `unchanged` with `restamped=0`, so RomM's `updated_at` in the upload
    response matches its later listing;
  - the conflict flow: the persistent warning toast after exit, its **Resolve**
    button, the dialog, and both **Use Local Version** and **Use Cloud
    Version**;
  - an offline launch: with RomM unreachable (502 through a reverse proxy) the
    launch skipped the pre-launch state pull immediately and the game started;
  - an auto-load launch with a local resume state (it also works while RomM is
    unreachable, since it only looks at local files).
- Not yet verified against a real RomM: whether re-POSTing an existing file name
  replaces it (Freegosy does not rely on it), and a launch against a RomM that
  is up but not answering (it should be delayed by no more than the ~20 s list
  timeout plus one 30 s download stall).

## Possible follow-ups

- Other emulators (DuckStation, RetroArch, PPSSPP, ares, Dolphin).
- Deleting states on RomM and propagating deletes.
