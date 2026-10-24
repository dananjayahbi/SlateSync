/// Progress / failure surface for one pairing attempt (Doc 25 §5 step 2).
///
/// The pairing screen used to close the moment a QR code was decoded, so a
/// failed handshake looked like "nothing happened". This card keeps the user
/// on the screen while the WebSocket opens and turns a rejection or a timeout
/// into actionable text plus a retry affordance.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';

/// Card shown while a pairing attempt is running or after it failed.
class PairingProgressCard extends StatelessWidget {
  const PairingProgressCard({
    super.key,
    required this.busy,
    required this.message,
    this.onCancel,
    this.onRetry,
  });

  /// `true` while the handshake is in flight (spinner + Cancel).
  final bool busy;

  /// Status copy to display.
  final String message;

  /// Invoked by "Cancel" while [busy].
  final VoidCallback? onCancel;

  /// Invoked by "Try again" after a failure.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('pairing-progress'),
      color: StudioTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: busy
                  ? const CircularProgressIndicator(
                      key: Key('pairing-progress-spinner'),
                      strokeWidth: 2.4,
                    )
                  : const Icon(
                      Icons.error_outline,
                      key: Key('pairing-progress-error'),
                      size: 20,
                      color: StudioTheme.danger,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                key: const Key('pairing-progress-text'),
                style: TextStyle(
                  color: busy ? StudioTheme.text : StudioTheme.danger,
                  fontSize: StudioTheme.captionSize + 1,
                ),
              ),
            ),
            if (busy && onCancel != null)
              TextButton(
                key: const Key('pairing-progress-cancel'),
                onPressed: onCancel,
                child: const Text('Cancel'),
              )
            else if (!busy && onRetry != null)
              TextButton(
                key: const Key('pairing-progress-retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}
