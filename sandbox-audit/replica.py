"""Byte-exact Python replicas of the Swift audio-pipeline logic.

Replicates (from apps/Watch/OfflineSession.swift and
apps/iPhone/OfflineTranslationEngine.swift):
  - OfflineSession.wavData(pcm:)          -> wav_data(pcm)
  - VadSegmenter                           -> VadSegmenter
  - OfflineTranslationEngine.signalPresent -> signal_present
  - A strict WAV parser mimicking what AVAudioFile(forReading:) requires.
"""
import struct


# ---------------------------------------------------------------- wav writer
def wav_data(pcm: bytes) -> bytes:
    """Exact replica of OfflineSession.wavData(pcm:) in Swift."""
    out = bytearray()
    def append_u32(v):
        out.append(v & 0xFF); out.append((v >> 8) & 0xFF)
        out.append((v >> 16) & 0xFF); out.append((v >> 24) & 0xFF)
    def append_u16(v):
        out.append(v & 0xFF); out.append((v >> 8) & 0xFF)
    out += b"RIFF"; append_u32(36 + len(pcm))
    out += b"WAVE"
    out += b"fmt "; append_u32(16)
    append_u16(1); append_u16(1); append_u32(24_000); append_u32(48_000)
    append_u16(2); append_u16(16)
    out += b"data"; append_u32(len(pcm))
    out += pcm
    return bytes(out)


# ------------------------------------------------- strict WAV parser (AVAudioFile-like)
def parse_wav_strict(data: bytes):
    """Parse like AVAudioFile would; raise on anything it would reject."""
    if len(data) < 44:
        raise ValueError("too short for WAV header")
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not RIFF/WAVE")
    riff_size = struct.unpack("<I", data[4:8])[0]
    if riff_size != len(data) - 8:
        raise ValueError(f"RIFF chunk size mismatch: header={riff_size} actual={len(data)-8}")
    if data[12:16] != b"fmt ":
        raise ValueError("fmt chunk missing")
    fmt_size = struct.unpack("<I", data[16:20])[0]
    if fmt_size != 16:
        raise ValueError("only PCM fmt(16) supported here")
    audio_fmt, channels, rate, byte_rate, block_align, bits = struct.unpack("<HHIIHH", data[20:36])
    if audio_fmt != 1:
        raise ValueError("not PCM")
    if byte_rate != rate * channels * bits // 8:
        raise ValueError("byteRate inconsistent")
    if block_align != channels * bits // 8:
        raise ValueError("blockAlign inconsistent")
    if data[36:40] != b"data":
        raise ValueError("data chunk missing")
    data_size = struct.unpack("<I", data[40:44])[0]
    if data_size != len(data) - 44:
        raise ValueError("data chunk size mismatch")
    if data_size % block_align != 0:
        raise ValueError("data not frame-aligned")
    return {
        "channels": channels, "sample_rate": rate, "bits": bits,
        "frames": data_size // block_align,
        "duration_s": data_size / block_align / rate,
        "pcm": data[44:],
    }


# ------------------------------------------------------------------- VAD
class VadSegmenter:
    """Exact replica of the Swift VadSegmenter (24 kHz int16 mono)."""
    WINDOW_BYTES = 960
    START_WINDOWS = 2
    END_SILENCE_WINDOWS = 40
    MIN_SPEECH_MS = 350
    MAX_WINDOWS = 600

    def __init__(self):
        self.noise_floor = 150.0
        self.in_speech = False
        self.silence_windows = 0
        self.speech_windows = 0
        self.pcm = bytearray()
        self.remainder = b""
        self._last_silence = 0

    @staticmethod
    def rms_of(window: bytes) -> float:
        n = len(window) // 2
        if n == 0:
            return 0.0
        s = 0
        for i in range(n):
            lo = window[i * 2]; hi = window[i * 2 + 1]
            v = lo | (hi << 8)
            if v >= 32768:
                v -= 65536
            s += v * v
        return (s / n) ** 0.5

    def process(self, data: bytes):
        data = self.remainder + data
        self.remainder = b""
        completed = None
        while len(data) >= self.WINDOW_BYTES:
            window = data[:self.WINDOW_BYTES]
            data = data[self.WINDOW_BYTES:]
            done = self._process_window(window)
            if done is not None:
                completed = done
        self.remainder = data
        return completed

    def _process_window(self, window: bytes):
        rms = self.rms_of(window)
        if self.in_speech:
            speaking = rms > max(self.noise_floor * 2.0, 220)
        else:
            speaking = rms > max(self.noise_floor * 3.0, 300)
            if not speaking:
                self.noise_floor = min(600, max(80, self.noise_floor * 0.995 + rms * 0.005))
        if speaking:
            self.pcm += window
            if not self.in_speech:
                self.speech_windows += 1
                if self.speech_windows >= self.START_WINDOWS:
                    self.in_speech = True
                    self.silence_windows = 0
            else:
                self.silence_windows = 0
        else:
            self.speech_windows = 0
            if self.in_speech:
                self.pcm += window
                self.silence_windows += 1
                if self.silence_windows >= self.END_SILENCE_WINDOWS:
                    self._last_silence = self.silence_windows
                    return self._finish()
        if self.in_speech and len(self.pcm) // self.WINDOW_BYTES >= self.MAX_WINDOWS:
            self._last_silence = self.silence_windows
            return self._finish()
        return None

    def _finish(self):
        pcm = bytes(self.pcm)
        self.in_speech = False
        self.silence_windows = 0
        self.speech_windows = 0
        self.pcm = bytearray()
        # FIX: only real speech windows count toward the minimum --
        # the trailing-silence padding (up to 800 ms) must not let a
        # 40 ms click through as an "utterance".
        total_windows = len(pcm) // self.WINDOW_BYTES
        speech_ms = (total_windows - self._last_silence) * 20
        if speech_ms < self.MIN_SPEECH_MS:
            return None
        return pcm


# ------------------------------------------------------------- energy gate
def signal_present(pcm_bytes: bytes) -> bool:
    """Exact replica of OfflineTranslationEngine.signalPresent (int16 mono)."""
    import numpy as np
    samples = np.frombuffer(pcm_bytes, dtype="<i2").astype(np.float64)
    if samples.size == 0:
        return False
    sparse = samples[::16]
    if sparse.size == 0:
        return False
    rms = float((np.mean(sparse ** 2)) ** 0.5)
    return rms > 120


def audio_stats(pcm_bytes: bytes):
    import numpy as np
    samples = np.frombuffer(pcm_bytes, dtype="<i2").astype(np.float64)
    if samples.size == 0:
        return {"rms": 0, "peak": 0, "zcr": 0, "dur_s": 0}
    rms = float((np.mean(samples ** 2)) ** 0.5)
    peak = float(np.max(np.abs(samples)))
    zcr = float(np.mean(np.diff(np.sign(samples)) != 0))
    return {"rms": rms, "peak": peak, "zcr": zcr, "dur_s": samples.size / 24000}
