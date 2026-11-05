import SwiftUI
import AppKit

struct CollectionPopover: NSViewRepresentable {
    @ObservedObject var model: WorkbenchModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ anchor: NSView, context: Context) { context.coordinator.update(anchor) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        let model: WorkbenchModel
        let popover = NSPopover()
        let host: NSHostingController<SkinRoot<CollectionMenuView>>
        var monitor: Any?
        weak var anchor: NSView?
        init(_ model: WorkbenchModel) {
            self.model = model; host = NSHostingController(rootView: SkinRoot(preferences: model.preferences) { CollectionMenuView(model: model) })
            super.init()
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host; popover.behavior = .applicationDefined; popover.delegate = self
            // Closing must finish before the anchored button can reopen the menu.
            popover.animates = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, self.popover.isShown, !self.model.choosingFiles else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.model.collectionEscape(); return nil }
                    if self.model.collectionPage == .confirmation && [36, 76].contains(event.keyCode) { return nil }
                } else if let window = self.host.view.window, !window.frame.contains(NSEvent.mouseLocation) {
                    if self.model.collectionDeleting { return nil }
                    self.model.closeCollectionMenu()
                    if let anchor = self.anchor, let parent = anchor.window,
                       anchor.bounds.contains(anchor.convert(parent.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) { return nil }
                }
                return event
            }
        }
        func update(_ anchor: NSView) {
            self.anchor = anchor
            if model.collectionPage == .closed { popover.close(); return }
            guard anchor.window != nil else { return }
            if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
        }
        func popoverShouldClose(_ popover: NSPopover) -> Bool { !model.collectionDeleting }
        func popoverDidClose(_ notification: Notification) { model.closeCollectionMenu() }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; popover.close() }
    }
}

