//
//  LocalProcess.swift
//  
// This file contains the supporting infrastructure to run local processes that can be connected
// to a Termianl
//
//  Created by Miguel de Icaza on 4/5/20.
//
#if !os(iOS) && !os(Windows)
import Foundation
import Dispatch
#if false //canImport(Subprocess)
import Subprocess
import System
#endif

/// Delegate that is invoked by the ``LocalProcess`` class in response to various
/// process-related events.
public protocol LocalProcessDelegate: AnyObject {
    /// This method is invoked on the delegate when the process has exited
    /// - Parameter source: the local process that terminated
    /// - Parameter exitCode: the exit code returned by the process, or nil if this was an error caused during the IO reading/writing
    func processTerminated (_ source: LocalProcess, exitCode: Int32?)
    
    /// This method is invoked when data has been received from the local process that should be send to the terminal for processing.
    func dataReceived (slice: ArraySlice<UInt8>)

    /// This method should return the window size to report to the local process.
    func getWindowSize () -> winsize
}

/**
 * This class provides the capabilities to launch a local Unix process, and connect it to a `Terminal`
 * class or subclass.
 *
 * The `MacLocalTerminalView` is an example of this, it is a subclass of the
 * `MacTerminalView` NSView, and it connects that view to the local system, providing a complete
 * terminal emulator connected to running local commands.
 *
 * When you create an instance of `LocalProcess`, you provide a delegate that is used to notify
 * your application when data is received from the lcoal process, to request the desired window size
 * that you would like to give to the child process, and when the process terminates.
 *
 * Once you create this instance, you can start a child process by calling the `startProcess` method
 * which will start the process.   You can then send data to this underlying process using the
 * `send(data:)` method, and you will receive the output on the provided delegate with the
 * `dataReceived(slice:)` method.
 *
 * Received data is dispatched via the queue that you provide in the LocalProcess constructor, if none
 * is provided, this will default to `DispatchQueue.main`.  Generally, this is a good default, but if you
 * have your own main loop or a different dispatching system, you will need to pass your own (for example,
 * the `HeadlessTerminal` implementation in the test suite does this.
 *
 * The `terminate` call will send the `SIGTERM` signal to the child process.
 *
 * The `shellPid` property has the PID for the child process, and this can be used to send signals
 * to it using the `kill` API.
 *
 * The `childfd` property has the Unix file descriptor for the primary side of the created pseudo-terminal.
 *
 * This implementation uses swift-subprocess with openpty/login_tty for pseudo-terminal support.
 */
public class LocalProcess {
    let readSize = 128*1024
    
    /* The file descriptor used to communicate with the child process */
    public private(set) var childfd: Int32 = -1
    
    /* The PID of our subprocess */
    public private(set) var shellPid: pid_t = 0
    var debugIO = false
    
    /* number of sent requests */
    var sendCount = 0
    var total = 0

    weak var delegate: LocalProcessDelegate?
    
    // Queue used to send the data received from the local process
    var dispatchQueue: DispatchQueue
    
    // The queue we use to read, it feels more interactive if we
    // read here and then post to the main thread.   Otherwise it feels
    // chunky.
    var readQueue: DispatchQueue
    
    var io: DispatchIO?

    private let usesMainQueue: Bool
    private let pendingChunkFlushThreshold = 32
    private let pendingTimeSliceNs: UInt64 = 4_000_000
    private var pendingChunks: [[UInt8]] = []
    private var pendingChunkIndex: Int = 0
    private var pendingScheduled = false
    private let pendingLock = NSLock()
    
    #if false //canImport(Subprocess)
    // Swift Subprocess related properties
    private var subprocessTask: Task<Void, Error>?
    private var masterFd: Int32 = -1
    private var slaveFd: Int32 = -1
    #endif
    
