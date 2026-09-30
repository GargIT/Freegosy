import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/rom_scanner_service.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/rom_mapping_service.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

class _FakeRommService extends Fake implements RommService {}

class _FakeDirectoryService extends Fake implements DirectoryService {
  @override
  final String romsRootPath;
  _FakeDirectoryService(this.romsRootPath);
}

void main() {
  late Directory tmp;
  late RomMappingService mappings;
  final root = p.join(p.separator, 'new', 'roms');
  final oldDrivePath = p.join(p.separator, 'old', 'roms', 'snes', 'a.sfc');
  final newDrivePath = p.join(root, 'snes', 'b.sfc');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('freegosy_prune_test');
    Hive.init(tmp.path);
    mappings = RomMappingService();
    await mappings.init();
    await mappings.updateMapping(oldDrivePath, '1');
    await mappings.updateMapping(newDrivePath, '2');
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  RomScannerService scanner(PathProbe probe) =>
      RomScannerService(_FakeRommService(), mappings, _FakeDirectoryService(root), probe: probe);

  test('unreadable path outside the ROMs root is pruned without throwing', () async {
    final pruned = await scanner((_) async => null).pruneDeadMappings();
    expect(pruned, 1);
    expect(mappings.getMappings().keys, [newDrivePath]);
  });

  test('missing paths are pruned, existing ones kept', () async {
    final pruned = await scanner((path) async => path == newDrivePath).pruneDeadMappings();
    expect(pruned, 1);
    expect(mappings.getMappings().keys, [newDrivePath]);
  });

  test('unreadable path inside the ROMs root is kept (drive may be temporarily unavailable)', () async {
    await scanner((_) async => null).pruneDeadMappings();
    expect(mappings.getMappings().containsKey(newDrivePath), isTrue);
  });
}
