// Dart-side unit tests for the winrt_ocr_flutter method-channel contract.
//
// These cannot exercise the real native Windows.Media.Ocr pipeline (that
// was verified separately by an actual `flutter build windows` +
// `flutter run -d windows` against real rendered test images — see
// README.md "Verification status"). What they verify, with a mocked
// platform channel, is the Dart-side contract this package promises:
// exactly what method name and argument shape go out over the channel,
// and that every kind of channel response (a string, null, or a
// PlatformException) is decoded into the documented, safe result.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:winrt_ocr_flutter/winrt_ocr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('winrt_ocr_flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('recognizeText — method channel contract', () {
    test('invokes "recognizeText" with imagePath as the argument', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return 'ok';
      });

      await WinrtOcr.recognizeText(r'C:\temp\receipt.jpg');

      expect(received, isNotNull);
      expect(received!.method, 'recognizeText');
      expect(received!.arguments, {'imagePath': r'C:\temp\receipt.jpg'});
    });

    test('returns the recognized text unchanged, including line breaks', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => 'WALMART\nMILK 3.48\nBREAD 2.50',
      );

      final result = await WinrtOcr.recognizeText(r'C:\temp\receipt.jpg');

      expect(result, 'WALMART\nMILK 3.48\nBREAD 2.50');
    });

    test('returns an empty string unchanged (a valid image with no text)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => '');

      final result = await WinrtOcr.recognizeText(r'C:\temp\blank.jpg');

      expect(result, '');
    });

    test('a null channel result is treated as an empty string, not a crash', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      final result = await WinrtOcr.recognizeText(r'C:\temp\receipt.jpg');

      expect(result, '');
    });

    test('a PlatformException is converted to WinrtOcrException, not '
        'left as a raw platform error', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(
          code: 'no_ocr_engine',
          message: 'Windows.Media.Ocr.OcrEngine is unavailable',
        ),
      );

      await expectLater(
        WinrtOcr.recognizeText(r'C:\temp\receipt.jpg'),
        throwsA(
          isA<WinrtOcrException>().having(
            (e) => e.message,
            'message',
            'Windows.Media.Ocr.OcrEngine is unavailable',
          ),
        ),
      );
    });

    test('falls back to the PlatformException code when message is null', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'winrt_ocr_flutter_failed'),
      );

      await expectLater(
        WinrtOcr.recognizeText(r'C:\temp\receipt.jpg'),
        throwsA(
          isA<WinrtOcrException>().having(
            (e) => e.message,
            'message',
            'winrt_ocr_flutter_failed',
          ),
        ),
      );
    });
  });

  group('WinrtOcrException', () {
    test('toString includes the message for readable logs', () {
      const exception = WinrtOcrException('engine unavailable');
      expect(exception.toString(), contains('engine unavailable'));
    });
  });
}
