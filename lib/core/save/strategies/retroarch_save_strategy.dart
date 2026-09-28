import 'dart:io' as io;
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import '../../disc/serial_extraction_service.dart';
import '../../platform/platform_info.dart';
import '../../romm/romm_models.dart';
import '../../storage/app_preferences.dart';
import '../../storage/directory_service.dart';
import '../ps1_memory_card.dart';
import '../ps2_memory_card.dart';
import '../save_strategy.dart';
import 'lrps2_memory_cards.dart';
import 'pcsx2_save_strategy.dart';
import 'package:path/path.dart' as p; // Import path package

/// Save strategy for RetroArch emulator.
///
/// Save files live next to RetroArch.exe in saves/{coreName}/.
/// Core name mapping is derived from the platform slug.
class RetroArchSaveStrategy extends SaveStrategy {
  final DirectoryService _directoryService;
  final PlatformInfo _platform;
  String _ndsCore = 'melonds'; // Default NDS core
  String? _cachedSaveRoot; // Cached from retroarch.cfg

  /// Cached RetroArch config flags read from retroarch.cfg.
  bool? _cachedSortSavefiles;
  bool? _cachedSortSavefilesByContent;
  bool? _cachedSavefilesInContentDir;

  /// The last-loaded RetroArch core ID parsed from `libretro_path` in retroarch.cfg.
  /// Used to resolve the correct save folder when a platform has multiple cores.
  String? _cachedActiveCore;

  /// Cached EmuDeck-for-Windows RetroArch root, once detected.
  String? _cachedEmuDeckWindowsRoot;

  /// The folder of the retroarch.cfg in use, and the `system_directory` /
  /// `rgui_config_directory` it sets (null: RetroArch's default).
  String? _cachedConfigDir;
  String? _cachedSystemDir;
  String? _cachedCoreOptionsDir;

  final SerialExtractionService? _serials;

  // Test-only override to skip reading the real retroarch.cfg.
  @visibleForTesting
  bool skipConfigRead = false;

  /// Test-only: the PS2 serial of a ROM, instead of reading the disc.
  @visibleForTesting
  Future<String?> Function(String romPath)? ps2SerialOverride;

  RetroArchSaveStrategy(this._directoryService,
      {PlatformInfo? platform, AppPreferences? prefs, SerialExtractionService? serialExtractionService})
      : _platform = platform ?? PlatformInfo.current,
        _serials = serialExtractionService ??
            (prefs == null ? null : SerialExtractionService(_directoryService, prefs, platform: platform));

  /// The core [game]'s saves come from, as RomM and other clients name it:
  /// its id without `_libretro` (e.g. `pcsx_rearmed`), or null when unknown.
  String? coreIdFor(Game game) {
    final core = _getCoreInfo(game.platformSlug?.toLowerCase() ?? '')?.coreName;
    if (core == null || core.isEmpty) return null;
    return core.replaceAll(RegExp(r'\.(dll|so|dylib)$'), '').replaceAll(RegExp(r'_libretro$'), '');
  }

  void setNdsCore(String core) {
    _ndsCore = core;
  }

  /// Per-platform core overrides (slug -> coreId). Set from StrategyRegistry.
  final Map<String, String> _coreOverrides = {};

  void loadCoreOverrides(Map<String, String> overrides) {
    _coreOverrides
      ..clear()
      ..addAll(overrides);
  }

  /// Temporarily overrides the core for a single push/pull operation.
  /// Used when the launch code knows which core was used (from the core picker)
  /// but the strategy registry hasn't been updated yet.
  String? _launchCoreOverride;
  void setLaunchCoreOverride(String? coreId) => _launchCoreOverride = coreId;

  /// Resolves the core info for a slug, checking overrides first.
  _CoreInfo? _getCoreInfo(String slug) {
    debugPrint('[SaveSync] [retroarch] _getCoreInfo: slug="$slug"  ndsCore=$_ndsCore');

    // 1. NDS dynamic override (backward compat)
    if (slug == 'nds' || slug == 'nintendo-ds') {
      final info = _ndsCore == 'desmume'
          ? const _CoreInfo('desmume2015_libretro', 'DeSmuME 2015', 'DeSmuME 2015')
          : const _CoreInfo('melonds_libretro', 'melonDS', 'melonDS');
      debugPrint('[SaveSync] [retroarch]   → NDS override: core=${info.coreName}');
      return info;
    }

    // 2. Launch-time core override (from core picker dialog)
    if (_launchCoreOverride != null) {
      final baseName = _launchCoreOverride!.replaceAll(RegExp(r'\.(dll|so|dylib)$'), '');
      final stripped = baseName.replaceAll(RegExp(r'_libretro$'), '');
      final folderInfo = _coreFolderOverrides[stripped];
      if (folderInfo != null) {
        debugPrint('[SaveSync] [retroarch] _getCoreInfo launch override (folderOverrides) → core=${folderInfo.coreName}');
        return folderInfo;
      }
      // Fallback: check _coreMap
      for (final entry in _coreMap.entries) {
        if (entry.value.coreName == baseName) {
          debugPrint('[SaveSync] [retroarch] _getCoreInfo launch override (_coreMap) → core=${entry.value.coreName}');
          return entry.value;
        }
      }
      debugPrint('[SaveSync] [retroarch] _getCoreInfo launch override (fallback) → core=$baseName');
      return _CoreInfo(baseName, baseName, 'States/$baseName');
    }

    // 3. General core override from registry
    final overrideCoreId = _coreOverrides[slug];
    if (overrideCoreId != null) {
      debugPrint('[SaveSync] [retroarch] _getCoreInfo registry override overrideCoreId=$overrideCoreId');
      final baseName = overrideCoreId.replaceAll(RegExp(r'\.(dll|so|dylib)$'), '');
      // Try to find matching _coreMap entry by coreName
      for (final entry in _coreMap.entries) {
        if (entry.value.coreName == baseName) {
          debugPrint('[SaveSync] [retroarch] _getCoreInfo registry override (_coreMap) → core=${entry.value.coreName}');
          return entry.value;
        }
      }
      // Try _coreFolderOverrides (maps core IDs to correct save folders)
      final stripped = baseName.replaceAll(RegExp(r'_libretro$'), '');
      final folderInfo = _coreFolderOverrides[stripped];
      if (folderInfo != null) {
        debugPrint('[SaveSync] [retroarch] _getCoreInfo registry override (folderOverrides) → core=${folderInfo.coreName}');
        return folderInfo;
      }

      // Fallback: use the override core name with generic save folders
      debugPrint('[SaveSync] [retroarch] _getCoreInfo registry override (fallback) → core=$baseName');
      return _CoreInfo(baseName, baseName, 'States/$baseName');
    }

    // 3. Active core from retroarch.cfg libretro_path.
    // When the user switches cores (e.g. Mupen64Plus → Parallel N64),
    // the save directory changes. Detect this and use the correct folder.
    if (_cachedActiveCore != null) {
      debugPrint('[SaveSync] [retroarch] _getCoreInfo activeCore=${_cachedActiveCore!}');
      final activeInfo = _coreFolderOverrides[_cachedActiveCore!];
      if (activeInfo != null) {
        // Check if this core supports the requested platform
        // by verifying the core's default map entry exists for this slug
        final defaultInfo = _coreMap[slug];
        if (defaultInfo != null) {
          debugPrint('[SaveSync] [retroarch] _getCoreInfo active core override → core=${activeInfo.coreName}');
          return activeInfo;
        }
      }
    }

    // 4. Default from static map
    final defaultCore = _coreMap[slug];
    debugPrint('[SaveSync] [retroarch] _getCoreInfo default map → ${defaultCore?.coreName ?? "null"}');
    return defaultCore;
  }

