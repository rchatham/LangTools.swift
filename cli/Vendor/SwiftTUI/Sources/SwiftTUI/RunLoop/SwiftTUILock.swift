import Foundation

/// Coarse process-wide lock serializing SwiftTUI's renderer, control tree and
/// input handling. `Application` construction and the first render may run on
/// a different thread than the scheduled-update/SIGWINCH/stdin sources (which
/// run on the main queue); the upstream renderer cache and control tree are
/// not safe for concurrent access — concurrent passes crashed with malloc
/// double-free / "deallocated with non-zero retain count" aborts inside
/// `Renderer.drawPixel` and "Index out of range" traps. Every entry point that
/// touches the renderer or the tree takes this lock, so all of SwiftTUI's
/// work is serialized regardless of which thread starts the application.
enum SwiftTUILock {
    static let shared = NSRecursiveLock()
}
