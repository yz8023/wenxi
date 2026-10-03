import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'common.dart';

class AppNavigation extends StatelessWidget {
  const AppNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.rail = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool rail;

  static const destinations = [
    ('解析', 'assets/navigation/parse.svg'),
    ('网盘', 'assets/navigation/cloud.svg'),
    ('下载', 'assets/navigation/downloads.svg'),
    ('我的', 'assets/navigation/settings.svg'),
  ];

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final compact = rail && MediaQuery.sizeOf(context).height < 560;
    final active = dark ? const Color(0xff64b5ff) : const Color(0xff006bdb);
    final inactive = dark ? const Color(0xffb8beca) : const Color(0xff606774);

    Widget item(int index) {
      final (label, asset) = destinations[index];
      final selected = index == selectedIndex;
      final color = selected ? active : inactive;
      void activate() => onSelected(index);
      return Semantics(
        key: ValueKey('navigation-$index'),
        label: label,
        selected: selected,
        button: true,
        onTap: activate,
        excludeSemantics: true,
        child: InkWell(
          onTap: activate,
          customBorder: const StadiumBorder(),
          splashColor: active.withValues(alpha: .12),
          highlightColor: active.withValues(alpha: .05),
          focusColor: active.withValues(alpha: .10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: rail ? 18 : 6,
                vertical: rail ? (compact ? 8 : 18) : 9,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(
                    asset,
                    width: 26,
                    height: 26,
                    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (rail) {
      return Container(
        width: 88,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: border(context), width: .5)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(vertical: compact ? 12 : 24),
                child: Image.asset(
                  'assets/icons/app.png',
                  width: 34,
                  height: 34,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < destinations.length; i++) item(i),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: compact ? 10 : 18),
                child: Text(
                  '文析助手',
                  style: TextStyle(fontSize: 10, color: inactive),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(60),
              boxShadow: [
                BoxShadow(
                  color: (dark ? Colors.black : const Color(0xff27364b))
                      .withValues(alpha: dark ? .3 : .11),
                  blurRadius: 26,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(60),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Material(
                  key: const Key('floating-navigation'),
                  color: (dark ? const Color(0xff202228) : Colors.white)
                      .withValues(alpha: dark ? .55 : .42),
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: dark ? .16 : .7),
                      width: .7,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        for (var i = 0; i < destinations.length; i++)
                          Expanded(child: item(i)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
