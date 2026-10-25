/// Round-12 issue 09 — the OCR tool's panel.
///
/// Two jobs: start a scan, and show what the PC is doing. The scan is a job on
/// the PC (rasterise a 300 DPI crop, run the model, return lines), so silence
/// for a few seconds is normal and needs to be visibly *working*, not looked
/// like a hang.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';
import 'package:mobile_app/features/ocr/ocr_client.dart';

/// Progress + actions for the in-flight OCR job.
class OcrPanel extends StatelessWidget {
  const OcrPanel({
    super.key,
    required this.canvasIsInfinite,
    required this.running,
    required this.stage,
    required this.percent,
    required this.hasSelection,
    required this.onScanSelection,
    required this.onScanCanvas,
    required this.onCancel,
    this.errorText,
    this.resultSummary,
  });

  /// Whole-canvas scans are meaningless on an infinite canvas: there is no
  /// bounded area to rasterise, so the control is disabled rather than failing
  /// after the user waits.
  final bool canvasIsInfinite;

  final bool running;
  final String stage;
  final double percent;
  final bool hasSelection;

  final VoidCallback onScanSelection;
  final VoidCallback onScanCanvas;
  final VoidCallback onCancel;
  final String? errorText;
  final String? resultSummary;

  static const ValueKey<String> scanSelectionKey =
      ValueKey<String>('ocr-scan-selection');
  static const ValueKey<String> scanCanvasKey =
      ValueKey<String>('ocr-scan-canvas');
  static const ValueKey<String> cancelKey = ValueKey<String>('ocr-cancel');

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (running) ...<Widget>[
          _OcrProgressRow(stage: stage, percent: percent, onCancel: onCancel),
        ] else ...<Widget>[
          Text(
            hasSelection
                ? 'Outline ready — scan it, or scan the whole canvas.'
                : 'Circle the text you want to scan, then scan it.',
            key: const ValueKey<String>('ocr-hint'),
            style: const TextStyle(
              fontSize: StudioTheme.captionSize,
              color: StudioTheme.text,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: scanSelectionKey,
                onPressed: hasSelection ? onScanSelection : null,
                icon: const Icon(Icons.crop_free, size: 18),
                label: const Text('Scan selection'),
              ),
              OutlinedButton.icon(
                key: scanCanvasKey,
                onPressed: canvasIsInfinite ? null : onScanCanvas,
                icon: const Icon(Icons.fullscreen, size: 18),
                label: const Text('Scan entire canvas'),
              ),
            ],
          ),
          if (canvasIsInfinite)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'An infinite canvas has no whole-page area — select a region.',
                key: ValueKey<String>('ocr-infinite-note'),
                style: TextStyle(
                  fontSize: StudioTheme.captionSize,
                  color: StudioTheme.text,
                ),
              ),
            ),
        ],
        if (errorText != null && errorText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              errorText!,
              key: const ValueKey<String>('ocr-error'),
              style: const TextStyle(
                fontSize: StudioTheme.captionSize,
                color: StudioTheme.danger,
              ),
            ),
          ),
        if (resultSummary != null && resultSummary!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              resultSummary!,
              key: const ValueKey<String>('ocr-result-summary'),
              style: const TextStyle(
                fontSize: StudioTheme.captionSize,
                color: StudioTheme.accent,
              ),
            ),
          ),
      ],
    );
  }
}

class _OcrProgressRow extends StatelessWidget {
  const _OcrProgressRow({
    required this.stage,
    required this.percent,
    required this.onCancel,
  });

  final String stage;
  final double percent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('ocr-progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${_label(stage)}… ${percent.round()}%',
                style: const TextStyle(
                  fontSize: StudioTheme.captionSize,
                  color: StudioTheme.text,
                ),
              ),
            ),
            TextButton(
              key: OcrPanel.cancelKey,
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: StudioTheme.bg,
          ),
        ),
      ],
    );
  }

  /// Human wording for the wire stage names.
  static String _label(String stage) => switch (stage) {
        'QUEUED' => 'Queued on the PC',
        'RASTERISING' => 'Rendering the area',
        'RECOGNISING' => 'Reading the text',
        'DONE' => 'Finishing',
        'ERROR' => 'Failed',
        _ => 'Scanning',
      };
}

/// Formats a finished scan for the panel: how much text, and where it ran.
///
/// The provider is deliberately shown — it is the only way a user can tell that
/// the GPU was used rather than a silent CPU fallback.
String describeOcrOutcome(OcrOutcome outcome) {
  final int lines = outcome.lines.length;
  final String where = outcome.provider == 'DmlExecutionProvider'
      ? 'GPU'
      : (outcome.provider ?? 'PC');
  final String timing = outcome.elapsedMs > 0
      ? ' in ${(outcome.elapsedMs / 1000).toStringAsFixed(1)}s'
      : '';
  if (!outcome.hasText) {
    return 'No text found ($where$timing)';
  }
  return 'Added $lines line${lines == 1 ? '' : 's'} ($where$timing)';
}
