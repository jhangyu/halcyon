import 'package:flutter/material.dart';

import '../theme_tokens.dart';

/// Small uppercase section heading shared by the rule editor and preview
/// panes of the rename dialog.
Widget renameSectionLabel(HalcyonTokens t, String text) {
  return Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: t.textDim,
    ),
  );
}
