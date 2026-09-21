#!/usr/bin/env python3
"""Bounded local-only regression using production tunnel lifecycle and bridge.
Only external platform probing/authentication and temporary-directory boundaries
are substituted. No SSH connection or user process is touched.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Packages/HerdrKit/Sources/HerdrKit/Platform/macOS'

with tempfile.TemporaryDirectory(prefix='herdr-owned-', dir='/tmp') as directory:
    out = Path(directory)
    tunnel = (SOURCE / 'SSHTunnel.swift').read_text()
    # Keep the actor's complete lifecycle, ending before unrelated diagnosis helpers.
    tunnel = tunnel[tunnel.index('public actor SSHTunnel'):tunnel.index('    /// Returns an asynchronous forwarding error')]
    start = tunnel.index('        if let remotePlatform { return remotePlatform }')
    end = tunnel.index('    public func remoteSocketPath()', start)
    tunnel = tunnel[:start] + '''        await ProbeGate.shared.probe()
        return .windows(home: "fixture-home", herdrExecutable: "fixture.exe")
    }

''' + tunnel[end:]
    tunnel = tunnel.replace('FileManager.default.temporaryDirectory', 'URL(fileURLWithPath: fixtureRoot)')
    tunnel += '''
    static func authenticationConfiguration(for id: UUID?) -> SSHAuthenticationConfiguration { .init() }
    static func sshDestination(_ s: String) -> String { s }
    static func powershellEncodedCommand(_ s: String) -> String { s }
    private static func failureReason(status: Int32, stderr: String) -> String { stderr }
    private func resetErrorCapture() {}
    private func finishErrorCapture() -> String { "" }
}
'''
    prefix = '''import Foundation
import CryptoKit
import Darwin
let fixtureRoot = CommandLine.arguments[2]
struct SSHAuthenticationConfiguration { let arguments: [String] = []; let environment: [String:String] = [:]; func discardAuthorization() {} }
enum HerdrError: Error { case tunnelFailed(String) }
final class SSHErrorBuffer: @unchecked Sendable { func append(_ d: Data) {}; var text: String { "" } }
actor ProbeGate {
 static let shared = ProbeGate()
 var continuation: CheckedContinuation<Void,Never>?
 var entered = false
 var first = true
 func probe() async { if first { first = false; entered = true; await withCheckedContinuation { continuation = $0 } } }
 func release() { continuation?.resume(); continuation = nil }
}
'''
    bridge = (SOURCE / 'SSHRemoteAPIBridge.swift').read_text()
    # Before the repair, use the existing synchronous teardown to establish RED.
    shutdown = 'let stopped = await bridge.stopAndWait(); precondition(stopped)' if 'func stopAndWait(' in bridge else 'bridge.stop()'
    main = '''
func connectSocket(_ path: String) -> Int32 {
 let fd = socket(AF_UNIX, SOCK_STREAM, 0)
 var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
 withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
 let rc = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
 if rc != 0 { close(fd); return -1 }; return fd
}
@main struct Main {
 static func main() async throws {
  if CommandLine.arguments[1] == "race" {
   let old = SSHTunnel(target: "fixture-only")
   let task = Task { try await old.ensureUp() }
   while !(await ProbeGate.shared.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
   task.cancel(); await old.tearDown()
   // A real replacement listener; never starts SSH even if accept wins teardown.
   let replacement = SSHRemoteAPIBridge(localSocketPath: SSHTunnel.localSocketPath(for: "fixture-only"), target: "unused", herdrExecutable: "unused", credentialID: nil, configureProcess: { p in p.executableURL = URL(fileURLWithPath: "/bin/cat"); p.arguments = [] })
   try replacement.start()
   await ProbeGate.shared.release()
   do { _ = try await task.value; fatalError("expected cancellation") } catch is CancellationError {}
   let fd = connectSocket(replacement.localSocketPath)
   print("replacement connect FD: \\(fd)"); fflush(stdout)
   precondition(fd >= 0, "obsolete probe unlinked replacement listener")
   close(fd); replacement.stop()
  } else {
   let bridge = SSHRemoteAPIBridge(localSocketPath: fixtureRoot + "/quit.sock", target: "fixture-only", herdrExecutable: "unused", credentialID: nil, configureProcess: { p in
    p.executableURL = URL(fileURLWithPath: fixtureRoot + "/resistant"); p.arguments = [fixtureRoot + "/child.pid"]
   }, makeAuthentication: { .init() })
   try bridge.start()
   let fd = connectSocket(bridge.localSocketPath); precondition(fd >= 0)
   for _ in 0..<2000 {
    if FileManager.default.fileExists(atPath: fixtureRoot + "/child.pid") { break }
    try await Task.sleep(nanoseconds: 1_000_000)
   }
   precondition(FileManager.default.fileExists(atPath: fixtureRoot + "/child.pid"))
   let start = Date()
   SHUTDOWN
   print("owned shutdown returned after \\(Date().timeIntervalSince(start)) seconds; exiting owner")
   fflush(stdout); exit(0)
  }
 }
}
'''.replace('SHUTDOWN', shutdown)
    (out / 'Fixture.swift').write_text(prefix + tunnel + bridge + main)
    (out / 'resistant.c').write_text('#include <signal.h>\n#include <unistd.h>\n#include <stdio.h>\nint main(int argc,char**argv){signal(SIGTERM,SIG_IGN);signal(SIGHUP,SIG_IGN);alarm(10);FILE*f=fopen(argv[1],"w");fprintf(f,"%d",getpid());fclose(f);for(;;)pause();}\n')
    subprocess.run(['cc', str(out / 'resistant.c'), '-o', str(out / 'resistant')], check=True, timeout=30)
    subprocess.run(['swiftc', '-parse-as-library', str(out / 'Fixture.swift'), '-o', str(out / 'fixture')], check=True, timeout=60)
    race = subprocess.run([str(out / 'fixture'), 'race', directory], timeout=10)
    try:
        owner = subprocess.run([str(out / 'fixture'), 'quit', directory], timeout=10)
        pid = int((out / 'child.pid').read_text())
        try:
            os.kill(pid, 0)
            alive = True
        except ProcessLookupError:
            alive = False
        print(f'owner exit={owner.returncode}; proxy survives owner exit={alive}', flush=True)
        assert owner.returncode == 0 and not alive, 'owned proxy survived affirmative owner termination'
        assert race.returncode == 0, 'replacement connection regression'
    finally:
        if (out / 'child.pid').exists():
            try:
                os.kill(int((out / 'child.pid').read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
    print('PASS: replacement connects; resistant proxy exits before owner')
