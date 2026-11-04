import 'dart:ui';

import 'package:flutter/material.dart';

/// Phase 5 — professional clean glass corporate style.
///
/// Palette is the existing MyMy logo palette, not a rebrand: deep
/// navy/indigo background, indigo → cyan accent, white text.
/// Contrast rule: body text is always white or white70+ on the dark
/// gradient — never grey-on-gradient. Glass cards are translucent
/// white over the gradient with a thin white border; the blur is
/// decorative (BackdropFilter) and the card stays readable even
/// where the blur cannot render, because the fill is opaque enough
/// on its own.

const Color glassNavy = Color(0xFF0A1030);
const Color glassNavyMid = Color(0xFF131B4A);
const Color glassIndigo = Color(0xFF312E81);
const Color glassCyan = Color(0xFF22D3EE);
const Color glassGold = Color(0xFFC5A04D);

ThemeData myMyGlassTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    scaffoldBackgroundColor: glassNavy,
    colorScheme: const ColorScheme.dark(
      primary: glassCyan,
      secondary: Color(0xFF818CF8),
      surface: glassNavyMid,
      error: Color(0xFFF87171),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Colors.white,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white70,
      indicatorColor: glassCyan,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    cardTheme: const CardThemeData(
      color: Color(0x14FFFFFF),
      elevation: 0,
    ),
  );
}

/// Full-screen gradient behind scrolling content. Tabs scroll over
/// it, so glass cards always have the gradient to frost over.
class GradientBackground extends StatelessWidget {
  const GradientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [glassNavy, glassNavyMid, glassIndigo],
        ),
      ),
      child: child,
    );
  }
}

/// A frosted-glass card: translucent white fill + thin white border
/// + blur of whatever gradient sits behind it. [color], when given,
/// replaces the fill (used for warning/error tints, kept translucent
/// so the glass look survives).
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: color ?? const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x2EFFFFFF)),
          ),
          child: child,
        ),
      ),
    );
  }
}
