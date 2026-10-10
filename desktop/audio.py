"""Audio bridge (Windows).

  phone microphone -> PC : PCM from the phone goes through a small jitter buffer into the virtual
                           cable "CABLE Input" (VB-Audio). Apps pick "CABLE Output" as microphone.
  PC sound -> phone      : WASAPI loopback of the default playback device is sent to the phone,
                           which plays it on its speaker / headphones. Follows the default device
                           when you plug in / switch headphones on the PC.

Wire format PC -> phone (after the 1-byte ack / key-frame messages 0x01 / 0x02):
    0x03 [len u16][rate u32][channels u8][PCM s16le]   PC sound
    0x04 [on/off u8]                                   microphone on / off (re-sent every 2 s)
Wire format phone -> PC: packet type 2: [rate u32][PCM s16le mono]
"""
import queue
import struct
import sys
import threading
import time

import numpy as np

try:
    import pyaudiowpatch as pyaudio
except Exception:                                # noqa: BLE001 - not installed / not Windows
    pyaudio = None

MIC_RATE = 48000                                 # we always feed the cable at 48 kHz mono
MIC_PREFILL = int(MIC_RATE * 0.05) * 2           # bytes buffered before playback starts (50 ms)
MIC_MAX = int(MIC_RATE * 0.30) * 2               # more than 300 ms waiting -> drop the oldest
MIC_KEEP = int(MIC_RATE * 0.10) * 2              # ... down to 100 ms