struct CollectionMenuView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var inset: Color { dark ? skin.palette.insetLight : skin.palette.lightInset }
    private func items(_ id: UUID) -> [Material] { model.index.items.filter { $0.collectionID == id } }
    private func current(_ id: UUID) -> some View {
        Group { if id == model.index.currentCollection {
            Text("当前").font(skin.typography.badge).foregroundStyle(skin.ink.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(dark ? skin.palette.controlBorder : skin.palette.lightCurrentBadge, in: skin.shapes.badge)
        } }
    }
    var body: some View {
        Group {
            switch model.collectionPage {
            case .closed, .switcher: switcher
            case .manager: manager
            case .confirmation: confirmation
            }
        }.frame(width: model.collectionPage == .switcher ? 240 : 300)
            .background(dark ? skin.palette.collectionDark : skin.palette.lightCollection)
    }
    private var switcher: some View {
        VStack(spacing: 1) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.index.collections) { group in
                        Button { model.selectCollection(group.id); model.closeCollectionMenu() } label: {
                            HStack {
                                Image(systemName: "checkmark").opacity(group.id == model.index.currentCollection ? 1 : 0)
                                Text(group.name).lineLimit(1).help(group.name); Spacer()
                                Text("\(items(group.id).count)").foregroundStyle(skin.ink.secondary).monospacedDigit()
                            }.padding(.horizontal, 10).frame(height: 30)
                                .background(group.id == model.index.currentCollection ? skin.palette.accent : skin.palette.clear, in: skin.shapes.control)
                                .foregroundStyle(group.id == model.index.currentCollection ? skin.palette.light : skin.palette.primary).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("重命名…") { model.closeCollectionMenu(); model.collectionNameDialog(group.id) }
                            Button("删除收集区…", role: .destructive) { model.showCollectionConfirmation([group.id], direct: true) }.disabled(model.locked)
                        }
                    }
                }
            }.frame(height: CGFloat(min(8, model.index.collections.count)) * 31)
            Divider().padding(.vertical, 4)
            Button("新建收集区…") { model.closeCollectionMenu(); model.collectionNameDialog() }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            Button("管理收集区…") { model.manageCollections() }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.buttonStyle(.plain).font(skin.typography.body).padding(6)
    }
    private var manager: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理收集区").fontWeight(skin.typography.emphasis); Spacer()
                Button("完成") { model.closeCollectionMenu() }.foregroundStyle(skin.palette.accent).fontWeight(skin.typography.emphasis)
            }.padding(.horizontal, 14).frame(height: 40)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.index.collections) { group in
                        let checked = model.collectionSelection.contains(group.id)
                        let members = items(group.id)
                        Button {
                            if checked { model.collectionSelection.remove(group.id) } else { model.collectionSelection.insert(group.id) }
                        } label: {
                            HStack(spacing: 9) {
                                skin.shapes.checkbox.fill(checked ? skin.palette.accent : skin.palette.clear)
                                    .overlay(skin.shapes.checkbox.stroke(checked ? skin.palette.clear : (dark ? skin.palette.checkboxBorder : skin.palette.uncheckedBorder), lineWidth: 1.5))
                                    .overlay { if checked { Image(systemName: "checkmark").font(skin.typography.checkmark).foregroundStyle(skin.palette.light) } }
                                    .frame(width: 16, height: 16)
                                Text(group.name).lineLimit(1).truncationMode(.tail).help(group.name)
                                current(group.id)
                                Spacer(minLength: 0)
                                Text(members.isEmpty ? "空" : "\(members.count) 样 · \(CapacityLimits.format(members.reduce(0) { $0 + $1.byteCount + ($1.linkPreview?.byteCount ?? 0) }))")
                                    .font(skin.typography.detail).monospacedDigit().foregroundStyle(skin.ink.secondary).fixedSize()
                            }.padding(.horizontal, 10).frame(height: 36).background(checked ? inset : skin.palette.clear, in: skin.shapes.control).contentShape(Rectangle())
                        }.accessibilityLabel("\(group.name)，\(checked ? "已选择" : "未选择")").accessibilityAddTraits(checked ? .isSelected : [])
                    }
                }.padding(.horizontal, 6)
            }.frame(height: CGFloat(min(6, model.index.collections.count)) * 36)
                .overlay(alignment: .bottom) {
                    if model.index.collections.count > 6 {
                        LinearGradient(colors: [skin.palette.clear, dark ? skin.palette.collectionFade : skin.palette.light], startPoint: .top, endPoint: .bottom).frame(height: 22).allowsHitTesting(false)
                    }
                }.padding(.vertical, 4)
            if model.collectionDeletedCount > 0, model.index.undo?.collections != nil {
                HStack {
                    Text("已删除 \(model.collectionDeletedCount) 个收集区"); Spacer()
                    Button("撤销") { model.undo(); model.collectionDeletedCount = 0 }.foregroundStyle(skin.palette.accent)
                }.font(skin.typography.detail).padding(.horizontal, 10).frame(height: 36).background(inset)
            }
            Divider()
            HStack(spacing: 6) {
                let all = Set(model.index.collections.map(\.id))
                Button(model.collectionSelection == all ? "取消全选" : "全选") { model.collectionSelection = model.collectionSelection == all ? [] : all }.foregroundStyle(skin.palette.accent)
                Spacer(minLength: 0)
                Text(model.collectionSelection.isEmpty ? "未选择" : "已选 \(model.collectionSelection.count) 个").font(skin.typography.detail).foregroundStyle(skin.ink.secondary)
                Spacer(minLength: 0)
                Button("删除所选…") { model.showCollectionConfirmation(model.collectionSelection) }
                    .padding(.horizontal, 8).frame(height: 28).foregroundStyle(skin.palette.destructive)
                    .background(skin.palette.collectionDestructive(dark: dark), in: skin.shapes.compactControl)
                    .opacity(model.collectionSelection.isEmpty ? skin.opacity.disabled : 1).disabled(model.collectionSelection.isEmpty || model.locked || model.collectionExporting)
            }.padding(.horizontal, 10).frame(height: 48)
        }.buttonStyle(.plain).font(skin.typography.body)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.collectionConfirmation {
                Text(title(snapshot)).font(skin.typography.collectionTitle)
                if !model.collectionStatus.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.collectionStatus).foregroundStyle(model.collectionError ? skin.palette.destructive : skin.palette.secondary)
                        if model.collectionDeleting { ProgressView().controlSize(.small) }
                        else if model.collectionExporting {
                            ProgressView(value: Double(model.collectionExportProgress?.completed ?? 0), total: Double(max(1, model.collectionExportProgress?.total ?? 1))).frame(height: 3)
                        }
                        if let url = model.collectionExportURL {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.foregroundStyle(skin.palette.accent)
                        }
                    }.font(skin.typography.detail).padding(9).frame(maxWidth: .infinity, alignment: .leading).background(inset, in: skin.shapes.compactControl)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(snapshot.collections) { group in
                            HStack {
                                Text(group.name).lineLimit(1).help(group.name); current(group.id); Spacer()
                                let count = snapshot.members[group.id]?.count ?? 0
                                Text(count == 0 ? "空" : "\(count) 样").foregroundStyle(skin.ink.secondary).fixedSize()
                            }.frame(height: 24)
                        }
                    }.padding(.horizontal, 8)
                }.frame(height: CGFloat(min(4, snapshot.collections.count)) * 24).background(inset, in: skin.shapes.compactControl).font(skin.typography.detail)
                Text(explanation(snapshot)).font(skin.typography.note)
                ForEach(ClearCategory.allCases, id: \.self) { category in
                    if let ids = snapshot.summary.unique[category], !ids.isEmpty {
                        HStack { Text(category.rawValue); Spacer(); Text("\(ids.count)") }.font(skin.typography.detail).foregroundStyle(skin.ink.secondary)
                    }
                }
                if snapshot.removesAll { Text("删除后将保留一个新的空白‘收集区’。").font(skin.typography.note) }
                if snapshot.summary.total > 0 { Text("删除后可以撤销一次。").font(skin.typography.detail).foregroundStyle(skin.ink.secondary) }
                if !snapshot.summary.uniqueIDs.isEmpty && !model.collectionDeleteFailed {
                    Button(model.collectionError ? "重试导出…" : "先导出这 \(snapshot.summary.uniqueIDs.count) 样…") { model.exportSelectedCollections() }
                        .frame(maxWidth: .infinity).frame(height: 28).background(inset, in: skin.shapes.compactControl).disabled(model.collectionDeleting || model.collectionExporting)
                }
                HStack {
                    Button(model.collectionDeleteFailed ? "返回列表" : "取消") { model.cancelCollectionConfirmation() }
                        .frame(maxWidth: .infinity).frame(height: 28).background(inset, in: skin.shapes.compactControl).disabled(model.collectionDeleting)
                    Button(model.collectionDeleting ? "正在删除…" : model.collectionDeleteFailed ? "重试" : snapshot.removesAll ? "删除全部" : snapshot.collections.count == 1 ? "删除收集区" : "删除 \(snapshot.collections.count) 个收集区") { model.deleteSelectedCollections() }
                        .frame(maxWidth: .infinity).frame(height: 28).foregroundStyle(skin.palette.light).background(skin.palette.destructive, in: skin.shapes.compactControl)
                        .disabled(model.collectionDeleting || model.collectionExporting || model.locked || snapshot.collections.isEmpty)
                }
            }
        }.padding(16).buttonStyle(.plain).font(skin.typography.note)
    }
    private func title(_ s: CollectionRemovalSnapshot) -> String {
        if s.removesAll { return "删除全部 \(s.collections.count) 个收集区？" }
        if s.collections.count == 1 { return "删除‘\(s.collections[0].name)’？" }
        return "删除这 \(s.collections.count) 个\(s.summary.total == 0 ? "空" : "")收集区？"
    }
    private func explanation(_ s: CollectionRemovalSnapshot) -> String {
        if s.summary.total == 0 { return "可以撤销一次。" }
        if s.summary.uniqueIDs.isEmpty { return "共 \(s.summary.total) 样，都是导入文件的副本，原件不受影响。" }
        return "共 \(s.summary.total) 样材料，其中 \(s.summary.uniqueIDs.count) 样只保存在\(AppIdentity.name)里，删除后将一并移除。" + (s.summary.backedUp == 0 ? "" : "其余 \(s.summary.backedUp) 样的外部原件不受影响。")
    }
}
