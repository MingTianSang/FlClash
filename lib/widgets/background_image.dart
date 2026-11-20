import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppBackground extends ConsumerStatefulWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends ConsumerState<AppBackground> {
  String? _name;
  Future<String>? _path;

  @override
  Widget build(BuildContext context) {
    final (name, opacity) = ref.watch(
      themeSettingProvider.select(
        (state) => (state.backgroundImage, state.backgroundOpacity),
      ),
    );
    if (_name != name) {
      _name = name;
      _path = isBackgroundImageName(name)
          ? appPath.backgroundImagePath(name!)
          : null;
    }
    final enabled = _path != null && opacity > 0;
    return PageBackgroundScope(
      enabled: enabled,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (enabled)
            Positioned.fill(
              key: const ValueKey('wallpaper'),
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: ColoredBox(
                    color: SurfaceLevel.page.colorOf(context.colorScheme),
                    child: FutureBuilder<String>(
                      future: _path,
                      builder: (context, snapshot) {
                        final path = snapshot.data;
                        return path == null
                            ? const SizedBox.expand()
                            : Image.file(
                                File(path),
                                fit: BoxFit.cover,
                                excludeFromSemantics: true,
                                frameBuilder: (_, child, _, _) =>
                                    Opacity(opacity: opacity, child: child),
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.expand(),
                              );
                      },
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(key: const ValueKey('content'), child: widget.child),
        ],
      ),
    );
  }
}
