import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The circled question mark that explains a field.
///
/// Notes sit behind this instead of under every card, so the page stays
/// readable and the explanation is one tap from the field it belongs to.
class NoteHelp extends StatelessWidget {
  const NoteHelp(this.note, {super.key, this.label = 'What this means'});

  final String note;
  final String label;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => showNote(context, note, label: label),
      tooltip: label,
      icon: const Icon(Icons.help_outline_rounded, size: 14),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      color: const Color(0xFF64748B),
      splashRadius: 14,
    );
  }
}

/// Shows [note] in a dialog, for a note too long to sit beside its field.
Future<void> showNote(
  BuildContext context,
  String note, {
  String label = 'What this means',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      content: Text(
        note,
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.55,
          color: AppColors.textMuted,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
