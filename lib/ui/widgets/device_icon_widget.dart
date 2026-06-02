import 'package:flutter/material.dart';

class DeviceIconWidget extends StatelessWidget {
  final String deviceType;
  final double size;

  const DeviceIconWidget({
    super.key,
    required this.deviceType,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = deviceType == 'mobile';
    final iconData = isMobile ? Icons.phone_iphone : Icons.laptop_mac;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
      ),
      child: Center(
        child: Icon(
          iconData,
          size: size * 0.65,
          color: const Color(0xFF3B82F6),
        ),
      ),
    );
  }
}
