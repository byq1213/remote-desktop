/// Pure resolution / stride helpers shared by capture and encoding.
///
/// Why width must be 64-aligned but height only even:
/// A captured/encoded frame's row stride `width * 4` must be a multiple of 256
/// (the macOS buffer alignment), so **width must be a multiple of 64**. Height
/// is independent of per-row stride and only needs to be EVEN for chroma
/// sampling, so forcing it to 64 would crush ordinary screens (1080/1200/1440
/// are none of them).
///
/// Everything here is a pure function so it can be unit-tested without a
/// display or a WebRTC peer.
library;

import 'dart:math';

/// Snap [v] to the nearest even integer (libwebrtc never emits odd sizes).
int roundEven(double v) {
  var r = v.round();
  if (r.isOdd) r += 1;
  return r;
}

/// Compute a stride-safe, DPI-aware capture size for a display of physical
/// [physW]x[physH] (already multiplied by DPR), capped so the long side never
/// exceeds [maxLongSide]. Returns (width, height) with width a multiple of 64
/// and height even.
(int, int)? resolveCaptureSize(int physW, int physH, double maxLongSide) {
  if (physW <= 0 || physH <= 0) return null;
  final landscape = physW >= physH;
  final long = (landscape ? physW : physH).toDouble();
  final short = (landscape ? physH : physW).toDouble();
  const block = 64;
  var targetLong = ((min(maxLongSide, long) ~/ block) * block).toInt();
  if (targetLong < block) targetLong = block;
  var targetShort = (short * targetLong / long).round();
  if (targetShort.isOdd) targetShort += 1;
  if (targetShort < 2) targetShort = 2;
  return landscape ? (targetLong, targetShort) : (targetShort, targetLong);
}

/// Downscale factor so the longer side fits within [maxLongSide] while keeping
/// aspect ratio and staying stride-safe (width % 64 == 0, height even).
///
/// [dpr] enables a HiDPI-aware budget: a Retina display's physical pixels are
/// dpr× its logical size, so scaling by ~dpr lands on the logical resolution
/// instead of blind-squashing a ~3000px frame into 1920.
double scaleFor(int? w, int? h, double maxLongSide, {double dpr = 1.0}) {
  if (w == null || h == null || w <= 0 || h <= 0) return 1.0;
  final longSide = (w > h ? w : h).toDouble();
  final shortSide = (w < h ? w : h).toDouble();
  const block = 64;

  var budget = maxLongSide;
  if (dpr > 1.0) {
    final logicalLong = longSide / dpr;
    budget = logicalLong < maxLongSide ? logicalLong : maxLongSide;
  }

  if (longSide <= budget && w % block == 0 && h % 2 == 0) return 1.0;

  var target = ((min(budget, longSide).toInt() ~/ block) * block);
  if (target < block) target = block;
  while (target >= block) {
    final scale = longSide / target;
    final shortOut = roundEven(shortSide / scale);
    if (shortOut % 2 == 0) break;
    target -= block;
  }
  return longSide / target;
}

/// Reorder the m=video payload types so [codec] (e.g. VP8) is first, steering
/// macOS WebRTC away from the flaky H.264 VideoToolbox screencast path.
/// Returns null if the codec isn't present.
String? preferCodec(String sdp, String codec) {
  final videoMatch = RegExp(r'm=video.*').firstMatch(sdp);
  if (videoMatch == null) return null;
  final codecMatch = RegExp(r'a=rtpmap:(\d+) $codec/90000').firstMatch(sdp);
  if (codecMatch == null) return null;
  final pt = codecMatch.group(1)!;
  final mLine = videoMatch.group(0)!;
  final parts = mLine.split(' ');
  if (parts.length < 4) return null;
  final head = parts.take(3).join(' ');
  final rest = parts.skip(3).where((p) => p != pt).join(' ');
  return sdp.replaceFirst(mLine, '$head $pt $rest');
}

/// Build a clean WebSocket URL from a base HTTP(S) URL, stripping any
/// fragment, query string, or trailing slash that could break the server's
/// exact path match.
String buildWsUrl(String base) {
  var s = base.trim();
  final hash = s.indexOf('#');
  if (hash != -1) s = s.substring(0, hash);
  final q = s.indexOf('?');
  if (q != -1) s = s.substring(0, q);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  s = s.replaceAll('http://', 'ws://').replaceAll('https://', 'wss://');
  if (!s.endsWith('/signal')) s = '$s/signal';
  return s;
}
