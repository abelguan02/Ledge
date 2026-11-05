import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The macOS 27 SDK also exports a State macro; select the macOS 14 wrapper explicitly.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct PanelShell<Content: View>: View {
    @Environment(\.ledgeSkin) private var skin
    var width = 520.0
    var height = 720.0
    var edge: DockEdge = .right
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassBackground()
                .overlay(skin.palette.panelTint(dark: scheme == .dark))
                .clipShape(EdgePanelShape(edge: edge))
                .overlay(EdgePanelShape(edge: edge).strokeBorderColor(scheme == .dark ? skin.palette.stackFront : skin.palette.lightPanelBorder))
                .skinShadow(skin.shadows.panel(dark: scheme == .dark, x: edge == .right ? -8 : edge == .left ? 8 : 0, y: edge == .top ? 8 : 6))
                .frame(width: width + (edge == .top ? 48 : 0), height: height + (edge == .top ? 0 : 48))
                .offset(x: edge == .right ? 20 : 0)
            content().frame(width: width, height: height).offset(x: edge == .top ? 24 : edge == .right ? 20 : 0, y: edge == .top ? 0 : 24)
        }.frame(width: width + (edge == .top ? 48 : 20), height: height + (edge == .top ? 20 : 48), alignment: .topLeading)
    }
}
private extension Shape {
    func strokeBorderColor(_ color: Color) -> some View { stroke(color, lineWidth: 0.5) }
}
struct WorkbenchView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    var width = 520.0
    var height = 720.0
    @ViewState private var parameterAction: String? = nil
    @ViewState private var imageSettings = ImageSettings()
    var body: some View {
        PanelShell(width: width, height: height, edge: model.preferences.dockEdge) {
            ZStack(alignment: .top) {
                canvas.padding(.top, 52)
                header
                VStack {
                    Spacer()
                    if !model.recoveryPaths.isEmpty {
                        Button("有 \(model.recoveryPaths.count) 批未入库文件，查看取回位置") {
                            NSWorkspace.shared.activateFileViewerSelecting(model.recoveryPaths)
                        }.buttonStyle(.bordered).padding(8).background(skin.materials.regular, in: skin.shapes.capsule)
                    }
                    if !model.message.isEmpty || !model.notice.isEmpty {
                        HStack(alignment: .top) {
                            Text(model.message.isEmpty ? model.notice : model.message).font(skin.typography.caption).textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button { if model.message.isEmpty { model.notice = "" } else { model.message = "" }; model.statusChanged?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(12).background(skin.materials.regular, in: skin.shapes.card).padding(.horizontal, 16)
                    }
                    if let failed = model.selectedItems.first(where: { model.errors[$0.id] != nil }), let error = model.errors[failed.id], model.activeAnswer != failed.id {
                        HStack(alignment: .top) {
                            Text(error).font(skin.typography.caption).foregroundStyle(skin.palette.destructive).textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button { model.errors[failed.id] = nil; model.statusChanged?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(12).background(skin.materials.regular, in: skin.shapes.card).padding(.horizontal, 16)
                    }
                    if !model.selectedItems.isEmpty { actionBar }
                    else if model.index.undo != nil || model.index.dissolved != nil {
                        Button(model.index.dissolved != nil ? "撤销解除堆叠" : "撤销上次删除") { model.undo() }.buttonStyle(.bordered).padding(14).background(skin.materials.regular, in: skin.shapes.capsule).padding(.bottom, 12)
                    }
                }
                if let request = model.removal { ClearConfirmation(model: model, request: request) }
                if model.collectionPage == .confirmation {
                    skin.palette.collectionDim.allowsHitTesting(false)
                }
            }.overlay(alignment: .bottomTrailing) {
                if model.isExpanded && model.removal == nil { zoomControls.padding(.trailing, 18).padding(.bottom, 18) }
            }
        }
        .popover(isPresented: Binding(get: { parameterAction != nil }, set: { if !$0 { parameterAction = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text(parameterAction ?? "图片处理").font(skin.typography.headline)
                Text("支持单帧 PNG / JPEG；生成独立副本。").font(skin.typography.systemCaption).foregroundStyle(skin.ink.secondary)
                Toggle("调整宽度", isOn: $imageSettings.resize)
                if imageSettings.resize { TextField("宽度（像素）", value: $imageSettings.width, format: .number).textFieldStyle(.roundedBorder) }
                Picker("格式", selection: $imageSettings.format) {
                    Text("原格式").tag("original"); Text("JPEG").tag("jpeg"); Text("PNG").tag("png")
                }.pickerStyle(.segmented)
                HStack { Text("JPEG 质量"); Slider(value: $imageSettings.quality, in: 0.2...1); Text("\(Int(imageSettings.quality*100))%") }.disabled(imageSettings.format == "png")
                HStack { Button("取消") { parameterAction = nil }; Spacer(); Button("处理") {
                    model.process(model.selectedItems, action: parameterAction ?? "压缩", settings: imageSettings); parameterAction = nil
                }.buttonStyle(.borderedProminent) }
            }.padding(20).frame(width: 300)
        }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button { if model.collectionPage == .closed { model.collectionPage = .switcher } else { model.closeCollectionMenu() } } label: {
                HStack(spacing: 5) { Text(model.collectionName).lineLimit(1); Image(systemName: "chevron.down").font(skin.typography.disclosure) }
            }.font(skin.typography.bodyStrong).buttonStyle(.plain)
                .background(CollectionPopover(model: model))
            Spacer()
            Button("清空") { model.askRemoval(ids: Set(model.items.map(\.id))) }
                .font(skin.typography.note).foregroundStyle(skin.ink.secondary).buttonStyle(.plain).disabled(model.items.isEmpty || model.locked)
            Button { model.toggleExpanded() } label: {
                Image(systemName: model.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(skin.typography.captionStrong).frame(width: 28, height: 28).background(skin.ink.headerControl, in: skin.shapes.circle)
            }.buttonStyle(.plain).accessibilityLabel(model.isExpanded ? "收回到屏幕边" : "铺开画布")
            Button { model.collapse?() } label: { Image(systemName: model.preferences.dockEdge == .top ? "chevron.up" : model.preferences.dockEdge == .left ? "chevron.left" : "chevron.right").font(skin.typography.captionStrong).frame(width: 28, height: 28).background(skin.ink.headerControl, in: skin.shapes.circle) }
                .buttonStyle(.plain).accessibilityLabel("收起")
        }.padding(.horizontal, 16).frame(height: 52)
    }
    private var canvas: some View {
        CanvasViewportView(model: model)
            .overlay { if let stack = model.openStackID { StackTrayOverlay(model: model, stack: stack) } }
            .overlay {
                if model.items.isEmpty { Text("拖进来，或按 ⌘V").font(skin.typography.body).foregroundStyle(skin.palette.secondary.opacity(0.65)).allowsHitTesting(false) }
            }
    }
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { model.changeCanvasZoom?(model.canvasZoom / 1.25) } label: { Image(systemName: "minus").frame(width: 28, height: 28) }
                .accessibilityLabel("缩小画布").disabled(model.canvasZoom <= CanvasViewportState.zoomRange.lowerBound + 0.001)
            Button { model.changeCanvasZoom?(1) } label: {
                Text("\(Int((model.canvasZoom * 100).rounded()))%").font(skin.typography.caption.monospacedDigit()).frame(width: 46, height: 28)
            }.accessibilityLabel("恢复画布到 100%")
            Button { model.changeCanvasZoom?(model.canvasZoom * 1.25) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                .accessibilityLabel("放大画布").disabled(model.canvasZoom >= CanvasViewportState.zoomRange.upperBound - 0.001)
        }.buttonStyle(.plain).padding(4).background(skin.materials.regular, in: skin.shapes.capsule)
            .help("双指平移，捏合缩放；按住空格拖动画布")
    }
    private var actionBar: some View {
        HStack(spacing: 14) {
            Text("\(model.selectedItems.count) 样").font(skin.typography.small).foregroundStyle(skin.ink.secondary)
            if model.canStack { Button("创建堆叠") { model.createStack() }.buttonStyle(.plain).font(skin.typography.caption) }
            Button { model.copySelected() } label: { Image(systemName: "doc.on.doc").font(skin.typography.actionIcon) }
                .buttonStyle(.plain).accessibilityLabel("复制选中").help("复制选中（⌘C）")
            if model.selectedItems.allSatisfy({ $0.kind == .image }) {
                ForEach([("压缩", "arrow.down.right.and.arrow.up.left"), ("尺寸", "arrow.up.left.and.arrow.down.right"), ("格式", "arrow.triangle.2.circlepath"), ("识别文字", "text.viewfinder")], id: \.0) { name, icon in
                    Button { if name == "识别文字" { model.process(model.selectedItems, action: name) }
                        else { imageSettings = ImageSettings(); imageSettings.resize = name == "尺寸"; parameterAction = name }
                    } label: { VStack(spacing: 4) { Image(systemName: icon); Text(name).font(skin.typography.tiny) } }.buttonStyle(.plain)
                }
            } else if model.selectedItems.allSatisfy({ $0.kind == .text }) {
                ForEach(TextAction.allCases) { action in
                    Button(action.rawValue) { model.process(model.selectedItems, action: action.rawValue) }.font(skin.typography.small).buttonStyle(.plain)
                        .disabled(!model.canUseAI).opacity(model.canUseAI ? 1 : skin.opacity.disabled).help(model.aiHelp)
                }
            } else {
                Button("导出…") { model.export(model.selected) }.buttonStyle(.plain).font(skin.typography.caption)
            }
            Divider().frame(height: 24)
            Button { model.askRemoval(ids: model.selected) } label: { Image(systemName: "trash").font(skin.typography.actionIcon) }.buttonStyle(.plain).accessibilityLabel("删除选中材料")
        }.disabled(model.locked).padding(.horizontal, 18).padding(.vertical, 12)
            .background(skin.materials.regular, in: skin.shapes.dialog).skinShadow(skin.shadows.actionBar).padding(.bottom, 14)
    }
}

struct StackTrayOverlay: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let stack: UUID
    var body: some View {
        GeometryReader { geometry in
            if let top = model.canvasItems.first(where: { $0.stackID == stack }) {
                let members = model.stackMembers(stack)
                let height = min(54 + Double((members.count + 2) / 3) * 88 + 12, max(134, geometry.size.height - 24))
                let target = CGPoint(x: (top.position.x + top.size.width / 2 - model.visibleCanvasRect.minX) * model.canvasCoordinateScale,
                                     y: (top.position.y - model.visibleCanvasRect.minY) * model.canvasCoordinateScale)
                let preferredY = target.y - height - 12 >= 8 ? target.y - height - 12 : target.y + top.size.height * model.canvasCoordinateScale + 12
                let origin = CGPoint(x: min(max(8, target.x - 166), max(8, geometry.size.width - 340)),
                                     y: min(max(8, preferredY), max(8, geometry.size.height - height - 16)))
                ZStack(alignment: .topLeading) {
                    skin.palette.trayDim.contentShape(Rectangle()).onTapGesture { model.closeStack() }
                    TrayPointer(target: CGPoint(x: target.x - origin.x, y: target.y - origin.y))
                        .fill(skin.materials.regular).frame(width: 332, height: height).offset(x: origin.x, y: origin.y).allowsHitTesting(false)
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(members.count) 样").font(skin.typography.captionMedium).foregroundStyle(skin.ink.secondary)
                            Spacer()
                            Button("解除堆叠") { model.dissolveStack(stack) }.buttonStyle(.plain).font(skin.typography.caption).disabled(model.locked)
                        }.padding(.horizontal, 18).frame(height: 46)
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 8), count: 3), spacing: 8) {
                                ForEach(members) { member in
                                    StackTrayCell(model: model, item: member).frame(width: 96, height: 80)
                                }
                            }.padding(.horizontal, 14).padding(.bottom, 12)
                        }
                    }.frame(width: 332, height: height).background(skin.materials.regular, in: skin.shapes.floatingCard)
                        .overlay { skin.shapes.floatingCard.stroke(skin.palette.trayBorder, lineWidth: 0.5).allowsHitTesting(false) }
                        .background(StackTrayGeometry(model: model))
                        .skinShadow(skin.shadows.tray).offset(x: origin.x, y: origin.y)
                }
            }
        }
    }
}

