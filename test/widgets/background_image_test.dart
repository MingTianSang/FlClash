import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/widgets/background_image.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/background_image.dart';
import '../helpers/test_app.dart';

void main() {
  late ProviderContainer container;
  late Directory root;
  late GlobalKey backgroundKey;
  final name = 'background-${'b' * 32}.png';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('flclash-background-widget-');
    await useAppPaths(root);
    container = ProviderContainer()..listen(themeSettingProvider, (_, _) {});
    backgroundKey = GlobalKey();
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> pumpBackground(WidgetTester tester, {bool modal = false}) async {
    const page = BaseScaffold(title: 'Page', body: Text('Content'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: HostApp(
          key: ValueKey(modal),
          builder: (context, child) => wrapAppScopes(
            context,
            RepaintBoundary(
              key: backgroundKey,
              child: AppBackground(child: child!),
            ),
          ),
          onGenerateRoute: (settings) => HomeRoute(
            settings: settings,
            builder: (_) => modal
                ? const SheetProvider(type: SheetType.sideSheet, child: page)
                : page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('only page canvases become transparent; sheets keep their fill', (
    tester,
  ) async {
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: name));
    await pumpBackground(tester);
    expect(
      tester.widget<PrismScaffold>(find.byType(PrismScaffold)).backgroundColor,
      Colors.transparent,
    );
    expect(
      tester.widget<ScaffoldBar>(find.byType(ScaffoldBar)).backgroundColor,
      isNull,
    );
    await pumpBackground(tester, modal: true);
    expect(
      tester.widget<PrismScaffold>(find.byType(PrismScaffold)).backgroundColor,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('image and opacity changes preserve the page state', (
    tester,
  ) async {
    await pumpBackground(tester);
    final element = tester.element(find.byType(BaseScaffold));
    await tester.runAsync(() async {
      final file = File(await appPath.backgroundImagePath(name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(await backgroundImageBytes());
      await precacheImage(
        FileImage(file),
        tester.element(find.byType(AppBackground)),
      );
    });
    container
        .read(themeSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(backgroundImage: name, backgroundOpacity: 1),
        );
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(BaseScaffold)), same(element));
    Future<List<int>> backgroundPixel() async {
      return (await tester.runAsync(() async {
        final boundary =
            backgroundKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = ((image.height - 2) * image.width + 2) * 4;
        final pixel = pixels.buffer.asUint8List(offset, 4).toList();
        image.dispose();
        return pixel;
      }))!;
    }

    expect(await backgroundPixel(), [0x34, 0x67, 0x82, 0xff]);
    final base = SurfaceLevel.page.colorOf(
      tester.element(find.byType(AppBackground)).colorScheme,
    );
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundOpacity: 0.5));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(BaseScaffold)), same(element));
    final faded = await backgroundPixel();
    final expected = Color.alphaBlend(const Color(0x80346782), base);
    for (var channel = 0; channel < 3; channel++) {
      final byte = (expected.toARGB32() >> (16 - 8 * channel)) & 0xff;
      expect(faded[channel], closeTo(byte, 1));
    }
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundOpacity: 1));
    await tester.pumpAndSettle();
    expect(await backgroundPixel(), [0x34, 0x67, 0x82, 0xff]);
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: null));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(BaseScaffold)), same(element));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('zero opacity and missing images leave usable content', (
    tester,
  ) async {
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: name));
    await pumpBackground(tester);
    expect(find.text('Content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundOpacity: 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PrismScaffold>(find.byType(PrismScaffold)).backgroundColor,
      isNull,
    );
    expect(find.byType(Image), findsNothing);
  });
}
