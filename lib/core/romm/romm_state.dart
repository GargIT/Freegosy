import 'dart:io' as io;
import 'dart:typed_data';

/// A save state stored on RomM (`/api/states`). States belong to one RomM
/// user and are private unless the owner flips `is_public` — Freegosy never
/// does.
class RommState {
  final int id;
  final String fileName;

  /// RomM's `updated_at`. Only ever compared for equality against the value
  /// stored right after our own upload/download: RomM sets it on rescans too,
  /// so it says "something happened", not "the bytes are newer".
  final String? updatedAt;

  const RommState({required this.id, required this.fileName, this.updatedAt});

  factory RommState.fromJson(Map<String, dynamic> json) => RommState(
        id: (json['id'] as num).toInt(),
        fileName: json['file_name'].toString(),
        updatedAt: json['updated_at']?.toString(),
      );
}

/// RomM answered 404 for a state id: the state was deleted on the server, or
/// the id belongs to a different RomM account than the one now logged in.
class RommStateNotFoundException implements Exception {
  final int stateId;
  const RommStateNotFoundException(this.stateId);

  @override
  String toString() => 'RomM state $stateId not found';
}

/// The slice of RomM's states API that state sync depends on. Kept narrow so
/// StateSyncService can be tested against an in-memory fake.
abstract class RommStatesApi {
  Future<List<RommState>> listStates(String romId);

  Future<RommState> uploadState(String romId, io.File file,
      {required String fileName});

  /// Throws [RommStateNotFoundException] if [stateId] no longer exists.
  Future<RommState> updateState(int stateId, io.File file,
      {required String fileName});

  /// Throws [RommStateNotFoundException] if [stateId] no longer exists.
  Future<Uint8List> downloadState(int stateId);
}
