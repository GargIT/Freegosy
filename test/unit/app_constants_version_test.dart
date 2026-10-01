import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/constants/app_constants.dart';

void main() {
  test('a leading v from the release tag is dropped, so the UI shows a single v', () {
    expect(AppConstants.normalizeVersion('v0.6.1'), '0.6.1');
    expect(AppConstants.normalizeVersion('V0.6.1'), '0.6.1');
  });

  test('a plain version is left alone', () {
    expect(AppConstants.normalizeVersion('0.6.1'), '0.6.1');
    expect(AppConstants.normalizeVersion(' 0.6.1 '), '0.6.1');
  });
}
