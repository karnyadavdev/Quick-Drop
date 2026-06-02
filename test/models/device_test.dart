import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/models/device.dart';

void main() {
  group('NetworkDevice.fromJson', () {
    test('parses discovery payload and defaults optional fields', () {
      final device = NetworkDevice.fromJson(
        {
          'id': 'peer-1',
          'name': '  Penguin   1234  ',
          'port': '50005',
        },
        '192.168.1.25',
      );

      expect(device.id, 'peer-1');
      expect(device.name, 'Penguin 1234');
      expect(device.deviceType, 'desktop');
      expect(device.ip, '192.168.1.25');
      expect(device.port, 50005);
      expect(device.status, 'free');
    });

    test('sanitizes optional discovery fields', () {
      final device = NetworkDevice.fromJson(
        {
          'id': 'peer-1',
          'name': 'Penguin 1234',
          'deviceType': 'invalid_type',
          'status': 'weird',
          'port': 50005,
        },
        '192.168.1.25',
      );

      expect(device.deviceType, 'desktop');
      expect(device.status, 'free');
    });

    test('rejects missing or empty discovery identity fields', () {
      expect(
        () => NetworkDevice.fromJson(
          {'name': 'Peer', 'port': 50005},
          '192.168.1.25',
        ),
        throwsFormatException,
      );

      expect(
        () => NetworkDevice.fromJson(
          {'id': 'peer-1', 'name': '   ', 'port': 50005},
          '192.168.1.25',
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid discovery ports', () {
      expect(
        () => NetworkDevice.fromJson(
          {'id': 'peer-1', 'name': 'Bad Port', 'port': 0},
          '192.168.1.25',
        ),
        throwsFormatException,
      );

      expect(
        () => NetworkDevice.fromJson(
          {'id': 'peer-1', 'name': 'Bad Port', 'port': 70000},
          '192.168.1.25',
        ),
        throwsFormatException,
      );
    });
  });

  group('NetworkDevice.isStale', () {
    test('marks peers stale only after the allowed silence window', () {
      final now = DateTime(2026, 5, 29, 12);
      final device = NetworkDevice(
        id: 'peer-1',
        name: 'Penguin',
        deviceType: 'desktop',
        ip: '192.168.1.25',
        port: 50005,
        lastSeen: now.subtract(const Duration(seconds: 4)),
      );

      expect(device.isStale(now, const Duration(seconds: 4)), isFalse);
      expect(
        device
            .copyWith(
              lastSeen: now.subtract(
                const Duration(seconds: 4, milliseconds: 1),
              ),
            )
            .isStale(now, const Duration(seconds: 4)),
        isTrue,
      );
    });
  });

  group('PeerPresence', () {
    test('reads busy status and defaults unknown values to free', () {
      expect(PeerPresence.fromJson({'status': 'busy'}).isBusy, isTrue);
      expect(PeerPresence.fromJson({'status': 'free'}).isBusy, isFalse);
      expect(PeerPresence.fromJson({'status': 'strange'}).status, 'free');
      expect(PeerPresence.fromJson({}).status, 'free');
    });
  });
}
