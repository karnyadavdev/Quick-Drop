import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

import 'models/device.dart';

import 'models/local_identity.dart';
import 'network/body_limit.dart';
import 'network/network_controller.dart';
import 'ui/widgets/peer_discovery_canvas.dart';
import 'ui/widgets/transfer_session_layer.dart';
import 'ui/widgets/profile_edit_modal.dart';
import 'ui/widgets/payload_selection_modal.dart';
import 'ui/widgets/device_icon_widget.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QuickDropApp());
}

class QuickDropApp extends StatelessWidget {
  const QuickDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quick Drop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF7C3AED),
          secondary: Color(0xFFFF4D8D),
          surface: Colors.white,
          onSurface: Color(0xFF111827),
        ),
        textTheme: ThemeData.light().textTheme,
        cardTheme: CardTheme(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.black.withAlpha(15)),
          ),
        ),
      ),
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8B5CF6),
          secondary: Color(0xFFFF70A6),
          surface: Color(0xFF1F2937),
          onSurface: Colors.white,
        ),
        textTheme: ThemeData.dark().textTheme,
        cardTheme: CardTheme(
          color: const Color(0xFF1F2937).withAlpha(150),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withAlpha(20)),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  late final NetworkController _networkController;
  late final AnimationController _animationController;

  String _initialName = 'Pioneer 1337';
  String _nodeId = '';
  String? _startupError;

  static const int _maxPingBodyBytes = 16 * 1024;

  @override
  void initState() {
    super.initState();
    _initializeIdentity();

    _networkController = NetworkController(
      deviceId: _nodeId,
      deviceName: _initialName,
    );
    _startNetworkController();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.wait([
        precacheImage(const AssetImage('assets/images/logo.png'), context),
      ]);
    });

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  Future<void> _startNetworkController() async {
    try {
      await _networkController.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startupError = 'Network startup failed: $e';
      });
    }
  }

  void _initializeIdentity() {
    final identity = LocalIdentity.random();
    _initialName = identity.name;
    _nodeId = identity.id;
  }

  @override
  void dispose() {
    _animationController.dispose();
    _networkController.dispose();
    super.dispose();
  }

  void _promptTransferPayload(NetworkDevice device) async {
    if (device.status == 'busy') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${device.name} is currently busy with another transfer.')),
      );
      return;
    }

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        final request = await client.getUrl(
          Uri.parse('http://${device.ip}:${device.port}/ping'),
        );
        final response = await request.close();
        if (response.statusCode == HttpStatus.ok) {
          final bodyStr = await BodyLimit.readUtf8(
            response,
            maxBytes: _maxPingBodyBytes,
          );
          final presence = PeerPresence.fromJson(
            jsonDecode(bodyStr) as Map<String, dynamic>,
          );
          if (presence.isBusy) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${device.name} is currently busy.')),
            );
            return;
          }
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {}

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(160),
      isScrollControlled: true,
      builder: (context) => PayloadSelectionModal(
        targetDevice: device,
        networkController: _networkController,
      ),
    );
  }

  void _showEditProfileModal() async {
    await showGeneralDialog<bool>(
      context: context,
      barrierColor: Colors.black.withAlpha(160),
      barrierDismissible: true,
      barrierLabel: 'Edit Profile',
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => ProfileEditModal(
        initialName: _networkController.deviceName,
        onSave: (newName) {
          _networkController.updateProfile(
              newName, _networkController.deviceType);
        },
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(curve),
          child: FadeTransition(
            opacity: curve,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _networkController,
        builder: (context, _) {
          final transferState = _networkController.transferType;

          return Stack(
            children: [
              AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return _AnimatedBackground(
                    value: _animationController.value,
                  );
                },
              ),
              Column(
                children: [
                  FloatingHeader(
                    localName: _networkController.deviceName,
                    localDeviceType: _networkController.deviceType,
                    onEditProfile: _showEditProfileModal,
                  ),
                  Expanded(
                    child: PeerDiscoveryCanvas(
                      devices: _networkController.devices,
                      animationController: _animationController,
                      onDeviceSelected: _promptTransferPayload,
                      localDeviceType: _networkController.deviceType,
                      localName: _networkController.deviceName,
                    ),
                  ),
                ],
              ),
              if (_startupError != null)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  child: SafeArea(
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B5C).withAlpha(238),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(45),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Text(
                          _startupError!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: transferState == 'none',
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder:
                        (Widget child, Animation<double> animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 0.95, end: 1.0)
                              .animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: transferState != 'none'
                        ? TransferSessionLayer(
                            key: const ValueKey('TransferLayer'),
                            networkController: _networkController,
                          )
                        : const SizedBox.shrink(key: ValueKey('Empty')),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class FloatingHeader extends StatelessWidget {
  final String localName;
  final String localDeviceType;
  final VoidCallback onEditProfile;

  const FloatingHeader({
    super.key,
    required this.localName,
    required this.localDeviceType,
    required this.onEditProfile,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Quick Drop',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                  color: const Color(0xFF172033),
                  shadows: [
                    Shadow(
                      color: Colors.white.withAlpha(245),
                      blurRadius: 14,
                    ),
                    Shadow(
                      color: Colors.white.withAlpha(200),
                      blurRadius: 28,
                    ),
                  ],
                ),
              ),
            ],
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onEditProfile,
              borderRadius: BorderRadius.circular(8),
              hoverColor: Colors.white.withAlpha(90),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DeviceIconWidget(deviceType: localDeviceType, size: 42),
                    const SizedBox(width: 10),
                    Text(
                      localName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF172033),
                        shadows: [
                          Shadow(
                            color: Colors.white,
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down,
                        size: 18, color: Color(0xFF6B7280)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedBackground extends StatelessWidget {
  final double value;

  const _AnimatedBackground({
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final breath = value < 0.5 ? value * 2 : (1.0 - value) * 2;
    final size = MediaQuery.of(context).size;

    final bg1 = isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC);
    final bg2 = isDark ? const Color(0xFF111827) : const Color(0xFFF1F5F9);
    final accentGlow = isDark
        ? const Color(0xFF8B5CF6).withAlpha((15 * breath).toInt())
        : const Color(0xFF3B82F6).withAlpha((8 * breath).toInt());

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [bg1, bg2],
            ),
          ),
        ),
        Positioned(
          top: -size.height * 0.1,
          right: -size.width * 0.1,
          width: size.width * 0.6,
          height: size.width * 0.6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accentGlow,
                  accentGlow.withAlpha(0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
