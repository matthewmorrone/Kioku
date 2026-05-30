import Foundation

// JSON wire types exchanged between the Node MCP server and the bridge.
// Distinct from the persisted Note type so the bridge can evolve without
// rolling the on-disk schema, and so write payloads can be partial.

// Returned by GET /v1/notes — list view.
struct BridgeNoteSummary: Codable, Equatable {
    let id: UUID
    let title: String
    let modifiedAt: Date
    let createdAt: Date
    let segmentCount: Int
    let hasAudio: Bool
}

// Returned by GET /v1/notes/{id} — full note including segments and furigana.
struct BridgeNoteDetail: Codable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let createdAt: Date
    let modifiedAt: Date
    let segments: [BridgeSegment]?
}

// Mirrors SegmentRange on the wire so the MCP server can read/write annotations
// without dragging the persisted struct's schema version field along.
struct BridgeSegment: Codable, Equatable {
    let surface: String
    let furigana: [BridgeFurigana]?
}

// Mirrors FuriganaAnnotation on the wire. UTF-16 offsets relative to the
// segment surface, half-open [start, end).
struct BridgeFurigana: Codable, Equatable {
    let start: Int
    let end: Int
    let reading: String
}

// Body of POST /v1/notes — create.
struct BridgeNoteCreateRequest: Decodable {
    let title: String?
    let content: String?
}

// Body of PATCH /v1/notes/{id} — update title or content. Either field may be
// omitted to leave that field unchanged. Updating content clears segmentation
// per the persistence invariant.
struct BridgeNoteUpdateRequest: Decodable {
    let title: String?
    let content: String?
}

// Body of PUT /v1/notes/{id}/segments — replace the segment array.
struct BridgeSegmentsReplaceRequest: Decodable {
    let segments: [BridgeSegment]
}

// Body of PUT /v1/notes/{id}/segments/{index}/furigana — replace one segment's
// furigana annotations. Pass an empty array to clear all readings on that segment.
struct BridgeFuriganaReplaceRequest: Decodable {
    let furigana: [BridgeFurigana]
}
