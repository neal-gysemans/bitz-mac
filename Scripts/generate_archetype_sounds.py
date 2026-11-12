#!/usr/bin/env python3
"""
Procedural Sound Generator for Bitz Companion Mascot Archetypes (Issue #150).
Synthesizes 5 deterministic, license-clean 22,050 Hz Mono 16-bit WAV audio files:
  1. drako_plasma_rumble.wav   (Drako: Low-frequency plasma hum / flame-core rumble)
  2. byte_servo_whine.wav      (Byte: Tactical servo whine / metallic pant / chirp)
  3. aero_turbine_spool.wav    (Aero: Antigravity turbine spool / ion levitation tone)
  4. pixel_stepper_click.wav   (Pixel: Hydraulic stepper click / cassette relay whir)
  5. volt_capacitor_chirp.wav  (Volt: High-voltage capacitor chirp / bionic pulse)

Standard:
  - Sample Rate: 22,050 Hz
  - Channels: 1 (Mono)
  - Bit Depth: 16-bit signed PCM
  - Max duration: <= 3.0 s
  - Max file size: < 100 KB
  - License: CC0 1.0 Universal / Public Domain Dedication
"""

import math
import os
import shutil
import struct
import wave

SAMPLE_RATE = 22050
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "src", "Resources", "Sounds")
ROOT_RESOURCES_DIR = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")


def clamp(value: float, min_val: float, max_val: float) -> float:
    return max(min_val, min(max_val, value))


def write_wav(filename: str, samples: list[float], sample_rate: int = SAMPLE_RATE) -> str:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    out_path = os.path.join(OUTPUT_DIR, filename)

    # Normalize samples to avoid clipping with safe headroom (peak 0.85)
    max_amp = max(abs(s) for s in samples) if samples else 1.0
    norm_factor = 0.85 / max_amp if max_amp > 0 else 1.0

    raw_bytes = bytearray()
    for s in samples:
        scaled = int(clamp(s * norm_factor, -1.0, 1.0) * 32767.0)
        raw_bytes.extend(struct.pack("<h", scaled))

    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(raw_bytes)

    if os.path.isdir(ROOT_RESOURCES_DIR):
        shutil.copy2(out_path, os.path.join(ROOT_RESOURCES_DIR, filename))

    size = os.path.getsize(out_path)
    duration = len(samples) / sample_rate
    print(f"Generated {filename:26s} | {duration:.2f}s | {size:6d} bytes | {size/1024:.1f} KB")
    return out_path


def envelope_fade(index: int, total: int, fade_in_samples: int, fade_out_samples: int) -> float:
    """Smooth cosine fade-in and fade-out envelope to guarantee click-free boundaries."""
    if index < fade_in_samples and fade_in_samples > 0:
        return 0.5 * (1.0 - math.cos(math.pi * index / fade_in_samples))
    elif index >= total - fade_out_samples and fade_out_samples > 0:
        remaining = total - 1 - index
        return 0.5 * (1.0 - math.cos(math.pi * remaining / fade_out_samples))
    return 1.0


# ---------------------------------------------------------------------------
# 1. Drako: Plasma Wyvern Rumble (Low-frequency plasma hum / flame-core rumble)
# ---------------------------------------------------------------------------
def generate_drako() -> list[float]:
    duration = 2.0
    total_samples = int(duration * SAMPLE_RATE)
    samples = []

    fade_in = int(0.25 * SAMPLE_RATE)
    fade_out = int(0.35 * SAMPLE_RATE)

    for i in range(total_samples):
        t = i / SAMPLE_RATE

        # Breathing / swelling pulsation (2 breath cycles across 2.0s)
        pulse = 0.70 + 0.30 * math.sin(2.0 * math.pi * 1.0 * t - 0.5 * math.pi)

        # Draconic sub-bass core rumble (52 Hz fundamental + 104 Hz 2nd harmonic)
        f_sub = 52.0 + 3.0 * math.sin(2.0 * math.pi * 3.5 * t)
        sub = 0.55 * math.sin(2.0 * math.pi * f_sub * t)
        harm2 = 0.25 * math.sin(2.0 * math.pi * (f_sub * 2.0) * t)

        # Warm plasma oscillation (156 Hz 3rd harmonic + 208 Hz 4th)
        plasma = 0.15 * math.sin(2.0 * math.pi * 156.0 * t + 0.4 * math.sin(2.0 * math.pi * 12.0 * t))

        # Thermal micro-crackle: deterministic pseudo-random plasma jitter
        jitter = 0.05 * math.sin(2.0 * math.pi * 340.0 * t) * math.sin(2.0 * math.pi * 23.0 * t)

        val = (sub + harm2 + plasma + jitter) * pulse
        env = envelope_fade(i, total_samples, fade_in, fade_out)
        samples.append(val * env)

    return samples


