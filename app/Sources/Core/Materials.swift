import Foundation

struct CanvasPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}
struct CanvasSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
}
struct CanvasRect: Sendable {
    var origin: CanvasPoint
    var size: CanvasSize
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    func intersectionArea(_ other: Self) -> Double {
        max(0, min(maxX, other.maxX) - max(origin.x, other.origin.x)) *
        max(0, min(maxY, other.maxY) - max(origin.y, other.origin.y))
    }
    func intersects(_ other: Self) -> Bool { intersectionArea(other) > 0 }
}
enum MaterialKind: String, Codable, Sendable {
    case image, text, link, video, audio, file, folder
    var resizable: Bool { [.image, .video, .text, .link].contains(self) }
    var size: CanvasSize {
        switch self {
        case .image, .video: CanvasSize(width: 144, height: 120)
        case .text: CanvasSize(width: 192, height: 144)
        case .link: CanvasSize(width: 216, height: 192)
        case .audio: CanvasSize(width: 216, height: 72)
        case .file, .folder: CanvasSize(width: 120, height: 144)
        }
    }
}
enum MaterialOrigin: String, Codable, Sendable {
    case importedFile, pastedText, unsourced, link, result
}
struct MaterialSource: Sendable, Equatable {
    var title: String?
    var url: String?
    init(title: String? = nil, url: String? = nil) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        self.url = url.flatMap { Library.webURL($0)?.absoluteString }
    }
}
struct Collection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
}
struct Material: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var collectionID: UUID
    var name: String
    var filename: String
    var kind: MaterialKind
    var origin: MaterialOrigin
    var created = Date()
    var byteCount: Int64 = 0
    var position = CanvasPoint(x: 24, y: 24)
    var sourcePath: String?
    var sourceBookmark: Data?
    var sourceFileID: String?
    var sourceTitle: String?
    var sourceURL: String?
    var linkPreview: LinkPreview?
    var derivedFrom: UUID?
    var displaySize: CanvasSize?
    var stackID: UUID?
    var stackOrder: Int?
    var size: CanvasSize { displaySize ?? kind.size }
    var rect: CanvasRect { CanvasRect(origin: position, size: size) }
}

enum CardResize {
    static func size(kind: MaterialKind, original: CanvasSize, delta: CanvasPoint, free: Bool) -> CanvasSize {
        guard kind.resizable else { return kind.size }
        func constrained(_ value: Double, lower: Double, upper: Double) -> Double {
            if free { return min(upper, max(lower, value)) }
            return min(floor(upper / 24) * 24, max(ceil(lower / 24) * 24, (value / 24).rounded() * 24))
        }
        if kind == .image || kind == .video {
            let ratio = original.width / original.height
            if abs(delta.x / original.width) >= abs(delta.y / original.height) {
                let width = constrained(original.width + delta.x, lower: max(96, 96 * ratio), upper: min(480, 480 * ratio))
                return CanvasSize(width: width, height: width / ratio)
            }
            let height = constrained(original.height + delta.y, lower: max(96, 96 / ratio), upper: min(480, 480 / ratio))
            return CanvasSize(width: height * ratio, height: height)
        }
        return CanvasSize(width: constrained(original.width + delta.x, lower: 144, upper: 480),
                          height: constrained(original.height + delta.y, lower: 96, upper: 480))
    }
    static func valid(_ size: CanvasSize, kind: MaterialKind) -> Bool {
        kind.resizable && size.width.isFinite && size.height.isFinite &&
        size.width >= (kind == .text || kind == .link ? 144 : 96) && size.width <= 480 && size.height >= 96 && size.height <= 480
    }
}
struct AnswerDraft: Codable, Equatable, Sendable {
    var sourceID: UUID
    var action = "解释"
    var answer = ""
    var followUp = ""
    var history = ""
    var manuallyEdited = false
}
struct UndoRemoval: Codable, Sendable {
    var actionTitle: String? = nil
    var items: [Material]
    var collection: Collection?
    var drafts: [AnswerDraft]
    var previousCurrentCollection: UUID
    var replacementCollection: UUID?
    var collectionIndex: Int?
    var itemOrder: [UUID]
    var stackLayout: [StackLayout]?
    var collections: [Collection]?
    var collectionOrder: [UUID]?
    var replacementRenamed: Bool?
}
struct StackLayout: Codable, Sendable {
    var id: UUID
    var stackID: UUID?
    var stackOrder: Int?
    var position: CanvasPoint
    init(_ item: Material) { id = item.id; stackID = item.stackID; stackOrder = item.stackOrder; position = item.position }
}
struct UndoDissolve: Codable, Sendable {
    var collectionID: UUID
    var members: [StackLayout]
}
struct LibraryIndex: Codable, Sendable {
    var schema = 1
    var collections: [Collection]
    var currentCollection: UUID
    var items: [Material] = []
    var drafts: [AnswerDraft] = []
    var undo: UndoRemoval?
    var garbage: [UUID] = []
    var dissolved: UndoDissolve?
    init() {
        let initial = Collection(name: "收集区")
        collections = [initial]; currentCollection = initial.id
    }
}