  @override
  String get strategyId => 'retroarch';

  @override
  bool get shouldZip => false;

  /// Save file extensions recognized by RetroArch cores.
  /// N64 cores use .sra/.eep/.fla/.mpk; most others use .srm/.sav/.mcd.
  static const _saveExtensions = {'.srm', '.sav', '.mcd', '.sra', '.eep', '.fla', '.mpk', '.ps2'};

  static bool _isSaveFile(String filename) {
    final ext = p.extension(filename).toLowerCase();
    return _saveExtensions.contains(ext);
  }

  // _CoreInfo maps platform slugs to RetroArch core info, including save and state directories.
  // With "Sort Saves/States into Folders by Core" on, RetroArch names both
  // folders after the core's library_name, which is the `corename` in the
  // core's .info file (libretro/libretro-core-info): e.g. `Mupen64Plus-Next`,
  // `LRPS2`, `FCEUmm`. PSP and 3DS keep their cores' own layouts.
  static const Map<String, _CoreInfo> _coreMap = {
    // Nintendo
    'gba':       _CoreInfo('mgba_libretro',            'mGBA',               'mGBA'),
    'gbc':       _CoreInfo('mgba_libretro',            'mGBA',               'mGBA'),
    'gb':        _CoreInfo('mgba_libretro',            'mGBA',               'mGBA'),
    'nes':       _CoreInfo('fceumm_libretro',          'FCEUmm',             'FCEUmm'),
    'snes':      _CoreInfo('snes9x_libretro',          'Snes9x',             'Snes9x'),
    'n64':       _CoreInfo('mupen64plus_next_libretro', 'Mupen64Plus-Next',   'Mupen64Plus-Next'),
    'nds':       _CoreInfo('melonds_libretro',         'melonDS',            'melonDS'),
    'nintendo-ds': _CoreInfo('melonds_libretro',       'melonDS',            'melonDS'),
    '3ds':       _CoreInfo('azahar_libretro',          '3DS',                'States/3DS'),
    'n3ds':      _CoreInfo('azahar_libretro',          '3DS',                'States/3DS'),
    'nintendo-3ds': _CoreInfo('azahar_libretro',       '3DS',                'States/3DS'),
    'virtualboy': _CoreInfo('mednafen_vb_libretro',    'Beetle VB',          'Beetle VB'),
    // Sony
    'psx':       _CoreInfo('pcsx_rearmed_libretro',    'PCSX-ReARMed',       'PCSX-ReARMed'),
    'ps1':       _CoreInfo('pcsx_rearmed_libretro',    'PCSX-ReARMed',       'PCSX-ReARMed'),
    'playstation': _CoreInfo('pcsx_rearmed_libretro',  'PCSX-ReARMed',       'PCSX-ReARMed'),
    'psp':       _CoreInfo('ppsspp_libretro',          'PPSSPP/PSP/SAVEDATA', 'PPSSPP'),
    'playstation-portable': _CoreInfo('ppsspp_libretro', 'PPSSPP/PSP/SAVEDATA', 'PPSSPP'),
    'ps2':       _CoreInfo('pcsx2_libretro',           'LRPS2',              'LRPS2'),
    // Sega
    'megadrive': _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'genesis':   _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'md':        _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'segacd':    _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'sms':       _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'mastersystem': _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'gamegear':  _CoreInfo('genesis_plus_gx_libretro', 'Genesis Plus GX',    'Genesis Plus GX'),
    'saturn':    _CoreInfo('mednafen_saturn_libretro', 'Beetle Saturn',      'Beetle Saturn'),
    'dc':        _CoreInfo('flycast_libretro',         'Flycast',            'Flycast'),
    'dreamcast': _CoreInfo('flycast_libretro',         'Flycast',            'Flycast'),
    // Atari
    'atari2600': _CoreInfo('stella_libretro',          'Stella',             'Stella'),
    'atari7800': _CoreInfo('prosystem_libretro',       'ProSystem',          'ProSystem'),
    'atari5200': _CoreInfo('atari800_libretro',        'Atari800',           'Atari800'),
    'atari800':  _CoreInfo('atari800_libretro',        'Atari800',           'Atari800'),
    'lynx':      _CoreInfo('mednafen_lynx_libretro',   'Beetle Lynx',        'Beetle Lynx'),
    // Arcade / SNK
    'neogeo':    _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'neo-geo':   _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'neogeoaes': _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'neogeomvs': _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'neo-geo-aes': _CoreInfo('fbneo_libretro',         'FinalBurn Neo',      'FinalBurn Neo'),
    'neo-geo-mvs': _CoreInfo('fbneo_libretro',         'FinalBurn Neo',      'FinalBurn Neo'),
    'mvs':       _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'aes':       _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'arcade':    _CoreInfo('fbneo_libretro',           'FinalBurn Neo',      'FinalBurn Neo'),
    'mame':      _CoreInfo('mame_libretro',            'MAME',               'MAME'),
    // FDS
    'fds':       _CoreInfo('fceumm_libretro',          'FCEUmm',             'FCEUmm'),
    'famicom-disk-system': _CoreInfo('fceumm_libretro', 'FCEUmm',            'FCEUmm'),
    // NEC
    'pcengine':  _CoreInfo('mednafen_pce_libretro',    'Beetle PCE',         'Beetle PCE'),
    'pcenginecd': _CoreInfo('mednafen_pce_libretro',   'Beetle PCE',         'Beetle PCE'),
    'supergrafx': _CoreInfo('mednafen_supergrafx_libretro', 'Beetle SuperGrafx', 'Beetle SuperGrafx'),
    'pcfx':      _CoreInfo('mednafen_pcfx_libretro',   'Beetle PC-FX',       'Beetle PC-FX'),
    // Bandai
    'wonderswan': _CoreInfo('mednafen_wswan_libretro', 'Beetle WonderSwan',  'Beetle WonderSwan'),
    'wonderswancolor': _CoreInfo('mednafen_wswan_libretro', 'Beetle WonderSwan', 'Beetle WonderSwan'),
    'ngp':       _CoreInfo('mednafen_ngp_libretro',    'Beetle NeoPop',      'Beetle NeoPop'),
    'ngpc':      _CoreInfo('mednafen_ngp_libretro',    'Beetle NeoPop',      'Beetle NeoPop'),
    // Computer
    'dos':       _CoreInfo('dosbox_pure_libretro',     'DOSBox-pure',        'DOSBox-pure'),
    'msx':       _CoreInfo('bluemsx_libretro',         'blueMSX',            'blueMSX'),
    'c64':       _CoreInfo('vice_x64_libretro',        'VICE x64',           'VICE x64'),
    'commodore64': _CoreInfo('vice_x64_libretro',      'VICE x64',           'VICE x64'),
    'amiga':     _CoreInfo('puae_libretro',            'PUAE',               'PUAE'),
    'zxspectrum': _CoreInfo('fuse_libretro',           'Fuse',               'Fuse'),
    'amstradcpc': _CoreInfo('cap32_libretro',          'Caprice32',          'Caprice32'),
    'acpc':       _CoreInfo('cap32_libretro',          'Caprice32',          'Caprice32'), // IGDB slug, what RomM actually sends — see #78
    'sharp68000': _CoreInfo('px68k_libretro',          'PX68k',              'PX68k'),
    'pc98':      _CoreInfo('np2kai_libretro',          'Neko Project II Kai', 'Neko Project II Kai'),
    // Other
    'vectrex':   _CoreInfo('vecx_libretro',            'vecx',               'vecx'),
  };

