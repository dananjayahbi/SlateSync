/// Round-12 issue 05 — typing into a text box.
///
/// A dialog with a real [TextField] rather than an on-canvas caret: the tablet
/// keyboard has to appear, and getting an IME popup positioned over a
/// transformed canvas is far more fragile than a modal the platform already
/// knows how to focus.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/text_box_model.dart';
import 'package:mobile_app/core/theme/studio_theme.dart';

/// Result of the editor: the new text and the settings the user chose.
class TextBoxEdit {
  const TextBoxEdit({
    required this.text,
    required this.fontSize,
    required this.align,
  });

  final String text;
  final double fontSize;
  final String align;
}

/// Opens the editor for [box]. Returns `null` when the user cancels.
///
/// An empty result is a legitimate outcome (the user cleared the box), so this
/// never treats "" as "cancelled" — the caller decides whether to keep an empty
/// text box.
Future<TextBoxEdit?> showTextBoxEditor(
  BuildContext context, {
  required TextBoxModel box,
  String title = 'Edit text',
}) {
  return showDialog<TextBoxEdit>(
    context: context,
    builder: (BuildContext ctx) => _TextBoxEditorDialog(box: box, title: title),
  );
}

class _TextBoxEditorDialog extends StatefulWidget {
  const _TextBoxEditorDialog({required this.box, required this.title});

  final TextBoxModel box;
  final String title;

  @override
  State<_TextBoxEditorDialog> createState() => _TextBoxEditorDialogState();
}

class _TextBoxEditorDialogState extends State<_TextBoxEditorDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  late double _fontSize;
  late String _align;

  static const List<double> _fontSizes = <double>[12, 16, 20, 24, 32, 48];
  static const List<String> _alignments = <String>['left', 'center', 'right'];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.box.text);
    _focus = FocusNode();
    _fontSize = clampFontSize(widget.box.fontSize);
    _align = normaliseAlign(widget.box.align);
    // The keyboard should be up immediately: the user just dragged a box
    // intending to type, so an extra tap would be pure friction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  TextAlign get _textAlign => switch (_align) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('text-box-editor'),
      backgroundColor: StudioTheme.surface,
      title: Text(widget.title, style: const TextStyle(color: StudioTheme.text)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('text-box-field'),
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              maxLines: 6,
              minLines: 1,
              textAlign: _textAlign,
              style: TextStyle(color: StudioTheme.text, fontSize: _fontSize),
              decoration: const InputDecoration(
                hintText: 'Type here…',
                border: OutlineInputBorder(),
              ),
              // Enter inserts a newline (multi-line notes); the buttons commit.
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: 12),
            const Text(
              'Size',
              style: TextStyle(
                fontSize: StudioTheme.captionSize,
                color: StudioTheme.text,
              ),
            ),
            Wrap(
              spacing: 6,
              children: <Widget>[
                for (final double size in _fontSizes)
                  ChoiceChip(
                    key: ValueKey<String>('text-size-${size.round()}'),
                    label: Text('${size.round()}'),
                    selected: _fontSize == size,
                    onSelected: (_) => setState(() => _fontSize = size),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Align',
              style: TextStyle(
                fontSize: StudioTheme.captionSize,
                color: StudioTheme.text,
              ),
            ),
            Wrap(
              spacing: 6,
              children: <Widget>[
                for (final String align in _alignments)
                  ChoiceChip(
                    key: ValueKey<String>('text-align-$align'),
                    label: Text(align),
                    selected: _align == align,
                    onSelected: (_) => setState(() => _align = align),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('text-box-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('text-box-save'),
          onPressed: () => Navigator.of(context).pop(
            TextBoxEdit(
              text: _controller.text,
              fontSize: _fontSize,
              align: _align,
            ),
          ),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
