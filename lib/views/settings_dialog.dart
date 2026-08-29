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
        child: SingleChildScrollView(
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
            const SizedBox(height: 8),
            const Text('Parallel RAW decodes'),
            Text(
              state.maxDecodeLaneWidth > 1
                  ? 'How many expensive RAW decodes may run at once. Higher is '
                        'faster on many-core machines and uses more memory. '
                        'This machine allows up to ${state.maxDecodeLaneWidth}.'
                  : 'This machine has too few cores (or too little memory) to '
                        'run RAW decodes in parallel.',
              style: const TextStyle(fontSize: 12),
            ),
            Slider(
              key: const Key('decodeLaneWidthSlider'),
              min: 1,
              max: state.maxDecodeLaneWidth.toDouble(),
              // Flutter asserts divisions > 0, so a ceiling of 1 passes null.
              divisions: state.maxDecodeLaneWidth > 1
                  ? state.maxDecodeLaneWidth - 1
                  : null,
              label: '${state.decodeLaneWidth}',
              value: state.decodeLaneWidth.toDouble(),
              onChanged: state.maxDecodeLaneWidth > 1
                  ? (double value) => context
                        .read<AppState>()
                        .setDecodeLaneWidth(value.round())
                  : null,
            ),
          ],
        ),
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
