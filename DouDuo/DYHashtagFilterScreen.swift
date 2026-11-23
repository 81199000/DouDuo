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
                        TextField("例如：美食、vlog、旅行", text: $input)
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
                            .accessibilityLabel("添加屏蔽关键词")
                            .accessibilityIdentifier("douyin.hashtags.add")
                    }
                } header: {
                    Text("添加关键词")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let feedback {
                            Text(feedback)
                                .accessibilityIdentifier("douyin.hashtags.feedback")
                        }
                        Text("标题或话题标签里只要含有这个词就屏蔽，例如屏蔽「美食」，#美食推荐、美食探店 也会被屏蔽。每次输入一个词，可省略 #；忽略英文大小写。只过滤推荐页，搜索、关注和作者作品不受影响。")
                    }
                }
                if !currentTags.isEmpty {
                    Section("当前视频的标签（点一下加为关键词）") {
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
                        Text("尚未屏蔽任何关键词").foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(filter.tags, id: \.self) { tag in
                                Button {
                                    var updated = filter
                                    updated.remove(tag)
                                    rawValue = updated.rawValue
                                    feedback = nil
                                } label: {
                                    tagChip(tag, symbol: "xmark.circle.fill", hash: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("取消屏蔽 " + tag)
                            }
                        }
                    }
                } header: {
                    Text("已屏蔽（\(filter.tags.count)）")
                } footer: {
                    Text("添加后立即生效，并保存在本机。点按已屏蔽的关键词可取消屏蔽，相关视频可再次出现在新推荐中。")
                }
            }
            .navigationTitle("按关键词屏蔽视频")
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

    private func tagChip(_ tag: String, symbol: String, selected: Bool = false, hash: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(hash ? "#" + tag : tag)
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
            feedback = "已添加，推荐页将屏蔽标题或标签含此词的视频"
        case .duplicate:
            feedback = "这个词已在屏蔽列表中"
        case .invalid:
            feedback = "请输入一个有效的词，不要只输入 # 或一次输入多个词"
        }
    }
}
