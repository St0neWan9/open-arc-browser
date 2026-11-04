// Exports production artwork using the same source as the native icon picker.
// Usage: swift scripts/make-app-icon.swift [default-output.icns]
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("openarc-artwork-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
let binary = temporary.appendingPathComponent("export-icons").path
try run("/usr/bin/swiftc", ["-swift-version", "6",
    root.appendingPathComponent("app/Sources/OpenArcShell/Appearance/AppIconArtwork.swift").path,
    root.appendingPathComponent("scripts/icon-export/main.swift").path, "-o", binary])
try run(binary, [root.path] + Array(CommandLine.arguments.dropFirst()))