# ---------------------------------------------------------------------------
# 2. Byte: Tactical Servo Whine (Precision servo whine / metallic pant / chirp)
# ---------------------------------------------------------------------------
def generate_byte() -> list[float]:
    duration = 1.6
    total_samples = int(duration * SAMPLE_RATE)
    samples = []

    fade_in = int(0.04 * SAMPLE_RATE)
    fade_out = int(0.15 * SAMPLE_RATE)

    for i in range(total_samples):
        t = i / SAMPLE_RATE

        # Phase 1: Rapid twin servo micro-puffs (tactical mechanical panting)
        # Pant 1: 0.0s - 0.45s, Pant 2: 0.45s - 0.9s
        servo_val = 0.0
        if t < 0.45:
            pt = t / 0.45
            p_env = math.sin(math.pi * pt)
            f_servo = 450.0 + 400.0 * pt
            servo_val = 0.5 * math.sin(2.0 * math.pi * f_servo * t) * p_env
            # Add subtle metallic texture
            servo_val += 0.15 * math.sin(2.0 * math.pi * (f_servo * 2.5) * t) * p_env
        elif t < 0.90:
            pt = (t - 0.45) / 0.45
            p_env = math.sin(math.pi * pt)
            f_servo = 520.0 + 480.0 * pt
            servo_val = 0.55 * math.sin(2.0 * math.pi * f_servo * t) * p_env
            servo_val += 0.18 * math.sin(2.0 * math.pi * (f_servo * 2.5) * t) * p_env
        else:
            # Phase 2: Friendly high-tech K9 confirmation chirp (0.9s - 1.6s)
            ct = (t - 0.90) / 0.70
            c_env = math.sin(math.pi * min(1.0, ct * 1.5)) * math.exp(-2.2 * ct)
            f_chirp = 1100.0 + 500.0 * math.sin(math.pi * ct)
            chirp = 0.65 * math.sin(2.0 * math.pi * f_chirp * t)
            harm = 0.20 * math.sin(2.0 * math.pi * (f_chirp * 1.5) * t)
            servo_val = (chirp + harm) * c_env

        env = envelope_fade(i, total_samples, fade_in, fade_out)
        samples.append(servo_val * env)

    return samples


# ---------------------------------------------------------------------------
# 3. Aero: Antigravity Turbine Spool (Harmonic ion levitation spool)
# ---------------------------------------------------------------------------
def generate_aero() -> list[float]:
    duration = 1.9
    total_samples = int(duration * SAMPLE_RATE)
    samples = []

    fade_in = int(0.20 * SAMPLE_RATE)
    fade_out = int(0.30 * SAMPLE_RATE)

    for i in range(total_samples):
        t = i / SAMPLE_RATE

        # Turbine spool curve: sweeps smoothly from 260 Hz up to 520 Hz then stabilizes
        spool_progress = min(1.0, t / 1.0)
        f_turbine = 260.0 + 260.0 * (1.0 - math.cos(0.5 * math.pi * spool_progress))

        # Primary turbine core
        turbine = 0.45 * math.sin(2.0 * math.pi * f_turbine * t)

        # Ion levitation harmonic: pure musical fifth (1.5x) and octave (2.0x) with soft chorus
        ion_fifth = 0.25 * math.sin(2.0 * math.pi * (f_turbine * 1.5) * t + 0.1 * math.sin(2.0 * math.pi * 5.0 * t))
        ion_octave = 0.18 * math.sin(2.0 * math.pi * (f_turbine * 2.0) * t)

        # Concentric levitation ring shimmer (soft ring modulation)
        ring_mod = 0.85 + 0.15 * math.sin(2.0 * math.pi * 8.0 * t)

        val = (turbine + ion_fifth + ion_octave) * ring_mod
        env = envelope_fade(i, total_samples, fade_in, fade_out)
        samples.append(val * env)

    return samples


