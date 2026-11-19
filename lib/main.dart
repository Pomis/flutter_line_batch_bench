// Line batch bench: what it costs to draw straight lines, by the way they
// are handed to the engine. A whole Flutter app in one file with no
// dependencies beyond the Flutter SDK, so it builds with any recent Flutter
// version or with an engine built from source (see tool/bench.py).
//
// It plays scenarios. A scenario is either a scene, a small drawing of the
// kind apps make out of lines, or `lines`, one set of plain lines whose
// number, cap, width, layout and way of drawing are set one by one.
//
// Scenes (all drawn with Canvas.drawRawPoints):
//   hatch      shapes shaded with clipped runs of parallel lines
//   chart      a grid, tick marks and six series as polylines
//   grid       graph paper: thin level and upright lines, scrolling
//   waveform   an audio wave as upright bars, mirrored
//   starfield  short streaks flying out from the middle
//   wireframe  a turning sphere as a mesh of edges
//   spiro      one long curve as a single polyline
//   rain       slanted drops in two layers
//
// `lines` takes: n (how many), cap (round, butt, square), w (width),
// layout (parallel, cross, ticks, random, wave), alpha, calls (split the
// lines over this many calls), clip, rot (a turned and stretched canvas),
// fx (none, blur, overlay, filter) and way:
//   rawpoints  Canvas.drawRawPoints(PointMode.lines)
//   polygon    Canvas.drawRawPoints(PointMode.polygon)
//   drawline   Canvas.drawLine once a line
//   path       one stroked Path with a moveTo/lineTo a line
//   vertices   one Canvas.drawVertices: two triangles a line
//   empty      nothing (the cost of a frame)
//
// The plan arrives as the start route, scenarios separated by `|`:
//
//   adb shell am start -n <app id>/.MainActivity --es route \
//       "'/?s=hatch|chart|lines:n=800,cap=butt&seconds=4&rounds=5'"
//
// Each round plays every scenario, starting one step later than the round
// before, so heat and the phone's clock fall on all of them alike. A step
// is reported as one `LINEBENCH {json}` log line: frames delivered, the
// engine's own UI and raster times, the CPU time the raster thread and the
// UI thread spent (from /proc, so waiting for the screen is not in it), the
// line segments in a frame, and a hash of the scenario's pixels at one fixed
// moment, to tell whether two engines draw it alike.
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const double _height = 220;
const Color _ink = Color(0xFF4A88F0);
const Color _pale = Color(0xFF9CC2FF);
const Color _page = Color(0xFF05070D);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final route = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final query = <String, String>{};
  final mark = route.indexOf('?');
  if (mark >= 0) {
    for (final part in route.substring(mark + 1).split('&')) {
      final equals = part.indexOf('=');
      if (equals > 0) {
        query[part.substring(0, equals)] = part.substring(equals + 1);
      }
    }
  }
  runApp(
    LineBench(
      scenarios: [
        for (final spec in (query['s'] ?? 'hatch|chart|lines:n=400').split('|'))
          if (spec.isNotEmpty) Scenario.parse(spec),
      ],
      seconds: double.tryParse(query['seconds'] ?? '') ?? 4,
      rounds: int.tryParse(query['rounds'] ?? '') ?? 5,
    ),
  );
}

/// One thing to draw every frame. [segments] is set by a paint: how many
/// line segments the frame held.
class Scenario {
  Scenario(this.spec, this.name, this.options);

  factory Scenario.parse(String spec) {
    final colon = spec.indexOf(':');
    final name = colon < 0 ? spec : spec.substring(0, colon);
    final options = <String, String>{};
    if (colon >= 0) {
      for (final part in spec.substring(colon + 1).split(',')) {
        final equals = part.indexOf('=');
        if (equals > 0) {
          options[part.substring(0, equals)] = part.substring(equals + 1);
        }
      }
    }
    return Scenario(spec, name, options);
  }

  final String spec;
  final String name;
  final Map<String, String> options;
  int segments = 0;

