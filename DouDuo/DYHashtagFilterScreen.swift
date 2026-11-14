import SwiftUI

struct DYHashtagFilterScreen: View {
    let currentTags: [String]
    /// 从设置页推进来时不再包一层 NavigationStack，也不显示「完成」
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DYHashtagFilter.storageKey) private var rawValue = ""
    @State private var input = ""
    @State private var feedback: String?
    private var filter: DYHashtagFilter { DYHashtagFilter(rawValue: rawValue) }

    var body: some View {
        if embedded { form } else { NavigationStack { form } }
    }

    private var form: some View {
            Form {
                Section {
                    HStack(spacing: 12) {
                        TextField("例如：美食或 #美食", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { add(input) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("douyin.hashtags.input")
                        Button("添加") { add(input) }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .frame(minWidth: 44, minHeight: 44)
                            .fixedSize()
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("添加屏蔽标签")
                            .accessibilityIdentifier("douyin.hashtags.add")
                    }
                } header: {
                    Text("添加标签")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let feedback {
                            Text(feedback)
                                .accessibilityIdentifier("douyin.hashtags.feedback")
                        }
                        Text("每次输入一个完整标签，可省略 #。只过滤推荐页，忽略英文字母大小写；搜索、关注和作者作品不受影响。")
                    }
                }
                if !currentTags.isEmpty {
                    Section("当前视频的标签") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(currentTags, id: \.self) { tag in
                                    Button {
                                        add(tag)
                                    } label: {
                                        tagChip(tag, symbol: filter.contains(tag) ? "checkmark" : "plus",
                                                selected: filter.contains(tag))
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(filter.contains(tag))
                                    .accessibilityLabel(filter.contains(tag) ? "已屏蔽 #" + tag : "屏蔽 #" + tag)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .accessibilityIdentifier("douyin.hashtags.current")
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    if filter.tags.isEmpty {
                        Text("尚未屏蔽任何标签").foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(filter.tags, id: \.self) { tag in
                                Button {
                                    var updated = filter
                                    updated.remove(tag)
                                    rawValue = updated.rawValue
                                    feedback = nil
                                } label: {
                                    tagChip(tag, symbol: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("取消屏蔽 #" + tag)
                            }
                        }
                    }
                } header: {
                    Text("已屏蔽（\(filter.tags.count)）")
                } footer: {
                    Text("添加后立即生效，并保存在本机。点按已屏蔽标签可取消屏蔽，相关视频可再次出现在新推荐中。")
                }
            }
            .navigationTitle("按标签过滤视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .accessibilityIdentifier("douyin.hashtags.done")
                    }
                }
            }
    }

    private func tagChip(_ tag: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text("#" + tag)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(.primary.opacity(selected ? 0.03 : 0.07),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func add(_ value: String) {
        var updated = filter
        switch updated.add(value) {
        case .added:
            rawValue = updated.rawValue
            input = ""
            feedback = "已添加，推荐页将过滤含此标签的视频"
        case .duplicate:
            feedback = "该标签已在屏蔽列表中"
        case .invalid:
            feedback = "请输入一个有效标签，不要只输入 # 或一次输入多个标签"
        }
    }
}
