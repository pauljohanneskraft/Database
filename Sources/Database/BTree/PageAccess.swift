/// RAII handle for a fixed buffer-manager page. `deinit` provides the
/// unfix-on-scope-exit backstop; the algorithm in `BTree._insert` calls
/// `unfix()` explicitly to release a latch early (latch-coupling,
/// ancestor early-release), so `deinit` only fires for entries left in
/// the path array at function exit.
final class PageAccess {
    let id: UInt64
    private let manager: BufferManager
    private let frame: BufferFrame
    private(set) var isDirty: Bool = false
    private var isFixed: Bool = true

    init(manager: BufferManager, pageId: UInt64, exclusive: Bool) throws {
        self.id = pageId
        self.manager = manager
        self.frame = try manager.fixPage(pageId: pageId, exclusive: exclusive)
    }

    var data: UnsafeMutableRawPointer {
        precondition(isFixed, "Trying to get content after unfixing page.")
        return frame.data
    }

    func setDirty() {
        isDirty = true
    }

    func unfix() {
        if isFixed {
            manager.unfixPage(frame, isDirty: isDirty)
            isFixed = false
        }
    }

    deinit {
        unfix()
    }
}
