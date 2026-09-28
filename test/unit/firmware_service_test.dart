import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/emulator/firmware_service.dart';
import 'package:freegosy/core/emulator/emulator_strategy.dart';
import 'package:freegosy/core/emulator/bios_registry.dart';
import 'package:freegosy/core/emulator/emulator_registry_data.dart';
import 'package:freegosy/core/emulator/retroarch_core_list.dart';

import 'firmware_service_test.mocks.dart';

class MockEmulatorStrategy extends Mock implements EmulatorStrategy {
  final String _emulatorId;
  MockEmulatorStrategy([this._emulatorId = 'test_emulator']);
  @override
  String get emulatorId => _emulatorId;
}

@GenerateMocks([RommService, DirectoryService, StrategyRegistry])
void main() {
  late FirmwareService service;
  late MockRommService mockRommService;
  late MockDirectoryService mockDirectoryService;
  late MockStrategyRegistry mockStrategyRegistry;

  setUp(() {
    mockRommService = MockRommService();
    mockDirectoryService = MockDirectoryService();
    mockStrategyRegistry = MockStrategyRegistry();
    service = FirmwareService(mockRommService, mockDirectoryService, mockStrategyRegistry);
  });

  group('FirmwareService', () {
    test('syncAllFirmware() downloads and places firmware correctly', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_test');
      final biosDir = p.join(tempDir.path, 'BIOS');
      await Directory(biosDir).create();

      final firmware = Firmware(
        id: 1,
        fileName: 'test_bios.bin',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 1,
        name: 'Test Platform',
        slug: 'test_platform',
        firmware: [firmware],
      );

      final mockStrategy = MockEmulatorStrategy();

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('test_platform')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('test_emulator')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

      await service.syncAllFirmware();

      final destFile = File(p.join(biosDir, 'test_bios.bin'));
      expect(await destFile.exists(), isTrue);
      expect(await destFile.readAsBytes(), equals([1, 2, 3]));

      await tempDir.delete(recursive: true);
    });

    test('syncAllFirmware() with installed emulators syncs every installed emulator for the platform', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_test_installed');
      final dirA = p.join(tempDir.path, 'A');
      final dirB = p.join(tempDir.path, 'B');

      final firmware = Firmware(id: 3, fileName: 'shared_bios.bin', fileSizeBytes: 3);
      final platform = Platform(id: 1, name: 'Test Platform', slug: 'test_platform', firmware: [firmware]);

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getAllStrategiesForSlug('test_platform')).thenReturn([
        MockEmulatorStrategy('emu_a'),
        MockEmulatorStrategy('emu_b'),
        MockEmulatorStrategy('emu_not_installed'),
      ]);
      when(mockDirectoryService.getEmulatorBiosDirectory('emu_a')).thenAnswer((_) async => dirA);
      when(mockDirectoryService.getEmulatorBiosDirectory('emu_b')).thenAnswer((_) async => dirB);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

      await service.syncAllFirmware(installedEmulatorIds: {'emu_a', 'emu_b'});

      expect(await File(p.join(dirA, 'shared_bios.bin')).exists(), isTrue);
      expect(await File(p.join(dirB, 'shared_bios.bin')).exists(), isTrue);
      verifyNever(mockDirectoryService.getEmulatorBiosDirectory('emu_not_installed'));
      verifyNever(mockStrategyRegistry.getStrategyForSlug(any));

      await tempDir.delete(recursive: true);
    });

    test('emulatorIdsForFirmwareSync() returns nothing when no installed emulator supports the platform', () {
      when(mockStrategyRegistry.getAllStrategiesForSlug('test_platform')).thenReturn([MockEmulatorStrategy('emu_a')]);
      expect(service.emulatorIdsForFirmwareSync('test_platform', {'emu_other'}), isEmpty);
    });

    test('syncFirmwareForPlatform() syncs specifically for one platform', () async {
       final tempDir = await Directory.systemTemp.createTemp('firmware_test_single');
      final biosDir = p.join(tempDir.path, 'BIOS');
      await Directory(biosDir).create();

      final firmware = Firmware(
        id: 2,
        fileName: 'platform_bios.bin',
        fileSizeBytes: 200,
      );

      final platform = Platform(
        id: 2,
        name: 'Single Platform',
        slug: 'single_slug',
        firmware: [firmware],
      );

      final mockStrategy = MockEmulatorStrategy();

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('single_slug')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('test_emulator')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([4, 5, 6]));

      await service.syncFirmwareForPlatform('single_slug');

      final destFile = File(p.join(biosDir, 'platform_bios.bin'));
      expect(await destFile.exists(), isTrue);
      expect(await destFile.readAsBytes(), equals([4, 5, 6]));

      await tempDir.delete(recursive: true);
    });
  });

  group('Firmware BIOS placement via registry subdirectory', () {
    test('Flycast Libretro BIOS placed in dc/ subdirectory per registry spec', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_subdir_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      // RomM returns filePath as "dc/bios" but the BIOS registry knows
      // Flycast expects files in system/dc/
      final firmware = Firmware(
        id: 3,
        fileName: 'dc_boot.bin',
        filePath: 'dc/bios',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 3,
        name: 'Dreamcast',
        slug: 'dc',
        firmware: [firmware],
      );

      // Use 'flycast' emulatorId so the BIOS registry lookup works
      final mockStrategy = MockEmulatorStrategy('retroarch');

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('dc')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('retroarch')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

      await service.syncAllFirmware();

      // Registry says subdirectory: 'dc' → system/dc/dc_boot.bin
      final correctPath = File(p.join(biosDir, 'dc', 'dc_boot.bin'));
      final wrongRommPath = File(p.join(biosDir, 'dc', 'bios', 'dc_boot.bin'));

      expect(await correctPath.exists(), isTrue,
          reason: 'BIOS should be in dc/ subdirectory per registry');
      expect(await wrongRommPath.exists(), isFalse,
          reason: 'Should NOT use RomM filePath as subdirectory');

      await tempDir.delete(recursive: true);
    });

    test('PS1 BIOS placed flat in system root (no subdirectory in registry)', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_flat_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      // RomM returns filePath as "psx/bios" but registry has no subdirectory
      // for PS1 BIOS → should go flat in system/
      final firmware = Firmware(
        id: 4,
        fileName: 'scph5501.bin',
        filePath: 'psx/bios',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 4,
        name: 'PlayStation',
        slug: 'psx',
        firmware: [firmware],
      );

      // mednafen_psx_hw has BIOS entries with no subdirectory
      final mockStrategy = MockEmulatorStrategy('mednafen_psx_hw');

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('psx')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('mednafen_psx_hw')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([4, 5, 6]));

      await service.syncAllFirmware();

      // No subdirectory in registry → system/scph5501.bin
      final correctPath = File(p.join(biosDir, 'scph5501.bin'));
      final wrongNestedPath = File(p.join(biosDir, 'psx', 'bios', 'scph5501.bin'));

      expect(await correctPath.exists(), isTrue,
          reason: 'PS1 BIOS should be flat in system root');
      expect(await wrongNestedPath.exists(), isFalse,
          reason: 'Should NOT nest under RomM filePath psx/bios/');

      await tempDir.delete(recursive: true);
    });

    test('unknown firmware (no registry match) placed flat in system root', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_unknown_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      // Firmware not in any registry spec — should fall back to flat placement
      final firmware = Firmware(
        id: 5,
        fileName: 'custom_bios.bin',
        filePath: 'custom/bios',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 5,
        name: 'Custom',
        slug: 'custom',
        firmware: [firmware],
      );

      final mockStrategy = MockEmulatorStrategy();

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('custom')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('test_emulator')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([7, 8, 9]));

      await service.syncAllFirmware();

      // No registry entry → flat
      final correctPath = File(p.join(biosDir, 'custom_bios.bin'));
      final wrongPath = File(p.join(biosDir, 'custom', 'bios', 'custom_bios.bin'));

      expect(await correctPath.exists(), isTrue,
          reason: 'Unknown firmware should go flat in system root');
      expect(await wrongPath.exists(), isFalse,
          reason: 'Should NOT use RomM filePath for unknown firmware');

      await tempDir.delete(recursive: true);
    });

    test('RetroArch Flycast core: dc_boot.bin placed in dc/ subdirectory', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_ra_flycast_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      // This is the actual user scenario from issue #56:
      // RomM returns filePath: "dc/bios", emulator is RetroArch (not standalone Flycast)
      final firmware = Firmware(
        id: 7,
        fileName: 'dc_boot.bin',
        filePath: 'dc/bios',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 7,
        name: 'Dreamcast',
        slug: 'dc',
        firmware: [firmware],
      );

      // Strategy is 'retroarch', NOT 'flycast' — this is the key difference
      final mockStrategy = MockEmulatorStrategy('retroarch');

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('dc')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('retroarch')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

      await service.syncAllFirmware();

      // RetroArch resolves default core for 'dc' → 'flycast_libretro' → registry key 'flycast'
      // Registry says subdirectory: 'dc' → system/dc/dc_boot.bin
      final correctPath = File(p.join(biosDir, 'dc', 'dc_boot.bin'));
      final wrongFlatPath = File(p.join(biosDir, 'dc_boot.bin'));
      final wrongRommPath = File(p.join(biosDir, 'dc', 'bios', 'dc_boot.bin'));

      expect(await correctPath.exists(), isTrue,
          reason: 'dc_boot.bin should be in dc/ subdirectory even when using RetroArch');
      expect(await wrongFlatPath.exists(), isFalse,
          reason: 'Should NOT be flat in system root');
      expect(await wrongRommPath.exists(), isFalse,
          reason: 'Should NOT use RomM filePath dc/bios/');

      await tempDir.delete(recursive: true);
    });

    test('RetroArch PS1 core: BIOS placed flat in system root', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_ra_psx_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      final firmware = Firmware(
        id: 8,
        fileName: 'scph5501.bin',
        filePath: 'psx/bios',
        fileSizeBytes: 100,
      );

      final platform = Platform(
        id: 8,
        name: 'PlayStation',
        slug: 'psx',
        firmware: [firmware],
      );

      final mockStrategy = MockEmulatorStrategy('retroarch');

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('psx')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('retroarch')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([4, 5, 6]));

      await service.syncAllFirmware();

      // RetroArch resolves default core for 'psx' → 'mednafen_psx_hw' → registry has no subdirectory
      final correctPath = File(p.join(biosDir, 'scph5501.bin'));
      final wrongPath = File(p.join(biosDir, 'psx', 'bios', 'scph5501.bin'));

      expect(await correctPath.exists(), isTrue,
          reason: 'PS1 BIOS should be flat in system root');
      expect(await wrongPath.exists(), isFalse,
          reason: 'Should NOT nest under RomM filePath');

      await tempDir.delete(recursive: true);
    });

    test('LRPS2 (PCSX2 Libretro) BIOS placed in pcsx2/bios/ subdirectory per registry', () async {
      final tempDir = await Directory.systemTemp.createTemp('firmware_ps2_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      // RomM returns filePath: "ps2/bios" but the PCSX2 registry entry
      // has subdirectory: "pcsx2/bios"
      final firmware = Firmware(
        id: 6,
        fileName: 'SCPH-70000_BIOS_V12_USA_200.BIN',
        filePath: 'ps2/bios',
        fileSizeBytes: 200,
      );

      final platform = Platform(
        id: 6,
        name: 'PlayStation 2',
        slug: 'ps2',
        firmware: [firmware],
      );

      final mockStrategy = MockEmulatorStrategy('retroarch');

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('ps2')).thenReturn(mockStrategy);
      when(mockDirectoryService.getEmulatorBiosDirectory('retroarch')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(firmware, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([10, 11, 12]));

      await service.syncAllFirmware();

      // Registry says subdirectory: 'pcsx2/bios'
      final correctPath = File(p.join(biosDir, 'pcsx2', 'bios', 'SCPH-70000_BIOS_V12_USA_200.BIN'));
      final wrongRommPath = File(p.join(biosDir, 'ps2', 'bios', 'SCPH-70000_BIOS_V12_USA_200.BIN'));

      expect(await correctPath.exists(), isTrue,
          reason: 'PS2 BIOS should be in pcsx2/bios/ per registry');
      expect(await wrongRommPath.exists(), isFalse,
          reason: 'Should NOT use RomM filePath ps2/bios/');

      await tempDir.delete(recursive: true);
    });

    test('PC-98 (Neko Project II Kai) BIOS goes in np2kai/, where the core reads it', () async {
      // np2kai_libretro.info: firmware paths are "np2kai/bios.rom",
      // "np2kai/sound.rom", ... The entry was keyed "neko_project_ii_kai",
      // which no core is called, so the files landed flat in system/.
      final tempDir = await Directory.systemTemp.createTemp('firmware_pc98_test');
      final biosDir = p.join(tempDir.path, 'system');
      await Directory(biosDir).create();

      final bios = Firmware(id: 9, fileName: 'bios.rom', filePath: 'pc98/bios', fileSizeBytes: 1);
      final font = Firmware(id: 10, fileName: 'font.bmp', filePath: 'pc98/bios', fileSizeBytes: 1);
      final platform = Platform(id: 9, name: 'PC-98', slug: 'pc98', firmware: [bios, font]);

      when(mockRommService.getPlatforms()).thenAnswer((_) async => [platform]);
      when(mockStrategyRegistry.getStrategyForSlug('pc98')).thenReturn(MockEmulatorStrategy('retroarch'));
      when(mockDirectoryService.getEmulatorBiosDirectory('retroarch')).thenAnswer((_) async => biosDir);
      when(mockRommService.downloadFirmware(any, onProgress: anyNamed('onProgress')))
          .thenAnswer((_) async => Uint8List.fromList([1]));

      await service.syncAllFirmware();

      expect(File(p.join(biosDir, 'np2kai', 'bios.rom')).existsSync(), isTrue);
      expect(File(p.join(biosDir, 'np2kai', 'font.bmp')).existsSync(), isTrue);
      expect(File(p.join(biosDir, 'bios.rom')).existsSync(), isFalse);

      await tempDir.delete(recursive: true);
    });
  });

  group('BIOS registry keys', () {
    test('every entry is found: keyed by an emulator id or a RetroArch core without _libretro', () {
      // FirmwareService looks a standalone emulator's entry up by its id and
      // RetroArch's by the platform's default core ("mednafen_saturn" for
      // mednafen_saturn_libretro). An entry under any other name is never
      // used: its subfolders and MD5 checks do nothing.
      final coreKeys = kRetroArchCores.map((c) => c.id.replaceAll(RegExp(r'_libretro$'), '')).toSet();
      final emulatorIds = kEmulatorDefinitions.map((e) => e['id'] as String).toSet();
      // No core or emulator for these in Freegosy yet.
      const noCoreYet = {'gearcoleco', 'emuscv', 'hatarib'};
      final unreachable = registeredEmulatorIds
          .where((k) => !coreKeys.contains(k) && !emulatorIds.contains(k) && !noCoreYet.contains(k))
          .toList();
      expect(unreachable, isEmpty);
    });
  });
}
