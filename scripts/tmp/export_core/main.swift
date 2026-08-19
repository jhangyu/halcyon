// Test driver (not shipped in the app). Compiled together with the EXPORT-CORE
// block extracted verbatim from macos/Runner/AppDelegate.swift by
// scripts/tmp/run_export_core_tests.sh, so what runs here IS the shipped text.
//
// usage: export_core <targetSize> <src> <out.jpg>
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let target = Int(args[1]) else {
  FileHandle.standardError.write("usage: export_core <targetSize> <src> <out.jpg>\n".data(using: .utf8)!)
  exit(2)
}
let src = URL(fileURLWithPath: args[2])
guard let data = AppDelegate.makeExportJpeg(url: src, targetSize: target) else {
  FileHandle.standardError.write("makeExportJpeg returned nil for \(src.path)\n".data(using: .utf8)!)
  exit(1)
}
do {
  try data.write(to: URL(fileURLWithPath: args[3]))
} catch {
  FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
  exit(1)
}
print("wrote \(args[3]) bytes=\(data.count)")
