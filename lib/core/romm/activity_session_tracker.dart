import 'dart:async';
import 'romm_service.dart';

/// Keeps RomM's real-time "active sessions" board in sync with a running
/// game (issue #93): sends an immediate heartbeat on [start], repeats it
/// periodically while the session is open, and clears it on [stop].
///
/// [RommService.sendActivityHeartbeat] and [RommService.clearActivityHeartbeat]
/// already fail silently, so this class does no error handling of its own.
class ActivitySessionTracker {
  final RommService _rommService;
  final Duration heartbeatInterval;

  Timer? _timer;
  String? _deviceId;

  ActivitySessionTracker(this._rommService, {this.heartbeatInterval = const Duration(seconds: 30)});

  bool get isActive => _timer != null;

  /// Sends an initial heartbeat for [romId]/[deviceId], then repeats it
  /// every [heartbeatInterval] until [stop] is called.
  Future<void> start({required String romId, required String deviceId}) async {
    _deviceId = deviceId;
    await _rommService.sendActivityHeartbeat(romId: romId, deviceId: deviceId);
    _timer?.cancel();
    _timer = Timer.periodic(heartbeatInterval, (_) {
      _rommService.sendActivityHeartbeat(romId: romId, deviceId: deviceId);
    });
  }

  /// Cancels the periodic heartbeat and clears the active session
  /// immediately, rather than waiting for it to expire server-side. A no-op
  /// if [start] was never called.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final deviceId = _deviceId;
    _deviceId = null;
    if (deviceId != null) await _rommService.clearActivityHeartbeat(deviceId: deviceId);
  }
}
