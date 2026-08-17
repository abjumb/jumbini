import Foundation
import CoreGraphics
import Security

/// The seam between the generator and Pixellab. The live client talks to the
/// Pixellab v2 API; tests substitute a mock that returns canned sprites, so
/// the whole pipeline (photos -> sprites -> coat folder) is exercised without
/// a network call.
protocol PixellabClientProtocol: Sendable {
    /// Create an 8-direction character from a south-facing reference photo.
    /// Returns the character id plus its eight idle rotation sprites (raw PNG).
    func createCharacter(referenceImage: Data) async throws -> GeneratedCharacter
    /// Generate the frames for one action across all eight directions,
    /// returning the raw PNG frames per direction, in order.
    func animate(characterID: String, action: PixellabAction) async throws -> [Facing: [Data]]
}

/// A Pixellab character: its id (for animation calls) and its eight idle
/// rotations keyed by facing.
struct GeneratedCharacter {
    let id: String
    let rotations: [Facing: Data]
}

/// The live Pixellab client (Foundation + URLSession only — no AppKit — so the
/// HTTP layer stays out of the way of the SpriteKit/AppKit app code and can be
/// swapped for a mock in tests).
///
/// `Sendable`: it is stateless (every stored thing is a `static let` or
/// derived per call), so a generation kicked off from a panel can hand it to
/// whatever task the pipeline runs on.
final class PixellabClient: PixellabClientProtocol, Sendable {
    private static let baseURL = URL(string: "https://api.pixellab.ai/v2")!

    private static let keychainService = "ai.pixellab.api"
    private static let keychainAccount = "Jumbini"

    /// Where the Pixellab API key comes from at runtime.
    ///
    /// Deliberately not a literal in this file. This repository is public, so a
    /// key pasted here is in git history permanently — rewriting the history
    /// afterwards does not unpublish it — and it ships extractable inside every
    /// DMG. Resolved in order:
    ///
    ///   1. $PIXELLAB_API_KEY — for `swift run` during development.
    ///   2. the login keychain — a generic password under service
    ///      "ai.pixellab.api", account "Jumbini". This is the one that matters
    ///      for a shipped app: Finder launches it with no environment to
    ///      inherit, so the env var is never set for a double-clicked build.
    ///
    /// Add the keychain item with:
    ///
    ///     security add-generic-password -s ai.pixellab.api -a Jumbini -w <key>
    ///
    /// Resolving nothing is not fatal. The client throws `.missingAPIKey` and
    /// the generator panel surfaces it, so a build with no key degrades to
    /// "generation is unavailable" rather than failing at launch — which is
    /// what every build from a fresh clone will do.
    static func resolveAPIKey() -> String? {
        if let environmentAPIKey { return environmentAPIKey }
        return keychainAPIKey()
    }

    /// Settings reports environment overrides separately from the persisted
    /// Keychain value so the source of the active credential is never vague.
    static var hasEnvironmentAPIKey: Bool { environmentAPIKey != nil }

    /// Whether Settings has a persisted key it can replace or remove.
    static var hasStoredAPIKey: Bool { keychainAPIKey() != nil }

