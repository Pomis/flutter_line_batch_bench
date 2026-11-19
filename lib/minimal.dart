// The smallest form of the benchmark: 800 lines, redrawn every frame.
//
//   flutter run --profile -t lib/minimal.dart
//
// Change `batched` to compare the two ways. On Impeller both cost the raster
// thread the same: one draw call per line.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

const bool batched = true;
const int lines = 800;

void main() {
  final time = ValueNotifier<double>(0);
  runApp(
    ColoredBox(
      color: const Color(0xFF05070D),
      child: CustomPaint(painter: LinesPainter(time), size: Size.infinite),
    ),
  );
  Ticker((elapsed) => time.value = elapsed.inMicroseconds / 1e6).start();
}

class LinesPainter extends CustomPainter {
  LinesPainter(this.time) : super(repaint: time);

  final ValueNotifier<double> time;
  final Float32List points = Float32List(lines * 4);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xB34A88F0)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final slide = math.sin(time.value * 2) * 3;
    // Four rows of 200 slanted lines.
    final row = size.height / 4;
    for (var i = 0; i < lines; i++) {
      final x = size.width * (i % 200) / 200 + slide;
      final y = row * (i ~/ 200);
      points[i * 4] = x;
      points[i * 4 + 1] = y + 12;
      points[i * 4 + 2] = x + 24;
      points[i * 4 + 3] = y + row - 12;
    }
    if (batched) {
      // One call from Dart...
      canvas.drawRawPoints(ui.PointMode.lines, points, paint);
    } else {
      // ...costs the same as one call per line.
      for (var i = 0; i < lines; i++) {
        canvas.drawLine(
          Offset(points[i * 4], points[i * 4 + 1]),
          Offset(points[i * 4 + 2], points[i * 4 + 3]),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(LinesPainter oldDelegate) => false;
}
