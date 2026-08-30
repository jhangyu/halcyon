import 'package:flutter/material.dart';
import '../theme_tokens.dart';

/// D1's `.section-label` (D1.html:56-60): uppercase caption plus a hairline
/// that fills the remaining width. Deliberately NOT `renameSectionLabel`
/// (rename_dialog/section_label.dart) -- that one has no trailing rule and
/// different metrics; sharing would force one of the two dialogs off-mockup.
Widget settingsSectionLabel(HalcyonTokens t, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.63, // 0.06em at 10.5px
            color: t.textFaint,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1, color: t.borderSoft)),
      ],
    ),
  );
}
