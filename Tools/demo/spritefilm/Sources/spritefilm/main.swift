import Foundation
import CoreGraphics

// spritefilm — renders the landing page's transparent hero assets straight
// from the app's PNGs. No app launch, no window server, no permissions.
//
//   spritefilm sheet   --pose walk --facing east --coat classic --scale 2 --out walk.png
//   spritefilm still   --pose idle --facing south --coat classic --scale 4 --out hero@2x.png
//   spritefilm contact --pose idle --coat classic --scale 2 --out rotations.png

struct Options {
    var pose = "walk"
    var facing = "east"
    var coat = "classic"
    var scale: CGFloat = 2
    var out = URL(fileURLWithPath: "out.png")
    var artDirectory = URL(fileURLWithPath: "Sources/Jumbini/Resources/jumba")
    var animations = URL(fileURLWithPath: "Tools/demo/animations.json")
}

let directions = ["south", "south-east", "east", "north-east",
                  "north", "north-west", "west", "south-west"]

func parse(_ arguments: [String]) -> (String, Options) {
    var options = Options()
    guard arguments.count > 1 else { return ("help", options) }
    let subcommand = arguments[1]
    var index = 2
    while index + 1 < arguments.count {
        let flag = arguments[index], value = arguments[index + 1]
        switch flag {
        case "--pose": options.pose = value
        case "--facing": options.facing = value
        case "--coat": options.coat = value
        case "--scale": options.scale = CGFloat(Double(value) ?? 2)
        case "--out": options.out = URL(fileURLWithPath: value)
        case "--art": options.artDirectory = URL(fileURLWithPath: value)
        case "--animations": options.animations = URL(fileURLWithPath: value)
        default: break
        }
        index += 2
    }
    return (subcommand, options)
}

/// Classic art is unprefixed, every other coat is `<coat>_`-prefixed, and
/// they all share one folder.
func filename(_ frame: String, coat: String) -> String {
    coat == "classic" ? "\(frame).png" : "\(coat)_\(frame).png"
}

/// Only `pair` takes a second coat, so it stays out of `Options`.
func parseCoat2(_ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--coat2"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func frames(pose: String, facing: String, options: Options) throws -> [String] {
    let data = try Data(contentsOf: options.animations)
    guard let table = try JSONSerialization.jsonObject(with: data)
            as? [String: [String: [String: Any]]],
          let spec = table[pose]?[facing],
          let list = spec["frames"] as? [String] else {
        throw SheetError.missingArt("\(pose)/\(facing) in animations.json")
    }
    return list
}

func images(_ names: [String], options: Options) throws -> [CGImage] {
    try names.map { name in
        let url = options.artDirectory
            .appendingPathComponent(filename(name, coat: options.coat))
        return try SheetBuilder.load(url)
    }
}

let (subcommand, options) = parse(CommandLine.arguments)

do {
    switch subcommand {
    case "sheet":
        let names = try frames(pose: options.pose, facing: options.facing, options: options)
        let sheet = try SheetBuilder.sheet(
            from: try images(names, options: options), scale: options.scale
        )
        try SheetBuilder.write(sheet, to: options.out)
        // The CSS consumer needs the cell count and width; print them rather
        // than making the caller open the PNG in an editor to find out.
        print("frames=\(names.count) cell=\(sheet.width / names.count) height=\(sheet.height)")

    case "still":
        let names = try frames(pose: options.pose, facing: options.facing, options: options)
        let first = try images([names[0]], options: options)
        try SheetBuilder.write(
            try SheetBuilder.sheet(from: first, scale: options.scale), to: options.out
        )
        print("wrote \(options.out.lastPathComponent)")

    case "contact":
        let names = try directions.map { direction -> String in
            try frames(pose: options.pose, facing: direction, options: options)[0]
        }
        let contact = try SheetBuilder.contactSheet(
            from: try images(names, options: options), columns: 4, scale: options.scale
        )
        try SheetBuilder.write(contact, to: options.out)
        print("wrote \(options.out.lastPathComponent)")

    case "pair":
        // Two coats of the same pose, side by side. `--coat` is the left one,
        // `--coat2` the right; the coats comparison still is the only caller.
        var second = options
        second.coat = parseCoat2(CommandLine.arguments) ?? "shaggy"
        let name = try frames(pose: options.pose, facing: options.facing, options: options)[0]
        let left = try images([name], options: options)
        let right = try images([name], options: second)
        let paired = try SheetBuilder.contactSheet(
            from: left + right, columns: 2, scale: options.scale
        )
        try SheetBuilder.write(paired, to: options.out)
        print("wrote \(options.out.lastPathComponent)")

    default:
        print("""
        spritefilm — transparent hero assets from Jumbini's sprite art

          sheet   --pose <idle|walk|run|sit|spin> --facing <direction> [--coat classic]
                  [--scale 2] --out <file.png>
          still   --pose <pose> --facing <direction> [--coat classic] [--scale 4] --out <file.png>
          contact --pose <pose> [--coat classic] [--scale 2] --out <file.png>
          pair    --pose <pose> --facing <direction> [--coat classic] [--coat2 shaggy]
                  [--scale 5] --out <file.png>

        Run from the repo root, or pass --art and --animations.
        """)
    }
} catch {
    FileHandle.standardError.write(Data("spritefilm: \(error)\n".utf8))
    exit(1)
}
