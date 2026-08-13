import SwiftUI
import UniformTypeIdentifiers

struct UTTypeConformanceEdge: Identifiable, Hashable {
    let childIdentifier: String
    let parentIdentifier: String

    var id: String { childIdentifier + "->" + parentIdentifier }
}

struct RegisteredUTTypeChain: Identifiable {
    let levels: [[String]]
    let id: String
}

enum UTTypeRelationshipAnalyzer {
    static func hierarchyEdges(for identifier: String) -> [UTTypeConformanceEdge] {
        guard let root = UTType(identifier) else { return [] }
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
                    if visited.insert(parent.identifier).inserted { next.append(parent) }
                }
            }
            frontier = next.sorted {
                $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
            }
        }
        return edges
    }

    static func registeredChains(among identifiers: [String]) -> [RegisteredUTTypeChain] {
        let types = identifiers.uniquedPreservingOrder().compactMap(UTType.init)
        guard !types.isEmpty else { return [] }

        let identifiers = Set(types.map(\.identifier))
        let links = nearestRegisteredLinks(among: types)
        let components = connectedComponents(identifiers: identifiers, links: links)
        return components.map { component in
            let componentLinks = links.filter {
                component.contains($0.childIdentifier) && component.contains($0.parentIdentifier)
            }
            return RegisteredUTTypeChain(
                levels: levels(in: component, links: componentLinks),
                id: component.sorted().joined(separator: "|")
            )
        }.sorted {
            ($0.levels.first?.first ?? "").localizedStandardCompare(
                $1.levels.first?.first ?? ""
            ) == .orderedAscending
        }
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
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func connectedComponents(identifiers: Set<String>,
                                            links: [UTTypeConformanceEdge]) -> [Set<String>] {
        var neighbors: [String: Set<String>] = [:]
        for link in links {
            neighbors[link.childIdentifier, default: []].insert(link.parentIdentifier)
            neighbors[link.parentIdentifier, default: []].insert(link.childIdentifier)
        }
        var remaining = identifiers
        var result: [Set<String>] = []
        while let start = remaining.sorted().first {
            var component = Set<String>()
            var frontier = [start]
            while let current = frontier.popLast() {
                guard component.insert(current).inserted else { continue }
                remaining.remove(current)
                frontier.append(contentsOf: neighbors[current, default: []]
                    .filter { !component.contains($0) })
            }
            result.append(component)
        }
        return result
    }

    private static func levels(in identifiers: Set<String>,
                               links: [UTTypeConformanceEdge]) -> [[String]] {
        var remaining = identifiers
        var result: [[String]] = []
        while !remaining.isEmpty {
            let current = remaining.filter { identifier in
                !links.contains {
                    remaining.contains($0.childIdentifier) && $0.parentIdentifier == identifier
                }
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !current.isEmpty else {
                result.append(remaining.sorted())
                break
            }
            result.append(current)
            remaining.subtract(current)
        }
        return result
    }
}

struct RegisteredUTTypeRelationshipsView: View {
    let identifiers: [String]
    var representativeIdentifier: String?

    private var uniqueIdentifiers: [String] {
        identifiers.uniquedPreservingOrder()
    }

    private var chains: [RegisteredUTTypeChain] {
        UTTypeRelationshipAnalyzer.registeredChains(among: uniqueIdentifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.string("注册类型链路（由具体子类型到宽泛上级类型）"))
                .font(.headline)
            if uniqueIdentifiers.count < 2 {
                Text(L10n.string("当前只有一个注册 UTType，无需比较类型之间的关系。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(chains) { chain in
                    chainView(chain)
                }
                if chains.count > 1 {
                    Text(L10n.string("这些链路之间没有直接父子关系。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.string("UTType 遵循关系只表示类型的具体与宽泛层级，不代表 macOS 对该扩展名的识别优先级。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chainView(_ chain: RegisteredUTTypeChain) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(chain.levels.enumerated()), id: \.offset) { index, level in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(level, id: \.self) { identifier in
                        typeLabel(identifier)
                    }
                }
                if index < chain.levels.count - 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                        Text(L10n.string("遵循"))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 10)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func typeLabel(_ identifier: String) -> some View {
        HStack(spacing: 5) {
            Text(identifier)
                .font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if identifier == representativeIdentifier {
                Text(L10n.string("主列表"))
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct UTTypeHierarchyRelationshipsView: View {
    let identifier: String

    private var edges: [UTTypeConformanceEdge] {
        UTTypeRelationshipAnalyzer.hierarchyEdges(for: identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.tint)
                Text(identifier).font(.caption.monospaced()).textSelection(.enabled)
                Text(L10n.string("当前类型"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(edges) { edge in
                HStack(spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(edge.childIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(edge.parentIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                }
                .padding(.leading, 12)
            }
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
