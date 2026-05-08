import Foundation

// Wires Kioku's notes/segments/furigana endpoints onto a BridgeRouter. Kept in
// one place so the URL surface area is easy to audit; each handler is a tiny
// closure that translates wire types to NotesStore mutations on the main actor.
@MainActor
enum BridgeRoutes {
    // Registers every route the MCP bridge exposes. Concrete paths are added
    // before parameterised ones so the router's first-match-wins dispatch
    // resolves them correctly.
    static func register(into router: inout BridgeRouter, notesStore: NotesStore) {
        router.add(method: "GET", template: "/v1/health") { _ in
            .json(["status": "ok"])
        }

        router.add(method: "GET", template: "/v1/notes") { _ in
            await listNotes(store: notesStore)
        }

        router.add(method: "POST", template: "/v1/notes") { request in
            await createNote(request: request, store: notesStore)
        }

        router.add(method: "GET", template: "/v1/notes/:id") { request in
            await getNote(request: request, store: notesStore)
        }

        router.add(method: "PATCH", template: "/v1/notes/:id") { request in
            await updateNote(request: request, store: notesStore)
        }

        router.add(method: "DELETE", template: "/v1/notes/:id") { request in
            await deleteNote(request: request, store: notesStore)
        }

        router.add(method: "GET", template: "/v1/notes/:id/segments") { request in
            await getSegments(request: request, store: notesStore)
        }

        router.add(method: "PUT", template: "/v1/notes/:id/segments") { request in
            await replaceSegments(request: request, store: notesStore)
        }

        router.add(method: "PUT", template: "/v1/notes/:id/segments/:index/furigana") { request in
            await replaceFurigana(request: request, store: notesStore)
        }
    }

    // GET /v1/notes — returns a lightweight summary list ordered as the store
    // holds it (newest-first by convention since adds happen at index 0).
    private static func listNotes(store: NotesStore) async -> BridgeHTTPResponse {
        let summaries = store.notes.map { note in
            BridgeNoteSummary(
                id: note.id,
                title: note.title,
                modifiedAt: note.modifiedAt,
                createdAt: note.createdAt,
                segmentCount: note.segments?.count ?? 0,
                hasAudio: note.audioAttachmentID != nil
            )
        }
        return .json(["notes": summaries])
    }

    // POST /v1/notes — accepts an optional title/content and inserts at index 0.
    // Returns the persisted detail so MCP callers know the assigned UUID.
    private static func createNote(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        let payload: BridgeNoteCreateRequest?
        do {
            payload = try request.decodeJSON(BridgeNoteCreateRequest.self)
        } catch {
            return .error(status: 400, code: "invalid_json", message: "could not decode request body: \(error.localizedDescription)")
        }

        let title = payload?.title ?? ""
        let content = payload?.content ?? ""
        let note = Note(title: title, content: content, segments: nil)
        store.addNote(note)
        return .json(detail(for: note), status: 201)
    }

