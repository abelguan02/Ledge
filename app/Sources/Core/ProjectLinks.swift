import Foundation

enum ProjectLinks {
    static let repository = URL(string: "https://github.com/abelguan02/Ledge")!
    static let feedback = repository.appendingPathComponent("issues/new")
    static let latestRelease = URL(string: "https://api.github.com/repos/abelguan02/Ledge/releases/latest")!
    static let releases = URL(string: "https://api.github.com/repos/abelguan02/Ledge/releases?per_page=1")!

    static func release(tag: String) -> URL {
        repository.appendingPathComponent("releases/tag").appendingPathComponent(tag)
    }
}
