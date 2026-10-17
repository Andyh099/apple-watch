import numpy as np
SR = 24000
rng = np.random.default_rng(7)

def synth_speech(dur_s, f0=130, amp=6000):
    """Vowel-like harmonic bursts with pauses (crude speech stand-in)."""
    t = np.arange(int(dur_s * SR)) / SR
    # syllable envelope: 4 syllables/sec, 60% duty
    env = (np.sin(2 * np.pi * 4 * t) > -0.2).astype(float)
    env = np.convolve(env, np.ones(240) / 240, mode="same")  # smooth edges
    harmonics = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 8))
    sig = amp * env * harmonics / 4
    sig += rng.normal(0, 120, sig.shape)  # mic-ish noise floor
    return np.clip(sig, -32768, 32767).astype("<i2").tobytes()

def silence(dur_s):
    sig = rng.normal(0, 60, int(dur_s * SR))
    return np.clip(sig, -32768, 32767).astype("<i2").tobytes()

def white_noise(dur_s, amp=1500):
    sig = rng.normal(0, amp, int(dur_s * SR))
    return np.clip(sig, -32768, 32767).astype("<i2").tobytes()

def tone(dur_s, f=1000, amp=4000):
    t = np.arange(int(dur_s * SR)) / SR
    sig = amp * np.sin(2 * np.pi * f * t)
    return np.clip(sig, -32768, 32767).astype("<i2").tobytes()



def utterance(pause_before=0.3, speech_dur=1.6, pause_after=1.2, f0=130, amp=6000):
    """One speech burst with real pauses -> VAD must cut exactly one segment."""
    return silence(pause_before) + synth_speech(speech_dur, f0=f0, amp=amp) + silence(pause_after)

def two_utterances():
    return utterance(0.3, 1.4, 1.2) + utterance(0.2, 1.1, 1.2)