enum CardStacks {
    static func visible(_ items: [Material]) -> [Material] {
        let tops = Dictionary(grouping: items.filter { $0.stackID != nil }, by: { $0.stackID! })
            .mapValues { $0.max { $0.stackOrder! < $1.stackOrder! }!.id }
        return items.filter { item in item.stackID.map { tops[$0] == item.id } ?? true }
    }
    static func valid(_ items: [Material]) -> Bool {
        guard items.allSatisfy({ ($0.stackID == nil) == ($0.stackOrder == nil) }) else { return false }
        let groups = Dictionary(grouping: items.filter { $0.stackID != nil }, by: { $0.stackID! })
        return groups.values.allSatisfy { members in
            guard members.count >= 2, Set(members.compactMap(\.stackOrder)).count == members.count else { return false }
            let first = members[0]
            return members.allSatisfy { $0.stackOrder! >= 0 && $0.stackOrder! < Int.max && $0.collectionID == first.collectionID && $0.position == first.position }
        }
    }
    static func dissolveSingletons(_ items: inout [Material]) {
        let counts = Dictionary(grouping: items.filter { $0.stackID != nil }, by: { $0.stackID! }).mapValues(\.count)
        for n in items.indices {
            if let id = items[n].stackID, counts[id] == 1 { items[n].stackID = nil; items[n].stackOrder = nil }
        }
    }
}
enum LibraryError: LocalizedError {
    case invalid(InterfaceText)
    var errorDescription: String? { if case let .invalid(value) = self { value.rendered(.simplified) } else { nil } }
}
extension InterfaceText {
    init(error: Error) {
        if let text = error as? InterfaceText { self = text }
        else if case let LibraryError.invalid(text) = error { self = text }
        else { self.init(key: error.localizedDescription) }
    }
}
struct CapacityLimits: Sendable {
    var collection: Int64 = 5_000_000_000
    var item: Int64 = 2_000_000_000
    var freeDisk: Int64 = 10_000_000_000
    func validate(incoming: Int64, used: Int64, available: Int64, hasCopiedPayload: Bool = false) throws {
        guard incoming <= item else { throw LibraryError.invalid("单个材料超过 \(bytes: item) 上限（\(bytes: incoming)）。") }
        guard incoming <= collection - used else { throw LibraryError.invalid("收集区已用 \(bytes: used)，放入后将超过 \(bytes: collection) 上限。") }
        guard available >= freeDisk, hasCopiedPayload || incoming <= available - freeDisk else { throw LibraryError.invalid("磁盘可用 \(bytes: available)，需保留 \(bytes: freeDisk)；暂停接收。") }
    }
}
enum ClearCategory: String, CaseIterable, Sendable {
    case pastedText = "粘贴的文字", result = "处理生成的结果", unsourced = "没有源文件的内容"
    case link = "链接", missingOriginal = "原件已不在的导入文件"
}
struct ClearSummary: Sendable, Equatable {
    var backedUp = 0
    var unique: [ClearCategory: [UUID]] = [:]
    var uniqueIDs: Set<UUID> { Set(unique.values.flatMap { $0 }) }
    var total: Int { backedUp + uniqueIDs.count }
}

struct CollectionRemovalSnapshot: Equatable, Sendable {
    var collections: [Collection]
    var allCollectionIDs: Set<UUID>
    var members: [UUID: Set<UUID>]
    var summary: ClearSummary
    var ids: Set<UUID> { Set(collections.map(\.id)) }
    var itemIDs: Set<UUID> { Set(members.values.flatMap { $0 }) }
    var removesAll: Bool { ids == allCollectionIDs }
}
