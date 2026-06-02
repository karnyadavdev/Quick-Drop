import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/device.dart';
import '../../network/network_controller.dart';

class PayloadSelectionModal extends StatelessWidget {
  final NetworkDevice targetDevice;
  final NetworkController networkController;

  const PayloadSelectionModal({
    super.key,
    required this.targetDevice,
    required this.networkController,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 28),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B).withAlpha(220)
                  : Colors.white.withAlpha(240),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                  top: BorderSide(
                      color: isDark
                          ? Colors.white.withAlpha(30)
                          : Colors.white.withAlpha(255))),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 80 : 15),
                  blurRadius: 40,
                  offset: const Offset(0, -10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(35),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Send to ${targetDevice.name}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF334155),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 24),
                _ActionButton(
                  icon: Icons.description_outlined,
                  title: 'Files',
                  subtitle: 'Choose one or more files',
                  color: const Color(0xFF3B82F6),
                  isDark: isDark,
                  onTap: () => _pickFiles(context),
                ),
                const SizedBox(height: 12),
                _ActionButton(
                  icon: Icons.folder_outlined,
                  title: 'Folder',
                  subtitle: 'Send a whole folder',
                  color: const Color(0xFF3B82F6),
                  isDark: isDark,
                  onTap: () => _pickFolder(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFiles(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      final paths =
          result?.files.map((file) => file.path).whereType<String>().toList() ??
              [];
      if (paths.isEmpty) return;

      if (paths.length == 1) {
        await networkController.sendFile(targetDevice, File(paths.single));
      } else {
        await networkController.sendMultipleFiles(targetDevice, paths);
      }
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('File selection failed: $e')));
    }
  }

  Future<void> _pickFolder(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);

    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path != null) {
        await networkController.sendFolder(targetDevice, path);
      }
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Folder selection failed: $e')));
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark
          ? const Color(0xFF0F172A).withAlpha(150)
          : Color.lerp(color, Colors.white, 0.88),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isDark
                      ? color.withAlpha(40)
                      : Colors.white.withAlpha(210),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                          color: isDark ? Colors.white60 : Colors.black54),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: isDark ? Colors.white30 : Colors.black38),
            ],
          ),
        ),
      ),
    );
  }
}
