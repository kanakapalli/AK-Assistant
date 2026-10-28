import Foundation

/// A phrase you can say to the AI hotkey, shown in Learn.
struct ToolExample: Identifiable, Hashable {
    let phrase: String
    /// Learn shows a "Try" button for safe examples. Risky ones and ones that act on the
    /// window in front (which would be Duck Keyboard itself) are say-only.
    var tryable = true
    var id: String { phrase }
}

/// One family of Mac commands, for Learn and for "what can you do?".
struct ToolGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let examples: [ToolExample]
    var note: String? = nil
}

enum ToolCatalog {
    static let groups: [ToolGroup] = [
        ToolGroup(
            id: "apps", title: "Apps & windows", symbol: "macwindow.on.rectangle",
            summary: "Open, switch to, hide or quit any app by name. Small mishearings like “ex code” still find Xcode.",
            examples: [
                ToolExample(phrase: "Open Xcode"),
                ToolExample(phrase: "Launch Safari"),
                ToolExample(phrase: "Switch to Finder"),
                ToolExample(phrase: "Open System Settings"),
                ToolExample(phrase: "Hide Chrome", tryable: false),
                ToolExample(phrase: "Hide all other apps", tryable: false),
                ToolExample(phrase: "Quit Slack", tryable: false),
                ToolExample(phrase: "Minimize this window", tryable: false),
                ToolExample(phrase: "New tab", tryable: false),
                ToolExample(phrase: "Close this tab", tryable: false),
                ToolExample(phrase: "Full screen", tryable: false),
            ],
            note: "Window commands go to the app you were using when you pressed the hotkey."
        ),
        ToolGroup(
            id: "web", title: "Websites & search", symbol: "safari",
            summary: "Open well-known sites or any web address, and search Google, YouTube, Wikipedia, Amazon, GitHub, Reddit, Maps and more.",
            examples: [
                ToolExample(phrase: "Open YouTube"),
                ToolExample(phrase: "Go to github.com"),
                ToolExample(phrase: "Search YouTube for lofi music"),
                ToolExample(phrase: "Google Swift concurrency"),
                ToolExample(phrase: "Look up black holes on Wikipedia"),
                ToolExample(phrase: "Pictures of the northern lights"),
                ToolExample(phrase: "Directions to the airport"),
            ]
        ),
        ToolGroup(
            id: "files", title: "Files, folders & settings", symbol: "folder",
            summary: "Open folders and System Settings pages, find files with Spotlight, and run your Shortcuts.",
            examples: [
                ToolExample(phrase: "Open Downloads"),
                ToolExample(phrase: "Open the Documents folder"),
                ToolExample(phrase: "Find files named invoice"),
                ToolExample(phrase: "Open file budget"),
                ToolExample(phrase: "Open Wi-Fi settings"),
                ToolExample(phrase: "Open Bluetooth settings"),
                ToolExample(phrase: "Run shortcut Morning routine"),
            ],
            note: "“Find files” searches your home folder and selects the newest matches in Finder."
        ),
        ToolGroup(
            id: "sound", title: "Sound & music", symbol: "speaker.wave.2",
            summary: "Change the volume and control whatever is playing: Music, Spotify, YouTube in the browser.",
            examples: [
                ToolExample(phrase: "Set volume to 40"),
                ToolExample(phrase: "Turn it up"),
                ToolExample(phrase: "Turn the volume down"),
                ToolExample(phrase: "Mute"),
                ToolExample(phrase: "Unmute"),
                ToolExample(phrase: "Pause the music"),
                ToolExample(phrase: "Next song"),
                ToolExample(phrase: "Previous track"),
            ]
        ),
        ToolGroup(
            id: "display", title: "Screen & system", symbol: "display",
            summary: "Brightness, dark mode, screenshots, Wi-Fi and keeping your Mac awake.",
            examples: [
                ToolExample(phrase: "Brightness up"),
                ToolExample(phrase: "Dim the screen"),
                ToolExample(phrase: "Turn on dark mode"),
                ToolExample(phrase: "Switch to light mode"),
                ToolExample(phrase: "Take a screenshot"),
                ToolExample(phrase: "Screenshot of an area"),
                ToolExample(phrase: "Record my screen"),
                ToolExample(phrase: "Turn off Wi-Fi", tryable: false),
                ToolExample(phrase: "Keep my Mac awake for 1 hour"),
                ToolExample(phrase: "Stop keeping my Mac awake"),
                ToolExample(phrase: "Start the screen saver", tryable: false),
            ],
            note: "Dark mode asks once for permission to control System Events."
        ),
        ToolGroup(
            id: "timers", title: "Timers & reminders", symbol: "timer",
            summary: "Countdowns, reminders at a time or after a while, and alarms. You get a notification and the popup reads it out.",
            examples: [
                ToolExample(phrase: "Set a timer for 10 minutes"),
                ToolExample(phrase: "Set a 25 minute timer"),
                ToolExample(phrase: "Remind me in 20 minutes to call mom"),
                ToolExample(phrase: "Remind me at 5 pm to check the oven"),
                ToolExample(phrase: "Remind me tomorrow at 9 to send the report"),
                ToolExample(phrase: "Set an alarm for 7 am"),
                ToolExample(phrase: "How much time is left"),
                ToolExample(phrase: "Cancel all timers"),
            ],
            note: "Timers live inside Duck Keyboard: quitting the app cancels them. Running ones are listed in the menu bar."
        ),
        ToolGroup(
            id: "info", title: "Quick info", symbol: "info.circle",
            summary: "Answers straight from your Mac, instantly and without the AI model.",
            examples: [
                ToolExample(phrase: "What time is it"),
                ToolExample(phrase: "What's today's date"),
                ToolExample(phrase: "What's my battery"),
                ToolExample(phrase: "How much space do I have"),
                ToolExample(phrase: "How much memory does my Mac have"),
                ToolExample(phrase: "What's my IP address"),
                ToolExample(phrase: "Which version of macOS am I on"),
                ToolExample(phrase: "How long has my Mac been on"),
                ToolExample(phrase: "What's on my clipboard"),
            ]
        ),
        ToolGroup(
            id: "text", title: "Typing & clipboard", symbol: "keyboard",
            summary: "Type a phrase into the app you're using, or put text on the clipboard.",
            examples: [
                ToolExample(phrase: "Type Thanks, talk soon!", tryable: false),
                ToolExample(phrase: "Copy see you at 6 to clipboard"),
            ],
            note: "For longer text, use the dictation hotkey instead: it's made for that."
        ),
        ToolGroup(
            id: "power", title: "Lock, sleep & power", symbol: "power",
            summary: "Lock the screen, sleep the display or the Mac, empty the Trash, restart, shut down or log out.",
            examples: [
                ToolExample(phrase: "Lock my screen", tryable: false),
                ToolExample(phrase: "Turn off the display", tryable: false),
                ToolExample(phrase: "Go to sleep", tryable: false),
                ToolExample(phrase: "Empty the trash", tryable: false),
                ToolExample(phrase: "Restart my Mac", tryable: false),
                ToolExample(phrase: "Shut down", tryable: false),
                ToolExample(phrase: "Log out", tryable: false),
            ],
            note: "Restart, shut down and log out show macOS's own confirmation. Turn on “Ask before risky actions” in Settings to confirm the others too."
        ),
    ]

    /// The answer to "what can you do?".
    static let spokenSummary = """
        Besides answering questions, I can work your Mac. Open or quit apps, open websites and search the web, \
        find files, set timers and reminders, change the volume, brightness and dark mode, control music, \
        take screenshots, lock or sleep your Mac, and tell you the time, your battery or free space. \
        Try “open Xcode” or “set a timer for 10 minutes”. The Learn section in Duck Keyboard lists everything.
        """

    /// Command phrases the AI model may hand back with "ACTION:" when you phrase something unusually.
    static var phrasesForModel: String {
        groups.flatMap { $0.examples.map(\.phrase) }.joined(separator: "; ")
    }
}
