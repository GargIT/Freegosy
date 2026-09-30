import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/formats/save_format_registry.dart';

/// A text "save" stored as `<stem>.<ext>`; the neutral form is the text.
class _TextFormat extends SaveFormat<String> {
  const _TextFormat(this.id, this.ext, this.tags, {this.encodesNothing = false});
  @override
  final String id;
  final String ext;
  @override
  final Set<String> tags;
  final bool encodesNothing;

  @override
  bool recognises(List<SaveBlob> files) => files.length == 1 && files.single.extension == ext;
  @override
  String decode(List<SaveBlob> files) {
    final text = utf8.decode(files.single.bytes);
    if (text == 'corrupt') throw const FormatException('corrupt');
    return text;
  }

  @override
  List<SaveBlob> encode(String save, {required String stem, List<SaveBlob> existing = const []}) =>
      encodesNothing ? [] : [SaveBlob('$stem$ext', Uint8List.fromList(utf8.encode(save)))];
}

const _a = _TextFormat('test.a', '.a', {'emu_a'});
const _b = _TextFormat('test.b', '.b', {'emu_b', 'emu_b2'});
const _alsoA = _TextFormat('test.a2', '.a', {'emu_a2'});
const _empty = _TextFormat('test.e', '.e', {'emu_e'}, encodesNothing: true);

final _systems = <SaveSystem<Object>>[
  const SaveSystem<String>(name: 'N64', slugs: {'n64'}, formats: [_a, _b, _empty]),
  const SaveSystem<String>(name: 'Ambiguous', slugs: {'amb'}, formats: [_a, _alsoA, _b]),
];

SaveBlob _blob(String name, String text) => SaveBlob(name, Uint8List.fromList(utf8.encode(text)));

List<SaveBlob>? _convert(String slug, List<SaveBlob> files, {String? from, required String to}) =>
    convertSave(platformSlug: slug, files: files, sourceTag: from, targetTag: to, stem: 'Game (USA)', systems: _systems);

void main() {
  test('converts from the tagged format to the target\'s format, under the ROM stem', () {
    final out = _convert('n64', [_blob('upload.a', 'hello')], from: 'emu_a', to: 'emu_b')!;
    expect(out.map((b) => b.name), ['Game (USA).b']);
    expect(utf8.decode(out.single.bytes), 'hello');
  });

  test('any of a format\'s tags selects it', () {
    expect(_convert('n64', [_blob('x.a', 'hi')], from: 'emu_a', to: 'emu_b2')!.single.name, 'Game (USA).b');
  });

  test('no format for the target tag: null', () {
    expect(_convert('n64', [_blob('x.a', 'hi')], from: 'emu_a', to: 'duckstation'), isNull);
  });

  test('an unknown, old ("freegosy") or missing tag falls back to recognising the files', () {
    expect(_convert('n64', [_blob('x.a', 'hi')], from: 'freegosy', to: 'emu_b')!.single.name, 'Game (USA).b');
    expect(_convert('n64', [_blob('x.a', 'hi')], to: 'emu_b')!.single.name, 'Game (USA).b');
  });

  test('a tagged format that doesn\'t recognise the files falls back to recognising them', () {
    expect(_convert('n64', [_blob('x.a', 'hi')], from: 'emu_b', to: 'emu_b')?.single.name, 'Game (USA).b');
  });

  test('files no format recognises: null', () {
    expect(_convert('n64', [_blob('x.zip', 'hi')], to: 'emu_b'), isNull);
  });

  test('files several formats recognise, with no tag to choose: null', () {
    expect(_convert('amb', [_blob('x.a', 'hi')], to: 'emu_b'), isNull);
    expect(_convert('amb', [_blob('x.a', 'hi')], from: 'emu_a2', to: 'emu_b')!.single.name, 'Game (USA).b');
  });

  test('already in the target\'s format: null, so the save is restored untouched', () {
    expect(_convert('n64', [_blob('x.b', 'hi')], from: 'emu_b', to: 'emu_b2'), isNull);
  });

  test('a save that fails to decode: null', () {
    expect(_convert('n64', [_blob('x.a', 'corrupt')], from: 'emu_a', to: 'emu_b'), isNull);
  });

  test('an encode that produces no files: null', () {
    expect(_convert('n64', [_blob('x.a', 'hi')], from: 'emu_a', to: 'emu_e'), isNull);
  });

  test('RomM\'s platform slugs are matched through their aliases', () {
    // canonicalPlatformSlug: 'ique-player' → 'n64'.
    expect(_convert('ique-player', [_blob('x.a', 'hi')], from: 'emu_a', to: 'emu_b'), isNotNull);
    expect(_convert('N64', [_blob('x.a', 'hi')], from: 'emu_a', to: 'emu_b'), isNotNull);
  });

  test('a platform without a save system: null', () {
    expect(_convert('snes', [_blob('x.a', 'hi')], from: 'emu_a', to: 'emu_b'), isNull);
  });

  test('SaveBlob.extension is lower-case', () {
    expect(_blob('GAME.SRM', '').extension, '.srm');
  });
}
