import SwiftUI
import UniformTypeIdentifiers

struct UTTypeConformanceEdge: Identifiable, Hashable {
    let childIdentifier: String
    let parentIdentifier: String

    var id: String { childIdentifier + "->" + parentIdentifier }
}

struct UTTypeRelationshipGraph {
    let nodes: [String]
    let edges: [UTTypeConformanceEdge]
    let levels: [[String]]
    let pathCount: Int
    let componentCount: Int

    init(nodes: [String], edges: [UTTypeConformanceEdge]) {
        let uniqueNodes = nodes.uniquedPreservingOrder()
        let nodeIdentifiers = Set(uniqueNodes)
        let uniqueEdges = edges.filter {
            $0.childIdentifier != $0.parentIdentifier
                && nodeIdentifiers.contains($0.childIdentifier)
                && nodeIdentifiers.contains($0.parentIdentifier)
        }.uniquedPreservingOrder().sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }

        self.nodes = uniqueNodes
        self.edges = uniqueEdges
        levels = Self.makeLevels(nodes: uniqueNodes, edges: uniqueEdges)
        pathCount = Self.countPaths(nodes: uniqueNodes, edges: uniqueEdges, levels: levels)
        componentCount = Self.countComponents(nodes: uniqueNodes, edges: uniqueEdges)
    }

    private static func makeLevels(nodes: [String],
                                   edges: [UTTypeConformanceEdge]) -> [[String]] {
        let identifiers = Set(nodes)
        var incomingCounts = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        var parentsByChild: [String: [String]] = [:]
        for edge in edges {
            incomingCounts[edge.parentIdentifier, default: 0] += 1
            parentsByChild[edge.childIdentifier, default: []].append(edge.parentIdentifier)
        }

        var depth = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        var frontier = incomingCounts.filter { $0.value == 0 }.map(\.key).sorted()
        var visited = Set<String>()
        while !frontier.isEmpty {
            let identifier = frontier.removeFirst()
            guard visited.insert(identifier).inserted else { continue }
            for parent in parentsByChild[identifier, default: []] {
                depth[parent] = max(depth[parent, default: 0], depth[identifier, default: 0] + 1)
                incomingCounts[parent, default: 0] -= 1
                if incomingCounts[parent] == 0 {
                    frontier.append(parent)
                    frontier.sort()
                }
            }
        }

        // UTType conformance should be acyclic. Keep unexpected cyclic declarations visible
        // in a final level rather than looping forever or silently dropping their nodes.
        let remaining = identifiers.subtracting(visited)
        if !remaining.isEmpty {
            let finalDepth = (depth.values.max() ?? -1) + 1
            for identifier in remaining { depth[identifier] = finalDepth }
        }

        let initialLevels = Dictionary(grouping: nodes, by: { depth[$0, default: 0] })
            .sorted { $0.key < $1.key }
            .map { entry in
                entry.value.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            }
        return minimizeCrossings(in: initialLevels, edges: edges)
    }

    private static func minimizeCrossings(in initialLevels: [[String]],
                                          edges: [UTTypeConformanceEdge]) -> [[String]] {
        guard initialLevels.count > 1 else { return initialLevels }
        var levels = initialLevels

        // Alternating barycenter sweeps keep the layout deterministic while moving
        // connected nodes toward the same vertical order on neighboring levels.
        for _ in 0..<4 {
            for levelIndex in 1..<levels.count {
                levels[levelIndex] = reordered(
                    levels[levelIndex],
                    neighbors: { identifier in
                        edges.filter { $0.parentIdentifier == identifier }
                            .map(\.childIdentifier)
                    },
                    levels: levels
                )
            }
            for levelIndex in stride(from: levels.count - 2, through: 0, by: -1) {
                levels[levelIndex] = reordered(
                    levels[levelIndex],
                    neighbors: { identifier in
                        edges.filter { $0.childIdentifier == identifier }
                            .map(\.parentIdentifier)
                    },
                    levels: levels
                )
            }
        }
        return levels
    }

    private static func reordered(_ level: [String],
                                  neighbors: (String) -> [String],
                                  levels: [[String]]) -> [String] {
        let positions = normalizedPositions(in: levels)
        let previousOrder = Dictionary(uniqueKeysWithValues:
            level.enumerated().map { ($0.element, $0.offset) })
        let scores = Dictionary(uniqueKeysWithValues: level.map { identifier in
            let neighborPositions = neighbors(identifier).compactMap { positions[$0] }
            let score = neighborPositions.isEmpty
                ? nil
                : neighborPositions.reduce(0, +) / Double(neighborPositions.count)
            return (identifier, score)
        })

        return level.sorted { lhs, rhs in
            switch (scores[lhs] ?? nil, scores[rhs] ?? nil) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return previousOrder[lhs, default: 0] < previousOrder[rhs, default: 0]
            }
        }
    }

    private static func normalizedPositions(in levels: [[String]]) -> [String: Double] {
        var positions: [String: Double] = [:]
        for level in levels {
            for (index, identifier) in level.enumerated() {
                positions[identifier] = level.count == 1
                    ? 0.5
                    : Double(index) / Double(level.count - 1)
            }
        }
        return positions
    }

    private static func countPaths(nodes: [String],
                                   edges: [UTTypeConformanceEdge],
                                   levels: [[String]]) -> Int {
        guard !nodes.isEmpty else { return 0 }
        let parentsByChild = Dictionary(grouping: edges, by: \.childIdentifier)
            .mapValues { $0.map(\.parentIdentifier) }
        let identifiersWithChildren = Set(edges.map(\.parentIdentifier))
        let sources = nodes.filter { !identifiersWithChildren.contains($0) }
        var pathsFromNode: [String: Int] = [:]

        for identifier in levels.reversed().flatMap({ $0 }) {
            let parents = parentsByChild[identifier, default: []]
            pathsFromNode[identifier] = parents.isEmpty
                ? 1
                : parents.reduce(0) { saturatedAdd($0, pathsFromNode[$1, default: 1]) }
        }
        return sources.reduce(0) { saturatedAdd($0, pathsFromNode[$1, default: 1]) }
    }

    private static func countComponents(nodes: [String],
                                        edges: [UTTypeConformanceEdge]) -> Int {
        var neighbors: [String: Set<String>] = [:]
        for edge in edges {
            neighbors[edge.childIdentifier, default: []].insert(edge.parentIdentifier)
            neighbors[edge.parentIdentifier, default: []].insert(edge.childIdentifier)
        }
        var remaining = Set(nodes)
        var result = 0
        while let start = remaining.first {
            result += 1
            var frontier = [start]
            while let identifier = frontier.popLast() {
                guard remaining.remove(identifier) != nil else { continue }
                frontier.append(contentsOf: neighbors[identifier, default: []])
            }
        }
        return result
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

enum UTTypeRelationshipAnalyzer {
    static func hierarchyGraph(for identifier: String) -> UTTypeRelationshipGraph {
        guard let root = UTType(identifier) else {
            return UTTypeRelationshipGraph(nodes: [], edges: [])
        }
        var nodes = [root.identifier]
        var edges: [UTTypeConformanceEdge] = []
        var seenEdges = Set<String>()
        var visited = Set([root.identifier])
        var frontier = [root]

        while !frontier.isEmpty {
            var next: [UTType] = []
            for child in frontier {
                for parent in directParents(of: child) {
                    let edge = UTTypeConformanceEdge(childIdentifier: child.identifier,
                                                     parentIdentifier: parent.identifier)
                    if seenEdges.insert(edge.id).inserted { edges.append(edge) }
                    if visited.insert(parent.identifier).inserted {
                        nodes.append(parent.identifier)
                        next.append(parent)
                    }
                }
            }
            frontier = next.sorted {
                $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
            }
        }
        return UTTypeRelationshipGraph(nodes: nodes, edges: edges)
    }

    static func registeredGraph(among identifiers: [String]) -> UTTypeRelationshipGraph {
        let types = identifiers.uniquedPreservingOrder().compactMap(UTType.init)
        return UTTypeRelationshipGraph(
            nodes: types.map(\.identifier),
            edges: nearestRegisteredLinks(among: types)
        )
    }

    private static func directParents(of type: UTType) -> [UTType] {
        let all = Array(type.supertypes)
        return all.filter { candidate in
            !all.contains { other in
                other != candidate && other.conforms(to: candidate)
            }
        }.sorted {
            $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
        }
    }

    private static func nearestRegisteredLinks(among types: [UTType]) -> [UTTypeConformanceEdge] {
        types.flatMap { child in
            let parentCandidates = types.filter {
                $0 != child && child.conforms(to: $0)
            }
            return parentCandidates.filter { candidate in
                !parentCandidates.contains { intermediate in
                    intermediate != candidate && intermediate.conforms(to: candidate)
                }
            }.map {
                UTTypeConformanceEdge(childIdentifier: child.identifier,
                                      parentIdentifier: $0.identifier)
            }
        }
    }
}

struct RegisteredUTTypeRelationshipsView: View {
    let identifiers: [String]
    var representativeIdentifier: String?

    private var uniqueIdentifiers: [String] {
        identifiers.uniquedPreservingOrder()
    }

    private var graph: UTTypeRelationshipGraph {
        UTTypeRelationshipAnalyzer.registeredGraph(among: uniqueIdentifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.string("注册类型关系（由具体到宽泛）"))
                .font(.headline)
            if uniqueIdentifiers.count < 2 {
                Text(L10n.string("当前只有一个注册 UTType，无需比较类型之间的关系。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                UTTypeRelationshipGraphView(
                    graph: graph,
                    highlightedIdentifier: representativeIdentifier,
                    highlightedLabel: representativeIdentifier == nil ? nil : L10n.string("主列表")
                )
                if graph.componentCount > 1 {
                    Text(L10n.string("这些关系组之间没有直接父子关系。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.string("UTType 遵循关系只表示类型的具体与宽泛层级，不代表 macOS 对该扩展名的识别优先级。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UTTypeHierarchyRelationshipsView: View {
    let identifier: String

    private var graph: UTTypeRelationshipGraph {
        UTTypeRelationshipAnalyzer.hierarchyGraph(for: identifier)
    }

    var body: some View {
        UTTypeRelationshipGraphView(
            graph: graph,
            highlightedIdentifier: identifier,
            highlightedLabel: L10n.string("当前类型")
        )
    }
}

private struct UTTypeRelationshipGraphView: View {
    let graph: UTTypeRelationshipGraph
    let highlightedIdentifier: String?
    let highlightedLabel: String?
    @State private var showsEdges = false

    private var layout: UTTypeGraphLayout {
        UTTypeGraphLayout(graph: graph,
                          highlightedIdentifier: highlightedIdentifier,
                          hasHighlightedLabel: highlightedLabel != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.format("uttype.relationshipSummary",
                             graph.pathCount, graph.nodes.count, graph.edges.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            if graph.nodes.isEmpty {
                Text(L10n.string("没有可显示的 UTType 关系。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    graphCanvas(layout)
                }
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsEdges.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showsEdges ? 90 : 0))
                        Text(L10n.string("直接关系明细"))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)

                if showsEdges {
                    VStack(alignment: .leading, spacing: 5) {
                        if graph.edges.isEmpty {
                            Text(L10n.string("这些类型之间没有直接父子关系。"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(graph.edges) { edge in
                                HStack(spacing: 7) {
                                    Text(edge.childIdentifier)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    Text(edge.parentIdentifier)
                                }
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.leading, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func graphCanvas(_ layout: UTTypeGraphLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in graph.edges {
                    guard let child = layout.frames[edge.childIdentifier],
                          let parent = layout.frames[edge.parentIdentifier] else { continue }
                    draw(edgeFrom: CGPoint(x: child.maxX, y: child.midY),
                         to: CGPoint(x: parent.minX, y: parent.midY),
                         in: &context)
                }
            }
            .accessibilityHidden(true)

            ForEach(graph.nodes, id: \.self) { identifier in
                if let frame = layout.frames[identifier] {
                    graphNode(identifier, width: frame.width)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func graphNode(_ identifier: String, width: CGFloat) -> some View {
        let isHighlighted = identifier == highlightedIdentifier
        return HStack(spacing: 6) {
            Circle()
                .fill(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.65))
                .frame(width: 7, height: 7)
            Text(identifier)
                .font(.caption.monospaced())
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            if isHighlighted, let highlightedLabel {
                Text(highlightedLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: UTTypeGraphLayout.nodeHeight, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.65)
                        : Color.secondary.opacity(0.24))
        }
        .accessibilityElement(children: .combine)
    }

    private func draw(edgeFrom start: CGPoint, to end: CGPoint,
                      in context: inout GraphicsContext) {
        let arrowLength: CGFloat = 7
        let arrowHalfHeight: CGFloat = 4
        let lineEnd = CGPoint(x: end.x - arrowLength, y: end.y)
        let controlOffset = max((lineEnd.x - start.x) * 0.5, 18)
        var line = Path()
        line.move(to: start)
        line.addCurve(to: lineEnd,
                      control1: CGPoint(x: start.x + controlOffset, y: start.y),
                      control2: CGPoint(x: lineEnd.x - controlOffset, y: lineEnd.y))
        context.stroke(line, with: .color(Color.secondary.opacity(0.58)),
                       style: StrokeStyle(lineWidth: 1.25, lineCap: .round))

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - arrowLength, y: end.y - arrowHalfHeight))
        arrow.addLine(to: CGPoint(x: end.x - arrowLength, y: end.y + arrowHalfHeight))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Color.secondary.opacity(0.72)))
    }
}

private struct UTTypeGraphLayout {
    static let nodeHeight: CGFloat = 36
    private static let horizontalGap: CGFloat = 72
    private static let verticalGap: CGFloat = 14
    private static let inset: CGFloat = 10

    let frames: [String: CGRect]
    let size: CGSize

    init(graph: UTTypeRelationshipGraph,
         highlightedIdentifier: String?,
         hasHighlightedLabel: Bool) {
        let maximumRows = max(graph.levels.map(\.count).max() ?? 0, 1)
        let contentHeight = CGFloat(maximumRows) * Self.nodeHeight
            + CGFloat(maximumRows - 1) * Self.verticalGap
        var x = Self.inset
        var frames: [String: CGRect] = [:]

        for level in graph.levels {
            let width = level.reduce(CGFloat(210)) { current, identifier in
                let labelReserve: CGFloat = identifier == highlightedIdentifier && hasHighlightedLabel
                    ? 86 : 0
                return max(current, CGFloat(identifier.count) * 7.2 + 38 + labelReserve)
            }
            let levelHeight = CGFloat(level.count) * Self.nodeHeight
                + CGFloat(max(level.count - 1, 0)) * Self.verticalGap
            var y = Self.inset + (contentHeight - levelHeight) / 2
            for identifier in level {
                frames[identifier] = CGRect(x: x, y: y, width: width, height: Self.nodeHeight)
                y += Self.nodeHeight + Self.verticalGap
            }
            x += width + Self.horizontalGap
        }

        self.frames = frames
        size = CGSize(
            width: max(x - Self.horizontalGap + Self.inset, 0),
            height: contentHeight + Self.inset * 2
        )
    }
}

private extension Sequence where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
