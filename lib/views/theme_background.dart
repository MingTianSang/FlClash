import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThemeBackgroundSettings extends ConsumerStatefulWidget {
  const ThemeBackgroundSettings({super.key});

  @override
  ConsumerState<ThemeBackgroundSettings> createState() =>
      _ThemeBackgroundSettingsState();
}

class _ThemeBackgroundSettingsState
    extends ConsumerState<ThemeBackgroundSettings> {
  bool _busy = false;
  double? _draft;
  String? _name;
  Future<String>? _path;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await globalState.safeRun(action);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final (name, opacity) = ref.watch(
      themeSettingProvider.select(
        (state) => (state.backgroundImage, state.backgroundOpacity),
      ),
    );
    if (_name != name) {
      _name = name;
      _path = name == null ? null : appPath.backgroundImagePath(name);
      _draft = null;
    }
    final action = ref.read(themeActionProvider.notifier);
    final value = _draft ?? opacity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoHeader(
          info: Info(label: l.backgroundImage, glyph: AppGlyphs.photos),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: context.raisedSurfaceLevel.colorOf(context.colorScheme),
              shape: AppShape.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (_path != null)
                  ClipRSuperellipse(
                    borderRadius: AppRadius.sm,
                    child: SizedBox(
                      height: 160,
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
                                    frameBuilder: (_, child, _, _) =>
                                        Opacity(opacity: value, child: child),
                                    excludeFromSemantics: true,
                                    errorBuilder: (_, _, _) => Center(
                                      child: Text(l.backgroundImageMissing),
                                    ),
                                  );
                          },
                        ),
                      ),
                    ),
                  ),
                Text(
                  l.backgroundImageHint,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TonalButton(
                      label: l.backgroundImageChoose,
                      glyph: AppGlyphs.photos,
                      onPressed: _busy
                          ? null
                          : () => _run(action.chooseBackgroundImage),
                    ),
                    if (name != null)
                      TonalButton(
                        label: l.backgroundImageRemove,
                        onPressed: _busy
                            ? null
                            : () => _run(action.clearBackgroundImage),
                      ),
                    if (_busy) const ActivityIndicator(),
                  ],
                ),
                if (name != null) ...[
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: Text(
                          l.backgroundImageOpacity,
                          style: AppTextStyle.subheadline.of(context),
                        ),
                      ),
                      Text(
                        '${(value * 100).round()}%',
                        style: AppTextStyle.subheadline.of(context),
                      ),
                    ],
                  ),
                  Semantics(
                    label: l.backgroundImageOpacity,
                    child: Slider(
                      value: value,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _draft = value),
                      onChangeEnd: (value) {
                        ref
                            .read(themeSettingProvider.notifier)
                            .update(
                              (state) =>
                                  state.copyWith(backgroundOpacity: value),
                            );
                        setState(() => _draft = null);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
