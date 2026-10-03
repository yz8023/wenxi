import 'package:flutter/material.dart';

const playerAccent = Color(0xfffb7299);
const playerPanelColor = Color(0xff18191c);

/// Media controls stay readable over video regardless of the surrounding app theme.
ThemeData playerTheme(ThemeData inherited) => inherited.copyWith(
  brightness: Brightness.dark,
  canvasColor: playerPanelColor,
  colorScheme: const ColorScheme.dark(
    primary: playerAccent,
    onPrimary: Color(0xff24141a),
    secondary: playerAccent,
    surface: playerPanelColor,
    onSurface: Colors.white,
    onSurfaceVariant: Colors.white60,
    outline: Colors.white24,
    outlineVariant: Colors.white12,
  ),
  textTheme: inherited.textTheme.apply(
    bodyColor: Colors.white,
    displayColor: Colors.white,
  ),
  iconTheme: const IconThemeData(color: Colors.white70),
  dividerColor: Colors.white12,
  dividerTheme: const DividerThemeData(color: Colors.white12, thickness: .6),
  listTileTheme: const ListTileThemeData(
    textColor: Colors.white,
    iconColor: Colors.white70,
    selectedColor: playerAccent,
    contentPadding: EdgeInsets.symmetric(horizontal: 20),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: playerAccent),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: playerAccent,
      foregroundColor: const Color(0xff24141a),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white24),
    ),
  ),
  sliderTheme: inherited.sliderTheme.copyWith(
    activeTrackColor: playerAccent,
    inactiveTrackColor: Colors.white24,
    thumbColor: playerAccent,
    overlayColor: playerAccent.withValues(alpha: .15),
  ),
  switchTheme: SwitchThemeData(
    thumbColor: const WidgetStatePropertyAll(Colors.white),
    trackColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.selected) ? playerAccent : Colors.white24,
    ),
    trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
  ),
);