class LinearResampler:
    """Small stateful linear resampler (voice only): no clicks between chunks."""

    def __init__(self):
        self.last = None
        self.pos = 0.0

    def process(self, x, step):
        """x: float32 mono samples at the source rate, step = src_rate / dst_rate."""
        if self.last is None:
            y, pos = x, 0.0
        else:
            y, pos = np.concatenate((self.last, x)), self.pos
        n = len(y) - 1
        if n < 1:
            return np.zeros(0, np.float32)
        k = int((n - pos) // step) + 1
        if k <= 0:
            self.last, self.pos = y[-1:], pos - n
            return np.zeros(0, np.float32)
        p = pos + np.arange(k) * step
        out = np.interp(p, np.arange(len(y)), y).astype(np.float32)
        self.pos = pos + k * step - n
        self.last = y[-1:]
        return out


class AudioBridge:
    def __init__(self):
        self.pa = None                           # PortAudio instance for the microphone output
        self.pa_pc = None                        # separate instance for the loopback capture
        self.pc_stream = None
        self.pc_dev = None
        self.pc_rate = 48000
        self.pc_ch = 2
        self.send = None
        self.pc_q = queue.Queue(maxsize=40)
        self.pc_thread = None
        self.pc_watch = None
        self.pc_want = False
        self.mic_lock = threading.Lock()
        self.mic_buf = bytearray()
        self.mic_primed = False
        self.mic_stream = None
        self.mic_rs = LinearResampler()
        self.mic_retry = 0.0
        self.halt = False
        self.last_error = ""

    # ---- helpers ------------------------------------------------------------------------
    def available(self):
        return pyaudio is not None and sys.platform == "win32"

    def _pa(self):
        if self.pa is None and pyaudio is not None:
            self.pa = pyaudio.PyAudio()
        return self.pa

    def refresh_devices(self):
        """PortAudio caches the device list: re-create it (e.g. after the cable was installed)."""
        self._close_mic()
        if self.pa is not None:
            try:
                self.pa.terminate()
            except Exception:                    # noqa: BLE001
                pass
            self.pa = None

    def cable_index(self):
        """Index of 'CABLE Input' (MME host API: Windows converts the sample rate for us)."""
        pa = self._pa()
        if pa is None:
            return None
        try:
            mme = pa.get_host_api_info_by_type(pyaudio.paMME)["index"]
            for i in range(pa.get_device_count()):
                d = pa.get_device_info_by_index(i)
                if d["hostApi"] == mme and d["maxOutputChannels"] > 0 and "CABLE Input" in d["name"]:
                    return i
        except Exception as e:                   # noqa: BLE001
            self.last_error = str(e)
        return None

    # ---- PC sound -> phone --------------------------------------------------------------
    def start_pc(self, send):
        self.send = send
        self.pc_want = True
        if self.pc_thread is None or not self.pc_thread.is_alive():
            self.pc_thread = threading.Thread(target=self._pc_sender, daemon=True)
            self.pc_thread.start()
        if self.pc_watch is None or not self.pc_watch.is_alive():
            self.pc_watch = threading.Thread(target=self._pc_watcher, daemon=True)
            self.pc_watch.start()
        if self.pc_stream is not None:
            return True
        return self._open_pc()

    def _open_pc(self):
        """(Re)opens the loopback capture of the CURRENT default playback device."""
        self._close_pc_stream()
        if pyaudio is None:
            return False
        try:
            if self.pa_pc is not None:
                try:
                    self.pa_pc.terminate()
                except Exception:                # noqa: BLE001
                    pass
            self.pa_pc = pyaudio.PyAudio()       # fresh instance = fresh device list
            dev = self.pa_pc.get_default_wasapi_loopback()
            self.pc_rate = int(dev["defaultSampleRate"])
            self.pc_ch = max(1, int(dev["maxInputChannels"]))
            self.pc_dev = dev["index"]
            self.pc_stream = self.pa_pc.open(
                format=pyaudio.paInt16, channels=self.pc_ch, rate=self.pc_rate,
                frames_per_buffer=max(256, self.pc_rate // 50), input=True,
                input_device_index=dev["index"], stream_callback=self._pc_cb)
            return True
        except Exception as e:                   # noqa: BLE001
            self.last_error = str(e)
            self.pc_stream = None
            return False

    def _close_pc_stream(self):
        s, self.pc_stream = self.pc_stream, None
        if s is not None:
            try:
                s.stop_stream()
                s.close()
            except Exception:                    # noqa: BLE001
                pass

    def _pc_cb(self, data, frames, info, status):
        try:
            ch = self.pc_ch
            if ch > 2:                           # 5.1 / 7.1 -> front left/right only
                data = np.frombuffer(data, np.int16).reshape(-1, ch)[:, :2].tobytes()
                ch = 2
            pkt = struct.pack(">BHIB", 3, 5 + len(data), self.pc_rate, ch) + data
            try:
                self.pc_q.put_nowait(pkt)
            except queue.Full:                   # sender is behind: drop the oldest, stay in sync
                try:
                    self.pc_q.get_nowait()
                    self.pc_q.put_nowait(pkt)
                except Exception:                # noqa: BLE001
                    pass
        except Exception:                        # noqa: BLE001
            pass
        return (None, pyaudio.paContinue)

    def _pc_sender(self):
        """Sends audio packets from its own thread so the audio callback never blocks on the network."""
        while not self.halt:
            try:
                pkt = self.pc_q.get(timeout=0.3)
            except queue.Empty:
                continue
            send = self.send
            if send is not None and self.pc_want:
                try:
                    send(pkt)
                except Exception:                # noqa: BLE001
                    pass

    def _pc_watcher(self):
        """Headphones plugged in / default playback device changed -> follow it."""
        while not self.halt:
            time.sleep(3)
            if not self.pc_want:
                continue
            try:
                probe = pyaudio.PyAudio()
                try:
                    cur = probe.get_default_wasapi_loopback()["index"]
                finally:
                    probe.terminate()
                if self.pc_stream is None or cur != self.pc_dev:
                    self._open_pc()
            except Exception as e:               # noqa: BLE001
                self.last_error = str(e)

    def stop_pc(self):
        self.pc_want = False
        self._close_pc_stream()
        while not self.pc_q.empty():
            try:
                self.pc_q.get_nowait()
            except queue.Empty:
                break

    # ---- phone microphone -> PC (virtual cable) ------------------------------------------
    def mic_write(self, rate, pcm):
        """Called for every microphone packet from the phone."""
        try:
            x = np.frombuffer(pcm[:len(pcm) // 2 * 2], dtype="<i2").astype(np.float32)
            if rate != MIC_RATE:
                x = self.mic_rs.process(x, rate / MIC_RATE)
            out = np.clip(x, -32768, 32767).astype("<i2").tobytes()
        except Exception:                        # noqa: BLE001
            return
        with self.mic_lock:
            self.mic_buf.extend(out)
            if len(self.mic_buf) > MIC_MAX:      # PC clock slower than the phone: drop the oldest
                del self.mic_buf[:len(self.mic_buf) - MIC_KEEP]
        if self.mic_stream is None:
            self._open_mic()

    def _open_mic(self):
        now = time.time()
        if now < self.mic_retry:
            return
        self.mic_retry = now + 2.0               # never retry more often than every 2 s
        idx = self.cable_index()
        if idx is None:
            return
        try:
            self.mic_stream = self._pa().open(
                format=pyaudio.paInt16, channels=1, rate=MIC_RATE, output=True,
                output_device_index=idx, frames_per_buffer=480, stream_callback=self._mic_cb)
        except Exception as e:                   # noqa: BLE001
            self.last_error = str(e)
            self.mic_stream = None

    def _mic_cb(self, in_data, frames, info, status):
        need = frames * 2
        with self.mic_lock:
            if not self.mic_primed and len(self.mic_buf) >= MIC_PREFILL:
                self.mic_primed = True
            if self.mic_primed:
                if len(self.mic_buf) >= need:
                    out = bytes(self.mic_buf[:need])
                    del self.mic_buf[:need]
                else:                            # underrun: play what we have, then buffer again
                    out = bytes(self.mic_buf) + b"\x00" * (need - len(self.mic_buf))
                    self.mic_buf.clear()
                    self.mic_primed = False
            else:
                out = b"\x00" * need
        return (out, pyaudio.paContinue)

    def _close_mic(self):
        s, self.mic_stream = self.mic_stream, None
        if s is not None:
            try:
                s.stop_stream()
                s.close()
            except Exception:                    # noqa: BLE001
                pass
        with self.mic_lock:
            self.mic_buf.clear()
            self.mic_primed = False
        self.mic_rs = LinearResampler()

    def mic_reset(self):
        """New stream from the phone: forget old samples."""
        with self.mic_lock:
            self.mic_buf.clear()
            self.mic_primed = False
        self.mic_rs = LinearResampler()

    def close(self):
        self.halt = True
        self.stop_pc()
        self.refresh_devices()
        if self.pa_pc is not None:
            try:
                self.pa_pc.terminate()
            except Exception:                    # noqa: BLE001
                pass
            self.pa_pc = None
