import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/app_paths.dart';
import '../helpers/background_image.dart';

class _TestThemeAction extends ThemeAction {
  Future<Uint8List?> Function() pick = () async => null;

  @override
  Future<Uint8List?> pickBackgroundImage() => pick();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer container;
  late _TestThemeAction action;

  setUp(() async {
    loadAppLocalizations(const Locale('en'));
    root = Directory.systemTemp.createTempSync('flclash-background-action-');
    await useAppPaths(root);
    container = ProviderContainer(
      overrides: [themeActionProvider.overrideWith(_TestThemeAction.new)],
    )..listen(themeSettingProvider, (_, _) {});
    action = container.read(themeActionProvider.notifier) as _TestThemeAction;
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  test('reselecting a missing image refreshes its cache key', () async {
    final bytes = await backgroundImageBytes();
    action.pick = () async => bytes;
    await action.chooseBackgroundImage();
    final previous = container.read(themeSettingProvider).backgroundImage!;
    File(await appPath.backgroundImagePath(previous)).deleteSync();
    await action.chooseBackgroundImage();
    final selected = container.read(themeSettingProvider).backgroundImage!;
    expect(selected, isNot(previous));
    expect(
      File(await appPath.backgroundImagePath(selected)).existsSync(),
      isTrue,
    );
  });

  test('imports a copy, cancels safely, and clears the image', () async {
    final bytes = await backgroundImageBytes();
    action.pick = () async => bytes;
    await action.chooseBackgroundImage();
    final selected = container.read(themeSettingProvider).backgroundImage!;
    final file = File(await appPath.backgroundImagePath(selected));
    expect(file.existsSync(), isTrue);
    action.pick = () async => null;
    await action.chooseBackgroundImage();
    expect(container.read(themeSettingProvider).backgroundImage, selected);
    await action.clearBackgroundImage();
    expect(container.read(themeSettingProvider).backgroundImage, isNull);
    expect(file.existsSync(), isFalse);
  });

  test(
    'a failed selection keeps the previous image and allows retry',
    () async {
      final first = await backgroundImageBytes();
      action.pick = () async => first;
      await action.chooseBackgroundImage();
      final selected = container.read(themeSettingProvider).backgroundImage;
      action.pick = () async => Uint8List.fromList([1, 2, 3]);
      await expectLater(
        action.chooseBackgroundImage(),
        throwsA(isA<MessageException>()),
      );
      expect(container.read(themeSettingProvider).backgroundImage, selected);
      final next = await backgroundImageBytes(width: 32, height: 64);
      action.pick = () async => next;
      await action.chooseBackgroundImage();
      expect(
        container.read(themeSettingProvider).backgroundImage,
        isNot(selected),
      );
      expect(
        File(await appPath.backgroundImagePath(selected!)).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'does not start overlapping selections or clear a pending import',
    () async {
      final gate = Completer<Uint8List?>();
      var selections = 0;
      action.pick = () {
        selections++;
        return gate.future;
      };
      final pending = action.chooseBackgroundImage();
      await action.chooseBackgroundImage();
      await action.clearBackgroundImage();
      expect(selections, 1);
      gate.complete(await backgroundImageBytes());
      await pending;
      expect(container.read(themeSettingProvider).backgroundImage, isNotNull);
    },
  );
}