    private static var environmentAPIKey: String? {
        guard let value = ProcessInfo.processInfo.environment["PIXELLAB_API_KEY"] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Read the key out of the login keychain. Any failure — no item, locked
    /// keychain, user denied access — is reported the same way, as nil: the
    /// caller's only reasonable response is to tell the user no key is
    /// configured, and an OSStatus in the UI would not help them.
    private static func keychainAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Save or replace the login-Keychain credential used by a launched app.
    static func storeAPIKey(_ rawValue: String) throws {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIKeyStoreError.emptyKey }
        let data = Data(key.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(updateStatus)
        }

        var item = identity
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw APIKeyStoreError.keychain(addStatus)
        }
    }

    /// Remove only the persisted key. A development environment override is
    /// process-owned and intentionally cannot be mutated by the app.
    static func removeStoredAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    enum APIKeyStoreError: Error, LocalizedError {
        case emptyKey
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey:
                return "Paste a Pixellab API key before saving."
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return detail.map { "The Keychain could not be updated: \($0)" }
                    ?? "The Keychain could not be updated (error \(status))."
            }
        }
    }

    enum PixellabError: Error, LocalizedError {
        case missingAPIKey
        case invalidResponse
        case httpStatus(Int)
        case jobFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Pixellab API key is configured. Open Jumbini Settings to add one."
            case .invalidResponse:
                return "Pixellab returned an unexpected response."
            case .httpStatus(let code):
                return "Pixellab request failed (HTTP \(code))."
            case .jobFailed(let jobID):
                return "Pixellab generation job failed (\(jobID))."
            }
        }
    }

    private let apiKey: String?
    private let session: URLSession
    private let pollInterval: TimeInterval

    init(
        apiKey: String? = PixellabClient.resolveAPIKey(),
        session: URLSession = .shared,
        pollInterval: TimeInterval = 5
    ) {
        self.apiKey = apiKey
        self.session = session
        self.pollInterval = pollInterval
    }

    // MARK: - createCharacter

    func createCharacter(referenceImage: Data) async throws -> GeneratedCharacter {
        guard !isMissingKey else { throw PixellabError.missingAPIKey }

        let request = CreateCharacterV3Request(
            description: "a dog",
            reference_image: Base64Image(base64: try pngBase64(referenceImage, maxDimension: 256)),
            image_size: V3OutputImageSize(width: DogGenerator.canvasSize, height: DogGenerator.canvasSize),
            template_id: "dog",
            view: "low top-down",
            no_background: true
        )

        let response: CreateCharacterV3Response = try await post(
            "/create-character-v3", body: request
        )
        try await waitForJob(response.background_job_id)

        let detail: CharacterDetail = try await get("/characters/\(response.character_id)")
        var rotations: [Facing: Data] = [:]
        guard let urls = detail.rotation_urls else {
            throw PixellabError.invalidResponse
        }
        for (name, urlString) in rotationURLPairs(urls) {
            guard let facing = Facing.allCases.first(where: { $0.fileSuffix == name }),
                  let url = URL(string: urlString) else { continue }
            rotations[facing] = try await download(url)
        }
        guard rotations.count == 8 else { throw PixellabError.invalidResponse }
        return GeneratedCharacter(id: response.character_id, rotations: rotations)
    }

    // MARK: - animate

    func animate(characterID: String, action: PixellabAction) async throws -> [Facing: [Data]] {
        guard !isMissingKey else { throw PixellabError.missingAPIKey }

        let directions = Facing.allCases.map(\.fileSuffix)
        let request = CreateCharacterAnimationRequest(
            character_id: characterID,
            animation_name: action.animationName,
            action_description: action.actionDescription,
            mode: "v3",
            frame_count: action.frameCount,
            directions: directions
        )

        let response: CreateCharacterAnimationResponse = try await post(
            "/animate-character", body: request
        )
        for jobID in response.background_job_ids {
            try await waitForJob(jobID)
        }

        // The animation frames live on the character, keyed by display name.
        let detail: CharacterDetail = try await get("/characters/\(characterID)")
        guard let group = detail.animations.first(where: {
            $0.display_name == action.animationName || $0.animation_type == action.animationName
        }) else {
            throw PixellabError.invalidResponse
        }

        var frames: [Facing: [Data]] = [:]
        for direction in group.directions {
            guard let facing = Facing.allCases.first(where: { $0.fileSuffix == direction.direction })
            else { continue }
            var directionFrames: [Data] = []
            for frameURL in direction.frames {
                guard let url = URL(string: frameURL) else { continue }
                directionFrames.append(try await download(url))
            }
            frames[facing] = directionFrames
        }
        return frames
    }

    // MARK: - HTTP plumbing

    private var isMissingKey: Bool {
        (apiKey ?? "").isEmpty
    }

    private var authHeader: String { "Bearer \(apiKey ?? "")" }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func post<T: Encodable, U: Decodable>(_ path: String, body: T) async throws -> U {
        let data = try JSONEncoder().encode(body)
        let (responseData, response) = try await session.data(for: request(path, method: "POST", body: data))
        try validate(response)
        return try JSONDecoder().decode(U.self, from: responseData)
    }

    private func get<U: Decodable>(_ path: String) async throws -> U {
        let (data, response) = try await session.data(for: request(path))
        try validate(response)
        return try JSONDecoder().decode(U.self, from: data)
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PixellabError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PixellabError.httpStatus(http.statusCode)
        }
    }

    private func waitForJob(_ jobID: String) async throws {
        while true {
            let job: BackgroundJobResponse = try await get("/background-jobs/\(jobID)")
            switch job.status {
            case "completed":
                return
            case "failed":
                throw PixellabError.jobFailed(jobID)
            default:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    /// Re-encode any photo (JPEG/HEIC/PNG) as a bounded PNG for the wire.
    private func pngBase64(_ data: Data, maxDimension: Int) throws -> String {
        guard let image = DogGenerator.decode(data) else { throw PixellabError.invalidResponse }
        let scaleFactor = min(
            1.0,
            min(Double(maxDimension) / Double(image.width), Double(maxDimension) / Double(image.height))
        )
        let width = max(1, Int((Double(image.width) * scaleFactor).rounded()))
        let height = max(1, Int((Double(image.height) * scaleFactor).rounded()))
        guard let resized = scale(image, toWidth: width, height: height),
              let png = DogGenerator.pngData(from: resized) else {
            throw PixellabError.invalidResponse
        }
        return png.base64EncodedString()
    }

    private func scale(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let scaled = data.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        return scaled
    }

    /// Flatten a rotation URL dictionary into a stable list of (name, url).
    private func rotationURLPairs(_ urls: CharacterRotationUrls) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("south", urls.south), ("west", urls.west), ("east", urls.east), ("north", urls.north),
        ]
        if let v = urls.south_east { pairs.append(("south-east", v)) }
        if let v = urls.north_east { pairs.append(("north-east", v)) }
        if let v = urls.north_west { pairs.append(("north-west", v)) }
        if let v = urls.south_west { pairs.append(("south-west", v)) }
        return pairs
    }
}