private struct StackTrayGeometry: NSViewRepresentable {
    let model: WorkbenchModel
    func makeNSView(context: Context) -> NSView { let view = NSView(); model.stackTrayView = view; return view }
    func updateNSView(_ view: NSView, context: Context) { model.stackTrayView = view }
}

private struct StackTrayCell: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let item: Material
    var body: some View {
        ZStack {
            if item.kind == .link, let image = model.webImages[item.id] {
                Image(nsImage: image).resizable().frame(width: 96, height: 60).frame(height: 80, alignment: .top)
            } else if let image = model.thumbnails[item.id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else if item.kind == .text || item.kind == .link {
                Text(item.kind == .link ? model.linkTitle(item) : (model.textPreviews[item.id] ?? item.name)).font(skin.typography.tiny).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            } else {
                VStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: model.payloadURLs[item.id]?.path ?? "")).resizable().scaledToFit().frame(height: 42)
                    Text(item.name).font(skin.typography.micro).lineLimit(1)
                }.padding(6)
            }
        }.frame(width: 96, height: 80).background(skin.ink.quaternary).clipped().clipShape(skin.shapes.trayItem)
            .overlay { if model.selected.contains(item.id) { skin.shapes.trayItem.stroke(skin.palette.accent, lineWidth: 2).allowsHitTesting(false) } }
            .overlay { MaterialDragSource(model: model, item: item, inTray: true) }
            .accessibilityLabel(item.name).accessibilityAddTraits(.isButton).accessibilityAction { model.select(item.id) }
    }
}

