import 'package:flutter/widgets.dart';
import 'package:prism_ui/scaffold.dart';

class PageBackgroundScope extends InheritedWidget {
  const PageBackgroundScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool isEnabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PageBackgroundScope>()
          ?.enabled ??
      false;

  static Color? colorOf(BuildContext context, Color? fallback) =>
      isEnabledOf(context) && !ScaffoldSurface.of(context).isModal
      ? const Color(0x00000000)
      : fallback;

  @override
  bool updateShouldNotify(PageBackgroundScope oldWidget) =>
      enabled != oldWidget.enabled;
}
