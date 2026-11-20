part of '../action.dart';

@Riverpod(keepAlive: true)
class ThemeAction extends _$ThemeAction {
  bool _selectingBackground = false;

  @override
  void build() {}

  @visibleForTesting
  Future<Uint8List?> pickBackgroundImage() => picker.pickBackgroundImage();

  Future<void> chooseBackgroundImage() async {
    if (_selectingBackground) {
      return;
    }
    _selectingBackground = true;
    try {
      final bytes = await pickBackgroundImage();
      if (bytes == null) {
        return;
      }
      final png = await prepareBackgroundImage(bytes);
      final name = await storeBackgroundImage(png);
      if (!ref.mounted) {
        return;
      }
      final previous = ref.read(themeSettingProvider).backgroundImage;
      ref
          .read(themeSettingProvider.notifier)
          .update((state) => state.copyWith(backgroundImage: name));
      if (previous != name) {
        await _removeBackground(previous);
      }
    } finally {
      _selectingBackground = false;
    }
  }

  Future<void> clearBackgroundImage() async {
    if (_selectingBackground) {
      return;
    }
    final previous = ref.read(themeSettingProvider).backgroundImage;
    ref
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(backgroundImage: null));
    await _removeBackground(previous);
  }

  Future<void> _removeBackground(String? name) async {
    try {
      await removeBackgroundImage(name);
    } on FileSystemException {
      commonPrint.log(
        'Background image cleanup failed',
        logLevel: LogLevel.warning,
      );
    }
  }

  void updateBrightness() {
    runAfterFrame(() {
      ref.read(systemBrightnessProvider.notifier).value =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(viewSizeProvider.notifier).value = size;
    });
  }
}
