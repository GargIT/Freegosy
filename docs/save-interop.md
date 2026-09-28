# Save interoperability between emulators and RomM clients

Freegosy syncs game saves through RomM, and so do other RomM clients (for
example [Argosy](https://github.com/rommapp/argosy-launcher) on Android). The
same game can be played with different emulators on different machines. This
page records, per platform, how each emulator stores its saves, whether those
files are the same format, and what happens when a save made in one place is
played in another. It's the reference for making saves move between
emulators, one platform at a time.

Each platform section follows the same outline: **formats**, **how each
emulator names its files**, **the interop matrix**, **gaps and
recommendations**. Findings are marked **verified** (checked against real
files or by hand) or **from source** (read in the emulator's code).

Platforms covered so far: [PlayStation (PS1)](#playstation-ps1).

## How Freegosy moves a game save

For reference when reading the matrices:

- **Upload**: the emulator's save strategy (`lib/core/save/strategies/`) lists
  the files for the game (`getSaveFilesWithScreenshots`). One file is uploaded
  under its own name; several go up as one zip. Game saves are tagged
  `emulator=freegosy` on RomM.
- **Download**: Freegosy takes RomM's **newest save for the game, whoever
  uploaded it** (`RommService.getLatestSave`; the `freegosy` tag only matters
  when pruning old saves), and hands it to the strategy of the emulator on this
  machine (`restoreSave`), which decides where, and under what name, it goes.
- So for a save to cross emulators, the **receiving** strategy must recognise
  the uploaded file (name and format) and write it where its emulator reads it.

## PlayStation (PS1)

### Format

A PS1 memory card is a **raw 128 KB image** (131,072 bytes): 16 blocks of 8 KB.
Block 0 starts with `MC` and holds a 15-entry directory, one 128-byte entry per
data block: allocation state, size, the next block of the save, the save's
file name and an XOR checksum. The file name starts with a region prefix and
the game's product code, e.g. `BESLES-02605-SETTING` (see
`lib/core/save/ps1_memory_card.dart`).

**DuckStation's `.mcd` and a RetroArch PS1 core's `.srm` are the same format.**
Verified: PCSX-ReARMed's `Crash Bandicoot (Europe).srm` and DuckStation's
`Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)_1.mcd` are both 131,072 bytes
with the same header and directory layout. The only difference is cosmetic:
PCSX-ReARMed fills free blocks with `00`, DuckStation with `FF`. SwanStation
(the libretro port of DuckStation) says so in its own option text: `.srm` and
per-game `.mcd` saves "have internally identical formats and can be converted
between one another via renaming the extension and removing/adding the slot
number (_1)".

### How each emulator names its cards

`<content>` is the file the emulator loaded without its extension: the ROM, or
the `.m3u` of a multi-disc game.

**DuckStation (standalone)**: set by *Memory Card Type* per port
(`[MemoryCards] CardNType` in `settings.ini`, overridable per game in
`gamesettings/<SERIAL>.ini`), in the `memcards` folder. Verified.

| Type (`CardNType`) | File |
|---|---|
| Separate Card Per Game (Serial) (`PerGame`) | `<serial>_N.mcd`, e.g. `SLES-02605_1.mcd` |
| Separate Card Per Game (Title) (`PerGameTitle`, the default for port 1) | `<title>_N.mcd`; the title is `saveName` (else `name`) from DuckStation's own `resources/gamedb.yaml`, or the disc set's from `discsets.yaml` for a multi-disc game when *Use Single Card For Multi-Disc Games* (`UsePlaylistTitle`) is on, unless a card under the disc's own title already exists. Unsafe characters become `_` per platform (Windows: `/ \ < > : " | ? *` and a trailing `.`; Linux: `/ *`; macOS: `/ * :`) |
| Separate Card Per Game (File Title) (`PerGameFileTitle`) | `<content>_N.mcd` |
| Shared Between All Games (`Shared`) | `shared_card_N.mcd` (or `CardNPath`) |
| No Memory Card / Non-Persistent | none |

**RetroArch PS1 cores**: in RetroArch's save folder (per core, e.g.
`saves/PCSX-ReARMed/`, when *Sort Saves into Folders by Core* is on). From
source, plus the verified files above.

| Core | Default (card 1) | Other settings |
|---|---|---|
| PCSX-ReARMed | `<content>.srm` (`pcsx_rearmed_memcard1 = libretro`) | `serial`: `<serial>_1.mcd` (the same name as DuckStation's Serial type); `shared`: `pcsx-card1.mcd`. Card 2 defaults to **shared**, `pcsx-card2.mcd` |
| Beetle / Mednafen PSX (+HW) | `<content>.srm` (*Memory Card 0 Method* = libretro) | Mednafen method: `<content>.0.mcr`; card 2 (when enabled): `<content>.1.mcr`; shared cards: `mednafen_psx_libretro_shared.N.mcr` |
| SwanStation | `<content>.srm` (`Libretro`) | By game code `<code>_N.mcd`; by title `<title>_N.mcd`; shared `duckstation_shared_card_N.mcd` |

With default settings **every RetroArch PS1 core uses `<content>.srm`**.

**Argosy (Android)**: from source (`SavePathResolver.kt`, `SaveDownloader.kt`,
`SavePathRegistry.kt`).

- PS1 runs mostly through RetroArch or Argosy's built-in libretro cores: the
  card is the game's `.srm`, and uploads go to RomM as `<content>.srm`.
- Standalone DuckStation on Android is registered but **disabled** (Android
  DuckStation writes its files unreadable to other apps). When enabled it only
  looks for `<content>_1.mcd` (File Title, port 1).
- On download Argosy writes the bytes to **its own** local path whatever the
  file is called on RomM: a PC-made `.mcd` lands as the game's `.srm`.

### Interop matrix

"verified" means checked by hand with real emulators and RomM: a DuckStation
save played on in RetroArch (PCSX-ReARMed) and back, both through Freegosy.
The other rows follow from the formats and the clients' code.

| Made in → played in | Result | Why |
|---|---|---|
| DuckStation → DuckStation | ✅ | The card is restored under the name this PC's Memory Card Type uses; a shared card gets only this game's saves merged in. |
| DuckStation → RetroArch (Freegosy) | ✅ verified | DuckStation uploads its port-1 card as `<content>.srm` (see below), which is the name the RetroArch core opens. |
| DuckStation → Argosy | ✅ | Argosy writes the bytes to its own `<content>.srm`. ⚠️ Two per-game ports upload a zip; not checked how Argosy handles that. |
| RetroArch (`.srm`) → DuckStation | ✅ verified | A 128 KB `.srm` with the `MC` header is taken as the port-1 card. |
| RetroArch ↔ RetroArch, RetroArch ↔ Argosy | ✅ | The same `<content>.srm` everywhere. |
| Argosy → DuckStation | ✅ | As RetroArch → DuckStation. |
| Older `.mcd` uploads (DuckStation before the `.srm` name, or other clients' `<serial>_1.mcd`) → RetroArch (Freegosy) | ❌ | The RetroArch strategy writes a `.mcd` under its own name; the core never opens it. |
| A RetroArch core set to serial / shared / Mednafen cards → anywhere | ⚠️ | The RetroArch strategy only finds `<content>.srm`-style files, so those cards are never uploaded. |

### Gaps and recommendations

1. **Done: DuckStation uploads its port-1 card as `<content>.srm`.** The same
   bytes under the name every RetroArch core, Argosy and RomM's in-browser
   player expect. Other ports keep `<name>_N.mcd` (in a zip with the `.srm`).
   DuckStation's own restore accepts both names.
2. **To do (RetroArch): restore a PS1 `.mcd` as `<content>.srm`**, when it is a
   128 KB `MC` card for port 1 (`_1.mcd`, no port, or a `shared_card_1`
   name). Needed for `.mcd` saves already on RomM and for other clients'
   serial/title cards.
3. **Done (RetroArch, every platform): a stricter save match** (#116). A save
   belongs to the game when it is the ROM name followed by an extension, or
   else has the same title (every word, numbers included; case, punctuation,
   word order and `(…)`/`[…]` tags ignored). Before, one shared word of 3+
   letters was enough, so "Crash Bandicoot 2" could pick up
   `Crash Bandicoot (Europe).srm`.
4. **Later (RetroArch): the cores' own card modes** (serial, shared, `.mcr`).
   Rare, since every core defaults to `.srm`.
5. **Noted: RetroArch's core folder.** The strategy picks the save folder from
   the platform's default core or the per-game core mapping; a game actually
   played with another core keeps its card in that core's folder.
6. **Unverified**: whether RomM's in-browser player (EmulatorJS, RetroArch
   cores) loads a PS1 `.srm` uploaded this way; how Argosy handles a zip of
   two PS1 cards.

### Sources

- DuckStation: this repository's findings in `docs/save-state-sync.md` and the
  DuckStation strategy; files of a real install (`settings.ini`,
  `resources/gamedb.yaml`, `discsets.yaml`, `memcards/`).
- [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed):
  `frontend/libretro.c` (`load_memcards`), `frontend/libretro_core_options.h`.
- [libretro/beetle-psx-libretro](https://github.com/libretro/beetle-psx-libretro):
  `libretro.c` (memcard options, `MDFN_MakeFName` / `MDFNMKF_SAV`).
- [libretro/swanstation](https://github.com/libretro/swanstation):
  `src/libretro/libretro_core_options.h`, `libretro_host_interface.cpp`.
- [rommapp/argosy-launcher](https://github.com/rommapp/argosy-launcher):
  `SavePathResolver.kt`, `SaveDownloader.kt`, `SavePathRegistry.kt`.
