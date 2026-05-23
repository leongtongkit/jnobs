import Foundation

/// Per-app volume control via AppleScript for apps that expose it.
///
/// Works for: Spotify, Music. Fast (~5 ms). Returns false silently if app
/// isn't running.
enum AppleScriptApps {
    /// Set Spotify's sound volume (0..100).
    @discardableResult
    static func setSpotifyVolume(_ pct: Int) -> Bool {
        runOSAScript("""
        if application "Spotify" is running then
            tell application "Spotify" to set sound volume to \(max(0, min(100, pct)))
        end if
        """)
    }

    /// Set Music.app's sound volume (0..100).
    @discardableResult
    static func setMusicVolume(_ pct: Int) -> Bool {
        runOSAScript("""
        if application "Music" is running then
            tell application "Music" to set sound volume to \(max(0, min(100, pct)))
        end if
        """)
    }

    /// Toggle Spotify playback (works whether playing or paused).
    @discardableResult
    static func spotifyPlayPause() -> Bool {
        runOSAScript("""
        if application "Spotify" is running then
            tell application "Spotify" to playpause
        end if
        """)
    }

    /// Toggle Spotify shuffle mode.
    @discardableResult
    static func spotifyShuffleToggle() -> Bool {
        runOSAScript("""
        if application "Spotify" is running then
            tell application "Spotify" to set shuffling to (not shuffling)
        end if
        """)
    }

    /// Toggle Spotify repeat mode.
    @discardableResult
    static func spotifyRepeatToggle() -> Bool {
        runOSAScript("""
        if application "Spotify" is running then
            tell application "Spotify" to set repeating to (not repeating)
        end if
        """)
    }

    private static func runOSAScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var err: NSDictionary?
        _ = script.executeAndReturnError(&err)
        return err == nil
    }
}
