import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/device_memory.dart';

void main() {
  // Pure-parsing tests: no process spawn, no filesystem, no MethodChannel --
  // these run identically on every platform CI runs this suite on.

  test(
    'TC-386: macOS sysctl output parses to bytes, trailing newline and all',
    () {
      expect(
        DeviceMemory.parseMacosSysctlOutput('17179869184\n'),
        17179869184,
      );
    },
  );

  test('TC-387: garbage macOS sysctl output yields null, not a throw', () {
    expect(DeviceMemory.parseMacosSysctlOutput('not a number'), isNull);
  });

  test('TC-388: /proc/meminfo MemTotal line parses kB to bytes', () {
    const sample = '''
MemTotal:       267894128 kB
MemFree:         12345678 kB
MemAvailable:   198765432 kB
''';
    expect(DeviceMemory.parseLinuxMeminfo(sample), 267894128 * 1024);
  });

  test(
    'TC-389: /proc/meminfo without a MemTotal line yields null, not a throw',
    () {
      expect(DeviceMemory.parseLinuxMeminfo('MemFree: 123 kB\n'), isNull);
    },
  );

  test(
    'TC-390: Windows PowerShell CIM output parses to bytes',
    () {
      expect(
        DeviceMemory.parseWindowsPowershellOutput('274877906944\r\n'),
        274877906944,
      );
    },
  );

  test('TC-391: garbage Windows PowerShell output yields null', () {
    expect(DeviceMemory.parseWindowsPowershellOutput(''), isNull);
  });

  // Live integration test -- deliberately not a channel/mock test (that
  // mechanism is gone): this calls the real platform-specific reader on
  // whatever host runs the suite and checks for a plausible positive
  // reading, proving the platform-neutral entry point actually reaches a
  // real OS value on desktop hosts.
  test(
    'TC-392: totalPhysicalBytes returns a plausible reading on desktop '
    'hosts, null elsewhere',
    () async {
      final bytes = await DeviceMemory.totalPhysicalBytes();
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        expect(bytes, isNotNull);
        expect(bytes! > 0, isTrue);
      } else {
        expect(bytes, isNull);
      }
    },
    // WMI/CIM provider cold-start on fresh Windows VMs can exceed the
    // suite's global 10s timeout (dart_test.yaml).
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
