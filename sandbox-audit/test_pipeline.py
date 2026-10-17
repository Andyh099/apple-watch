import sys, wave, io
import numpy as np
sys.path.insert(0, "/home/hatch/workspace/wrist-interpreter/sandbox-audit")
from signals import synth_speech, silence, white_noise, tone, utterance, two_utterances
from replica import wav_data, parse_wav_strict, VadSegmenter, signal_present, audio_stats

def run_case(name, pcm_stream, feed_chunk=4800):
    vad = VadSegmenter()
    segments = []
    for i in range(0, len(pcm_stream), feed_chunk):
        seg = vad.process(pcm_stream[i:i + feed_chunk])
        if seg:
            segments.append(seg)
    results = []
    for seg in segments:
        wav = wav_data(seg)
        with wave.open(io.BytesIO(wav), "rb") as w:
            assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 24000), \
                f"{name}: wave module disagrees on format"
            raw = w.readframes(w.getnframes())
        info = parse_wav_strict(wav)
        assert info["channels"] == 1 and info["sample_rate"] == 24000 and info["bits"] == 16
        assert info["pcm"] == seg, f"{name}: PCM corrupted in WAV round trip"
        assert raw == seg
        results.append((len(seg) // 48, signal_present(seg), audio_stats(seg)))
    return results

print("== 1: single utterance (speech 1.6s between pauses) ==")
r = run_case("utt", utterance())
print(f"  segments: {len(r)}")
for ms, gate, st in r:
    print(f"  seg {ms}ms gate={gate} rms={st['rms']:.0f} peak={st['peak']:.0f} zcr={st['zcr']:.3f}")
assert len(r) == 1 and r[0][1], "one utterance must segment and pass gate"

print("== 2: two utterances ==")
r = run_case("two", two_utterances())
print(f"  segments: {len(r)} (expect 2)")
assert len(r) == 2 and all(g for _, g, _ in r)

print("== 3: pure silence 3s ==")
r = run_case("silence", silence(3.0))
print(f"  segments: {len(r)} (expect 0)")
assert len(r) == 0

print("== 4: short blip 200ms speech (below 350ms min) ==")
r = run_case("blip", silence(1.0) + synth_speech(0.2) + silence(1.2))
print(f"  segments: {len(r)} (expect 0)")
assert len(r) == 0

print("== 5: white noise 3s @1500 ==")
r = run_case("noise", white_noise(3.0) + silence(1.2))
print(f"  segments: {len(r)}")
for ms, gate, st in r:
    print(f"  seg {ms}ms gate={gate} rms={st['rms']:.0f} zcr={st['zcr']:.3f}")

print("== 6: 1kHz tone 1.5s ==")
r = run_case("tone", tone(1.5) + silence(1.2))
print(f"  segments: {len(r)}")
for ms, gate, st in r:
    print(f"  seg {ms}ms gate={gate} rms={st['rms']:.0f} zcr={st['zcr']:.3f}")

print("== 7: wav edge cases ==")
for pcm in [b"", b"\x00" * 100]:
    wav = wav_data(pcm)
    try:
        parse_wav_strict(wav)
        print(f"  len={len(pcm)}: parses (header ok)")
    except ValueError as e:
        print(f"  len={len(pcm)}: rejected ({e})")

print("\nALL PIPELINE ASSERTIONS PASSED")
