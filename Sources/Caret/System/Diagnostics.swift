import os

/// Caret's log.
///
/// Only one kind of thing goes in here: a fault that leaves Caret running but not
/// working. That is the one failure it cannot report for itself — the user types,
/// nothing happens, the menu still says everything is fine, and there is nothing
/// anywhere to look at. Read it back with
///
///     log show --predicate 'subsystem == "com.maksim.caret"' --last 1h
///
/// Nothing the user typed is ever logged, at any level, in any build. The whole
/// point of the tap is that what goes through it stays there.
enum Diagnostics {
    private static let subsystem = "com.maksim.caret"

    /// The event tap: built, switched off by the system, rebuilt, given up on.
    static let tap = Logger(subsystem: subsystem, category: "tap")

    /// Reading keyboard layouts out of the system, which can fail without
    /// warning and takes Caret's ability to judge anything with it.
    static let layouts = Logger(subsystem: subsystem, category: "layouts")
}
