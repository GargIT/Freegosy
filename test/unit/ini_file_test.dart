import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/storage/ini_file.dart';

void main() {
  const sample = '[UI]\nTheme = dark\n; a comment\n\n[Achievements]\nEnabled = false\nUsername = \nChallengeMode = false\n\n[Folders]\nBios = bios\n';

  test('reads values, including an empty one', () {
    final ini = IniFile(sample);
    expect(ini.get('UI', 'Theme'), 'dark');
    expect(ini.get('Achievements', 'Enabled'), 'false');
    expect(ini.get('Achievements', 'Username'), '');
    expect(ini.get('Achievements', 'Token'), isNull);
    expect(ini.get('Nope', 'Enabled'), isNull);
  });

  test('keys are looked up in their own section only', () {
    final ini = IniFile('[A]\nKey = 1\n[B]\nKey = 2\n');
    expect(ini.get('A', 'Key'), '1');
    expect(ini.get('B', 'Key'), '2');
  });

  test('changing a value touches only that line', () {
    final ini = IniFile(sample);
    expect(ini.set('Achievements', 'Enabled', 'true'), isTrue);
    expect(ini.toText(), sample.replaceFirst('Enabled = false', 'Enabled = true'));
  });

  test('setting the value it already has changes nothing', () {
    final ini = IniFile(sample);
    expect(ini.set('Achievements', 'ChallengeMode', 'false'), isFalse);
    expect(ini.toText(), sample);
  });

  test('a new key goes after the section\'s last line, before the blank separator', () {
    final ini = IniFile(sample);
    expect(ini.set('Achievements', 'LoginTimestamp', '123'), isTrue);
    expect(ini.toText(),
        sample.replaceFirst('ChallengeMode = false\n', 'ChallengeMode = false\nLoginTimestamp = 123\n'));
  });

  test('a missing section is added at the end, after a blank line', () {
    final ini = IniFile('[UI]\nTheme = dark\n');
    expect(ini.set('Achievements', 'Token', 'abc'), isTrue);
    expect(ini.toText(), '[UI]\nTheme = dark\n\n[Achievements]\nToken = abc\n');
  });

  test('an empty file gets the section and key', () {
    final ini = IniFile('');
    ini.set('Achievements', 'Token', 'abc');
    expect(ini.toText(), '[Achievements]\nToken = abc\n');
  });

  test('removing a key leaves the rest', () {
    final ini = IniFile(sample);
    expect(ini.remove('Achievements', 'Username'), isTrue);
    expect(ini.remove('Achievements', 'Username'), isFalse);
    expect(ini.toText(), sample.replaceFirst('Username = \n', ''));
  });

  test('Windows line endings are kept', () {
    final ini = IniFile('[A]\r\nKey = 1\r\n');
    ini.set('A', 'Other', '2');
    expect(ini.toText(), '[A]\r\nKey = 1\r\nOther = 2\r\n');
  });

  test('comments and key-like text in comments are not treated as keys', () {
    final ini = IniFile('[A]\n; Key = 1\n# Key = 2\nKey = 3\n');
    expect(ini.get('A', 'Key'), '3');
  });
}
