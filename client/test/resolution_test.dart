import 'package:flutter_test/flutter_test.dart';
import 'package:remote_desktop/utils/resolution.dart';

void main() {
  group('roundEven', () {
    test('keeps even values', () {
      expect(roundEven(10.0), 10);
      expect(roundEven(12.0), 12);
      expect(roundEven(1080.0), 1080);
    });

    test('rounds and snaps up to even', () {
      expect(roundEven(11.4), 12);
      expect(roundEven(10.6), 12);
      expect(roundEven(13.0), 14);
    });
  });

  group('resolveCaptureSize', () {
    test('returns null for non-positive dimensions', () {
      expect(resolveCaptureSize(0, 1080, 1920), isNull);
      expect(resolveCaptureSize(1920, -5, 1920), isNull);
    });

    test('landscape: caps long side, width 64-aligned, height even', () {
      final size = resolveCaptureSize(2560, 1440, 1920);
      expect(size, isNotNull);
      final (w, h) = size!;
      expect(w % 64, 0, reason: 'width must be 64-aligned (stride-safe)');
      expect(h.isEven, isTrue, reason: 'height must be even');
      expect(w, 1920);
      expect(h, 1080);
    });

    test('caps to maxLongSide when source is larger', () {
      final (w, h) = resolveCaptureSize(2560, 1440, 1280)!;
      expect(w, 1280);
      expect(h, 720);
      expect(w % 64, 0);
      expect(h.isEven, isTrue);
    });

    test('portrait: swaps long/short but still resolves', () {
      final (w, h) = resolveCaptureSize(1080, 1920, 1920)!;
      // Height is the long side here; width is the short side.
      expect(h, 1920);
      expect(w, 1080);
    });
  });

  group('scaleFor', () {
    test('returns 1.0 for null/zero input', () {
      expect(scaleFor(null, 1080, 1920), 1.0);
      expect(scaleFor(1920, null, 1920), 1.0);
      expect(scaleFor(0, 1080, 1920), 1.0);
    });

    test('returns 1.0 when already stride-safe and within budget', () {
      expect(scaleFor(1920, 1080, 1920), 1.0);
      expect(scaleFor(1280, 720, 1920), 1.0);
    });

    test('downscales an oversized landscape frame to the budget', () {
      final scale = scaleFor(2560, 1440, 1920);
      // 2560 / scale should land on 1920 (the long-side budget).
      expect(2560 / scale, closeTo(1920, 1));
    });

    test('dpr triggers more aggressive downscaling for HiDPI sources', () {
      final base = scaleFor(3000, 1688, 1920, dpr: 1.0);
      final hidpi = scaleFor(3000, 1688, 1920, dpr: 2.0);
      expect(hidpi, greaterThan(base));
    });
  });

  group('preferCodec', () {
    const sdp = 'v=0\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98\n'
        'a=rtpmap:96 H264/90000\n'
        'a=rtpmap:97 VP8/90000\n'
        'a=rtpmap:98 red/90000\n';

    test('moves the preferred codec payload type to the front', () {
      final out = preferCodec(sdp, 'VP8');
      expect(out, isNotNull);
      expect(out, contains('m=video 9 UDP/TLS/RTP/SAVPF 97 96 98'));
    });

    test('returns null when codec is absent', () {
      expect(preferCodec(sdp, 'VP9'), isNull);
    });

    test('returns null when there is no m=video line', () {
      expect(preferCodec('v=0\nm=audio 9 RTP/AVP 0\n', 'VP8'), isNull);
    });
  });

  group('buildWsUrl', () {
    test('http -> ws and appends /signal', () {
      expect(buildWsUrl('http://localhost:3000'), 'ws://localhost:3000/signal');
    });

    test('https -> wss', () {
      expect(buildWsUrl('https://example.com/api/'),
          'wss://example.com/api/signal');
    });

    test('strips query string and fragment', () {
      expect(buildWsUrl('http://localhost:3000/?token=abc#frag'),
          'ws://localhost:3000/signal');
    });

    test('keeps an existing /signal path', () {
      expect(buildWsUrl('ws://localhost:3000/signal'),
          'ws://localhost:3000/signal');
    });
  });
}
