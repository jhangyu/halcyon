import 'package:flutter/material.dart';
import '../theme_tokens.dart';

/// D1's `.block` (D1.html:65): the bordered card each control sits inside.
Widget settingsBlock(HalcyonTokens t, Widget child) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: t.pane,
      border: Border.all(color: t.borderSoft),
      borderRadius: BorderRadius.circular(5),
    ),
    child: child,
  );
}

/// D1's `.row-label` (D1.html:68).
Widget settingsRowLabel(HalcyonTokens t, String text) {
  return Text(text, style: TextStyle(fontSize: 12.5, color: t.text));
}

/// D1's `.row-caption` (D1.html:69).
Widget settingsCaption(HalcyonTokens t, String text) {
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: t.textDim,
        fontFamily: 'monospace',
      ),
    ),
  );
}

/// F1/D1's `input[type=range]` (F1.html:70-71): track height 4, round thumb
/// of radius 7 (14px diameter, matching the mockup's `.slider-thumb`
/// `width:14px;height:14px`). Without this SliderTheme override Flutter's
/// default thumb radius (10) renders visibly larger than the mockup.
Widget settingsSlider({
  required Key key,
  required double min,
  required double max,
  int? divisions,
  required String label,
  required double value,
  required Color activeColor,
  required Color inactiveColor,
  required ValueChanged<double>? onChanged,
}) {
  return SliderTheme(
    data: SliderThemeData(
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    child: Slider(
      key: key,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      value: value,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      onChanged: onChanged,
    ),
  );
}

/// D1's `.key-chip` / `.conflict` (D1.html:85-86).
Widget settingsKeyChip(HalcyonTokens t, String label, {bool conflict = false}) {
  return Container(
    constraints: const BoxConstraints(minWidth: 40),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: conflict ? t.danger.withValues(alpha: 0.12) : t.input,
      border: Border.all(color: conflict ? t.danger : t.border),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontFamily: 'monospace',
        color: conflict ? t.danger : t.text,
      ),
    ),
  );
}

/// D1's `.record-btn` (D1.html:87), reused for Reset / Reset all.
Widget settingsSmallButton(
  HalcyonTokens t,
  String label,
  VoidCallback? onTap, {
  Key? key,
}) {
  return Material(
    key: key,
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: t.borderSoft),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, color: t.textDim)),
      ),
    ),
  );
}

/// D1's `.tabbar` + `.tab` (D1.html:40-43).
class SettingsTabBar extends StatelessWidget {
  const SettingsTabBar({
    super.key,
    required this.labels,
    required this.keys,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> labels;
  final List<Key> keys;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.input,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Material(
              key: keys[i],
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => onSelect(i),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    // null (not a Colors.* literal) paints nothing, which IS
                    // transparent for an idle tab.
                    color: i == selectedIndex ? t.border : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      color: i == selectedIndex ? t.text : t.textDim,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// D1's `.actions` footer (D1.html:90-93).
Widget settingsFooterButtons(
  HalcyonTokens t, {
  required VoidCallback onCancel,
  required VoidCallback onDone,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: t.borderSoft)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Material(
          key: const Key('settingsCancel'),
          color: t.surface,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: onCancel,
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                'Cancel',
                style: TextStyle(fontSize: 12.5, color: t.text),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Material(
          key: const Key('settingsDone'),
          color: t.accent,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: onDone,
            borderRadius: BorderRadius.circular(5),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Text(
                'Done',
                style: TextStyle(fontSize: 12.5, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
