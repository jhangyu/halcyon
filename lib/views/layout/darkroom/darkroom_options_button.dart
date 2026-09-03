import 'package:flutter/material.dart';

import '../../settings_dialog.dart';
import 'darkroom_column.dart';
import 'darkroom_palette.dart';

/// The mockup's column-footer gear (`c2-desktop-dark.html:443-445`).
///
/// It is a SECOND entry point to the same dialog the actions menu's `Options…`
/// row already opens (`app_actions_menu.dart:79-81`) — no new state, no new
/// behaviour.
///
/// [onPressed] exists so widget tests can drive the button without a
/// `Provider` scope; production builds pass nothing and get [openSettings].
class DarkroomOptionsButton extends StatelessWidget {
  const DarkroomOptionsButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  static void openSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = DarkroomPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Options',
      child: IconButton(
        key: const ValueKey<String>('darkroom-rail-options'),
        icon: Icon(
          Icons.settings_outlined,
          size: kDarkroomRailIconSize,
          color: palette.textFaint,
        ),
        onPressed: onPressed ?? () => openSettings(context),
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll<Size>(
            Size(kDarkroomRailButtonSize, kDarkroomRailButtonSize),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kDarkroomRailButtonRadius),
            ),
          ),
          overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed)) {
              return colors.surfaceContainer;
            }
            return null;
          }),
        ),
      ),
    );
  }
}
