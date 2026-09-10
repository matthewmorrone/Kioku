import SwiftUI
import UIKit
import SwiftDagre

// The "Paths" section's two candidate-segmentation visualizations for WordDetailView: a flat
// per-path chip strip, and the node/edge lattice diagram. Extracted from WordDetailView+Helpers
// so that file stays under the line-count invariant.
extension WordDetailView {
    // Visual chart for the "Paths" section, sitting above the existing flat text list (not
    // replacing it): one row per candidate segmentation path, in sublatticePaths' existing
    // most-divided-first order (see WordDetailView+Helpers's sort in the .task loader), each
    // segment its own chip. Replaced an earlier shared-edge lattice-arc diagram (candidate paths
    // sharing a segment collapsed into one curved arc, with divergent alternatives fanned into
    // separate lanes) — mathematically that laid out correctly, but for any note with several
    // divergent short segments the result was small, needle-thin arcs that didn't read as arcs at
    // all. One row per path has no such failure mode: every row is a plain horizontal strip
    // regardless of how many paths there are or how much they diverge.
    @ViewBuilder
    var sublatticeDiagramRowsPerPath: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sublatticePaths.enumerated()), id: \.offset) { _, path in
                HStack(spacing: 4) {
                    ForEach(Array(path.enumerated()), id: \.offset) { _, segment in
                        Text(segment)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // Visual lattice diagram for the "Paths" section, sitting above the flat text list (not
    // replacing it). An actual node-and-edge graph: every distinct (position, text) segment any
    // candidate path picks is one NODE (a chip carrying the segment's own text) — segments two or
    // more paths agree on collapse into a single shared node instead of drawing once per path.
    // A shared dot marks where every path begins and another where every path ends, so a first or
    // last segment that's unique to one path still has somewhere to connect to rather than
    // dangling. Every EDGE is a plain connector between two segments (or a segment and a marker)
    // that are adjacent within some candidate path. Layout (node/edge positions, and routing so
    // edges bend around whatever shares their span rather than crossing it) is handed to
    // SwiftDagre — the same ranked-DAG algorithm family behind Mermaid's flowcharts, which ranks
    // nodes left-to-right by character offset and orders each rank to minimize edge crossings —
    // rather than computed by hand: a hand-rolled greedy lane packer kept producing visual
    // artifacts (arcs in the wrong place, dangling stems where several edges shared an endpoint)
    // that were hard to get right by eye.
    var sublatticeDiagram: some View {
        sublatticeArcDiagram(
            segments: sublatticeUniqueSegments(for: sublatticePaths),
            transitions: sublatticeTransitions(for: sublatticePaths)
        )
    }

    // Every distinct (position, text) segment across all candidate paths, deduped so a segment
    // two or more paths agree on is drawn once rather than once per path. Includes the shared
    // empty-text origin and terminus markers every path is anchored to (see sublatticeNodes).
    func sublatticeUniqueSegments(for paths: [[String]]) -> [SublatticeSegment] {
        var segments: Set<SublatticeSegment> = []
        for path in paths {
            segments.formUnion(sublatticeNodes(for: path))
        }
        return segments.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.text < rhs.text
        }
    }

    // Every pair of segments that sit back-to-back within some candidate path, deduped so a
    // transition two or more paths share is drawn once. These are the lattice diagram's edges.
    func sublatticeTransitions(for paths: [[String]]) -> [SublatticeTransition] {
        var transitions: Set<SublatticeTransition> = []
        for path in paths {
            let nodes = sublatticeNodes(for: path)
            for (previous, next) in zip(nodes, nodes.dropFirst()) {
                transitions.insert(SublatticeTransition(from: previous, to: next))
            }
        }
        return transitions.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from.start < rhs.from.start }
            return lhs.to.start < rhs.to.start
        }
    }

    // One candidate path's full node sequence: a shared empty-text origin marker, the path's own
    // segments in order, and a shared empty-text terminus marker. Every path starts at character
    // offset 0 and covers the same total surface, so these markers are identical (start, end,
    // text) across every path and collapse to the same two nodes — giving the diagram a single
    // place where all paths begin and a single place where they all end, instead of leaving each
    // path's first and last segment dangling with no incoming or outgoing edge.
    private func sublatticeNodes(for path: [String]) -> [SublatticeSegment] {
        var offset = 0
        var nodes: [SublatticeSegment] = [SublatticeSegment(start: 0, end: 0, text: "")]
        for segment in path {
            nodes.append(SublatticeSegment(start: offset, end: offset + segment.count, text: segment))
            offset += segment.count
        }
        nodes.append(SublatticeSegment(start: offset, end: offset, text: ""))
        return nodes
    }

    // One candidate segment at a specific character-offset span — the lattice diagram's node.
    // Hashable by (start, end, text) so two paths that pick the identical segment at the
    // identical position collapse to the same node. An empty text with start == end is one of
    // the shared origin/terminus markers rather than a real segment (a real segment always
    // spans at least one character).
    struct SublatticeSegment: Hashable, Identifiable {
        let start: Int
        let end: Int
        let text: String
        var id: Self { self }
        var nodeID: String { "\(start)_\(end)_\(text)" }
        var isMarker: Bool { text.isEmpty }
    }

    // A directed adjacency between two segments that sit back-to-back in some candidate path —
    // the lattice diagram's edge. Carries no text of its own; the segment nodes already do.
    struct SublatticeTransition: Hashable, Identifiable {
        let from: SublatticeSegment
        let to: SublatticeSegment
        var id: Self { self }
    }

    // Shared rendering behind sublatticeDiagram: hands the segment/transition graph to SwiftDagre
    // for node/edge positioning, then draws the result — a text chip per real segment (a dot for
    // the shared origin/terminus markers), sized to fit, and a routed line per transition (bent
    // around whatever shares its span, for transitions crossing more than one other segment's
    // boundary).
    @ViewBuilder
    private func sublatticeArcDiagram(segments: [SublatticeSegment], transitions: [SublatticeTransition]) -> some View {
        if let layout = sublatticeLayout(segments: segments, transitions: transitions) {
            // A short word's diagram naturally lays out much narrower than the section row it
            // sits in, leaving it sitting in a fraction of the row with dead space beside it.
            // GeometryReader reports the row's actual width so the whole diagram — lines, chips,
            // and text together — can scale as one image to fill it (or pack down to fit, for an
            // unusually wide one), via a single scaleEffect. Scaling everything uniformly, rather
            // than independently repositioning each line and chip to some new width, is what
            // guarantees a line still lands exactly on its chip's edge at any size: the two were
            // already touching in SwiftDagre's own layout, and a single affine transform preserves
            // every such relationship exactly, with no separate coordinate math to fall out of
            // sync (which is exactly what independent repositioning did — see kioku git history
            // for the visible seams and self-crossing loops that approach produced).
            GeometryReader { geometry in
                let scale = geometry.size.width / layout.contentWidth

                ZStack(alignment: .topLeading) {
                    // Drawn before the chips below, so a Button's own opaque background paints
                    // over wherever a line passes behind it.
                    ForEach(transitions) { transition in
                        if let path = layout.edgePaths[transition] {
                            path.stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                        }
                    }
                    ForEach(segments) { segment in
                        if segment.isMarker == false, let frame = layout.nodeFrames[segment] {
                            Button {
                                openSublatticeSegment(segment)
                            } label: {
                                Text(segment.text)
                                    .font(Font(sublatticeChipUIFont))
                                    // Sized here, before the backgrounds, so the backgrounds (and
                                    // the visible chip they draw) fill this exact frame — the same
                                    // frame the lines above were laid out to touch.
                                    .frame(width: frame.width, height: frame.height)
                                    // The 12% accent tint alone let a line drawn behind the chip
                                    // show straight through it — a fully opaque base underneath
                                    // the tint is what actually hides whatever's below.
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color.accentColor.opacity(0.12))
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color(.secondarySystemGroupedBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(width: layout.contentWidth, height: layout.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: layout.height * scale, alignment: .topLeading)
                .clipped()
            }
            .aspectRatio(layout.contentWidth / layout.height, contentMode: .fit)
            .padding(.vertical, 4)
        }
    }

    // Opens a tapped node's own dictionary entry the same way a related-word tap does — looked
    // up directly by its surface (segments already come from the sublattice's own candidate
    // decomposition, which are dictionary-lookupable forms), recorded to history, and presented
    // in the nested WordDetailView sheet. Silently does nothing for a segment with no dictionary
    // entry of its own (e.g. a bound grammatical piece like れる with no standalone headword).
    private func openSublatticeSegment(_ segment: SublatticeSegment) {
        guard let dictionaryStore else { return }
        let mode: LookupMode = ScriptClassifier.containsKanji(segment.text) ? .kanjiAndKana : .kanaOnly
        guard let entry = (try? dictionaryStore.lookup(surface: segment.text, mode: mode))?.first else { return }
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        presentedRelatedSavedWord = ephemeralSavedWord(for: entry)
    }

    // One SwiftDagre layout pass's results, translated into what the view needs to draw: a frame
    // per segment node and a smoothed stroke path per transition edge, already shifted so x = 0
    // sits at the origin marker's own border and contentWidth is the span up to the terminus
    // marker's border — the markers themselves are excluded (see sublatticeLayout).
    private struct SublatticeLayout {
        var nodeFrames: [SublatticeSegment: CGRect]
        var edgePaths: [SublatticeTransition: Path]
        var contentWidth: CGFloat
        var height: CGFloat
    }

    // The exact font a segment chip renders its text with — shared by sublatticeChipSize (which
    // measures against it) and the chip's own Text view (which renders with it), so the two can
    // never drift apart the way a flat per-character width estimate once did (a real chip's
    // Text is given the measured size as a hard frame, so any gap between "what was measured"
    // and "what actually renders" shows up as clipped text).
    private var sublatticeChipUIFont: UIFont { .preferredFont(forTextStyle: .title2) }

    // The chip size a segment's own text needs, measured against sublatticeChipUIFont. The node
    // SwiftDagre lays out is the same size as the chip rendered at it. Empty text is one of the
    // shared origin/terminus markers, drawn as a small dot instead.
    private func sublatticeChipSize(for text: String) -> CGSize {
        guard text.isEmpty == false else { return CGSize(width: 8, height: 8) }
        let measured = (text as NSString).size(withAttributes: [.font: sublatticeChipUIFont])
        return CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 8)
    }

    // Rounds SwiftDagre's polyline (straight segments through each dummy-node bend point) into a
    // smooth curve, so a transition that bends around another rank's chip reads as one flowing
    // branch rather than a path with sharp elbows in it.
    private func sublatticeSmoothedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // Builds a left-to-right DAG (one node per segment or marker, one edge per transition, edge
    // length in ranks set to the source segment's own character count, clamped to at least 1 so
    // the zero-length origin marker still lands a rank before the real segments after it) and
    // lays it out with SwiftDagre. Every path from the origin marker to a given segment spans the
    // identical number of characters no matter how it's divided, so this graph's rank constraints
    // are always mutually consistent — SwiftDagre settles on exactly one rank per node, offset by
    // its start offset (shifted by one for the origin marker occupying rank 0), which keeps the
    // diagram in reading order, and its crossing-minimizing node ordering within each rank keeps
    // transitions between adjacent ranks from crossing.
    private func sublatticeLayout(segments: [SublatticeSegment], transitions: [SublatticeTransition]) -> SublatticeLayout? {
        guard segments.isEmpty == false else { return nil }
        let graph = DagreGraph(options: GraphOptions(directed: true))
        for segment in segments {
            let size = sublatticeChipSize(for: segment.text)
            graph.setNode(segment.nodeID, label: DagreNodeLabel(width: size.width, height: size.height))
        }
        for transition in transitions {
            let label = DagreEdgeLabel(minlen: max(transition.from.end - transition.from.start, 1), weight: 1)
            guard (try? graph.setEdge(transition.from.nodeID, transition.to.nodeID, label: label)) != nil else { return nil }
        }

        let options = LayoutOptions()
        options.rankdir = .leftRight
        // network-simplex (SwiftDagre's default) globally minimizes total edge length, which can
        // push a node to a LATER rank than the earliest one its minlen constraints allow, if that
        // shortens edges elsewhere in the graph — breaking the "same start offset always lands on
        // the same rank" assumption every alignment/crop calculation in this file depends on (two
        // segments starting at the same offset, like a whole-word candidate and the first piece of
        // its finer-grained alternative, would end up misaligned). longest-path always assigns the
        // tightest feasible rank, which is exactly the offset-equals-rank behavior this needs.
        options.ranker = .longestPath
        // Generous relative to the tight boundary-node diagram this replaced: nodesep is the gap
        // between alternative chips stacked in the same rank, so it has to be wide enough to read
        // as separate lanes rather than a cramped column; ranksep gives a diverging or
        // reconverging line room to bend visibly instead of looking like a kink.
        options.ranksep = 34
        options.nodesep = 26
        options.edgesep = 14
        guard (try? SwiftDagreLayout.layout(graph, options: options)) != nil else { return nil }

        var nodeFrames: [SublatticeSegment: CGRect] = [:]
        for segment in segments {
            guard let label = graph.node(segment.nodeID) else { continue }
            let size = sublatticeChipSize(for: segment.text)
            nodeFrames[segment] = CGRect(
                x: label.x - size.width / 2,
                y: label.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        // SwiftDagre centers every node sharing a rank on the same X — a branch point (several
        // alternative segments after a shared predecessor) then reads as center-aligned, which
        // makes each alternative's first character start at a different X depending on how long
        // its own text runs. Re-anchor every node in a rank to that rank's widest member's left
        // edge instead, so a branch's alternatives visibly start at the same point in the text.
        // Nodes shift as a whole (not just the drawn chip) so each edge's own endpoint moves with
        // the node it terminates at, rather than detaching from it.
        var alignmentShift: [String: CGFloat] = [:]
        let rankGroups = Dictionary(grouping: segments) { (nodeFrames[$0]?.midX ?? 0).rounded() }
        for (_, members) in rankGroups {
            guard let leftEdge = members.compactMap({ nodeFrames[$0]?.minX }).min() else { continue }
            for member in members {
                guard let frame = nodeFrames[member] else { continue }
                let shift = leftEdge - frame.minX
                alignmentShift[member.nodeID] = shift
                nodeFrames[member] = frame.offsetBy(dx: shift, dy: 0)
            }
        }

        var edgePoints: [SublatticeTransition: [CGPoint]] = [:]
        for transition in transitions {
            guard let edgeLabel = graph.edge(transition.from.nodeID, transition.to.nodeID) else { continue }
            var points = edgeLabel.points.map { CGPoint(x: $0.x, y: $0.y) }
            if let first = points.first {
                points[0] = CGPoint(x: first.x + (alignmentShift[transition.from.nodeID] ?? 0), y: first.y)
            }
            if points.count > 1 {
                let lastIndex = points.count - 1
                let last = points[lastIndex]
                points[lastIndex] = CGPoint(x: last.x + (alignmentShift[transition.to.nodeID] ?? 0), y: last.y)
            }
            edgePoints[transition] = points
        }

        // The origin/terminus markers exist so every path's first and last segment has somewhere
        // to connect to (see sublatticeNodes) — not to be seen themselves. Re-anchoring every
        // coordinate to the origin marker's own border, and reporting content width only up to
        // the terminus marker's border, crops both markers out of the diagram entirely: their
        // stub edges still run all the way to (and past) x = 0 / contentWidth, so they simply
        // run off the diagram's own edge instead of visibly dead-ending at a dot.
        let originMarker = segments.first { $0.isMarker && $0.start == 0 }
        let terminusMarker = segments.first { $0.isMarker && $0.start != 0 }
        let leftCrop = originMarker.flatMap { nodeFrames[$0] }?.maxX ?? 0
        let rightCrop = terminusMarker.flatMap { nodeFrames[$0] }?.minX ?? CGFloat(options.width)
        let contentWidth = max(rightCrop - leftCrop, 1)

        for segment in segments {
            nodeFrames[segment] = nodeFrames[segment]?.offsetBy(dx: -leftCrop, dy: 0)
        }

        var edgePaths: [SublatticeTransition: Path] = [:]
        for (transition, points) in edgePoints {
            let shifted = points.map { CGPoint(x: $0.x - leftCrop, y: $0.y) }
            edgePaths[transition] = sublatticeSmoothedPath(through: shifted)
        }

        return SublatticeLayout(
            nodeFrames: nodeFrames,
            edgePaths: edgePaths,
            contentWidth: contentWidth,
            height: CGFloat(options.height)
        )
    }
}
