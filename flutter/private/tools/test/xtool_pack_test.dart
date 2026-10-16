import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../xtool_pack.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('SHA-1 and SHA-256 NIST vectors', () {
    test('computes RFC 3174 SHA-1 digests', () {
      expect(
        _hex(sha1Bytes(utf8.encode(''))),
        equals('da39a3ee5e6b4b0d3255bfef95601890afd80709'),
      );
      expect(
        _hex(sha1Bytes(utf8.encode('abc'))),
        equals('a9993e364706816aba3e25717850c26c9cd0d89d'),
      );
      expect(
        _hex(
          sha1Bytes(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        equals('84983e441c3bd26ebaae4aa1f95129e5e54670f1'),
      );
    });

    test('computes FIPS 180-4 SHA-256 digests', () {
      expect(
        _hex(sha256Bytes(utf8.encode(''))),
        equals(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
      expect(
        _hex(sha256Bytes(utf8.encode('abc'))),
        equals(
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
      );
      expect(
        _hex(
          sha256Bytes(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        equals(
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
        ),
      );
    });
  });

  group('buildInfoPlist', () {
    test('substitutes Xcode variables and injects iOS defaults', () {
      const baseXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>\$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>\${PRODUCT_BUNDLE_IDENTIFIER}</string>
\t<key>CFBundleIconFile</key>
\t<string></string>
\t<key>UILaunchStoryboardName</key>
\t<string>LaunchScreen</string>
</dict>
</plist>
''';
      final result = buildInfoPlist(
        plistXmls: [baseXml],
        platform: 'ios',
        appName: 'Runner',
        bundleId: 'com.example.runner',
        minimumOsVersion: '14.0',
      );

      expect(
        result,
        contains('<key>CFBundleExecutable</key>\n\t<string>Runner</string>'),
      );
      expect(
        result,
        contains(
          '<key>CFBundleIdentifier</key>\n\t<string>com.example.runner</string>',
        ),
      );
      expect(result, isNot(contains('CFBundleIconFile')));
      expect(
        result,
        contains('<key>MinimumOSVersion</key>\n\t<string>14.0</string>'),
      );
      expect(result, contains('<string>iPhoneOS</string>'));
      expect(
        result,
        contains(
          '<key>UILaunchStoryboardName</key>\n\t<string>LaunchScreen</string>',
        ),
      );
    });

    test('injects macOS defaults and substitutes MACOSX_DEPLOYMENT_TARGET', () {
      const macXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>LSMinimumSystemVersion</key>
\t<string>\$(MACOSX_DEPLOYMENT_TARGET)</string>
</dict>
</plist>
''';
      final result = buildInfoPlist(
        plistXmls: [macXml],
        platform: 'macos',
        appName: 'MyMacApp',
        bundleId: 'com.example.macapp',
        minimumOsVersion: '11.0',
      );

      expect(
        result,
        contains('<key>LSMinimumSystemVersion</key>\n\t<string>11.0</string>'),
      );
      expect(result, contains('<string>MacOSX</string>'));
      expect(
        result,
        contains(
          '<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>',
        ),
      );
    });
  });

  group('generateCodeResources', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('xtool_codesign_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('records SHA-1 and SHA-256 digests and excludes main binary and Info.plist', () {
      File('${tempDir.path}/Runner').writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE]);
      File('${tempDir.path}/Info.plist')
          .writeAsStringSync('<plist><dict/></plist>');
      File('${tempDir.path}/PkgInfo').writeAsStringSync('APPL????');
      final assetDir = Directory('${tempDir.path}/flutter_assets')
        ..createSync(recursive: true);
      final assetFile = File('${assetDir.path}/AssetManifest.json')
        ..writeAsStringSync('{}');

      final codeResFile = writeCodeResources(
        tempDir,
        excludedRelativePaths: {'Runner'},
      );
      expect(codeResFile.existsSync(), isTrue);
      final xml = codeResFile.readAsStringSync();

      final expectedSha1 = base64.encode(
        sha1Bytes(assetFile.readAsBytesSync()),
      );
      final expectedSha256 = base64.encode(
        sha256Bytes(assetFile.readAsBytesSync()),
      );

      expect(xml, contains('<key>flutter_assets/AssetManifest.json</key>'));
      expect(xml, contains('<data>$expectedSha1</data>'));
      expect(xml, contains('<data>$expectedSha256</data>'));
      expect(xml, isNot(contains('<key>Runner</key>')));
      expect(xml, isNot(contains('<key>Info.plist</key>')));
      expect(xml, isNot(contains('<key>PkgInfo</key>')));
    });
  });

  group('assembleBundle', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('xtool_bundle_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('assembles deterministic iOS .ipa with App.framework and Flutter.xcframework', () {
      final execFile = File('${tempDir.path}/Runner_bin')
        ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]);

      final plistFile = File('${tempDir.path}/Info.plist')
        ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>\$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</dict>
</plist>
''');

      // Create a wrapper dir containing App.framework (matching flutter_ios_framework output).
      final appFwWrapper = Directory(
        '${tempDir.path}/App_framework/App.framework',
      )..createSync(recursive: true);
      File('${appFwWrapper.path}/App').writeAsBytesSync([1, 2, 3, 4]);
      Directory('${appFwWrapper.path}/flutter_assets').createSync();
      File('${appFwWrapper.path}/flutter_assets/FontManifest.json')
          .writeAsStringSync('[]');

      // Create a Flutter.xcframework with ios-arm64 and ios-arm64_x86_64-simulator slices.
      final xcframeworkDir = Directory('${tempDir.path}/Flutter.xcframework');
      final deviceSlice = Directory(
        '${xcframeworkDir.path}/ios-arm64/Flutter.framework',
      )..createSync(recursive: true);
      File('${deviceSlice.path}/Flutter').writeAsBytesSync([9, 8, 7, 6]);
      final simSlice = Directory(
        '${xcframeworkDir.path}/ios-arm64_x86_64-simulator/Flutter.framework',
      )..createSync(recursive: true);
      File('${simSlice.path}/Flutter').writeAsBytesSync([5, 5, 5, 5]);

      final profileFile = File('${tempDir.path}/profile.mobileprovision')
        ..writeAsStringSync('mock-profile');

      final ipaPath = '${tempDir.path}/out/Runner.ipa';
      final appOutPath = '${tempDir.path}/out/Runner.app';

      assembleBundle(
        BundleConfig(
          platform: 'ios',
          appName: 'Runner',
          bundleId: 'com.example.iosapp',
          executablePath: execFile.path,
          minimumOsVersion: '14.0',
          infoPlistPaths: [plistFile.path],
          frameworkPaths: [
            '${tempDir.path}/App_framework',
            xcframeworkDir.path,
          ],
          provisioningProfilePath: profileFile.path,
          outputArchivePath: ipaPath,
          outputAppDirPath: appOutPath,
        ),
      );

      final ipaBytes = File(ipaPath).readAsBytesSync();
      final entries = {for (final e in readZipEntries(ipaBytes)) e.path: e};

      expect(entries.keys, contains('Payload/Runner.app/Runner'));
      expect(entries['Payload/Runner.app/Runner']!.isExecutable, isTrue);
      expect(entries.keys, contains('Payload/Runner.app/Info.plist'));
      expect(entries.keys, contains('Payload/Runner.app/PkgInfo'));
      expect(
        entries.keys,
        contains('Payload/Runner.app/embedded.mobileprovision'),
      );
      expect(
        entries.keys,
        contains('Payload/Runner.app/Frameworks/App.framework/App'),
      );
      expect(
        entries['Payload/Runner.app/Frameworks/App.framework/App']!
            .isExecutable,
        isTrue,
      );
      expect(
        entries.keys,
        contains('Payload/Runner.app/Frameworks/Flutter.framework/Flutter'),
      );
      expect(
        entries['Payload/Runner.app/Frameworks/Flutter.framework/Flutter']!
            .data,
        equals([9, 8, 7, 6]),
      );
      expect(
        entries.keys,
        contains('Payload/Runner.app/_CodeSignature/CodeResources'),
      );
      expect(
        entries.keys,
        contains(
          'Payload/Runner.app/Frameworks/App.framework/_CodeSignature/CodeResources',
        ),
      );
      expect(Directory(appOutPath).existsSync(), isTrue);
    });

    test('assembles deterministic macOS .app.zip with Contents layout', () {
      final execFile = File('${tempDir.path}/MacRunner_bin')
        ..writeAsBytesSync([0xCF, 0xFA, 0xED, 0xFE, 10, 20]);

      final appFwDir = Directory('${tempDir.path}/App.framework')
        ..createSync(recursive: true);
      File('${appFwDir.path}/App').writeAsBytesSync([11, 22, 33]);
      Directory('${appFwDir.path}/Resources/flutter_assets')
          .createSync(recursive: true);
      File('${appFwDir.path}/Resources/flutter_assets/AssetManifest.bin')
          .writeAsBytesSync([42]);

      final zipPath = '${tempDir.path}/out/MacRunner.app.zip';

      assembleBundle(
        BundleConfig(
          platform: 'macos',
          appName: 'MacRunner',
          bundleId: 'com.example.macrunner',
          executablePath: execFile.path,
          minimumOsVersion: '10.15',
          frameworkPaths: [appFwDir.path],
          outputArchivePath: zipPath,
        ),
      );

      final zipBytes = File(zipPath).readAsBytesSync();
      final entries = {for (final e in readZipEntries(zipBytes)) e.path: e};

      expect(entries.keys, contains('MacRunner.app/Contents/MacOS/MacRunner'));
      expect(
        entries['MacRunner.app/Contents/MacOS/MacRunner']!.isExecutable,
        isTrue,
      );
      expect(entries.keys, contains('MacRunner.app/Contents/Info.plist'));
      expect(entries.keys, contains('MacRunner.app/Contents/PkgInfo'));
      expect(
        entries.keys,
        contains('MacRunner.app/Contents/Frameworks/App.framework/App'),
      );
      expect(
        entries['MacRunner.app/Contents/Frameworks/App.framework/App']!
            .isExecutable,
        isTrue,
      );
      expect(
        entries.keys,
        contains('MacRunner.app/Contents/_CodeSignature/CodeResources'),
      );
    });
  });
}
