import AVFoundation
import UIKit
import Network
import ImageIO
import VideoToolbox

enum StreamResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4k = "4K"

    var id: String { rawValue }
    var size: (w: Int32, h: Int32) {
        switch self {
        case .hd720:  return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4k:  return (3840, 2160)
        }
    }
}

/// Frame rates offered in the UI (only those the camera really supports are shown).
let streamFPSOptions = [120, 60, 30]

enum StreamQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
    var jpeg: Double {
        switch self {
        case .low:    return 0.6
        case .medium: return 0.75
        case .high:   return 0.9
        }
    }
    /// H.264 bits per pixel per frame: 1080p120 -> about 25 / 40 / 62 Mbit/s.
    var bitsPerPixel: Double {
        switch self {
        case .low:    return 0.10
        case .medium: return 0.16
        case .high:   return 0.25
        }
    }
}

enum StreamCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case mjpeg = "MJPEG"
    var id: String { rawValue }
}

/// Captures video from the iPhone camera and serves it over TCP port 9999, either through the
/// USB cable (usbmuxd) or over Wi-Fi (PC connects to the iPhone's IP).
/// Wire format, repeated: [4 bytes big-endian N][1 byte codec: 0 = JPEG, 1 = H.264 Annex-B access unit][N-1 bytes].
/// The PC answers every received frame with one byte (flow control).
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Phase { case starting, denied, noCamera, running }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var pcConnected = false
    @Published private(set) var resolution = "-"
    @Published private(set) var fps = 0
    @Published private(set) var usingFrontCamera = false
    @Published private(set) var selectedResolution: StreamResolution = .hd1080
    @Published private(set) var selectedQuality: StreamQuality = .high
    @Published private(set) var availableResolutions: [StreamResolution] = StreamResolution.allCases
    @Published private(set) var selectedFPS = 120
    @Published private(set) var availableFPS: [Int] = streamFPSOptions
    @Published private(set) var selectedCodec: StreamCodec = .h264
    @Published private(set) var wifiAddress = "-"
    @Published private(set) var diag = ""
    @Published private(set) var micActive = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "usc.session")
    private let frameQueue = DispatchQueue(label: "usc.frames", qos: .userInteractive)
    private let netQueue = DispatchQueue(label: "usc.net")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let output = AVCaptureVideoDataOutput()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var configured = false

    private let lock = NSLock()
    private var inFlight = 0
    private var frameCounter = 0
    private var lastFpsTick = CACurrentMediaTime()
    private var qualityValue: Double = StreamQuality.high.jpeg   // guarded by `lock`
    private var desiredResolution: StreamResolution = .hd1080      // sessionQueue only
    private var desiredFPS = 120                                   // sessionQueue only
    private var effectiveResolution: StreamResolution = .hd1080    // sessionQueue only
    private var effectiveFPS = 30                                  // sessionQueue only
    private var ackMode = false                                    // guarded by `lock`
    private let maxInFlight = 3
    private var codecValue: StreamCodec = .h264                    // guarded by `lock`
    private var encoderDirty = true                                // guarded by `lock`
    private var forceKey = true                                    // guarded by `lock`
    private var encFPS = 30                                        // guarded by `lock`
    private var vtSession: VTCompressionSession?                   // frameQueue only
    private var encW: Int32 = 0                                    // frameQueue only
    private var encH: Int32 = 0                                    // frameQueue only
    private var addressTimer: Timer?
    private var statsTimer: Timer?
    private var capCount = 0, busyCount = 0, sentCount = 0, encN = 0   // guarded by `lock`
    private var encSum = 0.0                                           // guarded by `lock`
    private var ctrlBuf = [UInt8]()                                    // netQueue only
    // audio (phone microphone -> PC, PC sound -> phone speaker / headphones)
    private var audioEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "usc.audio")
    private let audioLock = NSLock()
    private var audioAttached = false                                  // audioQueue only
    private var audioObserving = false                                 // audioQueue only
    private var audioRetryPending = false                              // audioQueue only
    private var audioFailures = 0                                      // audioQueue only
    private var playerRate = 0.0                                       // audioQueue only
    private var playerChannels: AVAudioChannelCount = 0                // audioQueue only
    private var playerFormat: AVAudioFormat?                           // audioQueue only
    private var playerPrimed = false                                   // audioQueue only
    private var queuedFrames = 0                                       // guarded by audioLock
    private var audioGen = 0                                           // guarded by audioLock
    private var micWanted = false                                      // audioQueue only
    private var micRunning = false                                     // audioQueue only
    // adaptive bitrate (Wi-Fi is slower and less steady than the USB cable)
    private var isWifiLink = false                                     // guarded by `lock`
    private var rateScale = 1.0                                        // guarded by `lock`
    private var cleanSeconds = 0                                       // guarded by `lock`
    private var appliedBitrate = 0                                     // frameQueue only
    private var isFront = false                                    // sessionQueue only

    override init() {
        let d = UserDefaults.standard
        let r = StreamResolution(rawValue: d.string(forKey: "usc.resolution") ?? "") ?? .hd1080
        let q = StreamQuality(rawValue: d.string(forKey: "usc.quality7") ?? "") ?? .high
        let f = d.integer(forKey: "usc.fps")
        let fps = streamFPSOptions.contains(f) ? f : 120
        selectedResolution = r
        selectedQuality = q
        selectedFPS = fps
        desiredFPS = fps
        desiredResolution = r
        qualityValue = q.jpeg
        let c = StreamCodec(rawValue: d.string(forKey: "usc.codec") ?? "") ?? .h264
        selectedCodec = c
        codecValue = c
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        refreshAddress()
        addressTimer?.invalidate()
        addressTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAddress()
        }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.publishDiag()
        }
        startListener()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                ok ? self?.configureAndRun() : self?.setPhase(.denied)
            }
        default:
            setPhase(.denied)
        }
    }

    // MARK: User settings (phone UI)

    func setResolution(_ r: StreamResolution) {
        UserDefaults.standard.set(r.rawValue, forKey: "usc.resolution")
        DispatchQueue.main.async { self.selectedResolution = r }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { self?.desiredResolution = r; return }
            self.desiredResolution = r
            self.reconfigure()
        }
    }

    func setFPS(_ f: Int) {
        UserDefaults.standard.set(f, forKey: "usc.fps")
        DispatchQueue.main.async { self.selectedFPS = f }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { self?.desiredFPS = f; return }
            self.desiredFPS = f
            self.reconfigure()
        }
    }

    func setQuality(_ q: StreamQuality) {
        UserDefaults.standard.set(q.rawValue, forKey: "usc.quality7")
        lock.lock(); qualityValue = q.jpeg; encoderDirty = true; lock.unlock()
        DispatchQueue.main.async { self.selectedQuality = q }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { return }
            self.session.beginConfiguration()
            self.applyVideoSettings()
            self.session.commitConfiguration()
        }
    }

    func setCodec(_ c: StreamCodec) {
        UserDefaults.standard.set(c.rawValue, forKey: "usc.codec")
        lock.lock(); codecValue = c; encoderDirty = true; forceKey = true; lock.unlock()
        DispatchQueue.main.async { self.selectedCodec = c }
        sessionQueue.async { [weak self] in
            guard let self = self, self.configured else { return }
            self.session.beginConfiguration()
            self.applyVideoSettings()
            self.session.commitConfiguration()
            self.tuneConnection()
        }
    }

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let front = !self.isFront
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.addInput(front: front) {
                self.isFront = front
                DispatchQueue.main.async { self.usingFrontCamera = front }
            } else {
                _ = self.addInput(front: !front)
            }
            self.session.commitConfiguration()
            self.reconfigure()
        }
    }

    // MARK: Camera

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.configured {
                self.session.automaticallyConfiguresApplicationAudioSession = false
                self.session.beginConfiguration()
                guard self.addInput(front: false) else {
                    self.session.commitConfiguration()
                    self.setPhase(.noCamera)
                    return
                }
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.configured = true
                // Pick the camera format (resolution + up to 120 fps), then the hardware JPEG
                // encoder (its codec list depends on the active format).
                self.reconfigure()
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.updateResolutionLabel()
            self.setPhase(.running)
        }
    }

    @discardableResult
    private func addInput(front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    private var currentDevice: AVCaptureDevice? {
        (session.inputs.first as? AVCaptureDeviceInput)?.device
    }

    /// Best 8-bit format for `res` that can run at `fps` (widest field of view wins).
    private func bestFormat(_ device: AVCaptureDevice, _ res: StreamResolution, _ fps: Int) -> AVCaptureDevice.Format? {
        let want = Double(fps)
        let matching = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == res.size.w && d.height == res.size.h &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= want && $0.maxFrameRate >= want }
        }
        let eightBit = matching.filter { f in
            let t = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return t == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                   t == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        let pool = eightBit.isEmpty ? matching : eightBit
        return pool.max { $0.videoFieldOfView < $1.videoFieldOfView }
    }

    /// Chooses the best format: highest fps first (up to the wanted one), then the wanted
    /// resolution or the next lower one that can do that fps.
    private func applyFormat() {
        guard let device = currentDevice else { return }
        let order: [StreamResolution] = [.uhd4k, .hd1080, .hd720]
        let start = order.firstIndex(of: desiredResolution) ?? 1
        for fps in streamFPSOptions where fps <= desiredFPS {
            for r in order[start...] {
                guard let format = bestFormat(device, r, fps) else { continue }
                guard (try? device.lockForConfiguration()) != nil else { return }
                device.activeFormat = format
                let d = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = d      // fixed rate = steady pacing
                device.activeVideoMaxFrameDuration = d
                if device.activeFormat.isVideoHDRSupported {  // HDR tone mapping adds latency
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
                device.unlockForConfiguration()
                effectiveResolution = r
                effectiveFPS = fps
                return
            }
        }
    }

    /// Format + encoder + connection tuning + UI state. Call on `sessionQueue`.
    private func reconfigure() {
        applyFormat()
        lock.lock(); encFPS = effectiveFPS; encoderDirty = true; lock.unlock()
        session.beginConfiguration()
        applyVideoSettings()
        session.commitConfiguration()
        tuneConnection()
        publishAvailable()
        updateResolutionLabel()
    }

    /// Video stabilization buffers several frames -> noticeable lag. Turn it off.
    private func tuneConnection() {
        if let c = output.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = .off
        }
    }

    private func applyVideoSettings() {
        lock.lock(); let q = qualityValue; let codec = codecValue; lock.unlock()
        if codec == .h264 {
            // Raw frames for the hardware H.264 encoder (VideoToolbox).
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            return
        }
        // MJPEG: hardware JPEG encoder, far faster than converting every frame on the CPU.
        if output.availableVideoCodecTypes.contains(.jpeg) {
            output.videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: q]
            ]
        }
    }

    private func publishAvailable() {
        guard let device = currentDevice else { return }
        let fpsNow = effectiveFPS
        let resList = StreamResolution.allCases.filter { bestFormat(device, $0, fpsNow) != nil }
        let fpsList = streamFPSOptions.filter { f in
            StreamResolution.allCases.contains { bestFormat(device, $0, f) != nil }
        }
        let res = effectiveResolution
        DispatchQueue.main.async {
            self.availableResolutions = resList.isEmpty ? [.hd720] : resList
            self.availableFPS = fpsList.isEmpty ? [30] : fpsList
            self.selectedResolution = res
            self.selectedFPS = fpsNow
        }
    }

    private func updateResolutionLabel() {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async { self.resolution = "\(d.width)x\(d.height)" }
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: Network (USB tunnel endpoint)

    private func startListener() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo      // Wi-Fi: video priority (WMM AC_VI)
            params.includePeerToPeer = false             // no AWDL channel hopping = steadier Wi-Fi
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: params, on: 9999)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.netQueue.asyncAfter(deadline: .now() + 1) { self?.startListener() }
                }
            }
            // Bonjour: the PC app finds the phone on the Wi-Fi by itself (no IP typing).
            l.service = NWListener.Service(name: "USC-CAM", type: "_usccam._tcp")
            l.start(queue: netQueue)
            listener = l
        } catch {
            netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; ackMode = false; forceKey = true; lock.unlock()
        ctrlBuf.removeAll()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready:
                let wifi = conn.currentPath?.usesInterfaceType(.wifi) ?? false
                self.lock.lock()
                self.isWifiLink = wifi
                self.rateScale = 1.0
                self.cleanSeconds = 0
                self.encoderDirty = true
                self.lock.unlock()
                DispatchQueue.main.async { self.pcConnected = true }
            case .failed, .cancelled:
                DispatchQueue.main.async { self.pcConnected = false }
                self.setMic(false)
                self.resetPlayback()
            default: break
            }
        }
        conn.start(queue: netQueue)
        receiveControl(conn)
    }

    /// Messages from the PC (all on netQueue):
    ///   0x01 frame received (flow control)      0x02 please send a key frame
    ///   0x03 [len u16][rate u32][channels u8][PCM s16le]  PC sound for the speaker / headphones
    ///   0x04 [0/1]  microphone off / on
    private func receiveControl(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, done, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let d = data, !d.isEmpty {
                self.ctrlBuf.append(contentsOf: d)
                self.parseControl()
            }
            if error == nil && !done { self.receiveControl(conn) }
        }
    }

    private func parseControl() {
        var i = 0
        var acks = 0
        parsing: while i < ctrlBuf.count {
            switch ctrlBuf[i] {
            case 0x01:
                acks += 1
                i += 1
            case 0x02:
                lock.lock(); forceKey = true; lock.unlock()
                i += 1
            case 0x04:
                guard i + 1 < ctrlBuf.count else { break parsing }
                setMic(ctrlBuf[i + 1] != 0)
                i += 2
            case 0x03:
                guard i + 2 < ctrlBuf.count else { break parsing }
                let len = (Int(ctrlBuf[i + 1]) << 8) | Int(ctrlBuf[i + 2])
                guard i + 3 + len <= ctrlBuf.count else { break parsing }
                playPCAudio(Array(ctrlBuf[(i + 3)..<(i + 3 + len)]))
                i += 3 + len
            default:
                i += 1
            }
        }
        if i > 0 { ctrlBuf.removeFirst(i) }
        if acks > 0 {
            lock.lock()
            ackMode = true
            inFlight = max(0, inFlight - acks)
            lock.unlock()
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); capCount += 1; lock.unlock()
        guard let conn = self.connection, conn.state == .ready else { return }

        lock.lock()
        let limit = encFPS >= 90 ? 5 : 3          // frames allowed on the way (acks come back per frame)
        if inFlight >= limit {                    // PC/link can't keep up -> drop frame, keep latency low
            busyCount += 1
            lock.unlock()
            return
        }
        inFlight += 1
        let codec = codecValue
        lock.unlock()

        switch codec {
        case .mjpeg:
            guard let jpeg = jpegData(from: sampleBuffer) else { releaseSlot(); return }
            sendPacket(conn, codec: 0, payload: jpeg)
        case .h264:
            encode(sampleBuffer)
        }
    }

    private func releaseSlot() {
        lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock()
    }

    private func sendPacket(_ conn: NWConnection, codec: UInt8, payload: Data) {
        sendRaw(conn, type: codec, payload: payload, isVideo: true)
    }

    /// Packet: [4 bytes big-endian N][1 byte type: 0 JPEG, 1 H.264, 2 microphone PCM][N-1 bytes].
    private func sendRaw(_ conn: NWConnection, type: UInt8, payload: Data, isVideo: Bool) {
        var length = UInt32(payload.count + 1).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(type)
        packet.append(payload)
        if isVideo {
            lock.lock(); sentCount += 1; lock.unlock()
            conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
                // Old PC app without acks: fall back to "handed to the kernel" accounting.
                guard let self = self else { return }
                self.lock.lock()
                if !self.ackMode { self.inFlight = max(0, self.inFlight - 1) }
                self.lock.unlock()
            })
        } else {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    // MARK: H.264 (VideoToolbox, low-latency, no B-frames)

    private func encode(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { releaseSlot(); return }
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        lock.lock()
        let dirty = encoderDirty; encoderDirty = false
        let key = forceKey; forceKey = false
        let fps = encFPS
        let q = selectedQualityLocked
        // Wi-Fi: lower ceiling; the scale shrinks when frames start to pile up and grows back when it is calm.
        let base = Double(w) * Double(h) * Double(fps) * q.bitsPerPixel
        let ceiling = isWifiLink ? 28_000_000.0 : 90_000_000.0
        let rate = Int(min(max(min(base, ceiling) * rateScale, 3_000_000), 90_000_000))
        lock.unlock()
        if dirty || vtSession == nil || w != encW || h != encH {
            rebuildEncoder(w, h, fps: fps, bitrate: rate)
            appliedBitrate = rate
        } else if let live = vtSession, abs(rate - appliedBitrate) * 10 > appliedBitrate {
            VTSessionSetProperty(live, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: rate))
            appliedBitrate = rate
        }
        guard let session = vtSession else { releaseSlot(); return }
        let props: CFDictionary? = key ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let t0 = CACurrentMediaTime()
        let st = VTCompressionSessionEncodeFrame(session,
                                                 imageBuffer: pb,
                                                 presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                                 duration: CMSampleBufferGetDuration(sb),
                                                 frameProperties: props,
                                                 infoFlagsOut: nil) { [weak self] status, _, out in
            self?.encoded(status, out, t0)
        }
        if st != noErr { releaseSlot() }
    }

    private var selectedQualityLocked: StreamQuality {
        // `qualityValue` is the only quality state shared with this queue.
        StreamQuality.allCases.first { $0.jpeg == qualityValue } ?? .high
    }

    private func rebuildEncoder(_ w: Int32, _ h: Int32, fps: Int, bitrate: Int) {
        destroyEncoder()
        var created: VTCompressionSession?
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true]
        let st = VTCompressionSessionCreate(allocator: nil, width: w, height: h,
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &created)
        guard st == noErr, let session = created else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(fps, 30) * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtSession = session
        encW = w
        encH = h
    }

    private func destroyEncoder() {
        if let s = vtSession {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)  // flush -> no leaked slots
            VTCompressionSessionInvalidate(s)
        }
        vtSession = nil
    }

    /// Encoder output (AVCC, length-prefixed) -> Annex-B access unit; SPS/PPS in front of key frames.
    private func encoded(_ status: OSStatus, _ sb: CMSampleBuffer?, _ t0: Double) {
        lock.lock(); encSum += (CACurrentMediaTime() - t0) * 1000; encN += 1; lock.unlock()
        guard status == noErr, let sb = sb, CMSampleBufferDataIsReady(sb),
              let conn = self.connection, conn.state == .ready,
              let block = CMSampleBufferGetDataBuffer(sb) else { releaseSlot(); return }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var index = 0
            var count = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let r = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index,
                                                                           parameterSetPointerOut: &ptr,
                                                                           parameterSetSizeOut: &size,
                                                                           parameterSetCountOut: &count,
                                                                           nalUnitHeaderLengthOut: nil)
                if r == noErr, let p = ptr {
                    out.append(contentsOf: startCode)
                    out.append(p, count: size)
                }
                index += 1
            } while index < count
        }

        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let base = dataPtr else { releaseSlot(); return }
        let raw = UnsafeRawPointer(base)
        var offset = 0
        while offset + 4 <= total {
            var be: UInt32 = 0
            memcpy(&be, raw + offset, 4)
            let len = Int(UInt32(bigEndian: be))
            offset += 4
            guard len > 0, offset + len <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: len))
            offset += len
        }
        if out.isEmpty { releaseSlot(); return }
        sendPacket(conn, codec: 1, payload: out)
    }

    // MARK: Wi-Fi address (shown on screen so the PC app can connect without USB)

    private func refreshAddress() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = CameraManager.localWiFiAddress()
            DispatchQueue.main.async { self?.wifiAddress = a }
        }
    }

    private static func localWiFiAddress() -> String {
        var found = "no Wi-Fi"
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    found = String(cString: host)
                }
            }
            cursor = ifa.ifa_next
        }
        return found
    }

    // MARK: Diagnostics (shown on the phone screen)

    private func publishDiag() {
        lock.lock()
        let cap = capCount, busy = busyCount, sent = sentCount, queue = inFlight
        let encMs = encN > 0 ? encSum / Double(encN) : 0
        capCount = 0; busyCount = 0; sentCount = 0; encN = 0; encSum = 0
        // adaptive bitrate: frames dropped because the link is behind -> send less data
        let dropRatio = cap > 0 ? Double(busy) / Double(cap) : 0
        if dropRatio > 0.06 {
            rateScale = max(0.2, rateScale * 0.75)
            cleanSeconds = 0
        } else if busy == 0 {
            cleanSeconds += 1
            if cleanSeconds >= 4 && rateScale < 1.0 {
                rateScale = min(1.0, rateScale * 1.10)
                cleanSeconds = 0
            }
        } else {
            cleanSeconds = 0
        }
        let mbit = rateScale
        lock.unlock()
        fps = sent
        diag = "camera \(cap)/s · sent \(sent)/s · dropped \(busy)/s · encode \(String(format: "%.1f", encMs)) ms · queue \(queue) · rate \(Int(mbit * 100))%"
    }

    // MARK: Audio
    //
    // Phone microphone -> PC and PC sound -> phone share one AVAudioEngine. Everything runs on `audioQueue`.
    // The graph is rebuilt after every route change (headphones in / out, Bluetooth), interruption
    // (call, Siri) and engine configuration change - previously the engine just stayed dead after those,
    // which is why the microphone and the headphone sound "sometimes worked and sometimes not".

    private func activateAudioSession() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try s.setActive(true)
        } catch {
            return false
        }
        // Always record from the phone's own microphone, also when headphones are connected
        // (a headset microphone would switch Bluetooth headphones to low-quality call mode).
        if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            do { try s.setPreferredInput(builtIn) } catch {}
        }
        return true
    }

    private func installAudioObservers() {
        guard !audioObserving else { return }
        audioObserving = true
        let nc = NotificationCenter.default
        let recover: (Notification) -> Void = { [weak self] _ in
            self?.audioQueue.async { self?.rebuildAudio() }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil, using: recover)
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: recover)
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            if let v = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: v) == .ended {
                self?.audioQueue.async { self?.rebuildAudio() }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.audioQueue.async {
                guard let self = self else { return }
                self.audioEngine = AVAudioEngine()          // the old objects are dead after a media services reset
                self.player = AVAudioPlayerNode()
                self.audioAttached = false
                self.micRunning = false
                self.rebuildAudio()
            }
        }
    }

    private func scheduleAudioRetry() {
        guard !audioRetryPending, audioFailures < 8 else { return }
        audioRetryPending = true
        audioFailures += 1
        audioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.audioRetryPending = false
            self.rebuildAudio()
        }
    }

    private func publishMic() {
        let running = micRunning
        DispatchQueue.main.async { self.micActive = running }
    }

    /// (Re)creates the whole audio graph for what is currently wanted. audioQueue only.
    private func rebuildAudio() {
        if !audioAttached {
            audioEngine.attach(player)
            audioAttached = true
        }
        installAudioObservers()
        player.stop()
        if audioEngine.isRunning { audioEngine.stop() }
        audioLock.lock(); audioGen += 1; queuedFrames = 0; audioLock.unlock()
        playerPrimed = false

        let needPlayback = playerFormat != nil
        if !micWanted && !needPlayback {                      // nothing to do: leave the audio hardware alone
            if micRunning { audioEngine.inputNode.removeTap(onBus: 0) }
            micRunning = false
            publishMic()
            return
        }
        guard activateAudioSession() else { scheduleAudioRetry(); return }

        if micWanted {
            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            let fmt = input.outputFormat(forBus: 0)
            if fmt.sampleRate > 0 && fmt.channelCount > 0 {
                input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                    self?.sendMic(buf)
                }
                micRunning = true
            } else {
                micRunning = false
                scheduleAudioRetry()
            }
        } else {
            if micRunning { audioEngine.inputNode.removeTap(onBus: 0) }
            micRunning = false
        }
        if let fmt = playerFormat {
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: fmt)
        } else {
            _ = audioEngine.mainMixerNode                      // makes sure the output side exists
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            audioFailures = 0
        } catch {
            micRunning = false
            scheduleAudioRetry()
        }
        publishMic()
    }

    /// Microphone on / off request from the PC (re-sent every 2 s, so it also repairs a dead microphone).
    private func setMic(_ on: Bool) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            if on {
                if self.micWanted && self.micRunning && self.audioEngine.isRunning { return }
                self.micWanted = true
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    self.audioQueue.async {
                        if granted { self.rebuildAudio() } else { self.micWanted = false }
                    }
                }
            } else {
                guard self.micWanted || self.micRunning else { return }
                self.micWanted = false
                self.rebuildAudio()
            }
        }
    }

    /// PC disconnected: stop playing the PC sound.
    private func resetPlayback() {
        audioQueue.async { [weak self] in
            guard let self = self, self.playerFormat != nil else { return }
            self.playerFormat = nil
            self.playerRate = 0
            self.playerChannels = 0
            self.rebuildAudio()
        }
    }

    private func sendMic(_ buf: AVAudioPCMBuffer) {
        guard let conn = connection, conn.state == .ready, let channels = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var rate = UInt32(buf.format.sampleRate).bigEndian
        var payload = Data(bytes: &rate, count: 4)
        var samples = [Int16](repeating: 0, count: n)
        let src = channels[0]
        for i in 0..<n {
            samples[i] = Int16(max(-1.0, min(1.0, src[i])) * 32767.0)
        }
        samples.withUnsafeBufferPointer { payload.append(Data(buffer: $0)) }
        sendRaw(conn, type: 2, payload: payload, isVideo: false)
    }

    /// PC sound -> phone speaker / headphones. `msg` = [rate u32][channels u8][PCM s16le].
    private func playPCAudio(_ msg: [UInt8]) {
        guard msg.count > 5 else { return }
        let rate = Double((UInt32(msg[0]) << 24) | (UInt32(msg[1]) << 16) | (UInt32(msg[2]) << 8) | UInt32(msg[3]))
        let ch = Int(msg[4])
        guard ch >= 1, ch <= 2, rate >= 8000 else { return }
        let frames = (msg.count - 5) / (2 * ch)
        guard frames > 0 else { return }
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            let formatChanged = rate != self.playerRate || AVAudioChannelCount(ch) != self.playerChannels
            if formatChanged || (!self.audioEngine.isRunning && !self.audioRetryPending) {
                guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                              channels: AVAudioChannelCount(ch), interleaved: false) else { return }
                self.playerFormat = fmt
                self.playerRate = rate
                self.playerChannels = AVAudioChannelCount(ch)
                self.rebuildAudio()
            }
            guard self.audioEngine.isRunning, let fmt = self.playerFormat else { return }

            self.audioLock.lock(); let queued = self.queuedFrames; let gen = self.audioGen; self.audioLock.unlock()
            if Double(queued) > rate * 0.25 { return }         // > 250 ms waiting: drop, stay in sync
            if queued == 0 && self.playerPrimed {              // ran dry: buffer a little again (no crackling)
                self.playerPrimed = false
                self.player.pause()
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
                  let out = buf.floatChannelData else { return }
            buf.frameLength = AVAudioFrameCount(frames)
            for c in 0..<ch {
                let dst = out[c]
                for i in 0..<frames {
                    let o = 5 + (i * ch + c) * 2
                    let v = Int16(bitPattern: UInt16(msg[o]) | (UInt16(msg[o + 1]) << 8))
                    dst[i] = Float(v) / 32768.0
                }
            }
            self.audioLock.lock(); self.queuedFrames += frames; let now = self.queuedFrames; self.audioLock.unlock()
            self.player.scheduleBuffer(buf) { [weak self] in
                guard let self = self else { return }
                self.audioLock.lock()
                if gen == self.audioGen { self.queuedFrames = max(0, self.queuedFrames - frames) }
                self.audioLock.unlock()
            }
            if !self.playerPrimed && Double(now) >= rate * 0.06 {   // 60 ms of cushion, then start
                self.playerPrimed = true
                self.player.play()
            }
        }
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Fallback path (raw pixels): encode with Core Image.
            lock.lock(); let q = qualityValue; lock.unlock()
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return ciContext.jpegRepresentation(of: image, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: q])
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let p = pointer, length > 0 else { return nil }
        return Data(bytes: p, count: length)
    }

    private func tickFps() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - lastFpsTick >= 1 {
            let value = Int((Double(frameCounter) / (now - lastFpsTick)).rounded())
            frameCounter = 0
            lastFpsTick = now
            DispatchQueue.main.async { self.fps = value }
        }
    }
}
