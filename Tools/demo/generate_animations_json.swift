// Emits animations.json from the same table SpriteLibrary uses. Standalone so
// it can run without building the app; HeroSpecTests is what keeps the two
// honest with each other.
import Foundation

let directions = ["south", "south-east", "east", "north-east",
                  "north", "north-west", "west", "south-west"]
let spinCycle = ["south", "south-west", "west", "north-west",
                 "north", "north-east", "east", "south-east"]
let baseScale = 2.4
let sitScale = 2.9

func spec(pose: String, d: String) -> [String: Any] {
    switch pose {
    case "idle": return ["frames": ["idle_\(d)"], "fps": 1.0, "scale": baseScale]
    case "walk": return ["frames": ["run1_\(d)", "run2_\(d)"], "fps": 4.0, "scale": baseScale]
    case "run":  return ["frames": ["run1_\(d)", "run2_\(d)"], "fps": 13.0, "scale": baseScale]
    case "sit":  return ["frames": ["sit_\(d)"], "fps": 1.0, "scale": sitScale]
    case "spin": return ["frames": spinCycle.map { "idle_\($0)" }, "fps": 24.0, "scale": baseScale]
    default: fatalError("unknown pose \(pose)")
    }
}

var table: [String: [String: [String: Any]]] = [:]
for pose in ["idle", "walk", "run", "sit", "spin"] {
    var byDirection: [String: [String: Any]] = [:]
    for d in directions { byDirection[d] = spec(pose: pose, d: d) }
    table[pose] = byDirection
}

let data = try JSONSerialization.data(
    withJSONObject: table, options: [.prettyPrinted, .sortedKeys]
)
FileHandle.standardOutput.write(data)
