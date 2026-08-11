import AppKit
import NintyCore
import SwiftUI

/// Interactive code-graph mindmap fed by graph-mcp's `graph_subgraph`.
/// Force-directed layout (spring + repulsion + centering), drag to pin,
/// click for details, filter by kind, search by name.
struct GraphTabView: View {
    @Environment(AppState.self) private var appState

    @State private var scene = GraphScene()
    @State private var status: LoadStatus = .loading
    @State private var selected: GraphNodeUI?
    @State private var filter = ""
    @State private var kindFilter: String?
    @State private var resyncing = false
    @State private var statsText = ""
    /// Lazy-load stages: small first paint, then background backfills
    /// (graph_subgraph is degree-ordered, so each stage is a superset).
    private let stageLimits = [120, 300, 500]
    /// Background stages still loading.
    @State private var backfilling = false
    /// A backfill stage timed out — graph stays usable, retry offered.
    @State private var backfillFailed = false
    /// Total node count from graph_status (caption "loaded 300/1234").
    @State private var totalNodes: Int?
    /// Guards against stale backfills merging into a reloaded scene.
    @State private var loadGeneration = 0
    /// Click-to-expand busy indicator.
    @State private var expanding = false

    enum LoadStatus {
        case loading, ready, unavailable, empty
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .loading:
                Spacer()
                ProgressView().controlSize(.small)
                Text("Loading graph…").font(Theme.caption).foregroundStyle(Theme.textMuted)
                Spacer()
            case .unavailable:
                emptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "No graph server",
                    message: "Add graph-mcp to the `mcp` section of ninty.json with a url, e.g.\n\"graph\": { \"url\": \"http://localhost:3001/mcp\" }"
                )
            case .empty:
                if appState.graphSyncStatus != nil {
                    syncProgressState
                } else {
                    emptyState(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Graph is empty",
                        message: "Sync this workspace to build its code graph.",
                        actionLabel: resyncing ? nil : "Sync workspace",
                        action: sync
                    )
                }
            case .error(let message):
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: "Graph query failed",
                    message: message,
                    actionLabel: resyncing ? nil : "Retry sync",
                    action: sync
                )
            case .ready:
                toolbar
                Divider().overlay(Theme.borderBase)
                canvas
                if let selected {
                    Divider().overlay(Theme.borderBase)
                    detailBar(selected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: appState.workspace?.id) { await load() }
        .onChange(of: appState.graphSyncStatus) { wasSyncing, syncStatus in
            // Sync finished while we're looking at an empty/error state: reload.
            guard wasSyncing != nil, syncStatus == nil else { return }
            if case .ready = status { return }
            Task { await load() }
        }
    }

    private var syncProgressState: some View {
        VStack(spacing: 10) {
            Spacer()
            if let progress = appState.graphSyncProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
            } else {
                ProgressView().controlSize(.regular)
            }
            Text("Syncing graph").font(Theme.sansMedium).foregroundStyle(Theme.textBase)
            if let status = appState.graphSyncStatus {
                Text(status)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Compact relative time for the "synced Xs ago" caption.
    private static func ago(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
            TextField("Filter symbols…", text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .frame(maxWidth: 160)

            Menu {
                Button("All kinds") { kindFilter = nil }
                Divider()
                ForEach(scene.kinds, id: \.self) { kind in
                    Button(kind) { kindFilter = kind }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(kindFilter ?? "All kinds").font(Theme.caption)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Theme.textMuted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let syncStatus = appState.graphSyncStatus {
                // Determinate bar while upserting (fraction known); spinner
                // during extraction.
                if let progress = appState.graphSyncProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(width: 70)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(syncStatus)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            } else if backfilling {
                ProgressView().controlSize(.mini)
                Text("Loading more nodes…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
            } else {
                HStack(spacing: 4) {
                    Text(statsText).font(Theme.caption).foregroundStyle(Theme.textMuted)
                    if let synced = appState.graphLastSynced {
                        Text("· synced \(Self.ago(synced))")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textFaint)
                    }
                    if backfillFailed {
                        Button("Retry") { Task { await load() } }
                            .font(Theme.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textAccent)
                            .help("Retry loading the remaining nodes")
                    }
                }
            }

            Button {
                scene.zoomStep(1 / 1.3)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom out")

            Button {
                scene.zoomStep(1.3)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom in")

            Button {
                scene.resetView()
            } label: {
                Image(systemName: "viewfinder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset view")

            Button(action: sync) {
                Image(systemName: resyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(resyncing)
            .help("Resync workspace graph")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            graphCanvas
                .onAppear { scene.clampTo(size: proxy.size) }
                .onChange(of: proxy.size) { _, size in scene.clampTo(size: size) }
        }
    }

    private var graphCanvas: some View {
        Canvas { context, _ in
            context.translateBy(x: scene.offset.width, y: scene.offset.height)
            context.scaleBy(x: scene.scale, y: scene.scale)

            // Edges batched into one Path per kind: a handful of strokes total
            // instead of thousands of individual stroke calls.
            var edgePaths: [String: Path] = [:]
            for edge in scene.edges {
                guard let from = scene.node(for: edge.from), let to = scene.node(for: edge.to) else { continue }
                edgePaths[edge.kind, default: Path()].move(to: from.position)
                edgePaths[edge.kind, default: Path()].addLine(to: to.position)
            }
            for (kind, path) in edgePaths {
                context.stroke(path, with: .color(edgeColor(kind).opacity(0.25)), lineWidth: 0.7 / scene.scale)
            }

            let showLabels = scene.scale > 0.6
            for node in scene.nodes where matches(node) {
                let radius = scene.radius(for: node)
                let isSelected = selected?.id == node.id
                let dimmed = matchesFilter && !visible(node)
                let color = nodeColor(node).opacity(dimmed ? 0.25 : 1)
                let rect = CGRect(x: node.position.x - radius, y: node.position.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if isSelected {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 1.4 / scene.scale)
                }
                if showLabels, radius >= 10 || isSelected {
                    let text = Text(node.name).font(.system(size: 9)).foregroundStyle(Theme.textBase)
                    context.draw(text, at: CGPoint(x: node.position.x, y: node.position.y + radius + 8))
                }
            }
        }
        .background(Theme.bgBase)
        .overlay(ScrollWheelPan { dx, dy in
            scene.offset.width += dx
            scene.offset.height += dy
        })
        .gesture(dragGesture)
        .gesture(magnifyGesture)
        .onTapGesture { location in
            selected = scene.nearestNode(to: scene.worldPoint(fromScreen: location), within: 14 / scene.scale)
        }
    }

    @State private var lastMagnification: CGFloat = 1

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                scene.zoom(by: delta, atScreen: value.startLocation)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    @State private var panBase: CGSize?

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let dragged = scene.draggedNode {
                    scene.move(dragged, to: scene.worldPoint(fromScreen: value.location))
                } else if let hit = scene.nearestNode(
                    to: scene.worldPoint(fromScreen: value.startLocation), within: 14 / scene.scale
                ) {
                    scene.draggedNode = hit
                    scene.move(hit, to: scene.worldPoint(fromScreen: value.location))
                } else {
                    // Empty space: pan the canvas.
                    if panBase == nil { panBase = scene.offset }
                    if let panBase {
                        scene.offset = CGSize(
                            width: panBase.width + value.translation.width,
                            height: panBase.height + value.translation.height
                        )
                    }
                }
            }
            .onEnded { _ in
                scene.draggedNode = nil
                panBase = nil
            }
    }

    // MARK: - Detail bar

    private func detailBar(_ node: GraphNodeUI) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(node.kind.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(nodeColor(node))
                Text(node.name).font(Theme.sansMedium)
                Spacer()
                // Lazy-load this node's neighborhood into the map on demand
                // (graph_explain) instead of pulling the whole graph up front.
                Button {
                    expandNeighbors(of: node)
                } label: {
                    if expanding {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .disabled(expanding)
                .help("Load this node's neighbors into the map")
                Text("\(node.file):\(node.line)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let signature = node.signature, !signature.isEmpty {
                Text(signature)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textBase)
                    .lineLimit(2)
            }
            let neighbors = scene.neighbors(of: node)
            if !neighbors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(neighbors.prefix(6), id: \.0) { direction, kind, name in
                        Text("\(direction == "out" ? "→" : "←") \(kind) \(name)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    if neighbors.count > 6 {
                        Text("… \(neighbors.count - 6) more")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.layer01)
    }

    // MARK: - Filtering / colors

    private var matchesFilter: Bool {
        filter.count >= 2
    }

    private func matches(_ node: GraphNodeUI) -> Bool {
        if let kindFilter, node.kind != kindFilter { return false }
        return true
    }

    private func visible(_ node: GraphNodeUI) -> Bool {
        guard matchesFilter else { return true }
        return node.name.localizedCaseInsensitiveContains(filter)
    }

    private func nodeColor(_ node: GraphNodeUI) -> Color {
        switch node.kind {
        case "file": return Color.gray
        case "class", "actor": return graphColor(0x5E, 0x5C, 0xE6)
        case "struct", "record": return graphColor(0x0A, 0x84, 0xFF)
        case "enum", "type": return graphColor(0xBF, 0x5A, 0xF2)
        case "protocol", "interface", "trait": return graphColor(0x64, 0xD2, 0xFF)
        case "func", "method": return graphColor(0x30, 0xD1, 0x58)
        case "extension", "impl", "module", "namespace", "object": return graphColor(0xFF, 0x9F, 0x0A)
        default: return graphColor(0x98, 0x98, 0x9D)
        }
    }

    private func edgeColor(_ kind: String) -> Color {
        switch kind {
        case "contains": return Color.gray
        case "imports": return graphColor(0x0A, 0x84, 0xFF)
        case "calls": return graphColor(0x30, 0xD1, 0x58)
        case "inherits", "implements": return graphColor(0xBF, 0x5A, 0xF2)
        default: return Color.gray
        }
    }

    private func emptyState(icon: String, title: String, message: String, actionLabel: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(title).font(Theme.sansMedium).foregroundStyle(Theme.textBase)
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textBase)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.layer01)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderBase))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func sync() {
        resyncing = true
        Task {
            let ok = await appState.resyncGraph()
            if ok {
                await load()
            } else {
                status = .error("Graph sync failed — check the graph-mcp server connection.")
            }
            resyncing = false
        }
    }

    /// Lazy load: stage 1 paints fast (top-degree nodes), remaining stages
    /// backfill in the background. A slow server only delays the tail.
    private func load() async {
        status = .loading
        backfillFailed = false
        loadGeneration += 1
        let generation = loadGeneration
        guard await appState.waitForMCPTool("graph_subgraph") else {
            status = .unavailable
            return
        }
        let first = await fetchSubgraph(limit: stageLimits[0])
        guard let payload = first.payload else {
            if !Task.isCancelled { status = .error(first.error ?? "Graph load failed") }
            return
        }
        let nodes = GraphNodeUI.parse(payload["nodes"])
        guard !nodes.isEmpty else {
            status = .empty
            return
        }
        scene.load(nodes: nodes, edges: GraphEdgeUI.parse(payload["edges"]))
        status = .ready
        await refreshTotals()
        updateStats()
        backfill(from: 1, generation: generation)
    }

    /// graph_subgraph behind a 20s deadline — timeout becomes an error
    /// message instead of hanging the tab.
    private func fetchSubgraph(limit: Int) async -> (payload: [String: JSONValue]?, error: String?) {
        guard let result = await appState.callMCPTool(
            "graph_subgraph", ["limit": .int(limit)], timeout: 20
        ) else {
            return (nil, "Timed out loading the graph — try again.")
        }
        switch result {
        case .success(let value):
            guard case .object(let object) = value else {
                return (nil, "Unexpected graph_subgraph response")
            }
            return (object, nil)
        case .failure(let error):
            return (nil, error.localizedDescription)
        }
    }

    /// Merge the remaining stages without blocking the loaded map.
    private func backfill(from startStage: Int, generation: Int) {
        guard startStage < stageLimits.count else { return }
        backfilling = true
        Task {
            for stage in startStage..<stageLimits.count {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let fetched = await fetchSubgraph(limit: stageLimits[stage])
                guard generation == loadGeneration else { return }
                guard let payload = fetched.payload else {
                    // Keep what's loaded; offer a retry in the toolbar.
                    backfillFailed = true
                    backfilling = false
                    return
                }
                scene.merge(
                    nodes: GraphNodeUI.parse(payload["nodes"]),
                    edges: GraphEdgeUI.parse(payload["edges"])
                )
                updateStats()
            }
            backfilling = false
        }
    }

    /// Click-to-expand: pull one node's neighborhood on demand (graph_explain)
    /// and merge it into the live scene.
    private func expandNeighbors(of node: GraphNodeUI) {
        guard !expanding else { return }
        expanding = true
        Task {
            defer { expanding = false }
            guard let result = await appState.callMCPTool(
                "graph_explain", ["node": .string(node.id)], timeout: 20
            ), case .success(let value) = result,
                case .object(let object) = value,
                case .array(let neighbors) = object["neighbors"] else { return }
            var nodeValues: [JSONValue] = []
            var edges: [GraphEdgeUI] = []
            for case .object(let neighbor) in neighbors {
                guard let nodeValue = neighbor["node"],
                      case .object(let inner) = nodeValue,
                      case .string(let key) = inner["node_key"],
                      case .string(let direction) = neighbor["direction"],
                      case .string(let kind) = neighbor["kind"] else { continue }
                nodeValues.append(nodeValue)
                edges.append(direction == "out"
                    ? GraphEdgeUI(from: node.id, to: key, kind: kind)
                    : GraphEdgeUI(from: key, to: node.id, kind: kind))
            }
            scene.merge(nodes: GraphNodeUI.parse(.array(nodeValues)), edges: edges)
            updateStats()
        }
    }

    private func refreshTotals() async {
        if let stats = await appState.callMCPTool("graph_status", [:], timeout: 10),
           case .success(let value) = stats,
           case .object(let object) = value {
            totalNodes = object["node_count"]?.intValue
        }
    }

    private func updateStats() {
        let loaded = scene.nodes.count
        if let totalNodes, totalNodes > loaded {
            statsText = "loaded \(loaded)/\(totalNodes) nodes"
        } else {
            statsText = "\(loaded) nodes"
        }
    }
}

// MARK: - UI models

struct GraphNodeUI: Identifiable, Equatable {
    let id: String // node_key
    let kind: String
    let name: String
    let file: String
    let line: Int
    let signature: String?
    let community: Int?
    var degree: Int = 0
    var position: CGPoint = .zero
    var velocity: CGVector = .zero

    static func parse(_ value: JSONValue?) -> [GraphNodeUI] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item,
                  let key = object["node_key"]?.stringValue,
                  let kind = object["kind"]?.stringValue,
                  let name = object["name"]?.stringValue,
                  let file = object["file"]?.stringValue else { return nil }
            return GraphNodeUI(
                id: key,
                kind: kind,
                name: name,
                file: file,
                line: object["line"]?.intValue ?? 0,
                signature: object["signature"]?.stringValue,
                community: object["community"]?.intValue
            )
        }
    }
}

struct GraphEdgeUI: Equatable {
    let from: String
    let to: String
    let kind: String

    static func parse(_ value: JSONValue?) -> [GraphEdgeUI] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard case .object(let object) = item,
                  let from = object["from_key"]?.stringValue,
                  let to = object["to_key"]?.stringValue,
                  let kind = object["kind"]?.stringValue else { return nil }
            return GraphEdgeUI(from: from, to: to, kind: kind)
        }
    }
}

// MARK: - Scene (layout simulation)

@MainActor @Observable
final class GraphScene {
    private(set) var nodes: [GraphNodeUI] = []
    private(set) var edges: [GraphEdgeUI] = []
    var draggedNode: GraphNodeUI?

    // View transform: screen = world * scale + offset.
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    private var index: [String: Int] = [:]
    private var adjacency: [String: [String]] = [:]
    private var springs: [Spring] = []
    private var simulationTask: Task<Void, Never>?
    private var canvasSize: CGSize = .init(width: 600, height: 600)

    var kinds: [String] {
        Array(Set(nodes.map(\.kind))).sorted()
    }

    // MARK: - View transform

    func worldPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    func zoom(by factor: CGFloat, atScreen anchor: CGPoint) {
        let old = scale
        let new = min(max(old * factor, 0.2), 5)
        guard new != old else { return }
        // Keep the world point under the anchor fixed on screen.
        offset.width = anchor.x - (anchor.x - offset.width) * (new / old)
        offset.height = anchor.y - (anchor.y - offset.height) * (new / old)
        scale = new
    }

    func zoomStep(_ factor: CGFloat) {
        zoom(by: factor, atScreen: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func resetView() {
        fitToView()
    }

    /// Scale + pan so the whole graph fits the canvas with a margin.
    func fitToView(margin: CGFloat = 40) {
        guard !nodes.isEmpty else { return }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for node in nodes {
            minX = min(minX, node.position.x); maxX = max(maxX, node.position.x)
            minY = min(minY, node.position.y); maxY = max(maxY, node.position.y)
        }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let s = min((canvasSize.width - margin * 2) / w, (canvasSize.height - margin * 2) / h)
        scale = min(max(s, 0.2), 5)
        offset = CGSize(
            width: canvasSize.width / 2 - (minX + w / 2) * scale,
            height: canvasSize.height / 2 - (minY + h / 2) * scale
        )
    }

    func load(nodes newNodes: [GraphNodeUI], edges newEdges: [GraphEdgeUI]) {
        simulationTask?.cancel()
        var nodes = newNodes
        var adjacency: [String: [String]] = [:]
        for edge in newEdges {
            adjacency[edge.from, default: []].append(edge.to)
            adjacency[edge.to, default: []].append(edge.from)
        }
        // Initial placement on a wide circle: starting dense is what makes
        // the first ticks the most expensive.
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = min(canvasSize.width, canvasSize.height) * 0.45
        for i in nodes.indices {
            let angle = Double(i) / Double(max(nodes.count, 1)) * 2 * .pi
            nodes[i].position = CGPoint(
                x: center.x + cos(angle) * radius + Double.random(in: -60...60),
                y: center.y + sin(angle) * radius + Double.random(in: -60...60)
            )
            nodes[i].degree = adjacency[nodes[i].id]?.count ?? 0
        }
        self.nodes = nodes
        edges = newEdges
        self.adjacency = adjacency
        index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        springs = newEdges.compactMap { edge in
            guard let a = index[edge.from], let b = index[edge.to] else { return nil }
            return Spring(a: a, b: b)
        }
        startSimulation()
    }

    func node(for key: String) -> GraphNodeUI? {
        index[key].map { nodes[$0] }
    }

    func neighbors(of node: GraphNodeUI) -> [(String, String, String)] {
        var result: [(String, String, String)] = []
        for edge in edges {
            if edge.from == node.id, let other = self.node(for: edge.to) {
                result.append(("out", edge.kind, other.name))
            } else if edge.to == node.id, let other = self.node(for: edge.from) {
                result.append(("in", edge.kind, other.name))
            }
        }
        return result
    }

    func radius(for node: GraphNodeUI) -> CGFloat {
        min(4 + CGFloat(node.degree) * 0.9, 14)
    }

    func nearestNode(to point: CGPoint, within distance: CGFloat) -> GraphNodeUI? {
        nodes
            .filter { $0.position.distance(to: point) <= distance }
            .min { $0.position.distance(to: point) < $1.position.distance(to: point) }
    }

    func move(_ node: GraphNodeUI, to point: CGPoint) {
        guard let i = index[node.id] else { return }
        nodes[i].position = point
        nodes[i].velocity = .zero
    }

    func clampTo(size: CGSize) {
        canvasSize = size
    }

    // MARK: - Force simulation

    /// Edge endpoints as node indices (tuples are not Sendable).
    private struct Spring: Sendable {
        let a, b: Int
    }

    /// Value-type snapshot so each tick's force computation runs off the
    /// main actor; only the cheap write-back happens on main.
    private struct SimState: Sendable {
        var positions: [SIMD2<Double>]
        var velocities: [SIMD2<Double>]
        let springs: [Spring]
        let pinned: Int?
    }

    private func startSimulation() {
        startSimulation(alpha: 1.0, fitOnSettle: true)
    }

    /// - Parameters:
    ///   - initialAlpha: 1.0 for fresh layouts; lower (~0.35) to gently
    ///     settle merged-in nodes without exploding the existing layout.
    ///   - fitOnSettle: refit the viewport when the sim cools. Off for
    ///     backfill merges so a zoomed-in user isn't yanked out.
    private func startSimulation(alpha initialAlpha: Double, fitOnSettle: Bool) {
        simulationTask = Task { [weak self] in
            var alpha = initialAlpha
            while !Task.isCancelled, alpha > 0.005 {
                guard let self, let sim = self.snapshot() else { return }
                let center = SIMD2<Double>(x: self.canvasSize.width / 2, y: self.canvasSize.height / 2)
                let stepAlpha = alpha // let-binding: capturing a var would be non-Sendable
                let stepped = await Task.detached(priority: .userInitiated) {
                    GraphScene.stepped(sim, alpha: stepAlpha, center: center)
                }.value
                guard !Task.isCancelled else { return }
                self.apply(stepped)
                alpha *= 0.97
                try? await Task.sleep(for: .milliseconds(33))
            }
            if fitOnSettle { self?.fitToView() }
        }
    }

    private struct EdgeKey: Hashable {
        let from, to, kind: String
    }

    /// Merge a superset batch (staged subgraph backfill) or a neighborhood
    /// (click-to-expand) into the live scene. Existing nodes keep their
    /// positions; new nodes seed near their loaded neighbors. Returns the
    /// number of nodes added.
    @discardableResult
    func merge(nodes newNodes: [GraphNodeUI], edges newEdges: [GraphEdgeUI]) -> Int {
        simulationTask?.cancel()
        var merged = nodes
        var newIndex = index
        var added = 0

        // Adjacency within the incoming batch → seed positions.
        var batchNeighbors: [String: [String]] = [:]
        for edge in newEdges {
            batchNeighbors[edge.from, default: []].append(edge.to)
            batchNeighbors[edge.to, default: []].append(edge.from)
        }

        for node in newNodes where newIndex[node.id] == nil {
            var seeded = node
            var sumX: CGFloat = 0, sumY: CGFloat = 0, known = 0
            for key in batchNeighbors[node.id] ?? [] {
                guard let i = newIndex[key] else { continue }
                sumX += merged[i].position.x
                sumY += merged[i].position.y
                known += 1
            }
            if known > 0 {
                seeded.position = CGPoint(
                    x: sumX / CGFloat(known) + CGFloat.random(in: -30...30),
                    y: sumY / CGFloat(known) + CGFloat.random(in: -30...30)
                )
            } else {
                seeded.position = CGPoint(
                    x: canvasSize.width / 2 + CGFloat.random(in: -90...90),
                    y: canvasSize.height / 2 + CGFloat.random(in: -90...90)
                )
            }
            merged.append(seeded)
            newIndex[node.id] = merged.count - 1
            added += 1
        }

        var seenEdges = Set(edges.map { EdgeKey(from: $0.from, to: $0.to, kind: $0.kind) })
        var mergedEdges = edges
        for edge in newEdges where seenEdges.insert(EdgeKey(from: edge.from, to: edge.to, kind: edge.kind)).inserted {
            mergedEdges.append(edge)
        }

        guard added > 0 || mergedEdges.count != edges.count else {
            startSimulation(alpha: 0.2, fitOnSettle: false)
            return 0
        }

        nodes = merged
        edges = mergedEdges
        index = newIndex
        var newAdjacency: [String: [String]] = [:]
        for edge in mergedEdges {
            newAdjacency[edge.from, default: []].append(edge.to)
            newAdjacency[edge.to, default: []].append(edge.from)
        }
        adjacency = newAdjacency
        for i in nodes.indices {
            nodes[i].degree = adjacency[nodes[i].id]?.count ?? 0
        }
        springs = mergedEdges.compactMap { edge in
            guard let a = index[edge.from], let b = index[edge.to] else { return nil }
            return Spring(a: a, b: b)
        }
        startSimulation(alpha: 0.35, fitOnSettle: false)
        return added
    }

    private func snapshot() -> SimState? {
        guard !nodes.isEmpty else { return nil }
        return SimState(
            positions: nodes.map { SIMD2(x: $0.position.x, y: $0.position.y) },
            velocities: nodes.map { SIMD2(x: $0.velocity.dx, y: $0.velocity.dy) },
            springs: springs,
            pinned: draggedNode.flatMap { index[$0.id] }
        )
    }

    private func apply(_ sim: SimState) {
        guard sim.positions.count == nodes.count else { return }
        for i in nodes.indices {
            nodes[i].position = CGPoint(x: sim.positions[i].x, y: sim.positions[i].y)
            nodes[i].velocity = CGVector(dx: sim.velocities[i].x, dy: sim.velocities[i].y)
        }
    }

    private nonisolated static func stepped(_ sim: SimState, alpha: Double, center: SIMD2<Double>) -> SimState {
        var sim = sim
        let count = sim.positions.count
        guard count > 0 else { return sim }
        let springLength = 120.0
        let repulsion = 16000.0
        let cutoff = 550.0
        let cutoffSq = cutoff * cutoff

        // Uniform grid: only nodes in the same or adjacent cells can be
        // within the repulsion cutoff — skips the O(n²) all-pairs scan.
        struct Cell: Hashable { var x, y: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(count)
        for (i, p) in sim.positions.enumerated() {
            grid[Cell(x: Int(floor(p.x / cutoff)), y: Int(floor(p.y / cutoff))), default: []].append(i)
        }

        // Repulsion via grid neighbourhoods.
        for i in 0..<count {
            if i == sim.pinned { continue }
            var force = SIMD2<Double>.zero
            let p = sim.positions[i]
            let cx = Int(floor(p.x / cutoff))
            let cy = Int(floor(p.y / cutoff))
            for gx in (cx - 1)...(cx + 1) {
                for gy in (cy - 1)...(cy + 1) {
                    guard let bucket = grid[Cell(x: gx, y: gy)] else { continue }
                    for j in bucket where j != i {
                        let delta = p - sim.positions[j]
                        let distSq = max((delta * delta).sum(), 100)
                        if distSq > cutoffSq { continue }
                        let dist = distSq.squareRoot()
                        force += delta / dist * (repulsion / distSq)
                    }
                }
            }
            // Weak centering gravity: keeps components together but lets
            // the graph spread organically.
            force += (center - p) * 0.006
            sim.velocities[i] = (sim.velocities[i] + force * alpha) * 0.6
        }

        // Springs along edges.
        for spring in sim.springs {
            let (a, b) = (spring.a, spring.b)
            let delta = sim.positions[b] - sim.positions[a]
            let dist = max((delta * delta).sum().squareRoot(), 1)
            let f = delta / dist * ((dist - springLength) * 0.03 * alpha)
            if a != sim.pinned { sim.velocities[a] += f }
            if b != sim.pinned { sim.velocities[b] -= f }
        }

        // Integrate. No boundary clamp: clamping every tick packs nodes into
        // a box; gravity + fitToView keep the graph on screen.
        for i in 0..<count where i != sim.pinned {
            sim.positions[i] += sim.velocities[i]
        }
        return sim
    }
}

private func graphColor(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}

// MARK: - Two-finger scroll pan

/// Transparent overlay that catches trackpad two-finger scroll (scrollWheel
/// events) and reports deltas, without intercepting clicks or drags.
private struct ScrollWheelPan: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatchView {
        let view = ScrollCatchView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCatchView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCatchView: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?

        override var isFlipped: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
        }

        // Only claim scroll-wheel events; let clicks/drags fall through.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let event = NSApp.currentEvent
            if event?.type == .scrollWheel { return self }
            return nil
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}
