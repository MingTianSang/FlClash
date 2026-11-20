import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';
import '../helpers/background_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => loadAppLocalizations(const ui.Locale('en')));

  test(
    'backup entries reject background paths outside the managed directory',
    () {
      expect(
        BackupEntries.of(
          profileIds: [],
          scriptIds: [],
          providers: [],
          backgroundImage: '../private.png',
        ),
        isEmpty,
      );
    },
  );

  test('normalizes an image and bounds its decoded size', () async {
    final source = await backgroundImageBytes(width: 3000, height: 1000);
    final normalized = await prepareBackgroundImage(source);
    final codec = await ui.instantiateImageCodec(normalized);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 2560);
    expect(image.height, 853);
    image.dispose();
    codec.dispose();
  });

  test('rejects corrupt and oversized images with useful messages', () async {
    await expectLater(
      prepareBackgroundImage(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<MessageException>().having(
          (error) => error.message,
          'message',
          currentAppLocalizations.backgroundImageInvalid,
        ),
      ),
    );
    await expectLater(
      prepareBackgroundImage(Uint8List(maxBackgroundImageBytes + 1)),
      throwsA(
        isA<MessageException>().having(
          (error) => error.message,
          'message',
          currentAppLocalizations.backgroundImageTooLarge,
        ),
      ),
    );
  });

  test('stores independent copies and removes only managed images', () async {
    final root = Directory.systemTemp.createTempSync('flclash-background-');
    addTearDown(() => root.deleteSync(recursive: true));
    await useAppPaths(root);
    final png = await prepareBackgroundImage(await backgroundImageBytes());
    final name = await storeBackgroundImage(png);
    expect(isBackgroundImageName(name), isTrue);
    expect(await storeBackgroundImage(png), isNot(name));
    final file = File(await appPath.backgroundImagePath(name));
    expect(await file.readAsBytes(), png);
    final unrelated = File('${root.path}/keep.png')..writeAsBytesSync(png);
    await removeBackgroundImage('../keep.png');
    expect(unrelated.existsSync(), isTrue);
    await expectLater(
      appPath.backgroundImagePath('../keep.png'),
      throwsArgumentError,
    );
    await removeBackgroundImage(name);
    expect(file.existsSync(), isFalse);
    await removeBackgroundImage(name);
  });
}
