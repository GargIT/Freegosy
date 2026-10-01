import 'dart:io' as io;
import 'package:path/path.dart' as p;
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'linux_environment_strategy.dart';

class NativeLinuxStrategy extends LinuxEnvironmentStrategy {
  // Cache for Flatpak detection — avoids running `flatpak list` repeatedly.
  Map<String, String>? _flatpakCache;
  final PlatformInfo _platform;

  NativeLinuxStrategy({PlatformInfo? platform}) : _platform = platform ?? PlatformInfo.current;

  @override
  String get name => 'Default';

  @override
  String get id => 'default';

  @override
  String getRomsRoot(String home, String? customPath, String? emudeckRoot) {
    return customPath ?? p.join(home, 'ROMs');
  }

  @override
  String getEmulatorsRoot(String home, String? customPath, String? emudeckRoot) {
    return customPath ?? p.join(home, 'Emulators');
  }

  @override
  String getEmulatorAppSupportDirectory(String home, String emulatorName, String? emudeckRoot, {String? platformSlug}) {
    // check common configuration directory for flatpak instalations
    var lowerCaseEmulatorName = emulatorName.toLowerCase();
    var flatpakPackage = kEmulatorFlatpakPackages[lowerCaseEmulatorName];
    if(flatpakPackage != null) {
      var supportDirectoryParent = p.join(home, ".var", "app", flatpakPackage, "config");
      final dir = io.Directory(supportDirectoryParent);
      if(dir.existsSync()) {
          var lowerAppName = flatpakPackage.split('.').last.toLowerCase();
          for (final entity in dir.listSync()) {  
            if (entity is io.File) continue;
            final lowerFolderName = p.basename(entity.path).toLowerCase();
            if (lowerFolderName == lowerAppName) {
              return entity.path;
            }
          }
      }
    }
    // check common configuration directory for app image instalations
    var altSupportDirectoryPath =  p.join(home, '.local', 'share', lowerCaseEmulatorName);
    if(io.Directory(altSupportDirectoryPath).existsSync()) {
          return altSupportDirectoryPath;
    }
    return p.join(home, '.config', emulatorName);
  }

  @override
  String getBiosPath(String home, String? emudeckRoot) {
    return p.join(home, 'Emulators', 'BIOS');
  }

  @override
  Future<String?> findExecutable(String emulatorId, String executableName, String emulatorsRoot, String? emudeckRoot) async {
    // 1. Check direct file
    final direct = io.File(p.join(emulatorsRoot, executableName));
    if (await direct.exists()) return direct.path;

    // 2. Check common AppImage locations (emulator folder, Emulators root,
    //    EmuDeck, Gear Lever, manual installs)
    final home = _platform.environment['HOME'] ?? '';
    // A release archive extracts into its own subfolder, e.g.
    // retroarch/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage, so
    // the emulator's folder is searched one level down as well.
    final emulatorDir = io.Directory(p.join(emulatorsRoot, emulatorId));
    final nestedDirs = <io.Directory>[];
    try {
      if (await emulatorDir.exists()) {
        await for (final entry in emulatorDir.list()) {
          if (entry is io.Directory) nestedDirs.add(entry);
        }
        nestedDirs.sort((a, b) => a.path.compareTo(b.path));
      }
    } catch (_) {
      // Unreadable folder: search the rest.
    }
    final searchDirs = [
      emulatorDir,
      ...nestedDirs,
      io.Directory(emulatorsRoot),
      io.Directory(p.join(home, 'Applications')),
      io.Directory(p.join(home, 'AppImages')),
      io.Directory(p.join(home, '.local', 'bin')),
      io.Directory(p.join(home, 'bin')),
    ];
    final found = await _findInDirs(searchDirs, emulatorId, executableName);
    if (found != null) return found;

    // 3. Check if a Flatpak is installed for this emulator
    final flatpakPkg = await _flatpakPackageFor(emulatorId);
    if (flatpakPkg != null) {
      // Return the Flatpak command string — the launch method will handle it
      return 'flatpak run $flatpakPkg';
    }

    return null;
  }

  /// An executable or AppImage for [emulatorId] inside the user-chosen
  /// [folder] or one level below it (a release archive extracts into its own
  /// subfolder), matched the same way as the default locations.
  @override
  Future<String?> findAppImageInFolder(String folder, String emulatorId, String executableName) async {
    final dirs = <io.Directory>[io.Directory(folder)];
    try {
      final nested = <io.Directory>[];
      await for (final entry in io.Directory(folder).list()) {
        if (entry is io.Directory) nested.add(entry);
      }
      nested.sort((a, b) => a.path.compareTo(b.path));
      dirs.addAll(nested);
    } catch (_) {
      // Missing or unreadable folder: nothing to find.
    }
    return _findInDirs(dirs, emulatorId, executableName);
  }