    /**
     * Initializes the LocalProcess runner and communication with the host happens via the provided
     * `LocalProcessDelegate` instance.
     * - Parameter delegate: the delegate that will receive events or request data from your application
     * - Parameter dispatchQueue: this is the queue that will be used to post data received from the
     * child process when calling the `send(dataReceived:)` delegate method.  If the value provided is `nil`,
     * then this will default to `DispatchQueue.main`
     */
    public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil)
    {
        self.delegate = delegate
        self.dispatchQueue = dispatchQueue ?? DispatchQueue.main
        self.readQueue = DispatchQueue(label: "sender")
        self.usesMainQueue = self.dispatchQueue === DispatchQueue.main
    }

    private func enqueueReceivedData(_ bytes: [UInt8]) {
        pendingLock.lock()
        pendingChunks.append(bytes)
        let shouldSchedule = !pendingScheduled
        if shouldSchedule {
            pendingScheduled = true
        }
        pendingLock.unlock()
        if shouldSchedule {
            dispatchQueue.async { [weak self] in
                self?.drainReceivedData()
            }
        }
    }

    private func drainReceivedData() {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            var chunk: [UInt8]?
            pendingLock.lock()
            if pendingChunkIndex < pendingChunks.count {
                chunk = pendingChunks[pendingChunkIndex]
                pendingChunkIndex += 1
                if pendingChunkIndex >= pendingChunkFlushThreshold {
                    pendingChunks.removeFirst(pendingChunkIndex)
                    pendingChunkIndex = 0
                }
            } else {
                pendingChunks.removeAll(keepingCapacity: true)
                pendingChunkIndex = 0
                pendingScheduled = false
                pendingLock.unlock()
                return
            }
            pendingLock.unlock()

            if let chunk {
                delegate?.dataReceived(slice: chunk[...])
            }

            if DispatchTime.now().uptimeNanoseconds - start >= pendingTimeSliceNs {
                dispatchQueue.async { [weak self] in
                    self?.drainReceivedData()
                }
                return
            }
        }
    }
    
    // MARK: - GALACTIC PATCH: ordered, complete writes with a completion signal
    //
    // Three defects in one function, all of which a caller feels as a prompt
    // that arrived wrong rather than as an error:
    //
    // 1. A short write dropped its remainder. `DispatchIO.write` hands the
    //    handler the bytes it could NOT write, and the handler ignored that
    //    parameter — so anything the kernel declined was lost. A pty in raw
    //    mode accepts about 1022 bytes when the child is not draining
    //    (MEASURED on macOS 15), which is well inside the size of a composed
    //    prompt, so a prompt written to a busy child lost its tail.
    // 2. `total` was advanced by the whole count regardless of how much was
    //    written, so the one number that could have exposed 1 was wrong in
    //    exactly the case that mattered.
    // 3. Every call issued an independent one-shot write on a CONCURRENT
    //    global queue, so two sends had no order relative to each other. Two
    //    prompts written close together interleaved their bytes.
    //
    // Writes are now serialized on a queue of this process's own and each is
    // carried to completion — retrying the remainder the kernel declined —
    // before the next begins. `completion` reports when the bytes are
    // genuinely gone, which is the signal a caller needs to know when a
    // following keystroke can be sent: no fixed delay can answer that,
    // because how fast the child drains depends on what the child is doing.
    // `DispatchIO.write` is not the primitive for this, which is the second
    // thing MEASURED here and the reason this patch is a rewrite rather than a
    // guard. Handed more than a pty's input queue can take, it never called
    // its handler at all — not with a remainder, not with an error — while the
    // tty rang the bell once per rejected byte. So it can neither be asked how
    // much it wrote nor relied on to say it finished.
    //
    // Explicit writes on a queue of this process's own answer both. Chunks are
    // kept well under the queue's capacity so a single write never trips the
    // overflow that discards and beeps, and the loop simply carries on where
    // the kernel left off.
    private let writeQueue = DispatchQueue(
        label: "swiftterm.localprocess.write")

    /// Queued sends, oldest first. Only `writeQueue` touches this.
    private var writeBacklog: [(data: [UInt8], completion: ((Bool) -> Void)?)] = []
    private var writeInFlight = false

    /// Comfortably inside the ~1022 bytes a raw-mode pty was measured to take,
    /// so no single write can reach the overflow path.
    private static let writeChunkSize = 256

    /**
     * Sends the array slice to the local process using DispatchIO
     * - Parameter data: The range of bytes to send to the child process
     */
    public func send (data: ArraySlice<UInt8>)
    {
        send(data: data, completion: nil)
    }

    /**
     * Sends the array slice to the local process, reporting when every byte
     * has been written.
     * - Parameter data: The range of bytes to send to the child process
     * - Parameter completion: called with `true` once all bytes have been
     *   written, or `false` if the write failed or the process went away.
     *   Delivered on the queue this process posts delegate callbacks to —
     *   the main queue unless the host supplied another.
     */
    public func send (data: ArraySlice<UInt8>, completion: ((Bool) -> Void)?)
    {
        guard running else {
            if let completion { dispatchQueue.async { completion(false) } }
            return
        }
        let bytes = Array(data)
        writeQueue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            self.writeBacklog.append((bytes, completion))
            self.pumpWrites()
        }
    }

    /// Start the next queued write, if one is not already running.
    ///
    /// `writeQueue` only. One write at a time is the whole point: ordering
    /// between two sends is not otherwise defined, and a caller that composes
    /// a prompt out of several sends has no way to impose it from outside.
    private func pumpWrites() {
        guard !writeInFlight, !writeBacklog.isEmpty else { return }
        writeInFlight = true
        let item = writeBacklog.removeFirst()
        let copy = sendCount
        sendCount += 1
        if debugIO {
            print ("[SEND-\(copy)] Queuing data to client: \(item.data.count) bytes")
        }
        writeChunk(
            item.data, offset: 0, id: copy, stalls: 0,
            completion: item.completion)
    }

    /// Write from `offset` to the end, resuming where the kernel left off.
    ///
    /// `writeQueue` only. Runs until the payload is gone, the child refuses to
    /// take any of it, or an error says stop. `stalls` bounds only the
    /// pathological case — a child that has stopped reading entirely — and is
    /// reset by any progress at all, so a large payload against a merely slow
    /// child takes as many rounds as it needs rather than being given up on.
    private func writeChunk(
        _ data: [UInt8], offset: Int, id: Int, stalls: Int,
        completion: ((Bool) -> Void)?
    ) {
        guard running, childfd >= 0 else {
            if debugIO {
                print ("[SEND-\(id)] abandoned at \(offset) of \(data.count)")
            }
            finishWrite(false, completion: completion)
            return
        }

        var at = offset
        while at < data.count {
            let count = min(Self.writeChunkSize, data.count - at)
            let n = data[at..<(at + count)].withUnsafeBytes { buf in
                Foundation.write(childfd, buf.baseAddress, buf.count)
            }
            if n > 0 {
                at += n
                total += n
                continue
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                break
            }
            print ("Error writing data to the child, errno=\(errno)")
            if debugIO {
                print ("[SEND-\(id)] failed at \(at) of \(data.count)")
            }
            finishWrite(false, completion: completion)
            return
        }

        if at >= data.count {
            if debugIO {
                print ("[SEND-\(id)] completed bytes=\(total)")
            }
            finishWrite(true, completion: completion)
            return
        }

        // The child is not taking any more right now. Wait rather than spin:
        // the queue drains as it reads, and there is nothing to do until then.
        let progressed = at > offset
        let nextStalls = progressed ? 0 : stalls + 1
        guard nextStalls <= Self.maxStalledWriteAttempts else {
            if debugIO {
                print ("[SEND-\(id)] gave up at \(at) of \(data.count)")
            }
            finishWrite(false, completion: completion)
            return
        }
        writeQueue.asyncAfter(deadline: .now() + Self.stalledWriteRetryDelay) {
            [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            self.writeChunk(
                data, offset: at, id: id, stalls: nextStalls,
                completion: completion)
        }
    }

    /// `writeQueue` only. Release the lane and start whatever is behind.
    ///
    /// The completion is posted to `dispatchQueue` — the same queue delegate
    /// callbacks go to, the main one unless a host said otherwise — and not
    /// called here. A caller's closure belongs to the caller's context: in a
    /// host built with Swift's concurrency checking, one written where the
    /// rest of the UI lives is main-actor isolated, and calling it on this
    /// queue trips the isolation assertion and takes the process down. Found
    /// exactly that way.
    private func finishWrite(_ ok: Bool, completion: ((Bool) -> Void)?) {
        writeInFlight = false
        if let completion {
            dispatchQueue.async { completion(ok) }
        }
        pumpWrites()
    }

    /// Roughly ten seconds of a child that never reads, after which the bytes
    /// are reported lost rather than held forever.
    private static let maxStalledWriteAttempts = 200
    private static let stalledWriteRetryDelay: TimeInterval = 0.05
    
    /* Used to generate the next file name counter */
    var logFileCounter = 0
    
    #if false //canImport(Subprocess)
    // Create pseudo-terminal pair using openpty
    private func createPseudoTerminal() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        
        let result = openpty(&master, &slave, nil, nil, nil)
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        
        return (master: master, slave: slave)
    }
    
    // Set up login tty for the slave side
    private func setupLoginTty(slaveFd: Int32) throws {
        let result = login_tty(slaveFd)
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
    #endif

    func childStopped(cancelProcessMonitor: Bool = true) {
        running = false
#if os(macOS)
        if cancelProcessMonitor {
            childMonitor?.cancel()
            childMonitor = nil
        }
#endif
    }

    /* Total number of bytes read */
    var totalRead = 0
    func childProcessRead (done: Bool, data: DispatchData?, errno: Int32) {
        guard let data else {
            // Re-schedule the read on transient errors to keep the chain alive
            if !done, running {
                io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
            }
            return
        }
        if debugIO {
            totalRead += data.count
            print ("[READ] count=\(data.count) received from host total=\(totalRead)")
        }
        
        if data.count == 0 {
            childfd = -1
            if running {
                // Keep process monitor alive so the exit event can still deliver
                // processTerminated to clients when PTY EOF arrives first.
                childStopped(cancelProcessMonitor: false)
                // delegate.processTerminated (self, exitCode: nil)
            }
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            if let dir = loggingDir {
                let path = dir + "/log-\(logFileCounter)"
                do {
                    let dataCopy = Data (ptr)
                    try dataCopy.write(to: URL.init(fileURLWithPath: path))
                    logFileCounter += 1
                } catch {
                    // Ignore write error
                    print ("Got error while logging data dump to \(path): \(error)")
                }
            }
        })
        if usesMainQueue {
            enqueueReceivedData(b)
        } else {
            dispatchQueue.sync {
                self.delegate?.dataReceived(slice: b[...])
            }
        }
        io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
    }

