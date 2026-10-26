import Foundation

/// Recognises Mac commands in what you said to the AI hotkey ("open Xcode", "set a timer for
/// 10 minutes", "volume 30"). It's plain pattern matching, so it's instant, works offline without
/// loading the AI model, and behaves the same every time. Anything it doesn't recognise goes to the AI,
/// which can still hand a command back (see `LLMService.actionInstructions`).
enum CommandParser {
    static func parse(_ text: String, now: Date = .now) -> MacCommand? {
        let s = clean(text)
        guard !s.isEmpty, s.count <= 200 else { return nil }
        // Order matters: specific phrases first, the catch-all "open …" / "quit …" last.
        // (A loop rather than a long `??` chain, which is very slow for the Swift type checker.)
        let groups: [(String) -> MacCommand?] = [
            help,
            { timers($0, now: now) },
            info, media, sound, display, power, windows,
            { textCommands($0, original: text) },
            files, search, apps,
        ]
        for group in groups {
            if let command = group(s) { return command }
        }
        return nil
    }

    // MARK: - Cleaning

    /// Lowercases, tidies punctuation and drops polite wrappers ("hey, can you please … for me").
    static func clean(_ text: String) -> String {
        var s = normalize(text)
        let prefixes = [
            "hey ak assistant ", "hey ak ", "ak assistant ", "hey assistant ", "hey ", "hi ", "ok ", "okay ", "so ",
            "can you please ", "could you please ", "would you please ", "will you please ", "please ", "kindly ",
            "can you ", "could you ", "would you ", "will you ", "can u ", "i want you to ", "i'd like you to ",
            "i would like you to ", "i need you to ", "i want to ", "i'd like to ", "i would like to ", "i need to ",
            "go ahead and ", "just ", "quickly ", "now ", "and ", "let's ", "lets ",
        ]
        let suffixes = [" please", " for me", " right now", " now", " quickly", " thanks", " thank you", " ok", " okay"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)); changed = true
            }
            for x in suffixes where s.hasSuffix(x) && s.count > x.count {
                s = String(s.dropLast(x.count)); changed = true
            }
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "p.m.", with: "pm").replacingOccurrences(of: "a.m.", with: "am")
        s = s.replacingOccurrences(of: #"\bwi[- ]?fi\b"#, with: "wifi", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\bx[- ]code\b"#, with: "xcode", options: .regularExpression)
        s = s.replacingOccurrences(of: " dot ", with: ".")
        s = s.replacingOccurrences(of: #"[,!?;"“”…]"#, with: " ", options: .regularExpression)
        // Sentence full stops (but not the dot in "youtube.com" or "2.5").
        s = s.replacingOccurrences(of: #"\.(\s|$)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Groups of commands

    private static func help(_ s: String) -> MacCommand? {
        if m(#"what (?:all )?can you do|what else can you do|help|what are (?:your|the) (?:commands|features|skills|tools)|(?:show|list|tell) (?:me )?(?:all )?(?:your |the )?(?:commands|features|tools)|what commands (?:do you (?:know|support|understand)|are there|can i (?:use|say))|how do i use (?:you|this|this app|ak assistant)"#, s) != nil {
            return .help
        }
        return nil
    }

    private static func timers(_ s: String, now: Date) -> MacCommand? {
        if m(#"(?:cancel|stop|delete|clear|remove|turn off|dismiss) (?:all )?(?:of )?(?:my |the )?(?:timers?|reminders?|alarms?|countdown)(?: (?:and )?(?:my |the )?(?:reminders?|timers?|alarms?))?"#, s) != nil {
            return .cancelTimers
        }
        if m(#"(?:how much time (?:is )?(?:left|remaining)|how long (?:is )?left|time left|time remaining|(?:check|show|list) (?:my |the )?(?:timers?|reminders?|alarms?)|(?:what|which) (?:timers?|reminders?|alarms?) (?:do i have|are (?:running|set|on))|(?:do i have|are there) any (?:timers?|reminders?|alarms?)(?: (?:running|set))?)(?: on (?:my |the )?timer)?"#, s) != nil {
            return .timerStatus
        }

        // Timers
        if let g = m(#"(?:set|start|create|put on|make|add)? ?(?:a |an |the |me a )?(?:timer|countdown) (?:for |of |to |on )?(.+)"#, s),
           let d = duration(g[1]) {
            return .startTimer(d)
        }
        if let g = m(#"(?:set|start|create|make|add)? ?(?:a |an |me a )?(.+?) (?:timer|countdown)"#, s), let d = duration(g[1]) {
            return .startTimer(d)
        }
        if let g = m(#"(?:wake me(?: up)?|ping me|alert me|tell me) (?:in|after) (.+)"#, s), let d = duration(g[1]) {
            return .startTimer(d)
        }

        // Alarms
        if let g = m(#"(?:set|create|add)? ?(?:an |a |my )?alarm (?:for |at |to )?(.+)"#, s), let date = timeOfDay(g[1], now: now) {
            return .remind(at: date, text: "Alarm")
        }
        if let g = m(#"wake me(?: up)? (?:at |by )?(.+)"#, s), let date = timeOfDay(g[1], now: now) {
            return .remind(at: date, text: "Wake up")
        }

        // Reminders
        let starts = ["remind me ", "set a reminder ", "set reminder ", "create a reminder ", "add a reminder ", "make a reminder ", "reminder "]
        guard let start = starts.first(where: { s.hasPrefix($0) }) else { return nil }
        var body = String(s.dropFirst(start.count))
        for lead in ["for ", "that i need ", "that i have "] where body.hasPrefix(lead) { body = String(body.dropFirst(lead.count)) }

        // "in 20 minutes to call mom"
        if let g = m(#"(?:in|after) (.+?) (?:to|that|about|for) (.+)"#, body), let d = duration(g[1]) {
            return .remind(at: now.addingTimeInterval(d), text: reminderText(g[2]))
        }
        // "at 5 pm to call mom", "tomorrow at 9 to …"
        if let g = m(#"((?:tomorrow |today |tonight )?(?:at |by )?.+?) (?:to|that|about) (.+)"#, body), let date = timeOfDay(g[1], now: now) {
            return .remind(at: date, text: reminderText(g[2]))
        }
        // "to call mom in 20 minutes" / "to call mom at 5 pm"
        for sep in [" in ", " after "] {
            if let r = body.range(of: sep, options: .backwards), let d = duration(String(body[r.upperBound...])) {
                return .remind(at: now.addingTimeInterval(d), text: reminderText(String(body[..<r.lowerBound])))
            }
        }
        for sep in [" tomorrow at ", " tomorrow morning at ", " tonight at ", " today at ", " at ", " by ", " tomorrow", " tonight"] {
            if let r = body.range(of: sep, options: .backwards) {
                let when = sep.trimmingCharacters(in: .whitespaces) + " " + String(body[r.upperBound...])
                if let date = timeOfDay(when, now: now) {
                    return .remind(at: date, text: reminderText(String(body[..<r.lowerBound])))
                }
            }
        }
        return nil
    }

    private static func reminderText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for lead in ["to ", "that ", "about ", "i need to ", "i have to ", "i should "] where t.hasPrefix(lead) {
            t = String(t.dropFirst(lead.count))
        }
        return t.isEmpty ? "Reminder" : t.capitalizedFirst
    }

    private static func info(_ s: String) -> MacCommand? {
        if m(#"what(?:'s| is) the (?:current )?time(?: now| right now)?|what time is it(?: now| right now)?|(?:tell|give) me the time|current time|time now|time"#, s) != nil {
            return .info(.time)
        }
        if m(#"what(?:'s| is) (?:today's date|the date(?: today)?|today|the day(?: today)?)|what(?:'s| is) today's date|(?:what|which) day is (?:it|today)(?: today)?|today's date|date today|what date is (?:it|today)|(?:tell|give) me the date"#, s) != nil {
            return .info(.date)
        }
        if m(#"(?:what(?:'s| is) )?(?:my |the )?battery(?: level| percentage| percent| status| life| charge)?(?: at| now| left)?|how much (?:battery|charge)(?: (?:do i have|is left|have i got))?(?: left)?|how(?:'s| is) (?:my |the )?battery(?: doing| life)?|check (?:my |the )?battery|is (?:my |the )?(?:mac|laptop|battery) charging"#, s) != nil {
            return .info(.battery)
        }
        if m(#"how much (?:free |disk |storage )?(?:space|storage)(?: do i have| is left| left| is free| is available| have i got)?(?: on (?:my |this |the )?(?:mac|disk|computer|drive|laptop))?(?: left)?|(?:check |what(?:'s| is) (?:my |the ))?(?:free |disk |available )?(?:storage|disk space|free space)(?: left)?"#, s) != nil {
            return .info(.storage)
        }
        if m(#"how much (?:ram|memory)(?: do i have| does (?:my |this )?mac have| is (?:installed|there)| have i got)?|(?:what(?:'s| is) (?:my |the ))?(?:ram|memory)(?: size)?"#, s) != nil {
            return .info(.memory)
        }
        if m(#"uptime|(?:what(?:'s| is) (?:my |the ))?uptime|how long (?:has|have) (?:my |the |this )?(?:mac|computer|laptop|it|i) been (?:on|running|up|awake)"#, s) != nil {
            return .info(.uptime)
        }
        if m(#"(?:what|which) (?:version of mac ?os|mac ?os version|os version|version of the os|version of mac|mac version)(?: (?:am i (?:on|running|using)|is this|do i have|is installed|is (?:my|this) mac (?:on|running)))?|mac ?os version"#, s) != nil {
            return .info(.macOSVersion)
        }
        if m(#"(?:what(?:'s| is) )?(?:my |the )?(?:local )?ip(?: address)?(?: of (?:this|my) mac)?"#, s) != nil {
            return .info(.ipAddress)
        }
        if m(#"what(?:'s| is) (?:on|in) (?:my |the )?clipboard|read (?:me )?(?:my |the )?clipboard|clipboard"#, s) != nil {
            return .info(.clipboard)
        }
        if m(#"(?:what|which) app (?:is (?:this|open|in front|active)|am i (?:in|using))"#, s) != nil {
            return .info(.frontApp)
        }
        return nil
    }

    private static func media(_ s: String) -> MacCommand? {
        if m(#"(?:play|pause|resume)(?: (?:the )?(?:music|song|track|video|audio|playback|media|it))?|stop (?:the )?(?:music|song|video|playback)|play pause|toggle (?:play|playback)"#, s) != nil {
            return .media(.playPause)
        }
        if m(#"(?:next|skip)(?: (?:song|track|video|one))?|skip (?:this |the )?(?:song|track)|play (?:the )?next(?: song| track)?"#, s) != nil {
            return .media(.next)
        }
        if m(#"previous(?: (?:song|track|video))?|last (?:song|track)|go back (?:a |one )?(?:song|track)|play (?:the )?previous(?: song| track)?|play (?:that|the) (?:last|previous) (?:song|track)(?: again)?"#, s) != nil {
            return .media(.previous)
        }
        return nil
    }

    private static func sound(_ s: String) -> MacCommand? {
        let n = wordsToDigits(s)
        if m(#"(?:(?:set|turn|put|make) (?:the )?)?(?:volume|sound)(?: level)? (?:to |at )?(?:max(?:imum)?|full|100(?: ?%| percent)?)|max(?:imum)? volume|full volume|(?:turn|crank) it all the way up"#, n) != nil {
            return .setVolume(100)
        }
        if let g = m(#"(?:(?:set|change|turn|put|make|adjust) (?:the )?)?(?:volume|sound)(?: level)?(?: to| at)? (\d{1,3})(?: ?%| percent)?"#, n), let v = Int(g[1]) {
            return .setVolume(min(100, v))
        }
        if m(#"(?:(?:set|turn|put) (?:the )?)?volume (?:to |at )?half(?: way)?"#, n) != nil {
            return .setVolume(50)
        }
        if m(#"turn (?:it |the volume |the sound |the music )?up(?: the (?:volume|sound|music))?|(?:increase|raise|boost|turn up) (?:the )?(?:volume|sound|music)|volume up|(?:make it |a (?:bit|little) |little )?louder"#, s) != nil {
            return .volumeStep(up: true)
        }
        if m(#"turn (?:it |the volume |the sound |the music )?down(?: the (?:volume|sound|music))?|(?:decrease|lower|reduce|turn down) (?:the )?(?:volume|sound|music)|volume down|(?:make it |a (?:bit|little) |little )?(?:quieter|softer)"#, s) != nil {
            return .volumeStep(up: false)
        }
        if m(#"unmute(?: (?:the )?(?:sound|volume|audio|mac|computer|it|speakers?))?|(?:turn on|restore|bring back) (?:the )?(?:sound|audio)"#, s) != nil {
            return .mute(false)
        }
        if m(#"(?:mute|silence)(?: (?:the )?(?:sound|volume|audio|mac|computer|it|speakers?|everything))?|(?:turn off|kill) (?:the )?(?:sound|audio)"#, s) != nil {
            return .mute(true)
        }
        return nil
    }

    private static func display(_ s: String) -> MacCommand? {
        if m(#"(?:increase|raise|turn up|boost) (?:the )?(?:screen |display )?brightness|(?:screen |display )?brightness up|turn (?:the )?(?:screen )?brightness up|(?:make (?:the )?(?:screen|display) |make it )?brighter"#, s) != nil {
            return .brightnessStep(up: true)
        }
        if m(#"(?:decrease|lower|reduce|turn down) (?:the )?(?:screen |display )?brightness|(?:screen |display )?brightness down|turn (?:the )?(?:screen )?brightness down|(?:make (?:the )?(?:screen|display) |make it )?dimmer|dim (?:the )?(?:screen|display)"#, s) != nil {
            return .brightnessStep(up: false)
        }
        if m(#"(?:toggle|switch|change) (?:the )?(?:dark mode|appearance|theme)"#, s) != nil {
            return .darkMode(nil)
        }
        if m(#"(?:turn off|disable|deactivate) (?:the )?dark (?:mode|theme)|dark (?:mode|theme) off|(?:turn on|enable|switch to|use|activate|go|change to) (?:the )?light (?:mode|theme)|light (?:mode|theme)(?: on)?"#, s) != nil {
            return .darkMode(false)
        }
        if m(#"(?:turn on|enable|switch to|use|activate|go|change to) (?:the )?dark (?:mode|theme)|dark (?:mode|theme)(?: on)?|turn (?:the )?dark mode on"#, s) != nil {
            return .darkMode(true)
        }
        if s.contains("wifi"), m(#"(?:turn |switch )?(?:on |off )?(?:the |my )?wifi(?: on| off)?|(?:enable|disable|connect|disconnect)(?: the| from| to)? wifi"#, s) != nil {
            if s.contains(" off") || s.hasPrefix("off") || s.contains("disable") || s.contains("disconnect") { return .wifi(false) }
            if s.contains(" on") || s.hasPrefix("on ") || s.contains("enable") || s.contains("connect") { return .wifi(true) }
        }
        if m(#"(?:take |capture |grab |make )?(?:a )?(?:screenshot|screen ?shot|screen capture|capture)(?: of)? (?:a |an |the |part of the |part of my |part of )?(?:part|area|selection|region|portion|section|window)(?: of (?:the |my )?screen)?|(?:take |capture )?(?:a )?partial screenshot"#, s) != nil {
            return .screenshot(.selection)
        }
        if m(#"(?:start )?(?:a )?(?:screen recording|recording of (?:the |my )?screen)|record (?:the |my |this )?screen"#, s) != nil {
            return .screenshot(.recording)
        }
        if m(#"(?:take |capture |grab |make )?(?:a )?(?:screenshot|screen ?shot|screen capture|screen grab)(?: of)?(?: (?:the |my |this )?(?:whole |full |entire )?screen)?|capture (?:the |my )?(?:whole |full |entire )?screen|screenshot (?:this|it)"#, s) != nil {
            return .screenshot(.fullScreen)
        }
        return nil
    }

    private static func power(_ s: String) -> MacCommand? {
        if m(#"lock(?: (?:the |my |this )?(?:screen|mac|computer|laptop|system))?|lock it(?: up)?|lock up"#, s) != nil { return .lockScreen }
        if m(#"(?:turn off|sleep|switch off) (?:the |my )?(?:display|screen|monitor)|(?:display|screen|monitor) (?:off|sleep)|put (?:the |my )?(?:display|screen|monitor) to sleep"#, s) != nil {
            return .sleepDisplay
        }
        if m(#"go to sleep|sleep(?: now)?|(?:put|send) (?:the |my |this )?(?:mac|computer|laptop|system) to sleep|sleep (?:the |my |this )?(?:mac|computer|laptop)"#, s) != nil {
            return .sleepMac
        }
        if m(#"(?:start|turn on|show|run|activate) (?:the |my )?screen ?saver|screen ?saver"#, s) != nil { return .screenSaver }

        if m(#"(?:stop keeping|stop) (?:my |the |this )?(?:mac |computer |screen |laptop )?(?:it )?awake|(?:let|allow) (?:my |the |this )?(?:mac|computer|screen|laptop|it) (?:to )?sleep(?: again)?|stop caffeinat(?:e|ing)|allow sleep|(?:turn off|disable) (?:keep awake|caffeinate)"#, s) != nil {
            return .stopKeepAwake
        }
        for pattern in [
            #"(?:keep|stay)(?: my| the| this)?(?: mac| computer| screen| laptop| display| it)? awake(?: for (.+))?"#,
            #"(?:don't|do not) (?:let (?:my |the |this )?(?:mac|computer|screen|laptop|display|it) )?(?:go to )?sleep(?: for (.+))?"#,
            #"caffeinate(?: (?:for )?(.+))?"#,
        ] {
            if let g = m(pattern, s) {
                return .keepAwake(g[1].isEmpty ? nil : duration(g[1]))
            }
        }

        if m(#"empty (?:the |my )?(?:trash|bin|recycle bin|trash can)|clear (?:the |my )?trash|take out the trash"#, s) != nil { return .emptyTrash }
        if m(#"(?:restart|reboot)(?: (?:the |my |this )?(?:mac|computer|laptop|system))?"#, s) != nil { return .restart }
        if m(#"(?:shut ?down|power (?:off|down))(?: (?:the |my |this )?(?:mac|computer|laptop|system))?|(?:turn|switch) off (?:the |my |this )?(?:mac|computer|laptop|system)"#, s) != nil {
            return .shutDown
        }
        if m(#"(?:log ?out|log off|sign out|sign off)(?: of)?(?: (?:my |the |this )?(?:mac|account|computer|user))?"#, s) != nil { return .logOut }
        return nil
    }

    private static func windows(_ s: String) -> MacCommand? {
        if m(#"minimi[sz]e(?: (?:this|the|my|current|that) (?:window|app))?(?: it| this)?"#, s) != nil { return .window(.minimize) }
        if m(#"close (?:this |the |my |current |that )?window"#, s) != nil { return .window(.closeWindow) }
        if m(#"close (?:this |the |current |that )?tab"#, s) != nil { return .window(.closeTab) }
        if m(#"(?:open |create |make )?(?:a )?new tab"#, s) != nil { return .window(.newTab) }
        if m(#"(?:open |create |make )?(?:a )?new window"#, s) != nil { return .window(.newWindow) }
        if m(#"(?:go |make (?:it|this|the window) |enter |exit |toggle |switch to |leave )?full ?screen(?: mode)?|maximi[sz]e(?: (?:this|the|my|current) window)?(?: it| this)?"#, s) != nil {
            return .window(.fullScreen)
        }
        if m(#"hide (?:all )?(?:the )?(?:other|others|other apps|other windows|everything else|all other apps|all apps|everything|all windows)"#, s) != nil {
            return .hideOtherApps
        }
        if m(#"hide (?:this|current|the current)(?: app| window)?|hide it"#, s) != nil { return .hideApp("this") }
        return nil
    }

    private static func textCommands(_ s: String, original: String) -> MacCommand? {
        if let g = m(#"run (?:the |my )?shortcuts? (?:called |named )?(.+)|run (?:the |my )?(.+) shortcut"#, s) {
            let name = g[1].isEmpty ? g[2] : g[1]
            if !name.isEmpty { return .runShortcut(name) }
        }
        // Take the text from what you actually said, so capitals and punctuation survive.
        if m(#"(?:type|type out|write out) (?!of )(.+)"#, s) != nil,
           let r = original.range(of: #"\b(?:type out|write out|type)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let text = String(original[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return .typeText(text) }
        }
        if let g = m(#"copy (.+) to (?:the |my )?clipboard"#, s) {
            if let r = original.range(of: #"\bcopy\s+"#, options: [.regularExpression, .caseInsensitive]),
               let end = original.range(of: #"\s+to\s+(?:the\s+|my\s+)?clipboard"#, options: [.regularExpression, .caseInsensitive, .backwards]),
               r.upperBound < end.lowerBound {
                return .copyText(String(original[r.upperBound..<end.lowerBound]))
            }
            return .copyText(g[1])
        }
        return nil
    }

    private static func files(_ s: String) -> MacCommand? {
        if let g = m(#"(?:find|search for|search|locate|look for|where is|where's|show me|show) (?:a |the |my |all |any )?(?:files?|documents?|docs?|pdfs?)(?: that are)? (?:named|called|with the name|titled|with name|containing|that contain|matching|about) (.+)"#, s) {
            return .findFile(g[1])
        }
        if let g = m(#"(?:find|locate|where is|where's|search for) (?:the |my )?(?:file|document|pdf) (.+)"#, s) {
            return .findFile(g[1])
        }
        if let g = m(#"open (?:the |my )?(?:file|document|doc|pdf) (?:named |called |titled )?(.+)"#, s) {
            return .openFile(g[1])
        }
        return nil
    }

    private static func search(_ s: String) -> MacCommand? {
        if let g = m(#"(?:get |give me |show me |find )?(?:the )?directions (?:to|for) (.+)|(?:navigate|drive) to (.+)|how (?:do i|can i|to) get to (.+)"#, s) {
            let place = [g[1], g[2], g[3]].first { !$0.isEmpty } ?? ""
            if !place.isEmpty { return .directions(place) }
        }

        let names: [(name: String, site: SearchSite)] = SearchSite.allCases
            .flatMap { site in site.spokenNames.map { (name: $0, site: site) } }
            .sorted { $0.name.count > $1.name.count }
        let alternation = names.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
        func site(_ name: String) -> SearchSite? { names.first { $0.name == name }?.site }
        func query(_ raw: String) -> String {
            var q = raw
            for lead in ["for ", "about "] where q.hasPrefix(lead) { q = String(q.dropFirst(lead.count)) }
            return q
        }

        // "search youtube for lofi music", "look up python on wikipedia", "play lofi on youtube"
        if let g = m(#"(?:search for|search|look up|look for|find|check) (?:on )?("# + alternation + #") for (.+)"#, s), let site = site(g[1]) {
            return .webSearch(site, query(g[2]))
        }
        if let g = m(#"(?:search for|search|look up|look for|find|play|watch|show me|check) (.+) (?:on|in|from) ("# + alternation + #")"#, s), let site = site(g[2]) {
            return .webSearch(site, query(g[1]))
        }
        if let g = m(#"("# + alternation + #") search (?:for )?(.+)"#, s), let site = site(g[1]) {
            return .webSearch(site, query(g[2]))
        }
        if let g = m(#"(?:show me |find |search for )?(?:pictures|images|photos) of (.+)"#, s) {
            return .webSearch(.images, g[1])
        }
        if let g = m(#"google (.+)|(?:search the web for|search the internet for|search online for|search google for|google search for|google search|search for|search up|search|look up|web search) (.+)"#, s) {
            let q = query(g[1].isEmpty ? g[2] : g[1])
            if !q.isEmpty { return .webSearch(.google, q) }
        }
        return nil
    }

    private static func apps(_ s: String) -> MacCommand? {
        if let g = m(#"(?:quit|close|exit|kill|force quit|terminate) (.+)"#, s), let name = appName(g[1]) {
            return .quitApp(name)
        }
        if let g = m(#"hide (.+)"#, s), let name = appName(g[1]) {
            return .hideApp(name)
        }
        if let g = m(#"(?:open|launch|open up|fire up|boot up|start up|load up) (.+)"#, s), let name = appName(g[1]) {
            return .open(name, strict: true)
        }
        if let g = m(#"(?:start|run|bring up|switch to|go to|show me|show|activate|focus on|focus|pull up|take me to|get me|load) (.+)"#, s), let name = appName(g[1]) {
            return .open(name, strict: false)
        }
        return nil
    }

    /// "the xcode app" → "xcode". Long phrases are probably a question, not an app name.
    private static func appName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for lead in ["up ", "the ", "my ", "a "] where name.hasPrefix(lead) { name = String(name.dropFirst(lead.count)) }
        for tail in [" app", " application", " website", " site", " web site", " for me", " please", " again", " now"] where name.hasSuffix(tail) {
            name = String(name.dropLast(tail.count))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        let words = name.split(separator: " ").count
        guard !name.isEmpty, words <= 5 else { return nil }
        return name
    }

    // MARK: - Durations and times

    /// "10 minutes", "an hour and a half", "1 hour 20 minutes", "ninety seconds", "5" (minutes).
    static func duration(_ raw: String) -> TimeInterval? {
        var t = " " + raw.trimmingCharacters(in: .whitespaces) + " "
        let phrases: [(String, String)] = [
            (" half an hour ", " 30 minutes "), (" half hour ", " 30 minutes "), (" a half hour ", " 30 minutes "),
            (" half a minute ", " 30 seconds "), (" quarter of an hour ", " 15 minutes "), (" a quarter hour ", " 15 minutes "),
            (" quarter hour ", " 15 minutes "), (" a couple of minutes ", " 2 minutes "), (" a couple minutes ", " 2 minutes "),
            (" a few minutes ", " 3 minutes "), (" few minutes ", " 3 minutes "),
        ]
        for (a, b) in phrases { t = t.replacingOccurrences(of: a, with: b) }
        t = wordsToDigits(t)

        let unit = #"(hours?|hrs?|hr|h|minutes?|mins?|min|m|seconds?|secs?|sec|s)"#
        var total: TimeInterval = 0
        var found = false
        var rest = t

        func seconds(_ value: Double, _ u: String) -> Double {
            if u.hasPrefix("h") { return value * 3600 }
            if u.hasPrefix("m") { return value * 60 }
            return value
        }
        // "1 hour and a half", "2 and a half minutes"
        for pattern in [#"(\d+(?:\.\d+)?) "# + unit + #" and a half\b"#, #"(\d+(?:\.\d+)?) and a half "# + unit + #"\b"#] {
            for g in all(pattern, rest) {
                if let v = Double(g[1]) { total += seconds(v + 0.5, g[2]); found = true }
            }
            rest = rest.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let simple = #"(\d+(?:\.\d+)?)\s*"# + unit + #"\b"#
        for g in all(simple, rest) {
            if let v = Double(g[1]) { total += seconds(v, g[2]); found = true }
        }
        rest = rest.replacingOccurrences(of: simple, with: " ", options: .regularExpression)
        let leftover = rest.split(separator: " ").filter { !["and", "for", "of", "a", "an", "the", "timer", "countdown", "from", "now", "more"].contains($0) }

        if found { return leftover.isEmpty && total > 0 ? total : nil }
        // Just a number: minutes.
        let words = t.split(separator: " ")
        if words.count == 1, let v = Double(words[0]), v > 0 { return v * 60 }
        return nil
    }

    /// "5 pm", "5:30 pm", "17:30", "7 in the morning", "tomorrow at 9", "noon". Returns the next time it happens.
    static func timeOfDay(_ raw: String, now: Date = .now) -> Date? {
        var t = " " + wordsToDigits(raw.trimmingCharacters(in: .whitespaces)) + " "
        var dayOffset = 0
        var hint: String? = nil   // "am" / "pm"
        if t.contains(" tomorrow ") { dayOffset = 1; t = t.replacingOccurrences(of: " tomorrow ", with: " ") }
        let dayParts: [(String, String)] = [(" in the morning ", "am"), (" this morning ", "am"), (" morning ", "am"),
                            (" in the afternoon ", "pm"), (" this afternoon ", "pm"), (" afternoon ", "pm"),
                            (" in the evening ", "pm"), (" this evening ", "pm"), (" evening ", "pm"),
                            (" at night ", "pm"), (" tonight ", "pm")]
        for (phrase, h) in dayParts where t.contains(phrase) {
            hint = h
            t = t.replacingOccurrences(of: phrase, with: " ")
        }
        for word in [" today ", " at ", " by ", " for ", " around ", " o'clock ", " oclock "] {
            t = t.replacingOccurrences(of: word, with: " ")
        }
        t = t.trimmingCharacters(in: .whitespaces)

        let calendar = Calendar.current
        var hour: Int
        var minute = 0
        var meridiem: String? = hint
        if t == "noon" || t == "midday" {
            hour = 12; meridiem = nil
        } else if t == "midnight" {
            hour = 0; meridiem = nil
            if dayOffset == 0 { dayOffset = 1 }
        } else if let g = m(#"(\d{1,2})(?:[:. ](\d{2}))? ?(am|pm|a m|p m)?"#, t), let h = Int(g[1]) {
            hour = h
            minute = Int(g[2]) ?? 0
            if !g[3].isEmpty { meridiem = g[3].replacingOccurrences(of: " ", with: "") }
        } else {
            return nil
        }
        guard hour <= 23, minute <= 59 else { return nil }
        if let meridiem, hour <= 12 {
            if meridiem == "am" && hour == 12 { hour = 0 }
            if meridiem == "pm" && hour < 12 { hour += 12 }
        }

        let today = calendar.startOfDay(for: now)
        func at(_ h: Int, dayPlus: Int) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: dayPlus, to: today) else { return nil }
            return calendar.date(bySettingHour: h, minute: minute, second: 0, of: day)
        }
        if dayOffset > 0 { return at(hour, dayPlus: dayOffset) }
        // No am/pm and a 12-hour clock time: pick the next one ("at 5" at 2 pm means 5 pm).
        if meridiem == nil, (1...12).contains(hour) {
            for candidate in [hour, hour + 12] where candidate < 24 {
                if let date = at(candidate, dayPlus: 0), date > now { return date }
            }
            return at(hour, dayPlus: 1)
        }
        if let date = at(hour, dayPlus: 0), date > now { return date }
        return at(hour, dayPlus: 1)
    }

    /// "twenty five minutes" → "25 minutes", "a minute" → "1 minute".
    static func wordsToDigits(_ s: String) -> String {
        let ones: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
            "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]
        let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        let units: Set<String> = ["hour", "hours", "minute", "minutes", "second", "seconds", "min", "mins", "sec", "secs", "hundred", "percent"]
        let tokens = s.replacingOccurrences(of: #"(?<=[a-z])-(?=[a-z])"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        var out: [String] = []
        var current: Int? = nil
        func flush() { if let c = current { out.append(String(c)); current = nil } }
        for (i, tok) in tokens.enumerated() {
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            if let v = ones[tok] {
                if let c = current, c % 10 != 0 || c == 0 || c < 20 { flush() }   // "five five" → two numbers
                current = (current ?? 0) + v
            } else if let v = tens[tok] {
                flush()
                current = v
            } else if tok == "hundred" {
                current = (current ?? 1) * 100
            } else if (tok == "a" || tok == "an"), current == nil, units.contains(next) {
                current = 1
            } else if tok == "and", current != nil, ones[next] != nil || tens[next] != nil {
                continue
            } else {
                flush()
                out.append(tok)
            }
        }
        flush()
        return out.joined(separator: " ")
    }

    // MARK: - Regex helpers

    /// Whole-string match. Returns the full match plus every group ("" for groups that didn't take part).
    static func m(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else {
            assertionFailure("Bad pattern: \(pattern)")
            return nil
        }
        guard let r = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return groups(r, in: s)
    }

    /// Every match anywhere in the string.
    private static func all(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { groups($0, in: s) }
    }

    private static func groups(_ r: NSTextCheckingResult, in s: String) -> [String] {
        (0..<r.numberOfRanges).map { i in
            guard let range = Range(r.range(at: i), in: s) else { return "" }
            return String(s[range]).trimmingCharacters(in: .whitespaces)
        }
    }
}
