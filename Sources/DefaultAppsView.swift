import SwiftUI

struct DefaultAppsView: View {
    @EnvironmentObject private var store: AssociationStore
    @State private var presentedCategory: DefaultAppCategory?
    @State private var refreshID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认 App").font(.title2.weight(.semibold))
                    Text("一次设置一组常用文件格式或网页链接的默认应用")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider().opacity(0.45)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(DefaultAppCategory.all) { category in
                        DefaultAppCategoryCard(category: category) {
                            presentedCategory = category
                        }
                        .environmentObject(store)
                    }
                }
                .id(refreshID)
                .padding(22)
            }
        }
        .sheet(item: $presentedCategory) { category in
            DefaultAppPickerSheet(category: category) {
                refreshID = UUID()
            }
            .environmentObject(store)
        }
    }
}

private struct DefaultAppCategoryCard: View {
    @EnvironmentObject private var store: AssociationStore
    let category: DefaultAppCategory
    let changeAction: () -> Void

    private var status: DefaultAppCategoryStatus {
        store.defaultAppStatus(for: category)
    }

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: category.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                Text(category.title).font(.headline)
                Text(category.subtitle).font(.caption).foregroundStyle(.secondary)
                currentLabel
            }
            Spacer(minLength: 12)
            Button("更改…", action: changeAction).buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08))
        }
    }

    @ViewBuilder private var currentLabel: some View {
        if status.isUnified, let app = status.unifiedApplication {
            HStack(spacing: 6) {
                AppIcon(url: app.url, size: 20)
                Text(app.name).lineLimit(1)
                Text("当前默认").foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("尚未统一", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                ForEach(status.assignments.prefix(2)) { assignment in
                    Text("\(assignment.application.name)：\(assignment.targets.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if status.assignments.count > 2 {
                    Text("另有 \(status.assignments.count - 2) 个 App…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !status.missingTargets.isEmpty {
                    Text("未设置：\(status.missingTargets.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct DefaultAppPickerSheet: View {
    @EnvironmentObject private var store: AssociationStore
    @Environment(\.dismiss) private var dismiss
    let category: DefaultAppCategory
    let didChange: () -> Void
    @State private var includesOptional = false
    @State private var candidates: [DefaultAppCandidate] = []
    @State private var selectedCandidateID: DefaultAppCandidate.ID?
    @State private var customApplicationURL: URL?
    @State private var isApplying = false
    @State private var resultMessage: String?
    @State private var progressText: String?
    @State private var validationMessage: String?

    private var selectedCandidate: DefaultAppCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    private var currentStatus: DefaultAppCategoryStatus {
        store.defaultAppStatus(for: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.system(size: 25)).foregroundStyle(.tint).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title).font(.title2.weight(.semibold))
                    Text(targetDescription).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("当前状态：").foregroundStyle(.secondary)
                    if let app = currentStatus.unifiedApplication {
                        AppIcon(url: app.url, size: 20)
                        Text(app.name).fontWeight(.medium)
                    } else {
                        Text("尚未统一").fontWeight(.medium).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                if !currentStatus.isUnified {
                    ForEach(currentStatus.assignments) { assignment in
                        Text("\(assignment.application.name)：\(assignment.targets.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !currentStatus.missingTargets.isEmpty {
                        Text("未设置：\(currentStatus.missingTargets.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)

            if category.hasOptionalExtensions {
                Divider()
                Toggle(isOn: $includesOptional) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.urlSchemes.isEmpty ? "包括扩展格式" : "同时设置本地网页文件")
                        Text(optionalDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .onChange(of: includesOptional) { _, _ in reloadCandidates() }
            }

            Divider()
            if candidates.isEmpty {
                ContentUnavailableView("没有找到可用的应用", systemImage: "app.badge.checkmark",
                                       description: Text("系统没有注册能够处理这些类型的应用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { candidate in
                    Button {
                        selectedCandidateID = candidate.id
                        resultMessage = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedCandidateID == candidate.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedCandidateID == candidate.id
                                                 ? Color.accentColor : Color.secondary)
                            AppIcon(url: candidate.application.url, size: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.application.name).foregroundStyle(.primary)
                                Text(candidate.application.bundleIdentifier)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if !candidate.currentTargets.isEmpty && !candidate.isCurrentDefault {
                                    Text("当前负责：\(candidate.currentTargets.joined(separator: "、"))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if candidate.isCurrentDefault {
                                    Label("当前默认", systemImage: "checkmark.circle.fill")
                                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                                }
                                Text("支持 \(candidate.supportedCount)/\(candidate.totalCount)")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying)
                }
                .scrollContentBackground(.hidden)
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let candidate = selectedCandidate {
                    Text("将 \(candidate.application.name) 设为\(category.title)")
                        .font(.headline)
                    Text("将修改：\(candidate.supportedTargets.joined(separator: "、"))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    let estimatedChanges = candidate.supportedTargets.filter {
                        !candidate.currentTargets.contains($0)
                    }.count
                    Text("预计需要修改 \(estimatedChanges) 项；macOS 可能逐项询问确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !candidate.unsupportedTargets.isEmpty {
                        Text("不会修改（应用未声明支持）：\(candidate.unsupportedTargets.joined(separator: "、"))")
                            .font(.callout).foregroundStyle(.orange).lineLimit(2)
                    }
                } else {
                    Text("请先选择一个应用。点击应用不会立即修改系统设置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let resultMessage {
                    Text(resultMessage).font(.callout.weight(.medium)).foregroundStyle(.green)
                }
                if let progressText {
                    Text(progressText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        chooseOtherApplication()
                    } label: {
                        Label("选择其他 App…", systemImage: "folder")
                    }
                    .disabled(isApplying)
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isApplying)
                    Button {
                        applySelection()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                            Text("正在设置…")
                        } else {
                            Text("设为\(category.title)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCandidate == nil || isApplying)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .onAppear { reloadCandidates() }
        .alert("无法使用所选 App", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var targetDescription: String {
        if !category.urlSchemes.isEmpty { return "处理 HTTP 和 HTTPS 网页链接" }
        return category.coreExtensions.map { "." + $0 }.joined(separator: "、")
    }

    private var optionalDescription: String {
        category.optionalExtensions.map { "." + $0 }.joined(separator: "、")
    }

    private func reloadCandidates() {
        candidates = store.defaultAppCandidates(for: category, includingOptional: includesOptional)
        if let customApplicationURL {
            do {
                let candidate = try store.validatedDefaultAppCandidate(
                    at: customApplicationURL,
                    for: category,
                    includingOptional: includesOptional
                )
                insertCustomCandidate(candidate)
            } catch {
                self.customApplicationURL = nil
            }
        }
        if let selectedCandidateID,
           !candidates.contains(where: { $0.id == selectedCandidateID }) {
            self.selectedCandidateID = nil
        }
    }

    private func chooseOtherApplication() {
        guard let url = chooseApplicationURL() else { return }
        do {
            let candidate = try store.validatedDefaultAppCandidate(
                at: url,
                for: category,
                includingOptional: includesOptional
            )
            customApplicationURL = url
            insertCustomCandidate(candidate)
            selectedCandidateID = candidate.id
            resultMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func insertCustomCandidate(_ candidate: DefaultAppCandidate) {
        candidates.removeAll { $0.id == candidate.id }
        candidates.append(candidate)
        candidates.sort {
            if $0.supportedCount != $1.supportedCount {
                return $0.supportedCount > $1.supportedCount
            }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }

    private func applySelection() {
        guard let candidate = selectedCandidate else { return }
        isApplying = true
        resultMessage = nil
        progressText = nil
        Task { @MainActor in
            await Task.yield()
            if let result = await store.setDefault(candidate.application, for: category,
                                                   includingOptional: includesOptional,
                                                   progress: { current, total, target in
                progressText = "正在设置 \(current)/\(total)：\(target)"
            }) {
                didChange()
                let skipped = result.skippedTargets.isEmpty
                    ? "" : "；跳过：\(result.skippedTargets.joined(separator: "、"))"
                let unchanged = result.unchangedTargets.isEmpty
                    ? "" : "；无需修改 \(result.unchangedTargets.count) 项"
                resultMessage = "已修改 \(result.changedTargets.count) 项\(unchanged)\(skipped)"
                progressText = nil
                try? await Task.sleep(for: .milliseconds(850))
                dismiss()
            } else {
                isApplying = false
            }
        }
    }
}