#if os(macOS)
    var childMonitor: DispatchSourceProcess?
#endif

    deinit {
#if os(macOS)
        childMonitor?.cancel()
        childMonitor = nil
#endif
    }

    func processTerminated ()
    {
        var n: Int32 = 0
        waitpid (shellPid, &n, WNOHANG)
        delegate?.processTerminated(self, exitCode: n)
        childStopped()
    }

    /// Indicates if the child process is currently running
    public private(set) var running: Bool = false
    
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
     {
        if running {
            return
        }
        
        #if false //canImport(Subprocess)
        startProcessWithSubprocess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #else
        startProcessWithForkpty(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #endif
    }
    
    #if false //canImport(Subprocess)
    private func startProcessWithSubprocess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        do {
            var size = delegate?.getWindowSize () ?? winsize()
            
            // Create pseudo-terminal pair using openpty
            let (master, slave) = try createPseudoTerminal()
            self.masterFd = master
            self.slaveFd = slave
            self.childfd = master
            
            // Set window size on the master fd
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: master, windowSize: &size)
            
            // Prepare environment
            var env: [String: String] = [:]
            let envArray = environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color")
            for envVar in envArray {
                let components = envVar.split(separator: "=", maxSplits: 1)
                if components.count == 2 {
                    env[String(components[0])] = String(components[1])
                }
            }
            
            // Create FileDescriptor instances for swift-subprocess
            let slaveFileDescriptor = System.FileDescriptor(rawValue: slave)
            
            // Mark as running and set up I/O for reading from master fd first
            running = true
            // Capture FD values for cleanup handler to close them safely after DispatchIO is done
            let masterToClose = master
            let slaveToClose = slave
            io = DispatchIO(type: .stream, fileDescriptor: master, queue: dispatchQueue, cleanupHandler: { _ in
                // Close file descriptors after DispatchIO has finished with them
                // This prevents EV_VANISHED crash by ensuring proper cleanup order
                close(masterToClose)
                close(slaveToClose)
            })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            io.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
            
            // Start subprocess with swift-subprocess asynchronously
            Task {
                do {
                    // Start subprocess with swift-subprocess, using the slave side of the pty
                    // The subprocess will automatically handle the pseudo-terminal setup when using FileDescriptor I/O
                    var options = PlatformOptions()
                    options.preSpawnProcessConfigurator = { spawnAttr, fileAttr in
                        var flags: Int16 = 0
                        posix_spawnattr_getflags(&spawnAttr, &flags)
                        posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
                        
                    }
                    let result = try await Subprocess.run(
                        .name(executable),
                        arguments: Arguments(executablePathOverride: execName ?? executable, remainingValues: Array(args)),
                        environment: .custom(Dictionary(uniqueKeysWithValues: env.map { (Environment.Key(stringLiteral: $0.key), $0.value) })),
                        workingDirectory: currentDirectory.map { System.FilePath($0) },
                        platformOptions: options,
                        input: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: true),
                        output: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false),
                        error: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false)
                    )
                    
                    // Process completed
                    await MainActor.run {
                        childStopped()
                        let exitCode: Int32?
                        switch result.terminationStatus {
                        case .exited(let code):
                            exitCode = code
                        default:
                            exitCode = nil
                        }
                        self.delegate?.processTerminated(self, exitCode: exitCode)
                    }

                } catch {
                    await MainActor.run {
                        childStopped()
                        self.delegate?.processTerminated(self, exitCode: nil)
                    }
                    print("Failed to start process with swift-subprocess: \(error)")
                }
            }
            
        } catch {
            childStopped()
            delegate?.processTerminated(self, exitCode: nil)
            print("Failed to create pseudo-terminal: \(error)")
        }
    }
    #endif
    
    private func startProcessWithForkpty(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        var size = delegate?.getWindowSize () ?? winsize()
    
        var shellArgs = args
        if let firstArgName = execName {
            shellArgs.insert (firstArgName, at: 0)
        } else {
            shellArgs.insert(executable, at: 0)
        }
        
        var env: [String]
        if environment == nil {
            env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        } else {
            env = environment!
        }

        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: env, currentDirectory: currentDirectory, desiredWindowSize: &size) {
#if os(macOS)
            childMonitor = DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
            if let cm = childMonitor {
                if #available(macOS 10.12, *) {
                    cm.activate()
                } else {
                    // Fallback on earlier versions
                }
                cm.setEventHandler(handler: { [weak self] in self?.processTerminated () })
            }
