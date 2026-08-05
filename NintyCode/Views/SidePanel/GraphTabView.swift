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
                emptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Graph is empty",
                    message: "Sync this workspace to build its code graph."
                )
            case .error(let message):
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: "Graph query failed",
                    message: message
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

            Text(statsText).font(Theme.caption).foregroundStyle(Theme.textMuted)

            Button {
                resyncing = true
                Task {
                    await appState.resyncGraph()
                    await load()
                    resyncing = false
                }
            } label: {
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
        Canvas { context, size in
            for edge in scene.edges {
                guard let from = scene.node(for: edge.from), let to = scene.node(for: edge.to) else { continue }
                var path = Path()
                path.move(to: from.position)
                path.addLine(to: to.position)
                context.stroke(path, with: .color(edgeColor(edge).opacity(0.25)), lineWidth: 0.7)
            }
            for node in scene.nodes where matches(node) {
                let radius = scene.radius(for: node)
                let isSelected = selected?.id == node.id
                let dimmed = matchesFilter && !visible(node)
                let color = nodeColor(node).opacity(dimmed ? 0.25 : 1)
                let rect = CGRect(x: node.position.x - radius, y: node.position.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if isSelected {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 1.4)
                }
                if radius >= 7 || isSelected {
                    let text = Text(node.name).font(.system(size: 9)).foregroundStyle(Theme.textBase)
                    context.draw(text, at: CGPoint(x: node.position.x, y: node.position.y + radius + 8))
                }
            }
        }
        .background(Theme.bgBase)
        .gesture(dragGesture)
        .onTapGesture { location in
            selected = scene.nearestNode(to: location, within: 14)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let dragged = scene.draggedNode {
                    scene.move(dragged, to: value.location)
                } else if let hit = scene.nearestNode(to: value.location, within: 14) {
                    scene.draggedNode = hit
                    scene.move(hit, to: value.location)
                }
            }
            .onEnded { _ in
                scene.draggedNode = nil
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

    private func edgeColor(_ edge: GraphEdgeUI) -> Color {
        switch edge.kind {
        case "contains": return Color.gray
        case "imports": return graphColor(0x0A, 0x84, 0xFF)
        case "calls": return graphColor(0x30, 0xD1, 0x58)
        case "inherits", "implements": return graphColor(0xBF, 0x5A, 0xF2)
        default: return Color.gray
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(title).font(Theme.sansMedium).foregroundStyle(Theme.textBase)
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        status = .loading
        guard await appState.graphToolAvailable() else {
            status = .unavailable
            return
        }
        let subgraph = await appState.callGraphTool("graph_subgraph", [
            "limit": .int(500)
        ])
        let payload: [String: JSONValue]
        switch subgraph {
        case .success(let value):
            guard case .object(let object) = value else {
                status = .error("Unexpected graph_subgraph response")
                return
            }
            payload = object
        case .failure(let error):
            status = .error(error.localizedDescription)
            return
        }
        let nodes = GraphNodeUI.parse(payload["nodes"])
        let edges = GraphEdgeUI.parse(payload["edges"])
        guard !nodes.isEmpty else {
            status = .empty
            return
        }
        scene.load(nodes: nodes, edges: edges)
        if case .success(let stats) = await appState.callGraphTool("graph_status"),
           case .object(let object) = stats {
            let nodeCount = object["node_count"]?.intValue ?? nodes.count
            let edgeCount = object["edge_count"]?.intValue ?? edges.count
            statsText = "\(nodeCount) nodes · \(edgeCount) edges (top \(nodes.count))"
        } else {
            statsText = "\(nodes.count) nodes · \(edges.count) edges"
        }
        status = .ready
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

    private var index: [String: Int] = [:]
    private var adjacency: [String: [String]] = [:]
    private var simulationTask: Task<Void, Never>?
    private var canvasSize: CGSize = .init(width: 600, height: 600)

    var kinds: [String] {
        Array(Set(nodes.map(\.kind))).sorted()
    }

    func load(nodes newNodes: [GraphNodeUI], edges newEdges: [GraphEdgeUI]) {
        simulationTask?.cancel()
        var nodes = newNodes
        var adjacency: [String: [String]] = [:]
        for edge in newEdges {
            adjacency[edge.from, default: []].append(edge.to)
            adjacency[edge.to, default: []].append(edge.from)
        }
        // Initial placement on a circle.
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = min(canvasSize.width, canvasSize.height) * 0.35
        for i in nodes.indices {
            let angle = Double(i) / Double(max(nodes.count, 1)) * 2 * .pi
            nodes[i].position = CGPoint(
                x: center.x + cos(angle) * radius + Double.random(in: -20...20),
                y: center.y + sin(angle) * radius + Double.random(in: -20...20)
            )
            nodes[i].degree = adjacency[nodes[i].id]?.count ?? 0
        }
        self.nodes = nodes
        edges = newEdges
        self.adjacency = adjacency
        index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
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

    private func startSimulation() {
        simulationTask = Task { [weak self] in
            var alpha = 1.0
            while !Task.isCancelled, alpha > 0.005 {
                self?.step(alpha: alpha)
                alpha *= 0.985
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func step(alpha: Double) {
        guard !nodes.isEmpty else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let springLength: Double = 70
        let repulsion: Double = 6000

        // Repulsion (all pairs).
        for i in nodes.indices {
            if nodes[i].id == draggedNode?.id { continue }
            var force = CGVector.zero
            for j in nodes.indices where j != i {
                let delta = CGVector(
                    dx: nodes[i].position.x - nodes[j].position.x,
                    dy: nodes[i].position.y - nodes[j].position.y
                )
                let distanceSquared = max(delta.dx * delta.dx + delta.dy * delta.dy, 100)
                let strength = repulsion / distanceSquared
                let distance = distanceSquared.squareRoot()
                force.dx += delta.dx / distance * strength
                force.dy += delta.dy / distance * strength
            }
            // Centering gravity.
            force.dx += (center.x - nodes[i].position.x) * 0.012
            force.dy += (center.y - nodes[i].position.y) * 0.012
            nodes[i].velocity.dx = (nodes[i].velocity.dx + force.dx * alpha) * 0.6
            nodes[i].velocity.dy = (nodes[i].velocity.dy + force.dy * alpha) * 0.6
        }

        // Springs along edges.
        for edge in edges {
            guard let a = index[edge.from], let b = index[edge.to] else { continue }
            let delta = CGVector(
                dx: nodes[b].position.x - nodes[a].position.x,
                dy: nodes[b].position.y - nodes[a].position.y
            )
            let distance = max((delta.dx * delta.dx + delta.dy * delta.dy).squareRoot(), 1)
            let strength = (distance - springLength) * 0.03 * alpha
            let fx = delta.dx / distance * strength
            let fy = delta.dy / distance * strength
            if nodes[a].id != draggedNode?.id {
                nodes[a].velocity.dx += fx
                nodes[a].velocity.dy += fy
            }
            if nodes[b].id != draggedNode?.id {
                nodes[b].velocity.dx -= fx
                nodes[b].velocity.dy -= fy
            }
        }

        // Integrate.
        for i in nodes.indices where nodes[i].id != draggedNode?.id {
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
            nodes[i].position.x = min(max(nodes[i].position.x, 20), canvasSize.width - 20)
            nodes[i].position.y = min(max(nodes[i].position.y, 20), canvasSize.height - 20)
        }
    }
}

private func graphColor(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }
}