// MARK: - DTOs

private struct Base64Image: Encodable {
    let type: String = "base64"
    let base64: String
    let format: String = "png"
}

private struct V3OutputImageSize: Encodable {
    let width: Int
    let height: Int
}

private struct CreateCharacterV3Request: Encodable {
    let description: String
    let reference_image: Base64Image
    let image_size: V3OutputImageSize
    let template_id: String
    let view: String
    let no_background: Bool
}

private struct CreateCharacterV3Response: Decodable {
    let background_job_id: String
    let character_id: String
}

private struct CreateCharacterAnimationRequest: Encodable {
    let character_id: String
    let animation_name: String
    let action_description: String
    let mode: String
    let frame_count: Int
    let directions: [String]
}

private struct CreateCharacterAnimationResponse: Decodable {
    let background_job_ids: [String]
    let directions: [String]
}

private struct BackgroundJobResponse: Decodable {
    let status: String
}

private struct CharacterDetail: Decodable {
    let rotation_urls: CharacterRotationUrls?
    let animations: [AnimationGroup]
}

private struct CharacterRotationUrls: Decodable {
    let south: String
    let west: String
    let east: String
    let north: String
    let south_east: String?
    let north_east: String?
    let north_west: String?
    let south_west: String?

    enum CodingKeys: String, CodingKey {
        case south, west, east, north
        case south_east = "south-east"
        case north_east = "north-east"
        case north_west = "north-west"
        case south_west = "south-west"
    }
}

private struct AnimationGroup: Decodable {
    let animation_type: String
    let display_name: String?
    let directions: [AnimationDirection]
}

private struct AnimationDirection: Decodable {
    let direction: String
    let frames: [String]
}
