import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The same file path, whichever separators it was built with. Tests for
/// Linux paths join with '/' where the host joins with '\', so on a Windows
/// machine the strings differ even though the path is the same.
Matcher samePath(String expected) =>
    predicate<String>((actual) => p.equals(actual, expected), 'the path $expected');