  /// Maps libretro core IDs (from `libretro_path` in retroarch.cfg) to their
  /// on-disk save folder names. When the active core differs from the default
  /// in `_coreMap`, this overrides the save folder resolution.
  static const Map<String, _CoreInfo> _coreFolderOverrides = {
    // N64 cores
    'mupen64plus_next':    _CoreInfo('mupen64plus_next_libretro', 'Mupen64Plus-Next', 'Mupen64Plus-Next'),
    'parallel_n64':        _CoreInfo('parallel_n64_libretro',     'ParaLLEl N64',     'ParaLLEl N64'),
    'mupen64plus':         _CoreInfo('mupen64plus_libretro',      'Mupen64Plus',      'States/Mupen64Plus'),
    // GBA cores
    'mgba':                _CoreInfo('mgba_libretro',             'mGBA',             'mGBA'),
    'vbam':                _CoreInfo('vbam_libretro',             'VBA-M',            'VBA-M'),
    'gpSP':                _CoreInfo('gpsp_libretro',             'gpSP',             'gpSP'),
    // SNES cores
    'snes9x':              _CoreInfo('snes9x_libretro',           'Snes9x',           'Snes9x'),
    'bsnes':               _CoreInfo('bsnes_libretro',            'bsnes',            'bsnes'),
    'bsnes_hd_beta':       _CoreInfo('bsnes_hd_beta_libretro',    'bsnes-hd beta',    'bsnes-hd beta'),
    // PS1 cores
    'pcsx_rearmed':        _CoreInfo('pcsx_rearmed_libretro',     'PCSX-ReARMed',     'PCSX-ReARMed'),
    'mednafen_psx':        _CoreInfo('mednafen_psx_libretro',     'Beetle PSX',       'Beetle PSX'),
    'mednafen_psx_hw':     _CoreInfo('mednafen_psx_hw_libretro',  'Beetle PSX HW',    'Beetle PSX HW'),
    'duckstation':         _CoreInfo('duckstation_libretro',      'DuckStation',      'DuckStation'),
    // NDS cores
    'melonds':             _CoreInfo('melonds_libretro',          'melonDS',          'melonDS'),
    'desmume':             _CoreInfo('desmume2015_libretro',      'DeSmuME 2015',     'DeSmuME 2015'),
    // PSP cores
    'ppsspp':              _CoreInfo('ppsspp_libretro',           'PPSSPP/PSP/SAVEDATA', 'PPSSPP'),
    // Genesis cores
    'genesis_plus_gx':     _CoreInfo('genesis_plus_gx_libretro',  'Genesis Plus GX',  'Genesis Plus GX'),
    'fceumm':              _CoreInfo('fceumm_libretro',           'FCEUmm',           'FCEUmm'),
  };

  /// Reads `savefile_directory` and sort flags from retroarch.cfg.
  ///
  /// Parses these RetroArch config keys:
  /// - `savefile_directory` — base save directory
  /// - `sort_savefiles_enable` — when "true", saves go into core subfolders
  /// - `sort_savefiles_by_content_enable` — when "true", saves go into ROM parent folder subfolders
  /// - `savefiles_in_content_dir` — when "true", saves go next to the ROM
  Future<String?> _readConfigSaveRoot() async {
    if (skipConfigRead) return null;
    if (_cachedSaveRoot != null) return _cachedSaveRoot;

    final List<String> candidates = [];

    if (_platform.isMacOS) {
      final home = _platform.environment['HOME'] ?? '';
      candidates.add(p.join(home, 'Library', 'Application Support', 'RetroArch', 'config', 'retroarch.cfg'));
      candidates.add(p.join(home, '.config', 'retroarch', 'retroarch.cfg'));
    } else if (_platform.isLinux) {
      final home = _platform.environment['HOME'] ?? '';
      candidates.add(p.join(home, '.config', 'retroarch', 'retroarch.cfg'));
    } else if (_platform.isWindows) {
      final appData = _platform.environment['APPDATA'] ?? '';
      candidates.add(p.join(appData, 'RetroArch', 'retroarch.cfg'));
    }

    // Also check next to the bundled exe
    final exePath = await _directoryService.findEmulatorExecutable('retroarch', _getRetroArchExe());
    if (exePath != null) {
      String exeDir = _platform.isMacOS
          ? p.join(io.File(exePath).parent.parent.parent.parent.path)
          : io.File(exePath).parent.path;
      if (await io.FileSystemEntity.isDirectory(exePath)) exeDir = exePath;
      candidates.add(p.join(exeDir, 'retroarch.cfg'));
    }
    debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot candidates=${candidates.length}: ${candidates.map((c) => p.basename(p.dirname(c))).join(', ')}');

    final savefileDirRe = RegExp(r'^\s*savefile_directory\s*=\s*"([^"]*)"');
    final systemDirRe = RegExp(r'^\s*system_directory\s*=\s*"([^"]*)"');
    final coreOptionsDirRe = RegExp(r'^\s*rgui_config_directory\s*=\s*"([^"]*)"');
    final boolRe = RegExp(r'^\s*(sort_savefiles_enable|sort_savefiles_by_content_enable|savefiles_in_content_dir)\s*=\s*"?(true|false)"?');
    final libretroPathRe = RegExp(r'^\s*libretro_path\s*=\s*"([^"]*)"');

    for (final cfgPath in candidates) {
      final cfgFile = io.File(cfgPath);
      if (!await cfgFile.exists()) {
        debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot not found: $cfgPath');
        continue;
      }
      debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot reading: $cfgPath');
      try {
        final lines = await cfgFile.readAsLines();
        final cfgDir = p.dirname(cfgPath);
        _cachedConfigDir = cfgDir;
        for (final line in lines) {
          final systemMatch = systemDirRe.firstMatch(line);
          if (systemMatch != null) _cachedSystemDir = _configPath(systemMatch.group(1)!, cfgDir);
          final optionsMatch = coreOptionsDirRe.firstMatch(line);
          if (optionsMatch != null) _cachedCoreOptionsDir = _configPath(optionsMatch.group(1)!, cfgDir);

          final saveMatch = savefileDirRe.firstMatch(line);
          if (saveMatch != null) {
            var dir = saveMatch.group(1)!;
            if (dir.startsWith('~')) {
              final home = _platform.environment['HOME'];
              if (home != null) dir = dir.replaceFirst('~', home);
            }
            if (await io.Directory(dir).exists()) {
              _cachedSaveRoot = dir;
              debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot savefile_directory=$dir');
            } else {
              debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot savefile_directory=$dir (dir does not exist)');
            }
          }

          final boolMatch = boolRe.firstMatch(line);
          if (boolMatch != null) {
            final key = boolMatch.group(1)!;
            final value = boolMatch.group(2)!.toLowerCase() == 'true';
            switch (key) {
              case 'sort_savefiles_enable':
                _cachedSortSavefiles = value;
                debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot sort_savefiles_enable=$value');
                break;
              case 'sort_savefiles_by_content_enable':
                _cachedSortSavefilesByContent = value;
                debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot sort_savefiles_by_content_enable=$value');
                break;
              case 'savefiles_in_content_dir':
                _cachedSavefilesInContentDir = value;
                debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot savefiles_in_content_dir=$value');
                break;
            }
          }

          // Parse libretro_path to detect the last-used core.
          // Example: libretro_path = "/path/to/parallel_n64_libretro.dylib"
          final coreMatch = libretroPathRe.firstMatch(line);
          if (coreMatch != null) {
            final corePath = coreMatch.group(1)!;
            if (corePath.isNotEmpty && corePath != 'default') {
              final coreFilename = p.basename(corePath);
              // Strip extension and _libretro suffix to get the base core ID
              // e.g. "parallel_n64_libretro.dylib" → "parallel_n64"
              final coreBase = coreFilename
                  .replaceAll(RegExp(r'\.(dll|so|dylib)$'), '')
                  .replaceAll(RegExp(r'_libretro$'), '');
              if (coreBase.isNotEmpty) {
                _cachedActiveCore = coreBase;
                debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot activeCore=$coreBase (from $coreFilename)');
              }
            }
          }
        }
        if (_cachedSaveRoot != null) break;
      } catch (_) {}
    }
    debugPrint('[SaveSync] [retroarch] _readConfigSaveRoot result: saveRoot=${_cachedSaveRoot ?? "null"}');
    return _cachedSaveRoot;
  }

