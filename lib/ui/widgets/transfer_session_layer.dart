import 'dart:ui';

import 'package:flutter/material.dart';

import '../../network/network_controller.dart';
import 'device_icon_widget.dart';

class TransferSessionLayer extends StatelessWidget {
  final NetworkController networkController;

  const TransferSessionLayer({
    super.key,
    required this.networkController,
  });

  @override
  Widget build(BuildContext context) {
    final state = networkController.transferType;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Container(
        color:
            isDark ? Colors.black.withAlpha(120) : Colors.white.withAlpha(92),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: switch (state) {
            'incoming_request' =>
              _IncomingRequest(controller: networkController, isDark: isDark),
            'send_requesting' =>
              _WaitingForPeer(controller: networkController, isDark: isDark),
            _ =>
              _TransferProgress(controller: networkController, isDark: isDark),
          },
        ),
      ),
    );
  }
}

class _TransferCard extends StatelessWidget {
  final Widget child;
  final bool isDark;

  const _TransferCard({required this.child, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width - 32;
    final cardWidth = maxWidth < 440.0 ? maxWidth : 440.0;

    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: cardWidth,
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B).withAlpha(180)
                  : Colors.white.withAlpha(200),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: isDark
                      ? Colors.white.withAlpha(25)
                      : Colors.white.withAlpha(180)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 80 : 15),
                  blurRadius: 50,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _IncomingRequest extends StatelessWidget {
  final NetworkController controller;
  final bool isDark;

  const _IncomingRequest({required this.controller, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return _TransferCard(
      isDark: isDark,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeviceIconWidget(
                deviceType: controller.transferSenderDeviceType,
                size: 66,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.transferSenderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF334155),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      controller.transferIsFolder
                          ? 'wants to send you items'
                          : 'wants to send you a file',
                      style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.black54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _FileSummary(controller: controller, isDark: isDark),
          const SizedBox(height: 24),
          _CodeDisplay(code: controller.transferSecurityCode, isDark: isDark),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: controller.declineTransfer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: FilledButton(
                  onPressed: controller.acceptTransfer,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WaitingForPeer extends StatelessWidget {
  final NetworkController controller;
  final bool isDark;

  const _WaitingForPeer({required this.controller, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final speed = controller.transferSpeed;
    final isError = speed == 'Busy' ||
        speed == 'Declined' ||
        speed == 'Ignored' ||
        speed == 'Failed';

    return _TransferCard(
      isDark: isDark,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusBubble(
            icon: isError ? Icons.error_outline : Icons.sync,
            color: isError ? Colors.redAccent : const Color(0xFF3B82F6),
          ),
          const SizedBox(height: 18),
          Text(
            isError ? _waitingErrorTitle(speed) : 'Waiting for approval',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isError
                  ? Colors.redAccent
                  : (isDark ? Colors.white : const Color(0xFF334155)),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isError
                ? _waitingErrorMessage(speed)
                : 'The receiver needs to accept your request.',
            textAlign: TextAlign.center,
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black54),
          ),
          if (!isError && controller.transferSecurityCode.isNotEmpty) ...[
            const SizedBox(height: 12),
            _CodeDisplay(code: controller.transferSecurityCode, isDark: isDark),
          ],
        ],
      ),
    );
  }

  String _waitingErrorTitle(String speed) {
    if (speed == 'Busy') return 'Peer is busy';
    if (speed == 'Declined') return 'Request declined';
    if (speed == 'Ignored') return 'Request ignored';
    return 'Connection failed';
  }

  String _waitingErrorMessage(String speed) {
    if (speed == 'Busy') return 'The receiver is already in another transfer.';
    if (speed == 'Declined') return 'The receiver declined this transfer.';
    if (speed == 'Ignored') return 'The receiver ignored repeated requests.';
    return 'Could not connect to the receiver.';
  }
}

class _TransferProgress extends StatelessWidget {
  final NetworkController controller;
  final bool isDark;

  const _TransferProgress({required this.controller, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final progress = controller.transferProgress.clamp(0.0, 1.0);
    final speed = controller.transferSpeed;
    final isSending = controller.transferType == 'send';
    final isDone = speed == 'Finished';
    final isFailed = speed == 'Failed';

    return GestureDetector(
        onTap: () {
          if ((isDone || isFailed) && controller.canDismiss) {
            controller.dismissTransfer();
          }
        },
        child: _TransferCard(
          isDark: isDark,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBubble(
                icon: isFailed
                    ? Icons.close
                    : isDone
                        ? Icons.check
                        : isSending
                            ? Icons.upload
                            : Icons.download,
                color: isFailed
                    ? Colors.redAccent
                    : isDone
                        ? const Color(0xFF00C853)
                        : const Color(0xFF3B82F6),
              ),
              const SizedBox(height: 16),
              Text(
                isFailed
                    ? 'Transfer failed'
                    : isDone
                        ? 'Transfer complete'
                        : isSending
                            ? 'Sending'
                            : 'Receiving',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              _FileSummary(controller: controller, isDark: isDark),
              const SizedBox(height: 22),
              if (!isDone && !isFailed) ...[
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(8),
                  backgroundColor:
                      isDark ? Colors.white12 : const Color(0xFFE2E8F0),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF3B82F6)),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${(progress * 100).round()}% - $speed',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black54,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: controller.cancelActiveTransfer,
                      child: const Text('Cancel',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ] else
                Text(
                  isFailed
                      ? 'The transfer was interrupted.'
                      : isSending
                          ? 'Sent successfully.'
                          : 'Saved to Downloads.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: isDark ? Colors.white70 : Colors.black54),
                ),
            ],
          ),
        ));
  }
}

class _CodeDisplay extends StatelessWidget {
  final String code;
  final bool isDark;

  const _CodeDisplay({required this.code, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (code.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        Text(
          'Security Code',
          style: TextStyle(
            color: isDark ? Colors.white70 : Colors.black54,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111827) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: isDark
                    ? Colors.white.withAlpha(20)
                    : Colors.black.withAlpha(20)),
          ),
          child: Text(
            code,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 8,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Verify this matches the other screen.',
          style: TextStyle(
              color: isDark ? Colors.white60 : Colors.black45, fontSize: 11),
        ),
      ],
    );
  }
}

class _FileSummary extends StatelessWidget {
  final NetworkController controller;
  final bool isDark;

  const _FileSummary({required this.controller, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF0B0F19).withAlpha(120)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isDark
                ? Colors.white.withAlpha(15)
                : Colors.black.withAlpha(10)),
      ),
      child: Row(
        children: [
          Icon(
            controller.transferIsFolder
                ? Icons.folder_outlined
                : Icons.description_outlined,
            color: const Color(0xFF3B82F6),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.transferFileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatBytes(controller.transferFileSize),
                  style: TextStyle(
                      color: isDark ? Colors.white60 : Colors.black54,
                      fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var index = 0;
    while (size >= 1024 && index < suffixes.length - 1) {
      size /= 1024;
      index++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[index]}';
  }
}

class _StatusBubble extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _StatusBubble({
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        color: Color.lerp(color, Colors.white, 0.82),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(56),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Icon(icon, size: 36, color: color),
    );
  }
}
