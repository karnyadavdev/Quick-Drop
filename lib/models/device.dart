class NetworkDevice {
  final String id;
  final String name;
  final String deviceType;
  final String ip;
  final int port;
  final DateTime lastSeen;
  final String status;

  NetworkDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.ip,
    required this.port,
    required this.lastSeen,
    this.status = 'free',
  });

  NetworkDevice copyWith({
    String? id,
    String? name,
    String? deviceType,
    String? ip,
    int? port,
    DateTime? lastSeen,
    String? status,
  }) {
    return NetworkDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'deviceType': deviceType,
        'ip': ip,
        'port': port,
        'status': status,
      };

  bool isStale(DateTime now, Duration staleAfter) {
    return now.difference(lastSeen) > staleAfter;
  }

  factory NetworkDevice.fromJson(Map<String, dynamic> json, String ip) {
    final id = _readText(json, 'id', maxLength: 64);
    final name = _readText(json, 'name', maxLength: 32);
    final rawPort = json['port'];
    final port = rawPort is int ? rawPort : int.tryParse('$rawPort');
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('Invalid discovery port.');
    }

    return NetworkDevice(
      id: id,
      name: name,
      deviceType: _readDeviceType(json['deviceType']),
      ip: ip,
      port: port,
      status: _readStatus(json['status']),
      lastSeen: DateTime.now(),
    );
  }

  static String _readText(
    Map<String, dynamic> json,
    String key, {
    required int maxLength,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Missing discovery field: $key.');
    }

    final trimmed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty discovery field: $key.');
    }
    return trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
  }

  static String _readDeviceType(Object? value) {
    if (value is String && (value == 'mobile' || value == 'desktop')) {
      return value;
    }
    return 'desktop';
  }

  static String _readStatus(Object? value) {
    return value == 'busy' ? 'busy' : 'free';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkDevice &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class PeerPresence {
  final String status;

  const PeerPresence({required this.status});

  bool get isBusy => status == 'busy';

  factory PeerPresence.fromJson(Map<String, dynamic> json) {
    return PeerPresence(status: json['status'] == 'busy' ? 'busy' : 'free');
  }
}
