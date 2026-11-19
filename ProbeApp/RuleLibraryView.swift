import SwiftUI

struct RuleLibraryView: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var draft: LibraryRuleDraft?
    @State private var rules: [ProfileRule] = []
    @State private var search = ""
    @State private var grouping = RuleGrouping.target
    @State private var expandedGroups = Set<String>()
    @State private var editMode = EditMode.inactive
    @State private var editor: RuleEditRequest?
    @State private var status = ""
    @State private var loading = true
    @State private var saving = false

    private var changed: Bool { draft.map { $0.document.rules.map(\.raw) != rules.map(\.raw) } ?? false }
    private var editable: Bool { draft != nil && draft?.document.readOnlyReason == nil && !saving && !model.busy }
    private var matches: [ProfileRule] {
        rules.filter { search.isEmpty || $0.raw.localizedCaseInsensitiveContains(search) }
    }
    private var groups: [(name: String, rules: [ProfileRule])] {
        Dictionary(grouping: rules) { grouping == .target ? $0.target : $0.type }
            .map { (name: $0.key, rules: $0.value) }
            .sorted { lhs, rhs in
                if lhs.rules.count != rhs.rules.count { return lhs.rules.count > rhs.rules.count }
                return lhs.name < rhs.name
            }
    }

    var body: some View {
        List {
            if loading { ProgressView("读取规则…") }
            if let draft {
                Section {
                    LabeledContent(draft.profile.displayName, value: "\(rules.count) 条规则")
                    if let reason = draft.document.readOnlyReason {
                        Label(reason, systemImage: "lock").font(.footnote).foregroundStyle(.secondary)
                    }
                    if changed { Label("有未保存的规则修改", systemImage: "pencil.circle").font(.footnote) }
                }
                Section {
                    TextField("搜索条件、策略或规则类型", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("rules-search")
                    Picker("分组", selection: $grouping) {
                        ForEach(RuleGrouping.allCases) { Text($0.rawValue).tag($0) }
                    }.accessibilityIdentifier("rules-grouping")
                }
                if !search.isEmpty {
                    Section("搜索结果") { ruleRows(matches) }
                } else if grouping == .original {
                    Section("规则顺序") { ruleRows(rules) }
                } else {
                    Section {
                        ForEach(groups, id: \.name) { group in
                            let expanded = expandedGroups.contains(group.name)
                            Button {
                                if expanded { expandedGroups.remove(group.name) }
                                else { expandedGroups.insert(group.name) }
                            } label: {
                                HStack {
                                    Text(group.name)
                                    Spacer()
                                    Text("\(group.rules.count)").foregroundStyle(.secondary).monospacedDigit()
                                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                                        .font(.footnote).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(group.name)
                            .accessibilityValue("\(group.rules.count) 条规则，" + (expanded ? "已展开" : "已收起"))
                            .accessibilityIdentifier("rule-group-" + group.name)
                            if expanded { ruleRows(group.rules) }
                        }
                    }
                }
                if matches.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "暂无规则" : "没有匹配的规则", systemImage: "list.bullet.rectangle")
                        .accessibilityIdentifier("rules-empty")
                }
            } else if !loading {
                ContentUnavailableView("无法读取规则", systemImage: "list.bullet.rectangle", description: Text(status))
            }
            if !status.isEmpty {
                Text(status).font(.footnote).textSelection(.enabled).accessibilityIdentifier("rules-status")
            }
        }
        .navigationTitle("规则")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(changed)
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if changed {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回", systemImage: "chevron.left") { confirmingDiscard = true }
                        .disabled(saving).accessibilityIdentifier("rules-back")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成排序" : "排序") {
                    if !editMode.isEditing { grouping = .original; search = "" }
                    editMode = editMode.isEditing ? .inactive : .active
                }.disabled(!editable || rules.isEmpty).accessibilityIdentifier("rules-edit-order")
                Button("添加规则", systemImage: "plus") { editor = RuleEditRequest(rule: nil) }
                    .disabled(!editable).accessibilityIdentifier("rules-add")
                Button("保存") { Task { await save() } }
                    .disabled(!editable || !changed).accessibilityIdentifier("rules-save")
            }
        }
        .confirmationDialog("放弃未保存的规则修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }.accessibilityIdentifier("rules-discard")
            Button("继续编辑", role: .cancel) {}.accessibilityIdentifier("rules-stay")
        }
        .sheet(item: $editor) { request in
            RuleEditorView(rule: request.rule, policies: draft?.document.policyChoices ?? []) { edited in
                if let index = rules.firstIndex(where: { $0.id == edited.id }) { rules[index] = edited }
                else { rules.insert(edited, at: rules.firstIndex(where: { $0.type == "MATCH" }) ?? rules.endIndex) }
            }
        }
        .task(id: model.selectedID) { expandedGroups.removeAll(); await load() }
        .onChange(of: grouping) { _, value in
            expandedGroups.removeAll()
            if value != .original { editMode = .inactive }
        }
        .onChange(of: search) { _, value in if !value.isEmpty { editMode = .inactive } }
    }

    private func ruleRows(_ visible: [ProfileRule]) -> some View {
        ForEach(visible) { rule in ruleRow(rule) }
            .onDelete { offsets in
                let ids = Set(offsets.map { visible[$0].id })
                rules.removeAll { ids.contains($0.id) }
            }
            .onMove { source, destination in rules.move(fromOffsets: source, toOffset: destination) }
            .deleteDisabled(!editable)
            .moveDisabled(!editable || grouping != .original || !search.isEmpty)
    }

    private func ruleRow(_ rule: ProfileRule) -> some View {
        let index = rules.firstIndex(where: { $0.id == rule.id }) ?? 0
        return Button { editor = RuleEditRequest(rule: rule) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(index + 1). \(rule.type)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(rule.target).font(.caption).foregroundStyle(.blue).lineLimit(1)
                }
                Text(rule.payload.isEmpty ? "匹配剩余请求" : rule.payload).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if !rule.options.isEmpty { Text(rule.options.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!editable || editMode.isEditing)
        .accessibilityIdentifier("rule-row-\(index)")
    }

    @MainActor private func load() async {
        loading = true
        draft = nil
        rules = []
        status = ""
        defer { loading = false }
        do {
            let loaded = try await model.loadRules()
            draft = loaded
            rules = loaded.document.rules
        } catch is CancellationError {} catch { status = error.localizedDescription }
    }

    @MainActor private func save() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        if await model.saveRules(rules, draft: draft) {
            await load()
            status = "规则已保存"
            editMode = .inactive
        } else { status = model.message }
    }
}

