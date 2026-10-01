import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/linux_strategies/linux_environment_strategy.dart';

void main() {
  const wayland = {'WAYLAND_DISPLAY': 'wayland-0', 'DISPLAY': ':0'};

  Map<String, String> env(String id, Map<String, String> parent, {bool nvidia = true}) =>
      LinuxEnvironmentStrategy.launchEnvironment(id, parent, nvidiaDriver: nvidia);

  test('Dolphin on NVIDIA in a Wayland session is launched with an X11 EGL platform and Qt xcb', () {
    expect(env('dolphin', wayland), {'EGL_PLATFORM': 'x11', 'QT_QPA_PLATFORM': 'xcb'});
  });

  test('other drivers are left alone', () {
    expect(env('dolphin', wayland, nvidia: false), isEmpty);
  });

  test('an X11 session is left alone', () {
    expect(env('dolphin', {'DISPLAY': ':0'}), isEmpty);
  });

  test('without XWayland (no DISPLAY) there is nothing to fall back to, so nothing is forced', () {
    expect(env('dolphin', {'WAYLAND_DISPLAY': 'wayland-0'}), isEmpty);
  });

  test('a session-wide EGL_PLATFORM=wayland (what triggers the crash) is replaced', () {
    expect(env('dolphin', {...wayland, 'EGL_PLATFORM': 'wayland'}), {'EGL_PLATFORM': 'x11', 'QT_QPA_PLATFORM': 'xcb'});
    expect(env('dolphin', {...wayland, 'EGL_PLATFORM': 'wayland', 'QT_QPA_PLATFORM': 'wayland'}),
        {'EGL_PLATFORM': 'x11', 'QT_QPA_PLATFORM': 'xcb'});
  });

  test('only values that would change are returned', () {
    expect(env('dolphin', {...wayland, 'EGL_PLATFORM': 'x11'}), {'QT_QPA_PLATFORM': 'xcb'});
    expect(env('dolphin', {...wayland, 'EGL_PLATFORM': 'x11', 'QT_QPA_PLATFORM': 'xcb'}), isEmpty);
  });

  test('other emulators are left alone', () {
    expect(env('pcsx2', wayland), isEmpty);
    expect(env('retroarch', wayland), isEmpty);
  });
}
