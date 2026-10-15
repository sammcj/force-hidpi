// PauseWrapper.swift
//
// `force-hidpi --pause-while <command> [args...]` asks the running instance
// to pause HiDPI, waits until it has, then execs the command in this
// process. The game inherits the PID the instance is watching, so the pause
// lasts exactly as long as the game. Intended for Steam launch options:
//   "/path/to/force-hidpi" --pause-while %command%

import AppKit

enum PauseHold {
    static let flag = "--pause-while"
    static let requestName = Notification.Name("com.force-hidpi.pause-request")
    static let ackName = Notification.Name("com.force-hidpi.pause-ack")
    /// Covers an activation already in flight plus the teardown. Past this
    /// the game launches regardless; a missed pause beats a game that won't start.
    static let ackTimeout: TimeInterval = 15

    static var steamLaunchOption: String {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().path
        return "\"\(binary)\" \(flag) %command%"
    }

    /// Display name for the menu status line: the enclosing .app if there is one.
    static func displayName(for program: String) -> String {
        let url = URL(fileURLWithPath: program)
        let app = url.pathComponents.last { $0.hasSuffix(".app") }
        return app.map { String($0.dropLast(4)) } ?? url.lastPathComponent
    }
}

func runPauseWrapper(_ command: [String], lockPath: String) -> Never {
    guard let program = command.first else {
        fputs("usage: force-hidpi \(PauseHold.flag) <command> [args...]\n", stderr)
        exit(64)
    }
    if isInstanceRunning(lockPath: lockPath) {
        requestPause(name: PauseHold.displayName(for: program))
    }
    let argv = command.map { strdup($0) } + [nil]
    execvp(program, argv)
    fputs("force-hidpi: cannot exec \(program): \(String(cString: strerror(errno)))\n", stderr)
    exit(127)
}

/// The instance holds an exclusive flock for its lifetime, so taking it
/// here means nothing is running and there is nobody to wait for.
private func isInstanceRunning(lockPath: String) -> Bool {
    let fd = open(lockPath, O_RDONLY)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return flock(fd, LOCK_EX | LOCK_NB) != 0
}

private func requestPause(name: String) {
    let center = DistributedNotificationCenter.default()
    let pid = String(getpid())
    var acked = false
    let observer = center.addObserver(forName: PauseHold.ackName, object: pid, queue: nil) { _ in
        acked = true
    }
    center.postNotificationName(PauseHold.requestName, object: pid,
                                userInfo: ["name": name], deliverImmediately: true)
    let deadline = Date().addingTimeInterval(PauseHold.ackTimeout)
    while !acked && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    center.removeObserver(observer)
    if !acked { fputs("force-hidpi: no pause confirmation, launching anyway\n", stderr) }
}
