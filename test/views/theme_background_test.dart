import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/theme_background.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';

class _TestThemeAction extends ThemeAction {
  Future<void> Function() choose = () async {};

  @override
  Future<void> chooseBackgroundImage() => choose();

  @override
  Future<void> clearBackgroundImage() async {
    ref
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: null));
  }
}

void main() {
  late ProviderContainer container;
  late Directory root;
  final name = 'background-${'a' * 32}.png';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('flclash-theme-view-');
    await useAppPaths(root);
    container = ProviderContainer(
      overrides: [themeActionProvider.overrideWith(_TestThemeAction.new)],
    );
    globalState.container = container;
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(
          child: BaseScaffold(title: 'Theme', body: ThemeBackgroundSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty settings show selection without a slider or clear', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Choose image'), findsOneWidget);
    expect(find.text('Remove image'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('shows a missing-image message and can clear the selection', (
    tester,
  ) async {
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: name));
    await pumpSettings(tester);
    await tester.runAsync(() async {
      for (var frame = 0; frame < 20; frame++) {
        if (find
            .text('Background image is missing or cannot be opened.')
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(
      find.text('Background image is missing or cannot be opened.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Remove image'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(container.read(themeSettingProvider).backgroundImage, isNull);
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('previews opacity while dragging and commits when released', (
    tester,
  ) async {
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: name));
    await pumpSettings(tester);
    final slider = find.byType(Slider);
    final drag = await tester.startGesture(tester.getCenter(slider));
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(container.read(themeSettingProvider).backgroundOpacity, 0.25);
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      container.read(themeSettingProvider).backgroundOpacity,
      greaterThan(0.25),
    );
  });

  testWidgets(
    'a failed picker releases loading and accepts another selection',
    (tester) async {
      final action =
          container.read(themeActionProvider.notifier) as _TestThemeAction;
      final gate = Completer<void>();
      action.choose = () => gate.future;
      await pumpSettings(tester);
      await tester.tap(find.text('Choose image'));
      await tester.pump();
      expect(find.byType(ActivityIndicator), findsOneWidget);
      expect(
        tester.widget<TonalButton>(find.byType(TonalButton).first).onPressed,
        isNull,
      );
      gate.completeError(const MessageException('Selection failed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ActivityIndicator), findsNothing);
      var retried = false;
      action.choose = () async => retried = true;
      await tester.tap(find.text('Choose image'));
      await tester.pump();
      expect(retried, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