struct MaterialView: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let item: Material
    @Environment(\.colorScheme) private var scheme
    @ViewState private var hovering = false
    var body: some View {
        ZStack {
            content.frame(width: item.size.width, height: item.size.height)
                .opacity(!model.selected.isEmpty && !model.selected.contains(item.id) ? skin.opacity.unselected : 1)
                .overlay { MaterialDragSource(model: model, item: item) }
            if model.busy.contains(item.id) { skin.shapes.card.fill(skin.palette.busyScrim); ProgressView().controlSize(.small) }
        }
        .clipShape(skin.shapes.card)
        .contentShape(.interaction, skin.shapes.card)
        .skinShadow(skin.shadows.card(dark: scheme == .dark))
        .overlay {
            if model.selected.contains(item.id) { skin.shapes.card.stroke(skin.palette.accent, lineWidth: 3).allowsHitTesting(false) }
            else if item.kind == .link, item.linkPreview?.state == .pending, model.webProgress[item.id] != nil {
                skin.shapes.card.stroke(skin.palette.pendingBorder, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if item.kind == .link, item.size.height >= 144, !model.missingCopies.contains(item.id),
               let action = LinkCardContent.actionTitle(model.linkPreviewState(item)) {
                Button(action) { model.generateWebPreview(item) }
                    .font(skin.typography.small).buttonStyle(.plain).foregroundStyle(skin.palette.linkAction)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(skin.palette.insetLight, in: skin.shapes.smallControl)
                    .overlay(skin.shapes.smallControl.stroke(skin.palette.controlBorder, lineWidth: 0.5))
                    .offset(y: (item.size.height - 72) / 2 + 13.5)
                    .accessibilityLabel(action + "：" + model.linkTitle(item))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.selected == [item.id], item.kind.resizable, item.stackID == nil {
                CardResizeHandle(model: model, item: item)
                    .frame(width: 16 / model.canvasCoordinateScale, height: 16 / model.canvasCoordinateScale)
            }
        }
        .overlay(alignment: .bottom) {
            if (hovering || model.selected.contains(item.id)) && item.kind == .image {
                Text(item.name).font(skin.typography.tiny).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3).background(skin.palette.accent, in: skin.shapes.capsule).foregroundStyle(skin.palette.light).offset(y: 20).allowsHitTesting(false)
            } else if model.selected.contains(item.id), item.kind == .link {
                Text(model.textPreviews[item.id] ?? item.sourceURL ?? item.name)
                    .font(skin.typography.linkAddress).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 3).frame(maxWidth: item.size.width + 84)
                    .background(skin.palette.accent, in: skin.shapes.capsule).foregroundStyle(skin.palette.light).offset(y: 28).allowsHitTesting(false)
            }
        }
        .overlay {
            if let feedback = model.webFeedback[item.id] {
                Text(feedback).font(skin.typography.small).multilineTextAlignment(.center).padding(8)
                    .background(skin.palette.feedbackBackdrop, in: skin.shapes.compactControl).foregroundStyle(skin.palette.light).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) { if model.errors[item.id] != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(skin.palette.destructive).background(skin.ink.background, in: skin.shapes.circle).help(model.errors[item.id]!) } }
        .overlay(alignment: .topLeading) {
            if model.drafts[item.id]?.answer.isEmpty == false {
                Label("回答", systemImage: "text.bubble.fill").font(skin.typography.tiny).padding(5).background(skin.materials.regular, in: skin.shapes.capsule).help("点开这张材料查看回答").allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: item.kind == .link ? .contain : .ignore).accessibilityLabel((item.kind == .link ? model.linkTitle(item) : item.name) + (model.missingCopies.contains(item.id) ? "，副本已丢失" : "")).accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(item.id) }
    }
    @ViewBuilder private var content: some View {
        if model.missingCopies.contains(item.id) {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.exclamationmark").font(skin.typography.titleIcon)
                Text(item.name).lineLimit(2)
                Text("副本已丢失").foregroundStyle(skin.ink.secondary)
            }.font(skin.typography.caption).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(skin.materials.regular)
        } else if item.kind == .text {
            let text = model.textPreviews[item.id] ?? ""
            let paragraph = NSMutableParagraphStyle()
            let _ = paragraph.lineSpacing = 4
            let measured = (text as NSString).boundingRect(with: CGSize(width: item.size.width - 26, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: skin.typography.measuredNote, .paragraphStyle: paragraph])
            Text(text).font(skin.typography.note).lineSpacing(4).foregroundStyle(skin.palette.noteText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: item.size.width - 26, height: item.size.height - 26, alignment: .topLeading).clipped().padding(13)
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle()
                        if measured.height > item.size.height - 26 {
                            LinearGradient(colors: [skin.palette.shade, skin.palette.clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        }
                    }
                }
                .background(scheme == .dark ? skin.palette.noteDark : skin.palette.noteLight)
        } else if item.kind == .link {
            LinkCardContent(model: model, item: item).accessibilityHidden(true)
        } else if let thumbnail = model.thumbnails[item.id] {
            Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: item.size.width, height: item.size.height).clipped()
                .overlay { if item.kind == .video { Image(systemName: "play.circle.fill").font(skin.typography.playIcon).foregroundStyle(skin.palette.linkAction) } }
                .overlay(alignment: .bottomTrailing) { if let duration = model.durations[item.id] { Text(duration).font(skin.typography.mediaTime).padding(4).background(skin.palette.clearDim, in: skin.shapes.badge).foregroundStyle(skin.palette.light).padding(5) } }
        } else if item.kind == .audio, let duration = model.durations[item.id] {
            HStack(spacing: 10) { Image(systemName: "play.circle.fill").font(skin.typography.mediaIcon); VStack(alignment: .leading) { Text(item.name).font(skin.typography.small).lineLimit(1); Text(duration).font(skin.typography.measurement).foregroundStyle(skin.ink.secondary) } }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(skin.materials.regular)
        } else {
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(for: item.kind == .folder ? .folder : (UTType(filenameExtension: item.filename.pathExtension) ?? .data))).resizable().scaledToFit().frame(width: 66, height: 80)
                Text(item.name).font(skin.typography.small).lineLimit(2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
private struct LinkCardContent: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let item: Material
    static func actionTitle(_ state: LinkPreviewState) -> String? {
        switch state { case .failed: "重试"; case .blocked: "生成预览"; default: nil }
    }
    private var state: LinkPreviewState { model.linkPreviewState(item) }
    private var status: String {
        switch state {
        case .pending: "正在生成预览"
        case .needsLogin: "需要登录才能看到"
        case .blocked: "这类链接不自动打开"
        case .failed, .ready: "没能生成预览"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if item.size.height >= 144 {
                ZStack(alignment: .top) {
                    if let image = model.webImages[item.id] {
                        // Always retain the full page width. Tall cards leave
                        // their normal background below the first-screen image.
                        Image(nsImage: image).resizable().frame(width: item.size.width, height: item.size.width * 800 / 1280)
                            .frame(width: item.size.width, height: item.size.height - 72, alignment: .top).clipped()
                    } else {
                        LinearGradient(colors: [skin.palette.stackRear, skin.palette.placeholderLow], startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 7) {
                            Image(systemName: "globe").font(skin.typography.linkPlaceholder).frame(height: 22)
                            Text(status).font(skin.typography.small).lineLimit(1).frame(height: 13)
                            if Self.actionTitle(state) != nil { skin.palette.clear.frame(height: 22) }
                        }.foregroundStyle(skin.palette.linkSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(width: item.size.width, height: item.size.height - 72).clipped()
                    .overlay(alignment: .bottomLeading) {
                        if let progress = model.webProgress[item.id] {
                            Rectangle().fill(skin.palette.previewProgress).frame(width: item.size.width * progress, height: 2)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.linkTitle(item)).font(skin.typography.cardTitle).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Label(model.linkSiteName(item), systemImage: "globe").font(skin.typography.small).foregroundStyle(skin.palette.linkSecondary).lineLimit(1)
            }.padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 10)
                .frame(width: item.size.width, height: item.size.height >= 144 ? 72 : item.size.height, alignment: .topLeading)
        }.foregroundStyle(skin.palette.linkText).background(skin.palette.link)
    }
}
private extension String { var pathExtension: String { (self as NSString).pathExtension } }

struct AnswerCard: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let item: Material
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(model.drafts[item.id]?.action ?? "解释").font(skin.typography.answerTitle); Spacer(); Button { model.closeAnswer(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(skin.ink.secondary) }.buttonStyle(.plain).accessibilityLabel("关闭回答") }
            Picker("动作", selection: Binding(get: { model.drafts[item.id]?.action ?? "解释" }, set: { value in if let action = TextAction(rawValue: value) { model.runText(item, action: action) } })) {
                ForEach(TextAction.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().disabled(model.busy.contains(item.id) || !model.canUseAI)
                .opacity(model.canUseAI ? 1 : skin.opacity.disabled).help(model.aiHelp)
            if model.busy.contains(item.id) { ProgressView().frame(maxWidth: .infinity).padding(20) }
            if let error = model.errors[item.id] { Text(error).font(skin.typography.caption).foregroundStyle(skin.palette.destructive).textSelection(.enabled) }
            TextEditor(text: Binding(get: { model.drafts[item.id]?.answer ?? "" }, set: { model.editDraft(item.id, answer: $0) }))
                .font(skin.typography.answer).scrollContentBackground(.hidden).frame(height: 220).disabled(model.busy.contains(item.id))
                .accessibilityLabel("回答内容")
            HStack {
                TextField("继续追问…", text: Binding(get: { model.drafts[item.id]?.followUp ?? "" }, set: { model.editDraft(item.id, followUp: $0) }))
                    .textFieldStyle(.plain).onSubmit { followUp() }
                    .accessibilityLabel("继续追问")
                Button { followUp() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.plain).accessibilityLabel("发送追问")
            }.padding(10).background(skin.ink.sectionInset, in: skin.shapes.field).disabled(model.busy.contains(item.id) || !model.canUseAI)
                .opacity(model.canUseAI ? 1 : skin.opacity.disabled).help(model.aiHelp)
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.drafts[item.id]?.answer ?? "", forType: .string) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制回答")
                Spacer()
                Button("放到画布上") { model.saveAnswer(item) }.buttonStyle(.borderedProminent).tint(skin.palette.primary)
            }.disabled((model.drafts[item.id]?.answer.isEmpty ?? true) || model.busy.contains(item.id))
        }.padding(16).background(skin.materials.regular, in: skin.shapes.floatingCard)
            .overlay(skin.shapes.floatingCard.stroke(skin.ink.floatingBorder, lineWidth: 0.5)).skinShadow(skin.shadows.answer)
    }
    private func followUp() { if let action = TextAction(rawValue: model.drafts[item.id]?.action ?? "解释") { model.runText(item, action: action, followUp: true) } }
}

