import Foundation
import HeadroomCore

@main
struct HeadroomCLI {
    static let usage = """
    headroom-cli scan [folder ...] | history | clean --yes /absolute/project/node_modules ...
    Read-only by default. Uses the same protections and state as the Mac app.
    Set HEADROOM_STATE_DIR to use a separate inventory database.
    """

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, ["scan", "history", "clean"].contains(command) else { print(usage); return }
            let engine = try Engine()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if command == "history" {
                print(String(decoding: try encoder.encode(await engine.history()), as: UTF8.self)); return
            }
            if command == "scan", args.count > 1 {
                var preferences = try await engine.preferences()
                preferences.roots = args.dropFirst().map { WatchedRoot(path: $0) }
                try await engine.save(preferences)
            }
            let inventory = try await engine.scan()
            if command == "scan" { print(String(decoding: try encoder.encode(inventory), as: UTF8.self)); return }
            let paths = args.dropFirst().filter { $0 != "--yes" }
            guard args.contains("--yes"), !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw HeadroomError.message("Permanent deletion requires: clean --yes /absolute/path ... Add its scan root in the app first.")
            }
            let plan = try await engine.plan(paths: Set(paths))
            print(String(decoding: try encoder.encode(await engine.execute(plan)), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
