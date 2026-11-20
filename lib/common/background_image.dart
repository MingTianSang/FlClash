import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;

import 'app_localizations.dart';
import 'exception.dart';
import 'path.dart';
import 'snowflake.dart';

const maxBackgroundImageBytes = 20 * 1024 * 1024;
const defaultBackgroundOpacity = 0.25;
final _backgroundName = RegExp(r'^background-[a-f0-9]{32}\.png$');

bool isBackgroundImageName(String? name) =>
    name != null && _backgroundName.hasMatch(name);

String? backgroundImageFromJson(Object? value) =>
    value is String && isBackgroundImageName(value) ? value : null;

double backgroundOpacityFromJson(Object? value) =>
    value is num && value.isFinite
    ? value.toDouble().clamp(0.0, 1.0)
    : defaultBackgroundOpacity;

Future<Uint8List> prepareBackgroundImage(Uint8List bytes) async {
  if (bytes.length > maxBackgroundImageBytes) {
    throw MessageException(currentAppLocalizations.backgroundImageTooLarge);
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 64000000) {
      throw const FormatException();
    }
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final ratio = longest > 2560 ? 2560 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * ratio).round().clamp(1, 2560),
      targetHeight: (descriptor.height * ratio).round().clamp(1, 2560),
    );
    image = (await codec.getNextFrame()).image;
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null) {
      throw const FormatException();
    }
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } catch (_) {
    throw MessageException(currentAppLocalizations.backgroundImageInvalid);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<String> storeBackgroundImage(Uint8List png) async {
  final name = 'background-${uuidV4.replaceAll('-', '')}.png';
  final file = File(await appPath.backgroundImagePath(name));
  if (!await file.exists()) {
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png, flush: true);
  }
  return name;
}

Future<void> removeBackgroundImage(String? name) async {
  if (!isBackgroundImageName(name)) {
    return;
  }
  final file = File(await appPath.backgroundImagePath(name!));
  if (await file.exists()) {
    await file.delete();
  }
}
