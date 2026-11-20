import 'dart:typed_data';
import 'dart:ui' as ui;

Future<Uint8List> backgroundImageBytes({
  int width = 64,
  int height = 32,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawPaint(ui.Paint()..color = const ui.Color(0xff346782));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
