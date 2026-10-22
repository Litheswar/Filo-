import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/application/conversion_manager.dart';
import 'package:filo/services/conversion/image_converter.dart';

void main() {
  late Directory tempDir;
  late ImageConverter converter;
  late DefaultConversionManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filo_test_');
    converter = ImageConverter();
    manager = DefaultConversionManager([converter]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // Helper to create programmatically generated test images
  File createTestJpeg(String fileName, {int width = 50, int height = 50}) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(255, 0, 0)); // Red image
    final bytes = img.encodeJpg(image);
    final file = File('${tempDir.path}/$fileName');
    file.writeAsBytesSync(bytes);
    return file;
  }

  File createTestPng(
    String fileName, {
    int width = 50,
    int height = 50,
    bool withAlpha = false,
  }) {
    final image = img.Image(
      width: width,
      height: height,
      numChannels: withAlpha ? 4 : 3,
    );
    if (withAlpha) {
      // Top half transparent, bottom half blue
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (y < height ~/ 2) {
            image.setPixel(
              x,
              y,
              img.ColorRgba8(0, 0, 0, 0),
            ); // Fully transparent
          } else {
            image.setPixel(x, y, img.ColorRgba8(0, 0, 255, 255)); // Solid blue
          }
        }
      }
    } else {
      img.fill(image, color: img.ColorRgb8(0, 255, 0)); // Solid green
    }
    final bytes = img.encodePng(image);
    final file = File('${tempDir.path}/$fileName');
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('ImageConverter - Basic properties & contract', () {
    test('reports correct name and supported types', () {
      expect(converter.name, 'ImageConverter');
      expect(converter.supportedTypes, {
        ConversionType.jpgToPng,
        ConversionType.pngToJpg,
      });
      expect(converter.canConvert(ConversionType.jpgToPng), isTrue);
      expect(converter.canConvert(ConversionType.pngToJpg), isTrue);
      expect(converter.canConvert(ConversionType.singleImageToPdf), isFalse);
    });

    test('validates jpegQuality bounds', () {
      expect(() => ImageConverter(jpegQuality: 0), throwsArgumentError);
      expect(() => ImageConverter(jpegQuality: 101), throwsArgumentError);
      expect(() => ImageConverter(jpegQuality: 85), returnsNormally);
    });
  });

  group('ImageConverter - Conversions', () {
    test(
      'successfully converts valid JPG to PNG and preserves source',
      () async {
        final sourceFile = createTestJpeg('sample.jpg');
        final originalLength = sourceFile.lengthSync();

        final job = ConversionJob(
          id: 'job_jpg_to_png',
          inputPaths: [sourceFile.path],
          conversionType: ConversionType.jpgToPng,
          outputDirectory: tempDir.path,
          requestedOutputName: 'converted_output',
        );

        final result = await converter.convert(job);

        expect(result.isSuccess, isTrue);
        expect(result.outputPath, isNotNull);
        expect(result.outputPath!.endsWith('.png'), isTrue);

        // Verify output exists and is decodable as PNG
        final outputFile = File(result.outputPath!);
        expect(await outputFile.exists(), isTrue);
        expect(await outputFile.length(), greaterThan(0));

        final decodedPng = img.decodePng(await outputFile.readAsBytes());
        expect(decodedPng, isNotNull);
        expect(decodedPng!.width, 50);
        expect(decodedPng.height, 50);

        // Verify source file is preserved intact
        expect(await sourceFile.exists(), isTrue);
        expect(await sourceFile.length(), equals(originalLength));
      },
    );

    test(
      'successfully converts valid PNG to JPG and preserves source',
      () async {
        final sourceFile = createTestPng('sample.png');
        final originalLength = sourceFile.lengthSync();

        final job = ConversionJob(
          id: 'job_png_to_jpg',
          inputPaths: [sourceFile.path],
          conversionType: ConversionType.pngToJpg,
          outputDirectory: tempDir.path,
          requestedOutputName: 'converted_output',
        );

        final result = await converter.convert(job);

        expect(result.isSuccess, isTrue);
        expect(result.outputPath, isNotNull);
        expect(result.outputPath!.endsWith('.jpg'), isTrue);

        final outputFile = File(result.outputPath!);
        expect(await outputFile.exists(), isTrue);
        expect(await outputFile.length(), greaterThan(0));

        final decodedJpg = img.decodeJpg(await outputFile.readAsBytes());
        expect(decodedJpg, isNotNull);
        expect(decodedJpg!.width, 50);
        expect(decodedJpg.height, 50);

        // Source preserved
        expect(await sourceFile.exists(), isTrue);
        expect(await sourceFile.length(), equals(originalLength));
      },
    );

    test(
      'handles transparent PNG conversion to JPG with white background',
      () async {
        final sourceFile = createTestPng('transparent.png', withAlpha: true);

        final job = ConversionJob(
          id: 'job_transparent_png_to_jpg',
          inputPaths: [sourceFile.path],
          conversionType: ConversionType.pngToJpg,
          outputDirectory: tempDir.path,
        );

        final result = await converter.convert(job);

        expect(result.isSuccess, isTrue);
        final outputFile = File(result.outputPath!);
        expect(await outputFile.exists(), isTrue);

        final decodedJpg = img.decodeJpg(await outputFile.readAsBytes());
        expect(decodedJpg, isNotNull);

        // Top pixel (which was transparent in PNG) should now be white (R:255, G:255, B:255)
        final topPixel = decodedJpg!.getPixel(25, 10);
        // JPEG lossy compression might have slight deviation, check tolerance close to 255
        expect(topPixel.r, greaterThanOrEqualTo(240));
        expect(topPixel.g, greaterThanOrEqualTo(240));
        expect(topPixel.b, greaterThanOrEqualTo(240));
      },
    );

    test(
      'handles transparent PNG conversion with black background policy',
      () async {
        final blackBgConverter = ImageConverter(
          alphaPolicy: AlphaChannelPolicy.compositeBlack,
        );
        final sourceFile = createTestPng(
          'transparent_black.png',
          withAlpha: true,
        );

        final job = ConversionJob(
          id: 'job_black_bg',
          inputPaths: [sourceFile.path],
          conversionType: ConversionType.pngToJpg,
          outputDirectory: tempDir.path,
        );

        final result = await blackBgConverter.convert(job);
        expect(result.isSuccess, isTrue);

        final decodedJpg = img.decodeJpg(
          await File(result.outputPath!).readAsBytes(),
        );
        expect(decodedJpg, isNotNull);

        // Top pixel should now be close to black (0, 0, 0)
        final topPixel = decodedJpg!.getPixel(25, 10);
        expect(topPixel.r, lessThanOrEqualTo(15));
        expect(topPixel.g, lessThanOrEqualTo(15));
        expect(topPixel.b, lessThanOrEqualTo(15));
      },
    );
  });

  group('ImageConverter - Error handling & validation', () {
    test('fails gracefully when source file does not exist', () async {
      final job = ConversionJob(
        id: 'job_missing',
        inputPaths: ['${tempDir.path}/non_existent.jpg'],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await converter.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('Source file does not exist'));
      expect(result.outputPath, isNull);
    });

    test('fails gracefully on empty (0-byte) source file', () async {
      final emptyFile = File('${tempDir.path}/empty.jpg')..writeAsBytesSync([]);

      final job = ConversionJob(
        id: 'job_empty',
        inputPaths: [emptyFile.path],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await converter.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('empty'));
    });

    test('fails gracefully when image bytes are corrupted/invalid', () async {
      final corruptFile = File('${tempDir.path}/corrupt.jpg')
        ..writeAsStringSync('THIS IS NOT A VALID IMAGE BYTE STREAM');

      final job = ConversionJob(
        id: 'job_corrupt',
        inputPaths: [corruptFile.path],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await converter.convert(job);

      expect(result.isSuccess, isFalse);
      expect(
        result.errorMessage,
        contains('Invalid or unsupported image data'),
      );
    });

    test('fails when given an unsupported conversion type', () async {
      final sourceFile = createTestJpeg('sample2.jpg');

      final job = ConversionJob(
        id: 'job_unsupported',
        inputPaths: [sourceFile.path],
        conversionType: ConversionType.singleImageToPdf,
      );

      final result = await converter.convert(job);

      expect(result.isSuccess, isFalse);
      expect(
        result.errorMessage,
        contains('does not support singleImageToPdf'),
      );
    });

    test('fails if output path would overwrite source file', () async {
      // Create a file already named test.png and try to output directly into test.png
      final sourceFile = createTestPng('collide.png');

      final job = ConversionJob(
        id: 'job_collision',
        inputPaths: [sourceFile.path],
        conversionType: ConversionType.jpgToPng,
        outputDirectory: tempDir.path,
        requestedOutputName: 'collide', // Would resolve to collide.png
      );

      final result = await converter.convert(job);

      expect(result.isSuccess, isFalse);
      expect(
        result.errorMessage,
        contains('cannot be identical to source path'),
      );
    });
  });

  group('ConversionManager Integration', () {
    test('DefaultConversionManager dispatches both JPG->PNG and PNG->JPG via ImageConverter', () async {
      final jpgFile = createTestJpeg('mgr_test.jpg');
      final pngFile = createTestPng('mgr_test.png');

      // 1. Dispatch JPG -> PNG
      final job1 = ConversionJob(
        id: 'mgr_job_1',
        inputPaths: [jpgFile.path],
        conversionType: ConversionType.jpgToPng,
        outputDirectory: tempDir.path,
      );
      final result1 = await manager.processJob(job1);
      expect(result1.isSuccess, isTrue);
      expect(result1.outputPath!.endsWith('.png'), isTrue);

      // 2. Dispatch PNG -> JPG
      final job2 = ConversionJob(
        id: 'mgr_job_2',
        inputPaths: [pngFile.path],
        conversionType: ConversionType.pngToJpg,
        outputDirectory: tempDir.path,
      );
      final result2 = await manager.processJob(job2);
      expect(result2.isSuccess, isTrue);
      expect(result2.outputPath!.endsWith('.jpg'), isTrue);

      // 3. Confirm unsupported types still fail gracefully through manager
      final job3 = ConversionJob(
        id: 'mgr_job_3',
        inputPaths: [jpgFile.path],
        conversionType: ConversionType.singleImageToPdf,
      );
      final result3 = await manager.processJob(job3);
      expect(result3.isSuccess, isFalse);
      expect(
        result3.errorMessage,
        contains('No registered converter supports singleImageToPdf'),
      );
    });
  });
}