  double _number(String key, double fallback) =>
      double.tryParse(options[key] ?? '') ?? fallback;

  void paint(Canvas canvas, Size size, double t) {
    segments = 0;
    switch (name) {
      case 'hatch':
        _hatch(canvas, size, t);
      case 'chart':
        _chart(canvas, size, t);
      case 'grid':
        _grid(canvas, size, t);
      case 'waveform':
        _waveform(canvas, size, t);
      case 'starfield':
        _starfield(canvas, size, t);
      case 'wireframe':
        _wireframe(canvas, size, t);
      case 'spiro':
        _spiro(canvas, size, t);
      case 'rain':
        _rain(canvas, size, t);
      case 'lines':
        _lines(canvas, size, t);
    }
  }

  // The engine reads the list during the call, so one buffer serves them all.
  static Float32List _buffer = Float32List(1024);
  static Float32List _room(int floats) {
    if (_buffer.length < floats) _buffer = Float32List(floats * 2);
    return _buffer;
  }

  void _segments(Canvas canvas, Float32List at, int count, Paint paint) {
    if (count == 0) return;
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.sublistView(at, 0, count * 4),
      paint,
    );
    segments += count;
  }

  void _polyline(Canvas canvas, Float32List at, int points, Paint paint) {
    if (points < 2) return;
    canvas.drawRawPoints(
      ui.PointMode.polygon,
      Float32List.sublistView(at, 0, points * 2),
      paint,
    );
    segments += points - 1;
  }

  /// Fills the buffer with lines [spacing] apart at [angle], long enough to
  /// cross [box] whole, and returns how many.
  int _hatchLines(Rect box, double angle, double spacing, double shift) {
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final reach = box.longestSide;
    final count = (reach * 2 / spacing).ceil();
    final at = _room(count * 4);
    for (var i = 0; i < count; i++) {
      final offset = (i - count / 2) * spacing + shift % spacing;
      final cx = box.center.dx - dy * offset;
      final cy = box.center.dy + dx * offset;
      at[i * 4] = cx - dx * reach;
      at[i * 4 + 1] = cy - dy * reach;
      at[i * 4 + 2] = cx + dx * reach;
      at[i * 4 + 3] = cy + dy * reach;
    }
    return count;
  }

  // Shapes shaded as an engraver would: each is a clip and a run of
  // parallel lines, some crossed by a second run.
  void _hatch(Canvas canvas, Size size, double t) {
    final w = size.width;
    final h = size.height;
    final sway = math.sin(t * 1.3) * 6;
    final shapes = <(Path, double, double, bool)>[
      (
        Path()..addRect(Rect.fromLTWH(0, h * 0.72, w, h * 0.28)),
        0.12,
        3.0,
        false,
      ),
      (
        Path()..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.08 + sway, h * 0.30, w * 0.26, h * 0.44),
            const Radius.circular(10),
          ),
        ),
        0.56,
        2.6,
        true,
      ),
      (
        Path()..addOval(
          Rect.fromCenter(
            center: Offset(w * 0.52, h * 0.42 + sway * 0.5),
            width: w * 0.24,
            height: h * 0.52,
          ),
        ),
        -0.5,
        2.4,
        true,
      ),
      (
        Path()
          ..moveTo(w * 0.70, h * 0.74)
          ..lineTo(w * 0.80 - sway, h * 0.16)
          ..lineTo(w * 0.94, h * 0.74)
          ..close(),
        1.1,
        2.8,
        false,
      ),
      (
        Path()..addOval(
          Rect.fromCenter(
            center: Offset(w * 0.30, h * 0.80),
            width: w * 0.5,
            height: h * 0.10,
          ),
        ),
        0.0,
        2.0,
        false,
      ),
      (Path()..addRect(Rect.fromLTWH(0, 0, w, h * 0.72)), 0.9, 9.0, false),
    ];
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.2;
    for (final (path, angle, spacing, crossed) in shapes.reversed) {
      final box = path.getBounds();
      canvas.save();
      canvas.clipPath(path);
      paint.color = _ink.withValues(alpha: 0.7);
      // The count first: making the lines may swap the buffer for a longer one.
      var count = _hatchLines(box, angle, spacing, t * 4);
      _segments(canvas, _buffer, count, paint);
      if (crossed) {
        paint.color = _pale.withValues(alpha: 0.45);
        count = _hatchLines(box, angle + 1.2, spacing * 1.5, -t * 3);
        _segments(canvas, _buffer, count, paint);
      }
      canvas.restore();
    }
  }

  // A line chart: a grid, tick marks, and six series of 300 points each.
  void _chart(Canvas canvas, Size size, double t) {
    final w = size.width;
    final h = size.height;
    final grid = Paint()
      ..color = _ink.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    var at = _room(64 * 4);
    var count = 0;
    for (var i = 0; i <= 10; i++) {
      final y = h * (0.06 + 0.84 * i / 10);
      at[count * 4] = w * 0.06;
      at[count * 4 + 1] = y;
      at[count * 4 + 2] = w * 0.98;
      at[count * 4 + 3] = y;
      count++;
    }
    for (var i = 0; i <= 16; i++) {
      final x = w * (0.06 + 0.92 * i / 16);
      at[count * 4] = x;
      at[count * 4 + 1] = h * 0.06;
      at[count * 4 + 2] = x;
      at[count * 4 + 3] = h * 0.90;
      count++;
    }
    _segments(canvas, at, count, grid);
    count = 0;
    at = _room(100 * 4);
    for (var i = 0; i <= 80; i++) {
      final x = w * (0.06 + 0.92 * i / 80);
      at[count * 4] = x;
      at[count * 4 + 1] = h * 0.90;
      at[count * 4 + 2] = x;
      at[count * 4 + 3] = h * (i % 5 == 0 ? 0.95 : 0.925);
      count++;
    }
    _segments(canvas, at, count, grid..strokeWidth = 1.5);
    const points = 300;
    final series = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var s = 0; s < 6; s++) {
      at = _room(points * 2);
      for (var i = 0; i < points; i++) {
        final u = i / (points - 1);
        at[i * 2] = w * (0.06 + 0.92 * u);
        at[i * 2 + 1] =
            h *
            (0.48 +
                0.16 * math.sin(u * (5 + s) + t * (0.6 + s * 0.2) + s) +
                0.10 * math.sin(u * (17 + s * 3) - t * 1.3) +
                0.04 * (s - 2.5));
      }
      series.color = Color.lerp(_ink, _pale, s / 5)!.withValues(alpha: 0.85);
      _polyline(canvas, at, points, series);
    }
  }

  // Graph paper: thin level and upright lines, scrolling sideways.
  void _grid(Canvas canvas, Size size, double t) {
    const step = 6.0;
    final shift = (t * 12) % step;
    final across = (size.width / step).ceil() + 1;
    final down = (size.height / step).ceil() + 1;
    final at = _room((across + down) * 4);
    var count = 0;
    for (var i = 0; i < across; i++) {
      final x = i * step + shift;
      at[count * 4] = x;
      at[count * 4 + 1] = 0;
      at[count * 4 + 2] = x;
      at[count * 4 + 3] = size.height;
      count++;
    }
    for (var i = 0; i < down; i++) {
      final y = i * step + shift * 0.5;
      at[count * 4] = 0;
      at[count * 4 + 1] = y;
      at[count * 4 + 2] = size.width;
      at[count * 4 + 3] = y;
      count++;
    }
    _segments(
      canvas,
      at,
      count,
      Paint()
        ..color = _ink
        ..strokeWidth = 0.5,
    );
  }

  // An audio wave as one upright bar every pixel and a half, and its
  // reflection.
  void _waveform(Canvas canvas, Size size, double t) {
    final bars = (size.width / 1.5).floor();
    final at = _room(bars * 4);
    final mid = size.height * 0.46;
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i < bars; i++) {
        final u = i / bars;
        final level =
            (0.5 + 0.5 * math.sin(u * 40 + t * 5)) *
            (0.5 + 0.5 * math.sin(u * 7 - t * 1.7)) *
            (0.35 + 0.65 * math.sin(u * math.pi));
        final x = i * 1.5 + 0.75;
        final reach = size.height * 0.40 * level + 1;
        at[i * 4] = x;
        at[i * 4 + 1] = pass == 0 ? mid - reach : mid + 3;
        at[i * 4 + 2] = x;
        at[i * 4 + 3] = pass == 0 ? mid : mid + 3 + reach * 0.5;
      }
      _segments(
        canvas,
        at,
        bars,
        Paint()
          ..color = pass == 0 ? _pale : _ink.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
  }

  static final List<double> _noise = () {
    final random = math.Random(7);
    return [for (var i = 0; i < 16384; i++) random.nextDouble()];
  }();

  // Streaks flying out from the middle, in three layers of 500.
  void _starfield(Canvas canvas, Size size, double t) {
    final centre = size.center(Offset.zero);
    final far = size.longestSide * 0.7;
    for (var layer = 0; layer < 3; layer++) {
      const stars = 500;
      final at = _room(stars * 4);
      for (var i = 0; i < stars; i++) {
        final seed = (layer * stars + i) * 3;
        final angle = _noise[seed] * math.pi * 2;
        final travel = (_noise[seed + 1] + t * (0.15 + layer * 0.1)) % 1.0;
        final from = travel * travel * far;
        final length = 3 + travel * (10 + layer * 8);
        final dx = math.cos(angle);
        final dy = math.sin(angle);
        at[i * 4] = centre.dx + dx * from;
        at[i * 4 + 1] = centre.dy + dy * from;
        at[i * 4 + 2] = centre.dx + dx * (from + length);
        at[i * 4 + 3] = centre.dy + dy * (from + length);
      }
      _segments(
        canvas,
        at,
        stars,
        Paint()
          ..color = Color.lerp(_ink, _pale, layer / 2)!.withValues(alpha: 0.8)
          ..strokeWidth = 0.8 + layer * 0.6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  // A turning sphere as its mesh of edges: 23 rings of 40 edges, and 40
  // half circles from pole to pole.
  void _wireframe(Canvas canvas, Size size, double t) {
    const rings = 24;
    const around = 40;
    final radius = size.height * 0.44;
    final centre = size.center(Offset.zero);
    final spin = t * 0.6;
    final tilt = 0.5 + math.sin(t * 0.4) * 0.2;
    Offset project(double latitude, double longitude) {
      final x = math.cos(latitude) * math.cos(longitude + spin);
      final y = math.sin(latitude);
      final z = math.cos(latitude) * math.sin(longitude + spin);
      final y2 = y * math.cos(tilt) - z * math.sin(tilt);
      final z2 = y * math.sin(tilt) + z * math.cos(tilt);
      final depth = 1 / (2.6 - z2);
      return centre + Offset(x, y2) * (radius * 2.2 * depth);
    }

    final at = _room((rings - 1) * around * 4 + around * rings * 4);
    var count = 0;
    void edge(Offset a, Offset b) {
      at[count * 4] = a.dx;
      at[count * 4 + 1] = a.dy;
      at[count * 4 + 2] = b.dx;
      at[count * 4 + 3] = b.dy;
      count++;
    }

    for (var r = 1; r < rings; r++) {
      final latitude = -math.pi / 2 + math.pi * r / rings;
      for (var a = 0; a < around; a++) {
        edge(
          project(latitude, math.pi * 2 * a / around),
          project(latitude, math.pi * 2 * (a + 1) / around),
        );
      }
    }
    for (var a = 0; a < around; a++) {
      final longitude = math.pi * 2 * a / around;
      for (var r = 0; r < rings; r++) {
        edge(
          project(-math.pi / 2 + math.pi * r / rings, longitude),
          project(-math.pi / 2 + math.pi * (r + 1) / rings, longitude),
        );
      }
    }
    _segments(
      canvas,
      at,
      count,
      Paint()
        ..color = _ink.withValues(alpha: 0.6)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
  }

  // One long curve that crosses itself, as a single polyline of 4,000 points.
  void _spiro(Canvas canvas, Size size, double t) {
    const points = 4000;
    final at = _room(points * 2);
    final centre = size.center(Offset.zero);
    final rx = size.width * 0.46;
    final ry = size.height * 0.46;
    for (var i = 0; i < points; i++) {
      final u = i / points * math.pi * 2 * 9;
      at[i * 2] =
          centre.dx + rx * (0.62 * math.cos(u) + 0.38 * math.cos(u * 3.7 + t));
      at[i * 2 + 1] =
          centre.dy +
          ry * (0.62 * math.sin(u * 1.3) + 0.38 * math.sin(u * 4.1 - t * 0.7));
    }
    _polyline(
      canvas,
      at,
      points,
      Paint()
        ..color = _pale.withValues(alpha: 0.55)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  // Slanted drops falling, a near layer and a far one.
  void _rain(Canvas canvas, Size size, double t) {
    for (var layer = 0; layer < 2; layer++) {
      const drops = 450;
      final at = _room(drops * 4);
      final length = layer == 0 ? 9.0 : 16.0;
      for (var i = 0; i < drops; i++) {
        final seed = 6000 + (layer * drops + i) * 2;
        final x = _noise[seed] * (size.width + 60) - 30;
        final fall =
            (_noise[seed + 1] + t * (0.5 + layer * 0.5)) %
                1.0 *
                (size.height + 40) -
            20;
        at[i * 4] = x + fall * 0.25;
        at[i * 4 + 1] = fall;
        at[i * 4 + 2] = x + (fall + length) * 0.25;
        at[i * 4 + 3] = fall + length;
      }
      _segments(
        canvas,
        at,
        drops,
        Paint()
          ..color = (layer == 0 ? _ink : _pale).withValues(alpha: 0.7)
          ..strokeWidth = layer == 0 ? 1 : 1.6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  Float32List _quads = Float32List(0);

  // Plain lines, every property set by an option.
  void _lines(Canvas canvas, Size size, double t) {
    final way = options['way'] ?? 'rawpoints';
    final count = _number('n', 400).round();
    if (way == 'empty' || count == 0) return;
    final layout =
        options['layout'] ?? (way == 'polygon' ? 'wave' : 'parallel');
    final width = _number('w', 1.2);
    final calls = math.max(1, _number('calls', 1).round());
    final slide = math.sin(t * 2) * 3;
    final w = size.width;
    final h = size.height;

    canvas.save();
    if (options['rot'] == '1') {
      canvas
        ..translate(w / 2, h / 2)
        ..rotate(0.3)
        ..scale(1.15, 0.85)
        ..translate(-w / 2, -h / 2);
    }
    if (options['clip'] == '1') {
      canvas.clipPath(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(20, 16, w - 40, h - 32),
            const Radius.circular(28),
          ),
        ),
      );
    }

    final paint = Paint()
      ..color = _ink.withValues(alpha: _number('alpha', 0.7))
      ..strokeWidth = width
      ..strokeCap = switch (options['cap']) {
        'butt' => StrokeCap.butt,
        'square' => StrokeCap.square,
        _ => StrokeCap.round,
      };
    switch (options['fx']) {
      case 'blur':
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      case 'overlay':
        paint.blendMode = BlendMode.overlay;
      case 'filter':
        paint.colorFilter = const ColorFilter.mode(
          Color(0xFF80FFC0),
          BlendMode.modulate,
        );
    }

    if (layout == 'wave') {
      // Points along a wave, for a polyline.
      final at = _room(count * 2);
      for (var i = 0; i < count; i++) {
        final u = i / (count - 1);
        at[i * 2] = w * u;
        at[i * 2 + 1] =
            h * (0.5 + 0.3 * math.sin(u * 22 + t * 2) * math.sin(u * 3.1));
      }
      if (way == 'polygon') {
        _polyline(canvas, at, count, paint);
      } else {
        for (var i = 0; i + 1 < count; i++) {
          canvas.drawLine(
            Offset(at[i * 2], at[i * 2 + 1]),
            Offset(at[i * 2 + 2], at[i * 2 + 3]),
            paint,
          );
        }
        segments += count - 1;
      }
      canvas.restore();
      return;
    }

    final at = _room(count * 4);
    const angle = 32 * math.pi / 180;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final span = w + h;
    for (var i = 0; i < count; i++) {
      final u = (i + 0.5) / count;
      switch (layout) {
        case 'cross':
          // Two sets that cross each other.
          final flip = i.isEven ? 1.0 : -1.0;
          final cx = -h * 0.5 + span * u + slide * flip;
          at[i * 4] = cx - dx * w * 0.5;
          at[i * 4 + 1] = h * 0.5 - dy * w * 0.5 * flip;
          at[i * 4 + 2] = cx + dx * w * 0.5;
          at[i * 4 + 3] = h * 0.5 + dy * w * 0.5 * flip;
        case 'ticks':
          // Short marks on a grid.
          final columns = math.sqrt(count * w / h).ceil();
          final rows = (count / columns).ceil();
          final cx = (i % columns + 0.5) * w / columns + slide;
          final cy = (i ~/ columns + 0.5) * h / rows;
          at[i * 4] = cx - dx * 4;
          at[i * 4 + 1] = cy - dy * 4;
          at[i * 4 + 2] = cx + dx * 4;
          at[i * 4 + 3] = cy + dy * 4;
        case 'random':
          final seed = (i * 4) % (_noise.length - 4);
          at[i * 4] = _noise[seed] * w + slide;
          at[i * 4 + 1] = _noise[seed + 1] * h;
          at[i * 4 + 2] = _noise[seed + 2] * w - slide;
          at[i * 4 + 3] = _noise[seed + 3] * h;
        default:
          // Parallel, each crossing the whole box.
          final cx = -h * 0.5 + span * u + slide;
          at[i * 4] = cx - dx * w * 0.5;
          at[i * 4 + 1] = h * 0.5 - dy * w * 0.5;
          at[i * 4 + 2] = cx + dx * w * 0.5;
          at[i * 4 + 3] = h * 0.5 + dy * w * 0.5;
      }
    }

    switch (way) {
      case 'drawline':
        for (var i = 0; i < count; i++) {
          canvas.drawLine(
            Offset(at[i * 4], at[i * 4 + 1]),
            Offset(at[i * 4 + 2], at[i * 4 + 3]),
            paint,
          );
        }
        segments += count;
      case 'path':
        final path = Path();
        for (var i = 0; i < count; i++) {
          path
            ..moveTo(at[i * 4], at[i * 4 + 1])
            ..lineTo(at[i * 4 + 2], at[i * 4 + 3]);
        }
        canvas.drawPath(path, paint..style = PaintingStyle.stroke);
        segments += count;
      case 'vertices':
        // Two triangles a line, as wide as the engine draws a line: never
        // under a device pixel (LineGeometry::ComputePixelHalfWidth).
        final scale =
            ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
        final half = math.max(width, 1 / scale) / 2;
        if (_quads.length != count * 12) _quads = Float32List(count * 12);
        final q = _quads;
        for (var i = 0; i < count; i++) {
          final x0 = at[i * 4];
          final y0 = at[i * 4 + 1];
          final x1 = at[i * 4 + 2];
          final y1 = at[i * 4 + 3];
          final lx = x1 - x0;
          final ly = y1 - y0;
          final length = math.sqrt(lx * lx + ly * ly);
          final ax = -ly / length * half;
          final ay = lx / length * half;
          final o = i * 12;
          q[o] = x0 - ax;
          q[o + 1] = y0 - ay;
          q[o + 2] = x1 - ax;
          q[o + 3] = y1 - ay;
          q[o + 4] = x0 + ax;
          q[o + 5] = y0 + ay;
          q[o + 6] = x0 + ax;
          q[o + 7] = y0 + ay;
          q[o + 8] = x1 - ax;
          q[o + 9] = y1 - ay;
          q[o + 10] = x1 + ax;
          q[o + 11] = y1 + ay;
        }
        final vertices = ui.Vertices.raw(ui.VertexMode.triangles, q);
        canvas.drawVertices(
          vertices,
          BlendMode.srcOver,
          Paint()..color = paint.color,
        );
        vertices.dispose();
        segments += count;
      default:
        // One call, or the lines shared out over several calls.
        final each = (count / calls).ceil();
        for (var from = 0; from < count; from += each) {
          final to = math.min(count, from + each);
          canvas.drawRawPoints(
            ui.PointMode.lines,
            Float32List.sublistView(at, from * 4, to * 4),
            paint,
          );
        }
        segments += count;
    }
    canvas.restore();
  }
}

class LineBench extends StatefulWidget {
  const LineBench({
    super.key,
    required this.scenarios,
    required this.seconds,
    required this.rounds,
  });

  final List<Scenario> scenarios;
  final double seconds;
  final int rounds;

  @override
  State<LineBench> createState() => _LineBenchState();
}

class _LineBenchState extends State<LineBench>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _time = ValueNotifier(0);
  final List<ui.FrameTiming> _timings = [];
  Scenario? _current;
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _time.value = elapsed.inMicroseconds / 1e6;
    })..start();
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    unawaited(_run());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  static final Map<String, String> _statFiles = {};

  /// Nanoseconds of CPU a thread of this app has used, by the thread's name.
  static int _cpuNanos(String thread) {
    var path = _statFiles[thread];
    if (path == null) {
      try {
        for (final task in Directory('/proc/self/task').listSync()) {
          try {
            final name = File('${task.path}/comm').readAsStringSync().trim();
            if (name == thread) {
              path = '${task.path}/schedstat';
              break;
            }
          } on Object {
            // A thread that ended while the list was read.
          }
        }
      } on Object {
        return -1;
      }
      if (path == null) return -1;
      _statFiles[thread] = path;
    }
    try {
      return int.parse(File(path).readAsStringSync().split(' ').first);
    } on Object {
      return -1;
    }
  }

  /// The UI thread's CPU time. Android runs Dart on the app's main thread;
  /// older engines gave it a thread of its own, named `1.ui`.
  static int _uiCpuNanos() {
    final own = _cpuNanos('1.ui');
    if (own >= 0) return own;
    try {
      return int.parse(
        File('/proc/self/schedstat').readAsStringSync().split(' ').first,
      );
    } on Object {
      return -1;
    }
  }

  /// Completes after a frame has been drawn, with that frame's number.
  Future<int> _frame() {
    final done = Completer<int>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      done.complete(
        WidgetsBinding.instance.platformDispatcher.frameData.frameNumber,
      );
    });
    SchedulerBinding.instance.scheduleFrame();
    return done.future;
  }

  /// A hash of the scenario's pixels at one fixed moment, drawn by this
  /// engine at the screen's own size: two engines that draw it alike give
  /// the same hash.
  Future<String> _pixelHash(Scenario scenario) async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final ratio = view.devicePixelRatio;
    final size = ui.Size(view.physicalSize.width / ratio, _height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    canvas.drawRect(Offset.zero & size, Paint()..color = _page);
    scenario.paint(canvas, size, 1.234);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (size.width * ratio).round(),
      (size.height * ratio).round(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();
    final bytes = data!.buffer.asUint8List();
    // FNV-1a, 32 bits.
    var hash = 0x811C9DC5;
    for (var i = 0; i < bytes.length; i++) {
      hash = ((hash ^ bytes[i]) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<void> _run() async {
    final steps = widget.scenarios;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    // On some phones the app runs before its view has a size.
    while (view.physicalSize.isEmpty) {
      await _frame();
    }
    print(
      'LINEBENCH ${jsonEncode({'type': 'start', 'refreshRate': view.display.refreshRate, 'devicePixelRatio': view.devicePixelRatio, 'widthPx': view.physicalSize.width, 'heightPx': _height * view.devicePixelRatio, 'steps': steps.length, 'rounds': widget.rounds, 'dart': Platform.version.split(' ').first})}',
    );
    final hashes = <String, String>{};
    for (var round = 0; round < widget.rounds; round++) {
      for (var i = 0; i < steps.length; i++) {
        final step = steps[(i + round) % steps.length];
        hashes[step.spec] ??= await _pixelHash(step);
        setState(() {
          _current = step;
          _status = 'round ${round + 1}/${widget.rounds}  ${step.spec}';
        });
        await _frame();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        final first = await _frame();
        final rasterBefore = _cpuNanos('1.raster');
        final uiBefore = _uiCpuNanos();
        final watch = Stopwatch()..start();
        await Future<void>.delayed(
          Duration(microseconds: (widget.seconds * 1e6).round()),
        );
        final last = await _frame();
        final rasterAfter = _cpuNanos('1.raster');
        final uiAfter = _uiCpuNanos();
        final wall = watch.elapsedMicroseconds / 1e6;
        // Timings arrive in batches about once a second in a profile build.
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        final frames = [
          for (final t in _timings)
            if (t.frameNumber > first && t.frameNumber <= last) t,
        ];
        _timings.clear();
        double middle(List<double> values, double at) {
          if (values.isEmpty) return 0;
          values.sort();
          return values[((values.length - 1) * at).round()];
        }

        final raster = [
          for (final t in frames) t.rasterDuration.inMicroseconds / 1000,
        ];
        final build = [
          for (final t in frames) t.buildDuration.inMicroseconds / 1000,
        ];
        final count = frames.isEmpty ? 1 : frames.length;
        print(
          'LINEBENCH ${jsonEncode({'type': 'step', 'round': round, 'spec': step.spec, 'segments': step.segments, 'hash': hashes[step.spec], 'frames': frames.length, 'fps': frames.length / wall, 'uiP50': middle(build, 0.5), 'uiP90': middle(build, 0.9), 'rasterP50': middle(raster, 0.5), 'rasterP90': middle(raster, 0.9), 'rasterCpuMsPerFrame': rasterBefore < 0 || rasterAfter < 0 ? null : (rasterAfter - rasterBefore) / 1e6 / count, 'uiCpuMsPerFrame': uiBefore < 0 || uiAfter < 0 ? null : (uiAfter - uiBefore) / 1e6 / count})}',
        );
      }
    }
    print('LINEBENCH ${jsonEncode({'type': 'done'})}');
    setState(() {
      _current = null;
      _status = 'done';
    });
  }

  @override
  Widget build(BuildContext context) {
    final step = _current;
    final view = View.of(context);
    // Only the widgets library is used, so the app builds the same on
    // every Flutter version: no Material, no theme.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: _page,
        child: Padding(
          padding: EdgeInsets.only(
            top: view.padding.top / view.devicePixelRatio,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: _height,
                child: step == null
                    ? null
                    : ClipRect(
                        child: CustomPaint(
                          painter: _ScenarioPainter(step, _time),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Line batch bench  $_status',
                  style: const TextStyle(
                    color: Color(0xFF8A8A8A),
                    fontSize: 14,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScenarioPainter extends CustomPainter {
  _ScenarioPainter(this.scenario, this.time) : super(repaint: time);

  final Scenario scenario;
  final ValueNotifier<double> time;

  @override
  void paint(Canvas canvas, Size size) =>
      scenario.paint(canvas, size, time.value);

  @override
  bool shouldRepaint(_ScenarioPainter old) => old.scenario != scenario;
}