  /// The first file in [dirs] (searched in order, not recursively) named
  /// [executableName], or an AppImage whose name fits [emulatorId].
  Future<String?> _findInDirs(List<io.Directory> dirs, String emulatorId, String executableName) async {
    final targetLower = executableName.toLowerCase();
    final targetStem = targetLower.replaceAll(RegExp(r'\.appimage$'), '');
    // Names to match AppImage files against, e.g. "pcsx2-qt" -> {pcsx2-qt, pcsx2}
    final idLower = emulatorId.toLowerCase();
    final names = <String>{
      targetStem,
      targetStem.split(RegExp(r'[-_.]')).first,
      idLower,
    }..removeWhere((n) => n.isEmpty);

    for (final dir in dirs) {
      if (!await dir.exists()) continue;

      // Exact name match
      final candidate = io.File(p.join(dir.path, executableName));
      if (await candidate.exists()) return candidate.path;

      try {
        final entries = await dir.list().toList();
        String? fuzzy;
        for (final entry in entries) {
          if (entry is! io.File) continue;
          final baseNameLower = p.basename(entry.path).toLowerCase();

          // Exact match (case-insensitive)
          if (baseNameLower == targetLower) return entry.path;

          // Versioned/renamed AppImages, e.g. "Cemu-2.6-x86_64.AppImage",
          // "DuckStation-x64.AppImage", "rpcs3-v0.0.35_linux64.AppImage".
          if (fuzzy == null && baseNameLower.endsWith('.appimage')) {
            final stem = baseNameLower.substring(0, baseNameLower.length - '.appimage'.length);
            final head = stem.split(RegExp(r'[-_.\s]')).first;
            if (names.contains(stem) || names.contains(head)) fuzzy = entry.path;
          }
        }
        if (fuzzy != null) return fuzzy;
      } catch (_) {
        // Silently ignore permission errors or other listing issues
      }
    }
    return null;
  }

  @override
  Future<void> launch(Game game, String romPath, String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = LinuxEnvironmentStrategy.splitCommand(exePath);
    _checkFlatpakSandboxAccessIfNeeded(exe, cmdArgs, romPath);
    if (cmdArgs.isNotEmpty) {
      // Flatpak commands (e.g. "flatpak run org.DolphinEmu.dolphin-emu") are
      // resolved via a raw PATH lookup by Process.start, which uses the app's
      // inherited environment rather than a shell-resolved one. On some
      // desktop/session setups (e.g. Steam Deck gamescope sessions) that PATH
      // doesn't include `flatpak`, causing a ProcessException even though
      // `flatpak` works fine from an interactive shell. splitCommand resolves
      // `flatpak` to its absolute path; if it couldn't be found, fall back to
      // shell resolution.
      await io.Process.start(exe, [...cmdArgs, ...args, romPath], mode: io.ProcessStartMode.detached, runInShell: exe == 'flatpak');
    } else if (exePath.endsWith('.sh')) {
      await io.Process.start('bash', [exePath, ...args, romPath], mode: io.ProcessStartMode.detached);
    } else {
      await io.Process.start(exePath, [...args, romPath], mode: io.ProcessStartMode.detached);
    }
  }

  @override
  Future<io.Process?> launchWithHandle(Game game, String romPath, String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = LinuxEnvironmentStrategy.splitCommand(exePath);
    _checkFlatpakSandboxAccessIfNeeded(exe, cmdArgs, romPath);
    if (cmdArgs.isNotEmpty) {
      // See comment in launch() above regarding runInShell for flatpak commands.
      return await io.Process.start(exe, [...cmdArgs, ...args, romPath], mode: io.ProcessStartMode.normal, runInShell: exe == 'flatpak');
    } else if (exePath.endsWith('.sh')) {
      return await io.Process.start('bash', [exePath, ...args, romPath], mode: io.ProcessStartMode.normal);
    } else {
      return await io.Process.start(exePath, [...args, romPath], mode: io.ProcessStartMode.normal);
    }
  }

  @override
  Future<void> launchStandalone(String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = LinuxEnvironmentStrategy.splitCommand(exePath);
    if (cmdArgs.isNotEmpty) {
      // See comment in launch() above regarding runInShell for flatpak commands.
      await io.Process.start(exe, [...cmdArgs, ...args], mode: io.ProcessStartMode.detached, runInShell: exe == 'flatpak');
    } else if (exePath.endsWith('.sh')) {
      await io.Process.start('bash', [exePath, ...args], mode: io.ProcessStartMode.detached);
    } else {
      final exeDir = io.File(exePath).parent.path;
      await io.Process.start(exePath, args, mode: io.ProcessStartMode.detached, workingDirectory: exeDir);
    }
  }

  /// Returns the Flatpak package ID for [emulatorId], using cached detection.
  Future<String?> _flatpakPackageFor(String emulatorId) async {
    _flatpakCache ??= await detectFlatpakEmulators();
    return _flatpakCache![emulatorId];
  }

  /// Additive pre-launch check (issue #75): if [exe]/[cmdArgs] represent a
  /// `flatpak run <package-id>` invocation, verify [romPath] is within the
  /// Flatpak's default sandbox access before handing off to Process.start.
  /// Flatpak confines its filesystem access to `$HOME`, `/run/media`, and
  /// `/media` by default — a ROM stored elsewhere (e.g. `/mnt/qvo/...`)
  /// fails to launch regardless of filename, which was previously
  /// misdiagnosed as a "spaces in filename" bug. Throws
  /// [FlatpakSandboxAccessException] with an actionable
  /// `flatpak override --user --filesystem=...` command; does nothing for
  /// non-Flatpak launches or paths already inside the default allowlist.
  void _checkFlatpakSandboxAccessIfNeeded(String exe, List<String> cmdArgs, String romPath) {
    if (!LinuxEnvironmentStrategy.isFlatpakExecutable(exe) || cmdArgs.length < 2 || cmdArgs.first != 'run') return;
    final flatpakPackageId = cmdArgs[1];
    final home = _platform.environment['HOME'] ?? '';
    if (home.isEmpty) return; // Can't determine default access without $HOME; skip rather than false-positive.
    LinuxEnvironmentStrategy.checkFlatpakSandboxAccess(flatpakPackageId, romPath, home: home);
  }
}
