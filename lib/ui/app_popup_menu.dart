import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'common.dart';

class AppMenuAction<T> {
  const AppMenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.selected = false,
    this.detail,
  });

  final T value;
  final String label;
  final IconData icon;
  final bool selected;
  final String? detail;
}

class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.actions,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final List<AppMenuAction<T>> actions;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: dark ? const Color(0xff1c1c1e) : Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: dark ? .3 : .12),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border(context).withValues(alpha: .7)),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 320),
      menuPadding: const EdgeInsets.all(6),
      icon: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: brandBlue.withValues(alpha: dark ? .14 : .07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: brandBlue, size: 21),
      ),
      itemBuilder: (context) => [
        for (final action in actions)
          PopupMenuItem<T>(
            value: action.value,
            padding: EdgeInsets.zero,
            child: Semantics(
              selected: action.selected ? true : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: action.selected
                      ? brandBlue.withValues(alpha: dark ? .16 : .07)
                      : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: brandBlue.withValues(alpha: dark ? .14 : .08),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(action.icon, color: brandBlue, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: action.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: action.selected
                              ? brandBlue
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (action.detail != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        action.detail!,
                        style: const TextStyle(fontSize: 12, color: brandBlue),
                      ),
                    ],
                    if (action.selected) ...[
                      const SizedBox(width: 8),
                      const Icon(
                        CupertinoIcons.checkmark,
                        color: brandBlue,
                        size: 16,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