struct ClearConfirmation: View {
    @Environment(\.ledgeSkin) private var skin
    @ObservedObject var model: WorkbenchModel
    let request: RemovalRequest
    var body: some View {
        ZStack {
            skin.palette.clearDim.contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 15) {
                Text(request.title).font(skin.typography.confirmationTitle)
                if !request.summary.uniqueIDs.isEmpty {
                    Text("其中 \(request.summary.uniqueIDs.count) 样只存在于这里，清空后将移除。").font(skin.typography.body)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ClearCategory.allCases, id: \.self) { category in
                            if let values = request.summary.unique[category], !values.isEmpty { HStack { Text(category.rawValue); Spacer(); Text("\(values.count)") } }
                        }
                    }.font(skin.typography.caption).padding(12).background(skin.ink.clearCategories, in: skin.shapes.field)
                    Text("其余 \(request.summary.backedUp) 样是副本，原件不受影响。").font(skin.typography.caption).foregroundStyle(skin.ink.secondary)
                } else { Text("这 \(request.summary.backedUp) 样都是导入文件的副本，原件不受影响。").font(skin.typography.body) }
                Text("可撤销一次，直到下次清空、删除收集区或退出应用。").font(skin.typography.small).foregroundStyle(skin.ink.secondary)
                Button(role: .destructive) { model.confirmRemoval() } label: { Text(request.collection == nil ? "清空" : "删除收集区").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(skin.palette.destructive).disabled(model.locked)
                if !request.summary.uniqueIDs.isEmpty { Button { model.export(request.summary.uniqueIDs) } label: { Text("先导出这 \(request.summary.uniqueIDs.count) 样…").frame(maxWidth: .infinity) }.buttonStyle(.bordered) }
                Button { model.removal = nil } label: { Text("取消").frame(maxWidth: .infinity) }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 400).background(skin.materials.regular, in: skin.shapes.dialog)
        }
    }
}