#endif
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
            // Capture FD value for cleanup handler to close it safely after DispatchIO is done
            let fdToClose = childfd
            io = DispatchIO(type: .stream, fileDescriptor: childfd, queue: dispatchQueue, cleanupHandler: { _ in
                // Close file descriptor after DispatchIO has finished with it
                // This prevents EV_VANISHED crash by ensuring proper cleanup order
                close(fdToClose)
            })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            io.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
        }
    }

    public func terminate()
    {
        #if false //canImport(Subprocess)
        if let task = subprocessTask {
            task.cancel()
            subprocessTask = nil
        }

        // Set FD markers to -1 (actual FDs are closed by DispatchIO cleanup handler)
        masterFd = -1
        slaveFd = -1
        #endif

        // Close DispatchIO - this will trigger the cleanup handler which closes file descriptors
        // The cleanup handler ensures FDs are closed AFTER DispatchIO is done with them,
        // preventing "BUG IN CLIENT OF LIBDISPATCH: Unexpected EV_VANISHED" crash
        // This applies to both Subprocess and forkpty paths
        io?.close()
        io = nil
        childfd = -1

        if shellPid != 0 {
            kill(shellPid, SIGTERM)
        }

        childStopped()
    }
    
    var loggingDir: String? = nil
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     * - Parameter directory: location where the log files will be stored.
     */
    public func setHostLogging (directory: String?)
    {
        loggingDir = directory
    }
}
#endif
