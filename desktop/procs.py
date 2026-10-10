"""Heavy work lives in separate PROCESSES (each with its own Python GIL):

    GUI process:  socket receive + acks + UI                (light)
    decoder proc: H.264 / JPEG decode, rotate, resize       (CPU heavy, native code)
    vcam proc:    feeds the DirectShow virtual camera       (holds its GIL while copying frames)

Frames travel decoder -> vcam / GUI through one shared-memory "bus" (3 slots, newest wins).
Running everything as threads of one process made the decoder wait for the virtual-camera
copy on every GIL hand-over, which capped the whole pipeline at a few fps.
"""
import struct
import sys
import time
from multiprocessing import shared_memory

import numpy as np

# ---- header slots (int64) ----------------------------------------------------------------
H_SEQ, H_SLOT, H_W, H_H, H_OUTFPS, H_QUIT, H_VSTATE, H_SENDUS, H_SENT, H_KEYREQ, \
    H_DECUS, H_CODEC, H_DECODED, H_AGEUS, H_TW, H_TH, H_ROT = range(17)
HEADER_INTS = 32
HEADER_BYTES = HEADER_INTS * 8
NSLOT = 3
CAM_NAME = "HD Camera iPhone"


class SharedBus:
    def __init__(self, max_w=3840, max_h=2160, name=None):
        self.slot_bytes = max_w * max_h * 3
        size = HEADER_BYTES + NSLOT * self.slot_bytes
        if name is None:
            self.shm = shared_memory.SharedMemory(create=True, size=size)
            self.owner = True
        else:
            self.shm = shared_memory.SharedMemory(name=name)
            self.owner = False
        self.hdr = np.ndarray((HEADER_INTS,), np.int64, buffer=self.shm.buf)
        if self.owner:
            self.hdr[:] = 0
            self.hdr[H_OUTFPS] = 30
            self.hdr[H_ROT] = 1

    @property
    def name(self):
        return self.shm.name

    def _view(self, slot, w, h):
        return np.ndarray((h, w, 3), np.uint8, buffer=self.shm.buf,
                          offset=HEADER_BYTES + slot * self.slot_bytes)

    def publish(self, frame, age_us=0):
        h, w = frame.shape[:2]
        if w * h * 3 > self.slot_bytes:
            return
        slot = (int(self.hdr[H_SLOT]) + 1) % NSLOT
        np.copyto(self._view(slot, w, h), frame)
        hdr = self.hdr
        hdr[H_W], hdr[H_H], hdr[H_AGEUS] = w, h, age_us
        hdr[H_SLOT] = slot
        hdr[H_SEQ] += 1

    def latest(self):
        """(seq, frame view or None). The view stays valid for about two more frames."""
        seq = int(self.hdr[H_SEQ])
        w, h = int(self.hdr[H_W]), int(self.hdr[H_H])
        if seq == 0 or w <= 0 or h <= 0:
            return seq, None
        return seq, self._view(int(self.hdr[H_SLOT]), w, h)

    def close(self):
        try:
            self.hdr = None
            self.shm.close()
            if self.owner:
                self.shm.unlink()
        except Exception:                        # noqa: BLE001
            pass


def _timer_1ms():
    import gc
    gc.collect()
    gc.freeze()
    gc.set_threshold(50000, 20, 20)
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.winmm.timeBeginPeriod(1)
        except Exception:                        # noqa: BLE001
            pass


# ---- H.264 --------------------------------------------------------------------------------
class H264Decoder:
    """Low-latency H.264 decoding with PyAV (FFmpeg): one access unit in -> one frame out."""

    def __init__(self):
        import av
        self.av = av
        self.reset()

    def reset(self):
        ctx = self.av.CodecContext.create("h264", "r")
        try:
            ctx.thread_type = "SLICE"            # no frame threading = no extra frames of delay
            ctx.options = {"flags": "low_delay"}
        except Exception:                        # noqa: BLE001
            pass
        self.ctx = ctx

    def decode(self, data, target):
        frames = self.ctx.decode(self.av.Packet(bytes(data)))
        if not frames:
            return None
        fr = frames[-1]
        w, h = target if target else (fr.width, fr.height)
        try:
            return fr.reformat(width=w, height=h, format="bgr24", src_colorspace="ITU709").to_ndarray()
        except Exception:                        # noqa: BLE001 - older PyAV without colorspace args
            return fr.reformat(width=w, height=h, format="bgr24").to_ndarray()


def is_keyframe(payload):
    """Our access units start with SPS (NAL type 7) on key frames."""
    return len(payload) > 4 and (payload[4] & 0x1F) == 7


