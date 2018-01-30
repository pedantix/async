import Dispatch
import COperatingSystem
import Foundation

private let maxExcessSignalCount: Int = 2

/// Data stream wrapper for a dispatch socket.
public final class SocketSource<Socket>: OutputStream
    where Socket: Async.Socket
{
    /// See OutputStream.Output
    public typealias Output = UnsafeBufferPointer<UInt8>

    /// The client stream's underlying socket.
    public var socket: Socket

    /// Bytes from the socket are read into this buffer.
    /// Views into this buffer supplied to output streams.
    private var buffer: UnsafeMutableBufferPointer<UInt8>

    /// Stores read event source.
    private var readSource: EventSource?

    /// Use a basic stream to easily implement our output stream.
    private var downstream: AnyInputStream<UnsafeBufferPointer<UInt8>>?
    
    /// A strong reference to the current eventloop
    private var eventLoop: EventLoop

    /// True if this source has been closed
    private var isClosed: Bool

    /// If true, downstream is ready for data.
    private var downstreamIsReady: Bool

    /// If true, the read source has been suspended
    private var sourceIsSuspended: Bool

    /// The current number of signals received while downstream was not ready
    /// since it was last ready
    private var excessSignalCount: Int

    /// The amount of bytes read from the socket. Only used for `Socket` types
    private var remainingBytes: Int?
    
    /// Creates a new `SocketSource`
    internal init(socket: Socket, on worker: Worker, bufferSize: Int) {
        self.socket = socket
        self.eventLoop = worker.eventLoop
        self.isClosed = false
        self.buffer = .init(start: .allocate(capacity: bufferSize), count: bufferSize)
        self.downstreamIsReady = true
        self.sourceIsSuspended = true
        self.excessSignalCount = 0
        self.remainingBytes = socket.size
        let readSource = self.eventLoop.onReadable(descriptor: socket.descriptor, readSourceSignal)
        self.readSource = readSource
    }

    /// See OutputStream.output
    public func output<S>(to inputStream: S) where S: Async.InputStream, S.Input == UnsafeBufferPointer<UInt8> {
        downstream = AnyInputStream(inputStream)
        resumeIfSuspended()
    }

    /// Cancels reading
    public func close() {
        guard !isClosed else {
            return
        }
        guard let readSource = self.readSource else {
            fatalError("SocketSource readSource illegally nil during close.")
        }
        readSource.cancel()
        socket.close()
        downstream?.close()
        self.readSource = nil
        downstream = nil
        isClosed = true
    }

    /// Reads data and outputs to the output stream
    /// important: the socket _must_ be ready to read data
    /// as indicated by a read source.
    private func readData() {
        guard let downstream = self.downstream else {
            fatalError("Unexpected nil downstream on SocketSource during readData.")
        }
        do {
            let read = try socket.read(into: buffer)
            switch read {
            case .read(let count):
                guard count > 0 else {
                    close()
                    return
                }
                
                let viewSize: Int

                // If the file has a limit of data that should be read
                if let remainingBytes = remainingBytes {
                    viewSize = min(remainingBytes, count)
                    self.remainingBytes = remainingBytes &- count
                } else {
                    viewSize = count
                }
                
                let view = UnsafeBufferPointer<UInt8>(start: buffer.baseAddress, count: viewSize)
                downstreamIsReady = false
                let promise = Promise(Void.self)
                downstream.input(.next(view, promise))
                promise.future.addAwaiter { result in
                    switch result {
                    case .error(let e): downstream.error(e)
                    case .expectation:
                        self.downstreamIsReady = true
                        self.resumeIfSuspended()
                    }
                }
                
                // If the file is fully read
                if let remainingBytes = self.remainingBytes, remainingBytes <= 0 {
                    self.close()
                }
            case .wouldBlock:
                resumeIfSuspended()
            }
        } catch {
            // any errors that occur here cannot be thrown,
            // so send them to stream error catcher.
            downstream.error(error)
        }
    }

    /// Called when the read source signals.
    private func readSourceSignal(isCancelled: Bool) {
        guard !isCancelled else {
            // source is cancelled, we will never receive signals again
            close()
            return
        }

        guard downstreamIsReady else {
            // downstream is not ready for data yet
            excessSignalCount = excessSignalCount &+ 1
            if excessSignalCount >= maxExcessSignalCount {
                guard let readSource = self.readSource else {
                    fatalError("SocketSource readSource illegally nil during signal.")
                }
                readSource.suspend()
                sourceIsSuspended = true
            }
            return
        }

        // downstream ready, reset exces count
        excessSignalCount = 0
        readData()
    }

    /// Resumes the readSource if it was currently suspended.
    private func resumeIfSuspended() {
        guard sourceIsSuspended else {
            return
        }

        guard let readSource = self.readSource else {
            fatalError("SocketSource readSource illegally nil on resumeIfSuspended.")
        }
        sourceIsSuspended = false
        readSource.resume()
    }

    /// Deallocated the pointer buffer
    deinit {
        buffer.baseAddress!.deinitialize()
        buffer.baseAddress!.deallocate(capacity: buffer.count)
    }
}

/// MARK: Create

extension Socket {
    /// Creates a data stream for this socket on the supplied event loop.
    public func source(on eventLoop: Worker, bufferSize: Int = 4096) -> SocketSource<Self> {
        return .init(socket: self, on: eventLoop, bufferSize: bufferSize)
    }
}

