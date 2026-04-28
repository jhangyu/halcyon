import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return AlertDialog(
      title: const Text('Options'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              title: const Text('Auto-advance on mark'),
              subtitle: const Text(
                'Automatically switch to the next photo after starring or trashing.',
                style: TextStyle(fontSize: 12),
              ),
              value: state.autoAdvance,
              onChanged: (bool? value) {
                if (value != null) {
                  context.read<AppState>().setAutoAdvance(value);
                }
              },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('Overwrite existing files on Copy/Move'),
              subtitle: const Text(
                'If checked, existing files in the destination folder will be overwritten. If unchecked, they will be skipped.',
                style: TextStyle(fontSize: 12),
              ),
              value: state.overwriteExisting,
              onChanged: (bool? value) {
                if (value != null) {
                  context.read<AppState>().setOverwriteExisting(value);
                }
              },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
