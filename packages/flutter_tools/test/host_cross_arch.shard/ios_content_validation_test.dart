// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/utils.dart';
import 'package:flutter_tools/src/build_info.dart';

import '../integration.shard/test_utils.dart';
import '../src/common.dart';
import '../src/darwin_common.dart';

void main() {
  group('iOS app validation', () {
    late String flutterRoot;
    late Directory pluginRoot;
    late String projectRoot;
    late String flutterBin;
    late Directory tempDir;
    late File hiddenFile;

    setUpAll(() {
      flutterRoot = getFlutterRoot();
      tempDir = createResolvedTempDirectorySync('ios_content_validation.');
      flutterBin = fileSystem.path.join(
        flutterRoot,
        'bin',
        'flutter',
      );

      final Directory xcframeworkArtifact = fileSystem.directory(
        fileSystem.path.join(
          flutterRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'ios',
          'Flutter.xcframework',
        ),
      );

      // Pre-cache iOS engine Flutter.xcframework artifacts.
      processManager.runSync(<String>[
        flutterBin,
        ...getLocalEngineArguments(),
        'precache',
        '--ios',
      ], workingDirectory: tempDir.path);

      // Pretend the SDK was on an external drive with stray "._" files in the xcframework
      hiddenFile = xcframeworkArtifact.childFile('._Info.plist')..createSync();

      // Test a plugin example app to allow plugins validation.
      processManager.runSync(<String>[
        flutterBin,
        ...getLocalEngineArguments(),
        'create',
        '--verbose',
        '--platforms=ios',
        '-t',
        'plugin',
        'hello',
      ], workingDirectory: tempDir.path);

      pluginRoot = tempDir.childDirectory('hello');
      projectRoot = pluginRoot.childDirectory('example').path;
    });

    tearDownAll(() {
      tryToDelete(hiddenFile);
      tryToDelete(tempDir);
    });

    for (final BuildMode buildMode in <BuildMode>[BuildMode.debug, BuildMode.release]) {
      group('build in ${buildMode.name} mode', () {
        late Directory outputPath;
        late Directory outputApp;
        late Directory frameworkDirectory;
        late Directory outputFlutterFramework;
        late File outputFlutterFrameworkBinary;
        late Directory outputAppFramework;
        late File outputAppFrameworkBinary;
        late File outputPluginFrameworkBinary;
        late Directory buildPath;
        late Directory buildAppFrameworkDsym;
        late File buildAppFrameworkDsymBinary;
        late ProcessResult buildResult;

        setUpAll(() {
          buildResult = processManager.runSync(<String>[
            flutterBin,
            ...getLocalEngineArguments(),
            'build',
            'ios',
            '--verbose',
            '--no-codesign',
            '--${buildMode.name}',
            '--obfuscate',
            '--split-debug-info=foo debug info/',
          ], workingDirectory: projectRoot);

          outputPath = fileSystem.directory(fileSystem.path.join(
            projectRoot,
            'build',
            'ios',
            'iphoneos',
          ));

          outputApp = outputPath.childDirectory('Runner.app');

          frameworkDirectory = outputApp.childDirectory('Frameworks');
          outputFlutterFramework = frameworkDirectory.childDirectory('Flutter.framework');
          outputFlutterFrameworkBinary = outputFlutterFramework.childFile('Flutter');

          outputAppFramework = frameworkDirectory.childDirectory('App.framework');
          outputAppFrameworkBinary = outputAppFramework.childFile('App');

          outputPluginFrameworkBinary = frameworkDirectory.childDirectory('hello.framework').childFile('hello');

          buildPath = fileSystem.directory(fileSystem.path.join(
            projectRoot,
            'build',
            'ios',
            '${sentenceCase(buildMode.name)}-iphoneos',
          ));

          buildAppFrameworkDsym = buildPath.childDirectory('App.framework.dSYM');
          buildAppFrameworkDsymBinary = buildAppFrameworkDsym.childFile('Contents/Resources/DWARF/App');
        });

        testWithoutContext('flutter build ios builds a valid app', () {
          printOnFailure('Output of flutter build ios:');
          printOnFailure(buildResult.stdout.toString());
          printOnFailure(buildResult.stderr.toString());
          expect(buildResult.exitCode, 0);

          expect(outputPluginFrameworkBinary, exists);

          expect(outputAppFrameworkBinary, exists);
          expect(outputAppFramework.childFile('Info.plist'), exists);

          expect(buildAppFrameworkDsymBinary.existsSync(), buildMode != BuildMode.debug);

          final File vmSnapshot = fileSystem.file(fileSystem.path.join(
            outputAppFramework.path,
            'flutter_assets',
            'vm_snapshot_data',
          ));

          expect(vmSnapshot.existsSync(), buildMode == BuildMode.debug);

          // Archiving should contain a bitcode blob, but not building.
          // This mimics Xcode behavior and prevents a developer from having to install a
          // 300+MB app.
          expect(containsBitcode(outputFlutterFrameworkBinary.path, processManager), isFalse);
        });

        testWithoutContext('Info.plist dart observatory Bonjour service', () {
          final String infoPlistPath = fileSystem.path.join(
            outputApp.path,
            'Info.plist',
          );
          final ProcessResult bonjourServices = processManager.runSync(
            <String>[
              'plutil',
              '-extract',
              'NSBonjourServices',
              'xml1',
              '-o',
              '-',
              infoPlistPath,
            ],
          );
          final bool bonjourServicesFound = (bonjourServices.stdout as String).contains('_dartobservatory._tcp');
          expect(bonjourServicesFound, buildMode == BuildMode.debug);

          final ProcessResult localNetworkUsage = processManager.runSync(
            <String>[
              'plutil',
              '-extract',
              'NSLocalNetworkUsageDescription',
              'xml1',
              '-o',
              '-',
              infoPlistPath,
            ],
          );
          final bool localNetworkUsageFound = localNetworkUsage.exitCode == 0;
          expect(localNetworkUsageFound, buildMode == BuildMode.debug);
        });

        testWithoutContext('check symbols', () {
          final ProcessResult symbols = processManager.runSync(
            <String>[
              'nm',
              '-g',
              outputAppFrameworkBinary.path,
              '-arch',
              'arm64',
            ],
          );
          final bool aotSymbolsFound = (symbols.stdout as String).contains('_kDartVmSnapshot');
          expect(aotSymbolsFound, buildMode != BuildMode.debug);
        });

        // dSYM is not created for a debug build so nothing to check.
        if (buildMode != BuildMode.debug) {
          testWithoutContext('check symbols in dSYM', () {
            final ProcessResult nm = processManager.runSync(
              <String>[
                'nm',
                '--debug-syms',
                '--defined-only',
                '--just-symbol-name',
                buildAppFrameworkDsymBinary.path,
                '-arch',
                'arm64',
              ],
            );
            final List<String> symbols = (nm.stdout as String).split('\n');
            expect(symbols, contains('_kDartVmSnapshotInstructions'));
          });
        }

        testWithoutContext('xcode_backend embed_and_thin', () {
          outputFlutterFramework.deleteSync(recursive: true);
          outputAppFramework.deleteSync(recursive: true);
          expect(outputFlutterFrameworkBinary.existsSync(), isFalse);
          expect(outputAppFrameworkBinary.existsSync(), isFalse);

          final String xcodeBackendPath = fileSystem.path.join(
            flutterRoot,
            'packages',
            'flutter_tools',
            'bin',
            'xcode_backend.sh',
          );

          // Simulate a common Xcode build setting misconfiguration
          // where FLUTTER_APPLICATION_PATH is missing
          final ProcessResult xcodeBackendResult = processManager.runSync(
            <String>[
              xcodeBackendPath,
              'embed_and_thin',
            ],
            environment: <String, String>{
              'SOURCE_ROOT': fileSystem.path.join(projectRoot, 'ios'),
              'BUILT_PRODUCTS_DIR': fileSystem.path.join(
                projectRoot,
                'build',
                'ios',
                'Release-iphoneos',
              ),
              'TARGET_BUILD_DIR': outputPath.path,
              'FRAMEWORKS_FOLDER_PATH': 'Runner.app/Frameworks',
              'VERBOSE_SCRIPT_LOGGING': '1',
              'FLUTTER_BUILD_MODE': 'release',
              'ACTION': 'install',
              // Skip bitcode stripping since we just checked that above.
            },
          );
          printOnFailure('Output of xcode_backend.sh:');
          printOnFailure(xcodeBackendResult.stdout.toString());
          printOnFailure(xcodeBackendResult.stderr.toString());

          expect(xcodeBackendResult.exitCode, 0);
          expect(outputFlutterFrameworkBinary.existsSync(), isTrue);
          expect(outputAppFrameworkBinary.existsSync(), isTrue);
        }, skip: !platform.isMacOS || buildMode != BuildMode.release); // [intended] only makes sense on macos.

        testWithoutContext('validate obfuscation', () {
          // HelloPlugin class is present in project.
          ProcessResult grepResult = processManager.runSync(<String>[
            'grep',
            '-r',
            'HelloPlugin',
            pluginRoot.path,
          ]);
          // Matches exits 0.
          expect(grepResult.exitCode, 0);

          // Not present in binary.
          grepResult = processManager.runSync(<String>[
            'grep',
            'HelloPlugin',
            outputAppFrameworkBinary.path,
          ]);
          // Does not match exits 1.
          expect(grepResult.exitCode, 1);
        });
      });
    }

    testWithoutContext('builds all plugin architectures for simulator', () {
      final ProcessResult buildSimulator = processManager.runSync(
        <String>[
          flutterBin,
          ...getLocalEngineArguments(),
          'build',
          'ios',
          '--simulator',
          '--verbose',
          '--no-codesign',
        ],
        workingDirectory: projectRoot,
      );
      expect(buildSimulator.exitCode, 0);

      final File pluginFrameworkBinary = fileSystem.file(fileSystem.path.join(
        projectRoot,
        'build',
        'ios',
        'iphonesimulator',
        'Runner.app',
        'Frameworks',
        'hello.framework',
        'hello',
      ));
      expect(pluginFrameworkBinary, exists);
      final ProcessResult archs = processManager.runSync(
        <String>['file', pluginFrameworkBinary.path],
      );
      expect(archs.stdout, contains('Mach-O 64-bit dynamically linked shared library x86_64'));
      expect(archs.stdout, contains('Mach-O 64-bit dynamically linked shared library arm64'));
    });

    testWithoutContext('build for simulator with all available architectures', () {
      final ProcessResult buildSimulator = processManager.runSync(
        <String>[
          flutterBin,
          ...getLocalEngineArguments(),
          'build',
          'ios',
          '--simulator',
          '--verbose',
          '--no-codesign',
        ],
        workingDirectory: projectRoot,
        environment: <String, String>{
          'FLUTTER_XCODE_ONLY_ACTIVE_ARCH': 'NO',
        },
      );
      // This test case would fail if arm64 or x86_64 simulators could not build.
      expect(buildSimulator.exitCode, 0);

      final File simulatorAppFrameworkBinary = fileSystem.file(fileSystem.path.join(
        projectRoot,
        'build',
        'ios',
        'iphonesimulator',
        'Runner.app',
        'Frameworks',
        'App.framework',
        'App',
      ));
      expect(simulatorAppFrameworkBinary, exists);
      final ProcessResult archs = processManager.runSync(
        <String>['file', simulatorAppFrameworkBinary.path],
      );
      expect(archs.stdout, contains('Mach-O 64-bit dynamically linked shared library x86_64'));
      expect(archs.stdout, contains('Mach-O 64-bit dynamically linked shared library arm64'));
    });
  }, skip: !platform.isMacOS, // [intended] only makes sense for macos platform.
     timeout: const Timeout(Duration(minutes: 7))
  );
}
