import Foundation
import BurrowCore

@main
struct BurrowWorker {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, ["scan", "history", "clean"].contains(command) else {
                print("burrow-worker scan [folder ...] | history | clean /absolute/project/target --yes\nRead-only by default. Uses the same protections and state as the Mac app.")
                return
            }
            let engine = try Engine()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
            guard args.count == 3, args[2] == "--yes", args[1].hasPrefix("/") else {
                throw BurrowError.message("Permanent deletion requires: clean /absolute/project/target --yes. Add its scan root in the app first.")
            }
            let plan = try await engine.plan(paths: [args[1]])
            print(String(decoding: try encoder.encode(await engine.execute(plan)), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