private enum RuleGrouping: String, CaseIterable, Identifiable {
    case original = "原顺序", target = "按策略", type = "按类型"
    var id: Self { self }
}

private struct RuleEditRequest: Identifiable {
    let id = UUID()
    let rule: ProfileRule?
}

private extension ProfileRuleFields.Kind {
    var title: String {
        switch self {
        case .domain: "完整域名"
        case .suffix: "域名后缀"
        case .keyword: "域名关键词"
        case .cidr: "IP 网段"
        case .cidr6: "IPv6 网段"
        case .geoIP: "IP 地区"
        case .geoSite: "域名集合"
        case .destinationPort: "目标端口"
        case .ruleSet: "规则集"
        case .match: "其余请求"
        }
    }

    var prompt: String {
        switch self {
        case .domain, .suffix: "example.com"
        case .keyword: "example"
        case .cidr: "192.0.2.0/24"
        case .cidr6: "2001:db8::/32"
        case .geoIP: "CN"
        case .geoSite: "geolocation-cn"
        case .destinationPort: "443"
        case .ruleSet: "规则集名称"
        case .match: ""
        }
    }
}

private struct RuleEditorView: View {
    let rule: ProfileRule?
    let policies: [String]
    let save: (ProfileRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: ProfileRuleFields
    @State private var raw: String
    @State private var editingRaw: Bool
    @State private var error = ""

    init(rule: ProfileRule?, policies: [String], save: @escaping (ProfileRule) -> Void) {
        self.rule = rule
        self.policies = policies
        self.save = save
        let parsed = rule.flatMap(ProfileRuleFields.init)
        _fields = State(initialValue: parsed ?? ProfileRuleFields())
        _raw = State(initialValue: rule?.raw ?? "")
        _editingRaw = State(initialValue: rule != nil && parsed == nil)
    }

    private var parsedFields: ProfileRuleFields? {
        guard let parsed = try? ProfileRule(raw: raw) else { return nil }
        return ProfileRuleFields(parsed)
    }

    var body: some View {
        NavigationStack {
            Form {
                if editingRaw {
                    Section("规则原文") {
                        TextEditor(text: $raw).font(.body.monospaced()).frame(minHeight: 140)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("rule-editor-raw")
                    }
                    if let parsed = parsedFields {
                        Button("按字段编辑") {
                            fields = parsed
                            editingRaw = false
                            error = ""
                        }
                    }
                } else {
                    Section {
                        Picker("规则类型", selection: $fields.type) {
                            ForEach(ProfileRuleFields.Kind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }.accessibilityIdentifier("rule-editor-type")
                        if fields.type != .match {
                            LabeledContent("匹配条件") {
                                TextField(fields.type.prompt, text: $fields.payload)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel("匹配条件").accessibilityIdentifier("rule-editor-condition")
                            }
                        }
                        Picker("策略", selection: $fields.target) {
                            ForEach(policies.contains(fields.target) ? policies : policies + [fields.target], id: \.self) {
                                Text($0).tag($0)
                            }
                        }.accessibilityIdentifier("rule-editor-target")
                        if fields.type.supportsNoResolve {
                            Toggle("跳过域名解析", isOn: $fields.noResolve)
                        }
                    }
                    Section {
                        Button("编辑原文") {
                            if fields != parsedFields { raw = fields.raw }
                            editingRaw = true
                            error = ""
                        }.accessibilityIdentifier("rule-editor-show-raw")
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("rule-editor-error") }
            }
            .navigationTitle(rule == nil ? "添加规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("rule-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        do {
                            let edited = editingRaw
                                ? try ProfileRule(raw: raw, id: rule?.id ?? UUID())
                                : try fields.rule(replacing: rule)
                            save(edited)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(editingRaw ? raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty :
                              fields.type != .match && fields.payload.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("rule-editor-save")
                }
            }
        }
    }
}