  /// Whether RetroArch sorts saves into core subfolders (e.g. `saves/mGBA/`).
  /// Defaults to `true` (RetroArch's default).
  bool get _sortSavefiles => _cachedSortSavefiles ?? true;

  /// Whether RetroArch sorts saves into ROM parent folder subfolders.
  /// Parsed from config but currently unused in path resolution — RetroArch
  /// handles this internally when the flag is set. Kept for future use if
  /// we need to construct paths including the content directory name.
  // ignore: unused_element
  bool get _sortSavefilesByContent => _cachedSortSavefilesByContent ?? false;

  /// Whether RetroArch saves are placed next to the ROM instead of a central dir.
  bool get _savefilesInContentDir => _cachedSavefilesInContentDir ?? false;

  /// Resolves the save root directory: retroarch.cfg first, then exe-relative.
  Future<String> _resolveSaveRoot() async {
    if (_platform.isWindows) {
      final emuDeckRoot = await _emuDeckWindowsRetroArchRoot();
      if (emuDeckRoot != null) return p.join(emuDeckRoot, 'saves');
    }
    final cfg = await _readConfigSaveRoot();
    if (cfg != null) return cfg;
    final exePath = await _directoryService.findEmulatorExecutable('retroarch', _getRetroArchExe());
    String exeDir = _platform.isMacOS
        ? p.join(io.File(exePath!).parent.parent.parent.parent.path)
        : io.File(exePath!).parent.path;
    if (await io.FileSystemEntity.isDirectory(exePath)) exeDir = exePath;
    return p.join(exeDir, 'saves');
  }

