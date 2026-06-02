import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/network/body_limit.dart';

void main() {
  group('BodyLimit', () {
    test('reads a small UTF-8 body', () async {
      final body = await BodyLimit.readUtf8(
        Stream<List<int>>.fromIterable([
          utf8.encode('{"name":"Penguin"}'),
        ]),
        maxBytes: 64,
      );

      expect(body, '{"name":"Penguin"}');
    });

    test('rejects bodies larger than the byte limit', () {
      expect(
        BodyLimit.readUtf8(
          Stream<List<int>>.fromIterable([
            utf8.encode('12345'),
            utf8.encode('67890'),
          ]),
          maxBytes: 8,
        ),
        throwsA(isA<BodyTooLargeException>()),
      );
    });

    test('rejects invalid limits', () {
      expect(
        () => BodyLimit.readUtf8(
          const Stream<List<int>>.empty(),
          maxBytes: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
