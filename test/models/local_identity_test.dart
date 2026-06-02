import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/models/local_identity.dart';

void main() {
  group('LocalIdentity', () {
    test('generates a compact random id and matching profile fields', () {
      final identity = LocalIdentity.random(random: math.Random(7));

      expect(identity.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(identity.name, matches(RegExp(r'^[A-Za-z]+ [1-9][0-9]{3}$')));
    });

    test('generates different ids across calls', () {
      final random = math.Random(11);
      final first = LocalIdentity.random(random: random);
      final second = LocalIdentity.random(random: random);

      expect(second.id, isNot(first.id));
    });
  });
}