# ---------------------------------------------------------------------------
# 4. Pixel: Hydraulic Stepper Click (Retro CRT mech relay whir & clicks)
# ---------------------------------------------------------------------------
def generate_pixel() -> list[float]:
    duration = 1.4
    total_samples = int(duration * SAMPLE_RATE)
    samples = []

    fade_in = int(0.01 * SAMPLE_RATE)
    fade_out = int(0.12 * SAMPLE_RATE)

    for i in range(total_samples):
        t = i / SAMPLE_RATE

        # Initial mechanical relay solenoid click (0.0s - 0.08s)
        click = 0.0
        if t < 0.08:
            ct = t / 0.08
            click_env = math.exp(-35.0 * ct)
            # Solenoid transient pulse
            click = 0.8 * math.sin(2.0 * math.pi * 320.0 * t) * click_env

        # Vintage cassette tape drive / stepper motor whir (0.05s - 0.85s)
        stepper = 0.0
        if 0.05 <= t < 0.85:
            st = (t - 0.05) / 0.80
            s_env = math.sin(math.pi * st)
            # Stepper motor tooth clicks (~140 Hz fundamental with odd harmonics)
            f_step = 160.0
            stepper_sq = (
                0.35 * math.sin(2.0 * math.pi * f_step * t)
                + 0.15 * math.sin(2.0 * math.pi * 3.0 * f_step * t)
                + 0.08 * math.sin(2.0 * math.pi * 5.0 * f_step * t)
            )
            stepper = stepper_sq * s_env

        # Playful 8-bit dual-tone CRT blip (0.85s - 1.4s)
        blip = 0.0
        if t >= 0.85:
            bt = (t - 0.85) / 0.55
            b_env = math.exp(-4.5 * bt)
            # Note 1 (E5, 659 Hz) transitioning to Note 2 (A5, 880 Hz)
            f_blip = 659.25 if bt < 0.20 else 880.0
            blip = (0.50 * math.sin(2.0 * math.pi * f_blip * t) + 0.15 * math.sin(2.0 * math.pi * 2.0 * f_blip * t)) * b_env

        val = click + stepper + blip
        env = envelope_fade(i, total_samples, fade_in, fade_out)
        samples.append(val * env)

    return samples


# ---------------------------------------------------------------------------
# 5. Volt: High-Voltage Capacitor Chirp (Capacitor charge & bionic pulse)
# ---------------------------------------------------------------------------
def generate_volt() -> list[float]:
    duration = 1.3
    total_samples = int(duration * SAMPLE_RATE)
    samples = []

    fade_in = int(0.02 * SAMPLE_RATE)
    fade_out = int(0.12 * SAMPLE_RATE)

    for i in range(total_samples):
        t = i / SAMPLE_RATE

        # Phase 1: High-voltage capacitor charge whine (0.0s - 0.45s)
        charge = 0.0
        if t < 0.45:
            ct = t / 0.45
            c_env = math.sin(0.5 * math.pi * ct)
            # Rapid upward exponential frequency sweep: 600 Hz -> 2200 Hz
            f_charge = 600.0 * math.pow(2200.0 / 600.0, ct)
            charge = 0.45 * math.sin(2.0 * math.pi * f_charge * t) * c_env

        # Phase 2: Bionic energetic hopper chirp (0.45s - 1.3s)
        # Playful springy double-chirp
        chirp = 0.0
        if t >= 0.45:
            pt = (t - 0.45) / 0.85
            if pt < 0.40:
                # First chirp: 1400 Hz -> 1900 Hz
                hop_t = pt / 0.40
                h_env = math.sin(math.pi * hop_t) * math.exp(-1.5 * hop_t)
                f_hop = 1400.0 + 500.0 * hop_t
                chirp = 0.60 * math.sin(2.0 * math.pi * f_hop * t) * h_env
            else:
                # Second buoyant chirp: 1800 Hz -> 2400 Hz
                hop_t = (pt - 0.40) / 0.60
                h_env = math.sin(math.pi * hop_t) * math.exp(-2.5 * hop_t)
                f_hop = 1800.0 + 600.0 * hop_t
                chirp = 0.55 * math.sin(2.0 * math.pi * f_hop * t) * h_env

        val = charge + chirp
        env = envelope_fade(i, total_samples, fade_in, fade_out)
        samples.append(val * env)

    return samples


def main() -> None:
    print(f"Synthesizing archetype companion audio in {OUTPUT_DIR}...")
    write_wav("drako_plasma_rumble.wav", generate_drako())
    write_wav("byte_servo_whine.wav", generate_byte())
    write_wav("aero_turbine_spool.wav", generate_aero())
    write_wav("pixel_stepper_click.wav", generate_pixel())
    write_wav("volt_capacitor_chirp.wav", generate_volt())
    print("All archetype companion sound files synthesized successfully.")


if __name__ == "__main__":
    main()