  /// Detects an EmuDeck-for-Windows install and returns its RetroArch root
  /// (`%USERPROFILE%\emudeck\EmulationStation-DE\Emulators\RetroArch`) if present.
  ///
  /// EmuDeck for Windows installs RetroArch there directly and exposes a
  /// `Emulation\saves\retroarch\...` junction pointing back to it. We resolve
  /// to the real path instead of the junction to avoid Windows "untrusted
  /// mount point" errors when traversing reparse points without admin rights.
  Future<String?> _emuDeckWindowsRetroArchRoot() async {
    if (_cachedEmuDeckWindowsRoot != null) return _cachedEmuDeckWindowsRoot;
    final userProfile = _platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) return null;
    final candidate = p.join(userProfile, 'emudeck', 'EmulationStation-DE', 'Emulators', 'RetroArch');
    if (await io.Directory(candidate).exists()) {
      _cachedEmuDeckWindowsRoot = candidate;
      debugPrint('[SaveSync] [retroarch] detected EmuDeck-for-Windows root=$candidate');
      return candidate;
    }
    return null;
  }

  /// A directory setting from retroarch.cfg as a path: `:` stands for the
  /// folder of the config (a portable install), `~` for the home folder;
  /// empty or `default` means RetroArch's default (null).
  String? _configPath(String value, String cfgDir) {
    var v = value.trim();
    if (v.isEmpty || v == 'default') return null;
    if (v.startsWith(':')) return p.normalize(p.join(cfgDir, v.substring(1).replaceFirst(RegExp(r'^[\\/]+'), '')));
    if (v.startsWith('~')) {
      final home = _platform.environment['HOME'] ?? _platform.environment['USERPROFILE'];
      if (home != null) v = v.replaceFirst('~', home);
    }
    return v;
  }

  // ─── LRPS2 (PS2) memory cards ─────────────────────────────────────────

  static const _ps2Slugs = {'ps2', 'playstation-2', 'playstation2'};

  bool _isLrps2(String slug) => _ps2Slugs.contains(slug) && _getCoreInfo(slug)?.coreName == 'pcsx2_libretro';

  /// RetroArch's own folder: where its retroarch.cfg is, else above the saves.
  Future<String> _retroArchDir() async {
    await _readConfigSaveRoot();
    return _cachedConfigDir ?? p.dirname(await _resolveSaveRoot());
  }

  /// LRPS2's memory cards for [romPath]: its two shared cards in the system
  /// folder, or the game's own card in the save folder when *Shared Memory
  /// Cards* is off (see [Lrps2MemoryCards]).
  Future<({List<io.File> cards, bool shared})> _lrps2Cards(Game game, String romPath) async {
    final raDir = await _retroArchDir();
    final optionsDir = _cachedCoreOptionsDir ?? p.join(raDir, 'config');
    final optionFiles = <String>[];
    for (final path in [
      p.join(optionsDir, 'LRPS2', '${p.basenameWithoutExtension(romPath)}.opt'),
      p.join(optionsDir, 'LRPS2', '${p.basename(p.dirname(romPath))}.opt'),
      p.join(optionsDir, 'LRPS2', 'LRPS2.opt'),
      p.join(raDir, 'retroarch-core-options.cfg'),
    ]) {
      final f = io.File(path);
      if (await f.exists()) optionFiles.add(await f.readAsString());
    }
    if (Lrps2MemoryCards.usesSharedCards(optionFiles)) {
      final memcards = p.join(_cachedSystemDir ?? p.join(raDir, 'system'), 'pcsx2', 'memcards');
      return (cards: [io.File(p.join(memcards, 'Mcd001.ps2')), io.File(p.join(memcards, 'Mcd002.ps2'))], shared: true);
    }
    final saveDir = await getSaveDir(game, romPath) ?? p.join(await _resolveSaveRoot(), 'LRPS2');
    return (cards: [io.File(p.join(saveDir, '${p.basenameWithoutExtension(romPath)}.ps2'))], shared: false);
  }

  Future<String?> _ps2Serial(String romPath) async {
    if (ps2SerialOverride != null) return ps2SerialOverride!(romPath);
    return _serials?.extractSerial(
        romPath: romPath, bootLinePattern: Pcsx2SaveStrategy.bootLinePattern, chdmanCandidates: const []);
  }

  /// Which saves on LRPS2's cards are [romPath]'s: those named after its
  /// serial; every save on a per-game card when the serial is unknown. Null
  /// when it can't be told (shared cards, serial unknown).
  Future<bool Function(String)?> _lrps2SavesOf(String romPath, bool shared) async {
    final serial = await _ps2Serial(romPath);
    if (serial != null) return (name) => Lrps2MemoryCards.isSaveOf(name, serial);
    return shared ? null : (_) => true;
  }

  static const _lrps2NoSerial = "Freegosy couldn't read this PS2 game's serial (e.g. SLUS-20851), which is how it "
      "tells this game's saves from the others on LRPS2's shared memory cards, so its saves weren't synced.";

  String get _lrps2TempRoot => p.join(io.Directory.systemTemp.path, 'freegosy_lrps2');

  /// This game's saves on LRPS2's cards, written out as save folders to
  /// upload (`BASLUS-20851AC5/…`). Nothing when no card changed since
  /// [sessionStart].
  Future<List<io.File>> _lrps2SaveFolders(Game game, String romPath, DateTime? sessionStart) async {
    final setup = await _lrps2Cards(game, romPath);
    final existing = [for (final c in setup.cards) if (await c.exists()) c];
    if (existing.isEmpty) return const [];
    if (sessionStart != null) {
      final since = sessionStart.subtract(const Duration(seconds: 2));
      var changed = false;
      for (final c in existing) {
        if (!(await c.stat()).modified.isBefore(since)) changed = true;
      }
      if (!changed) return const [];
    }
    final belongs = await _lrps2SavesOf(romPath, setup.shared);
    if (belongs == null) {
      debugPrint("[SaveSync] [retroarch] LRPS2: serial unknown — can't tell this game's saves on the shared cards");
      return const [];
    }
    final outDir = io.Directory(p.join(_lrps2TempRoot, game.id));
    if (await outDir.exists()) await outDir.delete(recursive: true);
    await outDir.create(recursive: true);
    final folders = <io.File>[];
    for (final card in existing) {
      final bytes = await card.readAsBytes();
      if (Ps2MemoryCard.isUnformatted(bytes)) continue;
      final List<Ps2CardSave> saves;
      try {
        saves = await Isolate.run(() => Ps2MemoryCard.parse(bytes).saves.where((s) => belongs(s.name)).toList());
      } on FormatException catch (e) {
        debugPrint('[SaveSync] [retroarch] LRPS2: ${card.path} not readable, skipped: $e');
        continue;
      }
      for (final save in saves) {
        final dir = io.Directory(p.join(outDir.path, save.name));
        if (await dir.exists()) continue; // the same save on both cards: the first card's
        await dir.create();
        for (final f in save.files) {
          await io.File(p.join(dir.path, f.name)).writeAsBytes(f.data);
        }
        folders.add(io.File(dir.path));
      }
    }
    debugPrint('[SaveSync] [retroarch] LRPS2: ${folders.length} save folder(s) of this game: '
        '${folders.map((f) => p.basename(f.path)).toList()}');
    return folders;
  }

  /// Puts the PS2 saves in a downloaded save onto LRPS2's card, replacing
  /// this game's and leaving every other game's as it is: the card that
  /// already holds this game's saves (else the first), after a `.bak`,
  /// written to a temporary file and swapped in.
  Future<void> _restoreLrps2(Game game, String romPath, Uint8List data, String filename) async {
    final List<Ps2CardSave> incoming;
    try {
      incoming = Lrps2MemoryCards.savesFromUpload(data, filename);
    } on FormatException catch (e) {
      throw SaveSyncNotPossibleException(
          "The PS2 memory card from RomM ($filename) isn't one Freegosy can read ($e). Nothing was changed.");
    }
    final setup = await _lrps2Cards(game, romPath);
    final belongs = await _lrps2SavesOf(romPath, setup.shared);
    if (belongs == null) throw SaveSyncNotPossibleException(_lrps2NoSerial);
    final mine = incoming.where((s) => belongs(s.name)).toList();
    if (mine.isEmpty) {
      debugPrint('[SaveSync] [retroarch] LRPS2: $filename holds no saves of this game — cards left as they are');
      return;
    }

    var target = setup.cards.first;
    Uint8List? targetBytes;
    for (final card in setup.cards) {
      if (!await card.exists()) continue;
      final bytes = await card.readAsBytes();
      final holdsGame = await Isolate.run(() {
        try {
          return Ps2MemoryCard.parse(bytes).saves.any((s) => belongs(s.name));
        } on FormatException {
          return false;
        }
      });
      if (holdsGame || card.path == setup.cards.first.path) {
        target = card;
        targetBytes = bytes;
        if (holdsGame) break;
      }
    }

    final Uint8List merged;
    try {
      final source = targetBytes;
      merged = await Isolate.run(() => Lrps2MemoryCards.merge(source, mine, belongs));
    } on FormatException catch (e) {
      throw SaveSyncNotPossibleException(
          "LRPS2's memory card (${p.basename(target.path)}) doesn't look like a PS2 memory card Freegosy can "
          'safely change ($e), so it was left as it is.');
    } on Ps2CardFullException catch (e) {
      throw SaveSyncNotPossibleException(
          "The save from RomM doesn't fit on LRPS2's memory card (${p.basename(target.path)}) with the saves "
          'already on it: ${e.needed} KB needed, ${e.capacity} KB on the card. Nothing was changed. Free some '
          "space in the PS2 BIOS's memory card screen, then pull again.");
    }
    if (SaveRestoreGuard.restoreTooLate) {
      debugPrint('[SaveSync] [retroarch] LRPS2: RetroArch has started without this pull — ${target.path} left as it is');
      return;
    }
    await target.parent.create(recursive: true);
    if (await target.exists()) await backupSave(target.path);
    final temp = io.File('${target.path}.freegosy_tmp');
    await temp.writeAsBytes(merged, flush: true);
    await temp.rename(target.path);
    debugPrint('[SaveSync] [retroarch] LRPS2: put ${mine.map((s) => s.name).toList()} on ${target.path}');
  }

  @override
  Future<String?> saveSyncBlockedReason(Game game, String romPath) async {
    final slug = game.platformSlug?.toLowerCase() ?? '';
    if (!_isLrps2(slug)) return null;
    try {
      final setup = await _lrps2Cards(game, romPath);
      return await _lrps2SavesOf(romPath, setup.shared) == null ? _lrps2NoSerial : null;
    } catch (e) {
      debugPrint('[SaveSync] [retroarch] LRPS2: cannot tell whether saves can be synced: $e');
      return null;
    }
  }

  /// LRPS2 opens its shared cards when a game starts, so a pull that lands
  /// after that would be overwritten when the game saves.
  @override
  Future<bool> pullMustFinishBeforeLaunch(Game game, String romPath) async {
    final slug = game.platformSlug?.toLowerCase() ?? '';
    if (!_isLrps2(slug)) return false;
    try {
      return (await _lrps2Cards(game, romPath)).shared;
    } catch (_) {
      return false;
    }
  }


  String _getRetroArchExe() {
    if (_platform.isWindows) return 'RetroArch.exe';
    if (_platform.isMacOS) return 'RetroArch.app/Contents/MacOS/RetroArch';
    return 'retroarch';
  }

  @override
  Future<String?> getSaveDir(Game game, String romPath) async {
    final slug = game.platformSlug?.toLowerCase() ?? '';
    final coreInfo = _getCoreInfo(slug);

    if (coreInfo == null) {
      debugPrint('[SaveSync] [retroarch] getSaveDir: no core info for slug="$slug"');
      return null;
    }

    // Ensure config flags are parsed on all platforms (Linux, macOS, Windows).
    await _readConfigSaveRoot();

    debugPrint('[SaveSync] [retroarch] getSaveDir: slug="$slug" core=${coreInfo.coreName} saveFolder=${coreInfo.saveFolder}');

    if (_platform.isLinux) {
      final baseDir = await _directoryService.getEmulatorAppSupportDirectory('retroarch', platformSlug: slug);
      final isEmuDeck = _directoryService.linuxSyncPreset == 'emudeck' || baseDir.contains('Emulation/saves');
      debugPrint('[SaveSync] [retroarch] getSaveDir linux baseDir=$baseDir emudeck=$isEmuDeck');

      if (isEmuDeck) {
        // EmuDeck structure: Emulation/saves/retroarch/saves/CoreName
        final result = p.basename(baseDir) == 'saves'
            ? p.join(baseDir, coreInfo.saveFolder)
            : p.join(baseDir, 'saves', coreInfo.saveFolder);
        debugPrint('[SaveSync] [retroarch] getSaveDir emudeck → $result');
        return result;
      }

      // Non-EmuDeck Linux: prefer the parsed savefile_directory from retroarch.cfg
      // (honors custom save locations); fall back to baseDir/saves otherwise.
      final saveRoot = (_cachedSaveRoot != null && await io.Directory(_cachedSaveRoot!).exists())
          ? _cachedSaveRoot!
          : p.join(baseDir, 'saves');
      debugPrint('[SaveSync] [retroarch] getSaveDir linux saveRoot=$saveRoot');

      // Non-EmuDeck Linux: respect sort_savefiles_enable config flag
      if (!_sortSavefiles) {
        // sort_savefiles_enable=false: saves go flat into saveRoot, no core subfolder
        debugPrint('[SaveSync] [retroarch] getSaveDir linux no-sort → $saveRoot');
        return saveRoot;
      }

      // Try the expected core subfolder first
      final expectedDir = p.join(saveRoot, coreInfo.saveFolder);
      if (await io.Directory(expectedDir).exists()) {
        debugPrint('[SaveSync] [retroarch] getSaveDir linux expectedDir exists → $expectedDir');
        return expectedDir;
      }

      // Fallback: scan saveRoot subdirectories for the ROM's save file, since
      // RetroArch core folder names are unpredictable (e.g. "ParaLLEl N64"
      // vs "Parallel N64" vs "N64").
      final romStem = p.basenameWithoutExtension(romPath).toLowerCase();
      final rootDir = io.Directory(saveRoot);
      if (await rootDir.exists()) {
        await for (final entity in rootDir.list()) {
          if (entity is! io.Directory) continue;
          final subdir = entity.path;
          await for (final f in io.Directory(subdir).list()) {
            if (f is! io.File) continue;
            final fname = p.basename(f.path).toLowerCase();
            if (isSaveNamedFor(fname, romStem) && _isSaveFile(fname)) {
              debugPrint('[SaveSync] [retroarch] getSaveDir linux fallback scan matched → $subdir');
              return subdir;
            }
          }
        }
      }

      debugPrint('[SaveSync] [retroarch] getSaveDir linux fallback expectedDir → $expectedDir');
      return expectedDir;
    }

    // macOS / Windows: respect sort_savefiles_enable config flag
    if (_savefilesInContentDir) {
      // savefiles_in_content_dir=true: saves go next to the ROM
      final result = io.File(romPath).parent.path;
      debugPrint('[SaveSync] [retroarch] getSaveDir savefilesInContentDir → $result');
      return result;
    }
    final saveRoot = await _resolveSaveRoot();
    if (!_sortSavefiles) {
      // sort_savefiles_enable=false: saves go flat into saveRoot, no core subfolder
      debugPrint('[SaveSync] [retroarch] getSaveDir no-sort → $saveRoot');
      return saveRoot;
    }

    // Try the expected core subfolder first
    final expectedDir = p.join(saveRoot, coreInfo.saveFolder);
    if (await io.Directory(expectedDir).exists()) {
      debugPrint('[SaveSync] [retroarch] getSaveDir expectedDir exists → $expectedDir');
      return expectedDir;
    }

    // Fallback 1: scan saveRoot subdirectories for the ROM's save file.
    // RetroArch core folder names are unpredictable (e.g. "ParaLLEl N64"
    // vs "Parallel N64" vs "N64"). Scanning finds the actual folder.
    final romStem = p.basenameWithoutExtension(romPath).toLowerCase();
    final rootDir = io.Directory(saveRoot);
    if (await rootDir.exists()) {
      await for (final entity in rootDir.list()) {
        if (entity is! io.Directory) continue;
        final subdir = entity.path;
        await for (final f in io.Directory(subdir).list()) {
          if (f is! io.File) continue;
          final fname = p.basename(f.path).toLowerCase();
          if (isSaveNamedFor(fname, romStem) && _isSaveFile(fname)) {
            debugPrint('[SaveSync] [retroarch] getSaveDir fallback1 scan matched → $subdir');
            return subdir;
          }
        }
      }
    }

    // No save for this game yet (first pull): the core's own folder, which
    // RetroArch names after the core's library_name. Never another core's
    // folder: guessing "the most recently modified one" wrote PS2 memory
    // cards into the N64 core's folder.
    debugPrint('[SaveSync] [retroarch] getSaveDir fallback expectedDir → $expectedDir');
    return expectedDir;
  }

  /// Whether [fileName] is a save named after [stem]: the stem followed by
  /// an extension, e.g. `Pokemon.srm` or `Pokemon.0.mcr`. A bare prefix is
  /// not enough: "Crash Bandicoot" must not claim `Crash Bandicoot 2.srm`.
  /// Case-insensitive.
  @visibleForTesting
  static bool isSaveNamedFor(String fileName, String stem) =>
      fileName.toLowerCase().startsWith('${stem.toLowerCase()}.');

  /// Whether the save file [fileName] has the same title as the ROM [stem],
  /// ignoring case, punctuation, word order and `(…)` / `[…]` tags, so
  /// `Legend of Zelda, The (Europe).srm` matches "The Legend of Zelda (USA)".
  /// Every word counts, numbers included: "Crash Bandicoot 2" does not match
  /// `Crash Bandicoot (Europe).srm`, and neither does "Crash Bandicoot" match
  /// `Crash Bandicoot 2.srm`.
  @visibleForTesting
  static bool isSameTitle(String stem, String fileName) {
    final a = _titleWords(stem);
    return a.isNotEmpty && setEquals(a, _titleWords(p.basenameWithoutExtension(fileName)));
  }

  static Set<String> _titleWords(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();

  @override
  Future<List<io.File>> getSaveFiles(Game game, String romPath, {DateTime? sessionStart, String syncMode = 'both'}) async {
    final map = await getSaveFilesWithScreenshots(game, romPath, sessionStart: sessionStart, syncMode: syncMode);
    final slug = game.platformSlug?.toLowerCase() ?? '';
    if (!_isLrps2(slug)) return map.keys.toList();
    // Local backups keep LRPS2's whole cards, not the save folders the sync
    // takes out of them.
    final files = [for (final f in map.keys) if (!p.isWithin(_lrps2TempRoot, f.path)) f];
    if (files.length != map.length) {
      for (final card in (await _lrps2Cards(game, romPath)).cards) {
        if (await card.exists()) files.add(card);
      }
    }
    return files;
  }

  @override
  Future<Map<io.File, io.File?>> getSaveFilesWithScreenshots(Game game, String romPath, {DateTime? sessionStart, String syncMode = 'both'}) async {
    final slug = game.platformSlug?.toLowerCase() ?? '';
    final coreInfo = _getCoreInfo(slug);

    if (coreInfo == null) return {};

    String? rootSaveDir;
    String? statesRoot;

    if (_platform.isLinux) {
      rootSaveDir = await getSaveDir(game, romPath);
      final baseDir = await _directoryService.getEmulatorAppSupportDirectory('retroarch', platformSlug: slug);

      if (_directoryService.linuxSyncPreset == 'emudeck') {
        // EmuDeck: saves are in Emulation/saves/retroarch, states in Emulation/states/retroarch
        // baseDir is .../Emulation/saves/retroarch
        final emulationRoot = p.dirname(p.dirname(baseDir));
        statesRoot = p.join(emulationRoot, 'states', 'retroarch', coreInfo.statesFolder);
      } else if (_directoryService.linuxSyncPreset == 'retrodeck') {
        // RetroDECK: baseDir is .../retroarch/
        statesRoot = p.join(baseDir, 'states', coreInfo.statesFolder);
      } else {
        statesRoot = p.join(p.dirname(baseDir), 'states', coreInfo.statesFolder);
      }
    } else {
      rootSaveDir = await getSaveDir(game, romPath);

      // States use the same root but under a states/ subfolder
      final saveRoot = await _resolveSaveRoot();
      statesRoot = p.join(io.Directory(saveRoot).parent.path, 'states', coreInfo.statesFolder);
    }

    debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots slug=$slug rootSaveDir=$rootSaveDir statesRoot=$statesRoot');

    if (rootSaveDir == null) return {};

    final stem = getRomStem(game);
    final List<io.File> filesToCheck = [];
    debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots stem=$stem syncMode=$syncMode');

    // Special case for PSP saves
    if (slug == 'psp' || slug == 'playstation-portable') {
      if (syncMode == 'saves' || syncMode == 'both') {
        final pspDir = io.Directory(rootSaveDir);
        if (await pspDir.exists()) {
          bool hasFiles = false;
          await for (final _ in pspDir.list(recursive: true)) {
            hasFiles = true;
            break;
          }
          if (hasFiles) {
            filesToCheck.add(io.File(rootSaveDir));
            debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots PSP dir has files');
          }
        }
      }
    } else if (_isLrps2(slug)) {
      if (syncMode == 'saves' || syncMode == 'both') {
        filesToCheck.addAll(await _lrps2SaveFolders(game, romPath, sessionStart));
      }
    } else {
      if (syncMode == 'saves' || syncMode == 'both') {
        final savesDirObj = io.Directory(rootSaveDir);
        if (await savesDirObj.exists()) {
          final stemLower = stem.toLowerCase();
          bool found = false;
          await for (final entity in savesDirObj.list()) {
            if (entity is! io.File) continue;
            final fname = p.basename(entity.path).toLowerCase();
            if (isSaveNamedFor(fname, stemLower) && _isSaveFile(fname)) {
              filesToCheck.add(entity);
              found = true;
              debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots exact match: $fname');
              break;
            }
          }
          if (!found) {
            await for (final entity in savesDirObj.list()) {
              if (entity is! io.File) continue;
              final fname = p.basename(entity.path).toLowerCase();
              if (_isSaveFile(fname) && isSameTitle(stem, fname)) {
                filesToCheck.add(entity);
                found = true;
                debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots title match: $fname');
                break;
              }
            }
          }
          if (!found) {
            // No save file matches this game by name (exact stem or same title). Do NOT fall back to "any .srm/.sav file in the directory" —
            // that previously caused an unrelated game's save (e.g. a different
            // ROM's leftover .srm sitting in the same core folder) to be picked up
            // and uploaded under the current game's RomM entry (see issue #95).
            // It is much safer to find nothing than to grab the wrong file.
            //
            // We still probe for the exact expected filename ($stem.srm); if it
            // doesn't exist, the existence check below drops it and no save is
            // reported — which is correct for save-state-only platforms/cores
            // (e.g. Atari 2600/Stella) that have no battery-backed save file.
            debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots no name-matching save found, probing for $stem.srm only');
            filesToCheck.add(io.File(p.join(rootSaveDir, '$stem.srm')));
          }
        } else {
          debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots rootSaveDir does not exist');
          filesToCheck.add(io.File(p.join(rootSaveDir, '$stem.srm')));
        }
      }
    }

    // Handle States
    if ((syncMode == 'states' || syncMode == 'both')) {
      final romStem = io.File(romPath).uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
      for (final checkStem in [stem, romStem]) {
        filesToCheck.add(io.File('$statesRoot/$checkStem.state.auto'));
        for (int i = 0; i <= 9; i++) {
          filesToCheck.add(io.File('$statesRoot/$checkStem.state$i'));
        }
      }
    }

    // Filter out non-existent files and apply sessionStart filter
    final finalResult = <io.File, io.File?>{};
    for (final f in filesToCheck) {
      final existsAsFile = await f.exists();
      final existsAsDir = await io.Directory(f.path).exists();
      if (!existsAsFile && !existsAsDir) continue;
      if (sessionStart != null && existsAsFile) {
        final stat = await f.stat();
        if (stat.modified.isBefore(sessionStart.subtract(const Duration(seconds: 2)))) continue;
      }

      // Check for screenshots if it's a state file
      io.File? screenshot;
      if (f.path.contains('.state')) {
        final screenshotPath = '${f.path}.png';
        final screenFile = io.File(screenshotPath);
        if (await screenFile.exists()) {
          screenshot = screenFile;
        }
      }

      finalResult[f] = screenshot;
    }
    debugPrint('[SaveSync] [retroarch] getSaveFilesWithScreenshots result: ${finalResult.length} file(s) found');
    return finalResult;
  }

  /// Whether a downloaded [fileName] is a PS1 memory card for port 1 that the
  /// core should open as the game's `<content>.srm`: every RetroArch PS1 core
  /// keeps card 1 there by default, and a raw `.mcd` card is the same format.
  /// Covers DuckStation's cards (`<name>_1.mcd`, shared `shared_card_1.mcd`,
  /// `mcd1.mcd`), PCSX-ReARMed's `<serial>_1.mcd` / `pcsx-card1.mcd`, and a
  /// `.mcd` with no port in its name. Cards for other ports keep their names.
  @visibleForTesting
  static bool isPs1Port1Card(String slug, String fileName, List<int> bytes) {
    if (!_ps1Slugs.contains(slug)) return false;
    final base = p.basename(fileName).toLowerCase();
    if (!base.endsWith('.mcd')) return false;
    if (!Ps1MemoryCard.looksLikeCard(bytes is Uint8List ? bytes : Uint8List.fromList(bytes))) return false;
    final port = RegExp(r'(?:_|^mcd|card)(\d+)\.mcd$').firstMatch(base)?.group(1);
    return port == null || int.parse(port) == 1;
  }

  static const _ps1Slugs = {'psx', 'ps1', 'playstation'};

  @override
  Future<bool> restoreSave(Game game, String destPath, Uint8List data, String filename) async {
    try {
      final slug = game.platformSlug?.toLowerCase() ?? '';
      final coreInfo = _getCoreInfo(slug);

      if (coreInfo == null) return false;

      // LRPS2: the saves go onto its memory card; states below as usual.
      final lrps2 = _isLrps2(slug);
      if (lrps2 && !filename.contains('.state')) {
        await _restoreLrps2(game, destPath, data, filename);
        if (!filename.toLowerCase().endsWith('.zip')) return true;
      }

      if (filename.toLowerCase().endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(data);
        for (final file in archive) {
          if (!file.isFile) continue;
          if (file.name == 'freegosy_sync.txt') continue;

          final isFileState = file.name.contains('.state');
          if (lrps2 && !isFileState) continue;
          String? fileTargetDir;
          if (isFileState) {
            if (_platform.isLinux) {
              final baseDir = await _directoryService.getEmulatorAppSupportDirectory('retroarch', platformSlug: slug);
              if (_directoryService.linuxSyncPreset == 'emudeck') {
                final emulationRoot = p.dirname(p.dirname(baseDir));
                fileTargetDir = p.join(emulationRoot, 'states', 'retroarch', coreInfo.statesFolder);
              } else if (_directoryService.linuxSyncPreset == 'retrodeck') {
                fileTargetDir = p.join(baseDir, 'states', coreInfo.statesFolder);
              } else {
                fileTargetDir = p.join(p.dirname(baseDir), 'states', coreInfo.statesFolder);
              }
            } else {
              final saveRoot = await _resolveSaveRoot();
              fileTargetDir = p.join(io.Directory(saveRoot).parent.path, 'states', coreInfo.statesFolder);
            }
          } else {
            fileTargetDir = await getSaveDir(game, destPath);
          }
          if (fileTargetDir == null) return true;
          final dir = io.Directory(fileTargetDir);
          if (!await dir.exists()) await dir.create(recursive: true);

          String targetFilename = file.name;
          if (!isFileState && file.name.toLowerCase().endsWith('.sav')) {
            targetFilename = '${p.basenameWithoutExtension(file.name)}.srm';
          } else if (!isFileState && isPs1Port1Card(slug, file.name, file.content)) {
            targetFilename = '${getRomStem(game)}.srm';
          }

          final targetPath = p.normalize(p.join(fileTargetDir, targetFilename));
          await backupSave(targetPath);
          await io.File(targetPath).writeAsBytes(file.content);
        }
        return true;
      }

      String? targetDir;
      final isState = filename.contains('.state');

      if (isState) {
        if (_platform.isLinux) {
          final baseDir = await _directoryService.getEmulatorAppSupportDirectory('retroarch', platformSlug: slug);
          if (_directoryService.linuxSyncPreset == 'emudeck') {
            final emulationRoot = p.dirname(p.dirname(baseDir));
            targetDir = p.join(emulationRoot, 'states', 'retroarch', coreInfo.statesFolder);
          } else if (_directoryService.linuxSyncPreset == 'retrodeck') {
            targetDir = p.join(baseDir, 'states', coreInfo.statesFolder);
          } else {
            targetDir = p.join(p.dirname(baseDir), 'states', coreInfo.statesFolder);
          }
        } else {
          final saveRoot = await _resolveSaveRoot();
          targetDir = p.join(io.Directory(saveRoot).parent.path, 'states', coreInfo.statesFolder);
        }
      } else {
        // For saves: use getSaveDir() which scans for the actual folder
        targetDir = await getSaveDir(game, destPath);
      }

      if (targetDir == null) return false;
      final dir = io.Directory(targetDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      // Handle .sav to .srm renaming for RetroArch NDS cores
      String targetFilename = filename;
      if (!isState && filename.toLowerCase().endsWith('.sav')) {
        targetFilename = '${p.basenameWithoutExtension(filename)}.srm';
      } else if (!isState && isPs1Port1Card(slug, filename, data)) {
        targetFilename = '${getRomStem(game)}.srm';
      }

      final targetPath = p.normalize(p.join(targetDir, targetFilename));
      await backupSave(targetPath); // Backup existing file
      await io.File(targetPath).writeAsBytes(data);
      return true;
    } on SaveSyncNotPossibleException {
      rethrow;
    } catch (e) {
      debugPrint('[SaveSync] [retroarch] restoreSave failed: $e');
      return false;
    }
  }
}

class _CoreInfo {
  final String coreName;
  final String saveFolder;
  final String statesFolder;
  const _CoreInfo(this.coreName, this.saveFolder, this.statesFolder);
}
