import Foundation

/// A stored voice: the mean WeSpeaker v2 embedding of a speaker's recordings. The user's own (`userID`) is
/// enrolled from History on request, seeds every notes session's `SpeakerRegistry` as "You", and is deleted
/// only when the user asks (not by deleting coach data). Other people's voiceprints carry a name and come from
/// naming a speaker in a notes transcript (`SpeakerNaming`); they seed later sessions the same way.
public struct Voiceprint: Codable, Equatable, Sendable {
	public var id: String
	public var name: String?
	public var isUser: Bool
	/// The model the embedding came from; embeddings of different models can't be compared.
	public var embedder: String
	/// Unit length, `dimensions` long.
	public var embedding: [Float]
	public var enrolledAt: Date
	/// Recordings the voiceprint was averaged from.
	public var sourceCount: Int
	/// Speech in those recordings, in seconds.
	public var sourceSeconds: Double
	/// Median cosine of the sources against the voiceprint: how consistent the enrolment was.
	public var selfScoreMedian: Float

	public init(
		id: String,
		name: String? = nil,
		isUser: Bool,
		embedder: String = Voiceprint.embedderName,
		embedding: [Float],
		enrolledAt: Date,
		sourceCount: Int,
		sourceSeconds: Double,
		selfScoreMedian: Float
	) {
		self.id = id
		self.name = name
		self.isUser = isUser
		self.embedder = embedder
		self.embedding = embedding
		self.enrolledAt = enrolledAt
		self.sourceCount = sourceCount
		self.sourceSeconds = sourceSeconds
		self.selfScoreMedian = selfScoreMedian
	}

	public static let userID = "you"
	/// FluidAudio's diarizer embedding model (WeSpeaker ResNet34 v2).
	public static let embedderName = "wespeaker-v2"
	public static let dimensions = 256
	/// A voice scoring at least this against a voiceprint is that person. Bench (2026-10-16, `lsbench voice
	/// --diarize`): the user's diarized cluster scored 0.61, remote voices in the same room 0.24 or less.
	public static let matchThreshold: Float = 0.4

	/// Cosine similarity; 0 for vectors of different lengths or a zero vector.
	public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
		guard a.count == b.count, !a.isEmpty else { return 0 }
		var dot: Float = 0, normA: Float = 0, normB: Float = 0
		for index in a.indices {
			dot += a[index] * b[index]
			normA += a[index] * a[index]
			normB += b[index] * b[index]
		}
		let norm = (normA * normB).squareRoot()
		return norm > 0 ? dot / norm : 0
	}

	/// The vector scaled to unit length (a zero vector stays zero).
	public static func normalized(_ vector: [Float]) -> [Float] {
		let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
		guard norm > 1e-9 else { return vector }
		return vector.map { $0 / norm }
	}

	/// This voiceprint with `other` averaged in: the centroids weighted by their speech seconds (equally when
	/// either has none), counts and seconds summed. Keeps this one's ID, name and enrolment date;
	/// `selfScoreMedian` becomes the mean cosine of the two against the result.
	public func merged(with other: Voiceprint) -> Voiceprint {
		let weights = sourceSeconds > 0 && other.sourceSeconds > 0 ? [sourceSeconds, other.sourceSeconds] : [1, 1]
		var result = self
		result.embedding = Self.normalizedMean([embedding, other.embedding], weights: weights)
		result.sourceCount = sourceCount + other.sourceCount
		result.sourceSeconds = sourceSeconds + other.sourceSeconds
		result.selfScoreMedian = (Self.cosine(embedding, result.embedding) + Self.cosine(other.embedding, result.embedding)) / 2
		return result
	}

	/// The L2-normalized mean of the given embeddings (empty for none).
	public static func normalizedMean(_ embeddings: [[Float]]) -> [Float] {
		normalizedMean(embeddings, weights: embeddings.map { _ in 1 })
	}

	/// The L2-normalized weighted mean. Embeddings of another length than the first are ignored.
	public static func normalizedMean(_ embeddings: [[Float]], weights: [Double]) -> [Float] {
		guard let first = embeddings.first else { return [] }
		var sum = [Float](repeating: 0, count: first.count)
		for (embedding, weight) in zip(embeddings, weights) where embedding.count == sum.count {
			let weight = Float(weight)
			for index in sum.indices { sum[index] += embedding[index] * weight }
		}
		let norm = max(sum.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
		return sum.map { $0 / norm }
	}
}

/// Voiceprints on disk: `<data root>/Voiceprints/<id>.json`, one file each.
public struct VoiceprintStore: Sendable {
	public let directory: URL

	public init(directory: URL) {
		self.directory = directory
	}

	func url(_ id: String) -> URL {
		// An ID is a file name; keep it from reaching outside the folder.
		let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
		return directory.appending(component: "\(safe).json")
	}

	/// Nil when there is none, it doesn't parse, or it came from another embedder or has the wrong length
	/// (a voiceprint the current model can't be compared with).
	public func load(_ id: String) -> Voiceprint? {
		guard let data = try? Data(contentsOf: url(id)) else { return nil }
		return Self.decode(data)
	}

	/// Every usable voiceprint, the user's first, then by ID.
	public func all() -> [Voiceprint] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names
			.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
			.compactMap { (try? Data(contentsOf: directory.appending(component: $0))).flatMap(Self.decode) }
			.sorted { ($0.isUser ? 0 : 1, $0.id) < ($1.isUser ? 0 : 1, $1.id) }
	}

	/// Written atomically; replaces a voiceprint with the same ID.
	public func save(_ voiceprint: Voiceprint) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Self.encoder.encode(voiceprint).write(to: url(voiceprint.id), options: .atomic)
	}

	/// Removing one that doesn't exist is not an error.
	public func delete(_ id: String) throws {
		let url = url(id)
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		try FileManager.default.removeItem(at: url)
	}

	static func decode(_ data: Data) -> Voiceprint? {
		guard let voiceprint = try? decoder.decode(Voiceprint.self, from: data),
		      voiceprint.embedder == Voiceprint.embedderName,
		      voiceprint.embedding.count == Voiceprint.dimensions
		else { return nil }
		return voiceprint
	}

	static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}()

	static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()
}