# ---- decoder process ----------------------------------------------------------------------
# message from the GUI process: b"J"|b"H" + 8 bytes (time.time() at arrival) + payload,
#                               b"R" (new stream: reset decoder)
def decoder_main(bus_name, conn, max_w, max_h):
    import cv2
    _timer_1ms()
    bus = SharedBus(max_w, max_h, name=bus_name)
    hdr = bus.hdr
    h264 = None
    need_key = True
    src_w = 0
    while not hdr[H_QUIT]:
        try:
            if not conn.poll(0.1):
                continue
            msgs = [conn.recv_bytes()]
            while len(msgs) < 64 and conn.poll(0):
                msgs.append(conn.recv_bytes())

            # a reset starts a new stream: forget everything before it
            for i in range(len(msgs) - 1, -1, -1):
                if msgs[i][:1] == b"R":
                    msgs = msgs[i + 1:]
                    h264 = None
                    need_key = True
                    break

            target = (int(hdr[H_TW]), int(hdr[H_TH])) if hdr[H_TW] else None
            hs = [m for m in msgs if m[:1] == b"H"]
            js = [m for m in msgs if m[:1] == b"J"]
            frame = None
            t_rx = time.time()

            if hs:
                # backlog: H.264 frames depend on each other, so skip ahead to the newest key frame
                if len(hs) > 4:
                    keys = [i for i, m in enumerate(hs) if is_keyframe(memoryview(m)[9:])]
                    if keys:
                        hs = hs[keys[-1]:]
                    else:
                        hs = []
                        need_key = True
                        hdr[H_KEYREQ] = 1
                if h264 is None:
                    h264 = H264Decoder()
                for m in hs:
                    payload = memoryview(m)[9:]
                    if need_key:
                        if not is_keyframe(payload):
                            hdr[H_KEYREQ] = 1
                            continue
                        need_key = False
                    t0 = time.perf_counter()
                    try:
                        f = h264.decode(payload, target)
                    except Exception:            # noqa: BLE001 - wait for the next key frame
                        h264.reset()
                        need_key = True
                        hdr[H_KEYREQ] = 1
                        continue
                    hdr[H_DECUS] = int(hdr[H_DECUS] * 0.9 + (time.perf_counter() - t0) * 1e6 * 0.1)
                    if f is not None:
                        frame = f
                        t_rx = struct.unpack("<d", m[1:9])[0]
                        hdr[H_CODEC] = 2
            elif js:
                m = js[-1]                       # MJPEG: only the newest picture matters
                t0 = time.perf_counter()
                flag = cv2.IMREAD_COLOR
                if target and src_w >= 2 * target[0]:
                    flag = cv2.IMREAD_REDUCED_COLOR_2
                f = cv2.imdecode(np.frombuffer(memoryview(m)[9:], np.uint8), flag)
                if f is not None:
                    src_w = f.shape[1] * (2 if flag == cv2.IMREAD_REDUCED_COLOR_2 else 1)
                    if target and (f.shape[1], f.shape[0]) != target:
                        f = cv2.resize(f, target, interpolation=cv2.INTER_LINEAR)
                    frame = f
                    t_rx = struct.unpack("<d", m[1:9])[0]
                    hdr[H_CODEC] = 1
                    hdr[H_DECUS] = int(hdr[H_DECUS] * 0.9 + (time.perf_counter() - t0) * 1e6 * 0.1)

            if frame is not None:
                if hdr[H_ROT]:
                    frame = cv2.rotate(frame, cv2.ROTATE_180)
                bus.publish(frame, int(max(0.0, time.time() - t_rx) * 1e6))
                hdr[H_DECODED] += 1
        except (EOFError, OSError):
            break
        except Exception:                        # noqa: BLE001 - never die, ask for a key frame
            need_key = True
            hdr[H_KEYREQ] = 1
    bus.close()


# ---- virtual camera process ---------------------------------------------------------------
def vcam_main(bus_name, max_w, max_h):
    import pyvirtualcam
    _timer_1ms()
    bus = SharedBus(max_w, max_h, name=bus_name)
    hdr = bus.hdr
    cam = None
    key = None
    swap = False
    send_ms = 0.0
    next_t = time.perf_counter()
    while not hdr[H_QUIT]:
        fps = max(1, int(hdr[H_OUTFPS]) or 30)
        interval = 1.0 / fps
        wait = next_t - time.perf_counter()
        if wait > 0.0005:
            time.sleep(wait)
        next_t = max(next_t + interval, time.perf_counter() - interval)

        seq, frame = bus.latest()
        if frame is None:
            time.sleep(0.01)
            continue
        h, w = frame.shape[:2]
        if cam is None or key != (w, h, fps):
            if cam is not None:
                try:
                    cam.close()
                except Exception:                # noqa: BLE001
                    pass
                cam = None
            for fmt, sw in ((pyvirtualcam.PixelFormat.BGR, False), (pyvirtualcam.PixelFormat.RGB, True)):
                try:
                    cam = pyvirtualcam.Camera(width=w, height=h, fps=fps, fmt=fmt, backend="unitycapture")
                    swap = sw
                    key = (w, h, fps)
                    hdr[H_VSTATE] = 1
                    break
                except Exception:                # noqa: BLE001
                    cam = None
            if cam is None:
                hdr[H_VSTATE] = 2                # driver missing
                time.sleep(0.5)
                continue
        t0 = time.perf_counter()
        try:
            if swap:
                import cv2
                cam.send(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            else:
                cam.send(frame)
        except Exception:                        # noqa: BLE001 - reopen on the next round
            try:
                cam.close()
            except Exception:                    # noqa: BLE001
                pass
            cam = None
            continue
        send_ms = send_ms * 0.9 + (time.perf_counter() - t0) * 1000 * 0.1
        hdr[H_SENDUS] = int(send_ms * 1000)
        hdr[H_SENT] += 1
    if cam is not None:
        try:
            cam.close()
        except Exception:                        # noqa: BLE001
            pass
    bus.close()
