import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/device.dart';
import 'radar_painter.dart';
import 'device_icon_widget.dart';

class PeerDiscoveryCanvas extends StatelessWidget {
  final List<NetworkDevice> devices;
  final AnimationController animationController;
  final Function(NetworkDevice) onDeviceSelected;
  final String localDeviceType;
  final String localName;

  const PeerDiscoveryCanvas({
    super.key,
    required this.devices,
    required this.animationController,
    required this.onDeviceSelected,
    required this.localDeviceType,
    required this.localName,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final centerX = constraints.maxWidth / 2;
        final centerY = constraints.maxHeight / 2;

        final maxRadius =
            math.min(constraints.maxWidth, constraints.maxHeight) * 0.40;
        final radarDiameter = maxRadius * 2;

        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              left: centerX - maxRadius,
              top: centerY - maxRadius,
              width: radarDiameter,
              height: radarDiameter,
              child: AnimatedBuilder(
                animation: animationController,
                builder: (context, _) => CustomPaint(
                  size: Size(radarDiameter, radarDiameter),
                  painter: RadarPainter(
                    animationValue: animationController.value,
                    baseColor: const Color(0xFF3B82F6),
                  ),
                ),
              ),
            ),
            Positioned(
              left: centerX - 62,
              top: centerY - 62,
              width: 124,
              height: 124,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF60A5FA).withAlpha(70),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: DeviceIconWidget(deviceType: localDeviceType, size: 124),
              ),
            ),
            Positioned(
              left: centerX - 120,
              top: centerY + 74,
              width: 240,
              child: Center(
                child: Text(
                  localName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.5,
                    color: isDark ? Colors.white : const Color(0xFF334155),
                    shadows: [
                      Shadow(
                        color:
                            isDark ? Colors.black : Colors.white.withAlpha(230),
                        blurRadius: 12,
                      ),
                      Shadow(
                        color: isDark
                            ? Colors.black.withAlpha(150)
                            : Colors.white.withAlpha(190),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (devices.isNotEmpty)
              ...List.generate(devices.length, (index) {
                final device = devices[index];

                final int count = devices.length;
                int ringCount = 1;
                if (count > 4) ringCount = 2;
                if (count > 10) ringCount = 3;
                if (count > 20) ringCount = 4;

                final int ringIndex = index % ringCount;
                final double angle =
                    (index * 2 * math.pi / count) - (math.pi / 2);

                double radiusFraction = 0.65;
                if (ringCount == 2) {
                  radiusFraction = ringIndex == 0 ? 0.50 : 0.80;
                }
                if (ringCount == 3) {
                  radiusFraction =
                      ringIndex == 0 ? 0.45 : (ringIndex == 1 ? 0.65 : 0.85);
                }
                if (ringCount == 4) {
                  radiusFraction = 0.35 + (ringIndex * 0.20);
                }

                final double radius = maxRadius * radiusFraction;
                final double x = centerX + radius * math.cos(angle);
                final double y = centerY + radius * math.sin(angle);

                double scaleFactor = 1.0;
                if (count > 20) {
                  scaleFactor = 0.6;
                } else if (count > 10) {
                  scaleFactor = 0.8;
                }

                final double nodeW = 126 * scaleFactor;
                final double nodeH = 148 * scaleFactor;

                return Positioned(
                  left: x - (nodeW / 2),
                  top: y - (nodeH / 2),
                  width: nodeW,
                  height: nodeH,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    builder: (context, value, child) {
                      return Transform.scale(
                        scale: value,
                        child: child,
                      );
                    },
                    child: PeerRadarNode(
                      device: device,
                      scaleFactor: scaleFactor,
                      isDark: isDark,
                      onTap: () => onDeviceSelected(device),
                    ),
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}

class PeerRadarNode extends StatefulWidget {
  final NetworkDevice device;
  final double scaleFactor;
  final bool isDark;
  final VoidCallback onTap;

  const PeerRadarNode({
    super.key,
    required this.device,
    this.scaleFactor = 1.0,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<PeerRadarNode> createState() => _PeerRadarNodeState();
}

class _PeerRadarNodeState extends State<PeerRadarNode> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final statusColor = widget.device.status == 'free'
        ? const Color(0xFF00E676)
        : const Color(0xFFFF3D00);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isHovered ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B82F6)
                          .withAlpha(_isHovered ? 80 : 42),
                      blurRadius: (_isHovered ? 28 : 20) * widget.scaleFactor,
                      offset: Offset(0, 8 * widget.scaleFactor),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    DeviceIconWidget(
                      deviceType: widget.device.deviceType,
                      size: 92 * widget.scaleFactor,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 16 * widget.scaleFactor,
                        height: 16 * widget.scaleFactor,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: 2 * widget.scaleFactor,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: statusColor.withAlpha(100),
                              blurRadius: 4 * widget.scaleFactor,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 9 * widget.scaleFactor),
              Text(
                widget.device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13 * widget.scaleFactor,
                  fontWeight: FontWeight.w900,
                  color: widget.isDark ? Colors.white : const Color(0xFF334155),
                  letterSpacing: 0,
                  shadows: [
                    Shadow(
                      color: widget.isDark
                          ? Colors.black
                          : Colors.white.withAlpha(235),
                      blurRadius: 10 * widget.scaleFactor,
                    ),
                    Shadow(
                      color: widget.isDark
                          ? Colors.black.withAlpha(150)
                          : Colors.white.withAlpha(190),
                      blurRadius: 18 * widget.scaleFactor,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