    // GET /v1/notes/{id} — returns full note detail including segments + furigana.
    private static func getNote(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard let note = store.note(withID: id) else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }
        return .json(detail(for: note))
    }

    // PATCH /v1/notes/{id} — partial title/content update. Mutating content
    // clears segments so the segmenter recomputes (preserving the persistence
    // invariant in NotesStore).
    private static func updateNote(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard let existing = store.note(withID: id) else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }

        let payload: BridgeNoteUpdateRequest?
        do {
            payload = try request.decodeJSON(BridgeNoteUpdateRequest.self)
        } catch {
            return .error(status: 400, code: "invalid_json", message: "could not decode request body: \(error.localizedDescription)")
        }
        guard let payload, payload.title != nil || payload.content != nil else {
            return .error(status: 400, code: "no_fields", message: "request must include at least one of title, content")
        }

        let newTitle = payload.title ?? existing.title
        let newContent = payload.content ?? existing.content
        let preservedSegments = (payload.content == nil) ? existing.segments : nil

        _ = store.upsertNote(id: id, title: newTitle, content: newContent, segments: preservedSegments)
        guard let updated = store.note(withID: id) else {
            return .error500(message: "note disappeared after update")
        }
        return .json(detail(for: updated))
    }

    // DELETE /v1/notes/{id} — returns 204 on success, 404 when the note is gone.
    private static func deleteNote(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard store.deleteNote(id: id) != nil else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }
        return .noContent()
    }

    // GET /v1/notes/{id}/segments — returns the segments array on its own so
    // MCP-side tools that only edit segmentation don't have to ship the
    // whole note around.
    private static func getSegments(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard let note = store.note(withID: id) else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }
        return .json(["segments": (note.segments ?? []).map(toBridge)])
    }

    // PUT /v1/notes/{id}/segments — replaces the entire segments array after
    // verifying that the new array satisfies the concat-equals-content invariant.
    private static func replaceSegments(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard let note = store.note(withID: id) else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }

        let payload: BridgeSegmentsReplaceRequest?
        do {
            payload = try request.decodeJSON(BridgeSegmentsReplaceRequest.self)
        } catch {
            return .error(status: 400, code: "invalid_json", message: "could not decode request body: \(error.localizedDescription)")
        }
        guard let payload else {
            return .error(status: 400, code: "no_body", message: "request body required")
        }

        if let failure = BridgeSegmentValidator.validateConcatenation(segments: payload.segments, content: note.content) {
            return failure
        }

        let newSegments = payload.segments.map(toModel)
        _ = store.upsertNote(id: id, title: note.title, content: note.content, segments: newSegments)
        guard let updated = store.note(withID: id) else {
            return .error500(message: "note disappeared after segment replace")
        }
        return .json(detail(for: updated))
    }

    // PUT /v1/notes/{id}/segments/{index}/furigana — replaces the annotation
    // array on a single segment, leaving every other segment untouched.
    private static func replaceFurigana(request: BridgeHTTPRequest, store: NotesStore) async -> BridgeHTTPResponse {
        guard let id = noteID(from: request) else {
            return .error(status: 400, code: "invalid_id", message: "note id must be a UUID")
        }
        guard let note = store.note(withID: id) else {
            return .error(status: 404, code: "note_not_found", message: "no note with id \(id.uuidString)")
        }
        guard let indexString = request.query["index"], let index = Int(indexString) else {
            return .error(status: 400, code: "invalid_index", message: "segment index must be an integer")
        }
        guard var segments = note.segments, segments.indices.contains(index) else {
            return .error(status: 404, code: "segment_not_found", message: "no segment at index \(indexString)")
        }

        let payload: BridgeFuriganaReplaceRequest?
        do {
            payload = try request.decodeJSON(BridgeFuriganaReplaceRequest.self)
        } catch {
            return .error(status: 400, code: "invalid_json", message: "could not decode request body: \(error.localizedDescription)")
        }
        guard let payload else {
            return .error(status: 400, code: "no_body", message: "request body required")
        }

        let surface = segments[index].surface
        if let failure = BridgeSegmentValidator.validateFurigana(payload.furigana, segmentSurface: surface, segmentIndex: index) {
            return failure
        }

        segments[index].furigana = payload.furigana.isEmpty ? nil : payload.furigana.map { FuriganaAnnotation(start: $0.start, end: $0.end, reading: $0.reading) }
        _ = store.upsertNote(id: id, title: note.title, content: note.content, segments: segments)
        guard let updated = store.note(withID: id) else {
            return .error500(message: "note disappeared after furigana replace")
        }
        return .json(detail(for: updated))
    }

    // Parses the `:id` path parameter as a UUID. Returns nil for malformed input
    // so handlers can surface a 400 with a clear message.
    private static func noteID(from request: BridgeHTTPRequest) -> UUID? {
        guard let raw = request.query["id"] else { return nil }
        return UUID(uuidString: raw)
    }

    // Converts a persisted Note into the wire-format detail payload.
    private static func detail(for note: Note) -> BridgeNoteDetail {
        BridgeNoteDetail(
            id: note.id,
            title: note.title,
            content: note.content,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            segments: note.segments?.map(toBridge)
        )
    }

    // Converts a persisted SegmentRange to the wire BridgeSegment.
    private static func toBridge(_ segment: SegmentRange) -> BridgeSegment {
        BridgeSegment(
            surface: segment.surface,
            furigana: segment.furigana?.map { BridgeFurigana(start: $0.start, end: $0.end, reading: $0.reading) }
        )
    }

    // Converts a wire BridgeSegment to the persisted SegmentRange.
    private static func toModel(_ segment: BridgeSegment) -> SegmentRange {
        SegmentRange(
            surface: segment.surface,
            furigana: segment.furigana?.map { FuriganaAnnotation(start: $0.start, end: $0.end, reading: $0.reading) }
        )
    }
}
