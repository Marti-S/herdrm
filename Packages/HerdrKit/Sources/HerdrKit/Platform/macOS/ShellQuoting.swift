import Foundation

/// Portable shell quoting, shared by the macOS service layer and the
/// platform-independent attachment path formatting.
public enum ShellQuoting {
    /// Wraps a path for a POSIX shell. Single quotes so nothing inside expands;
    /// the quote dance survives sh, zsh, and fish login shells alike.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
