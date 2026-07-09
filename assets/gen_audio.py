"""
TRON: EXONIX — full audio pass.
SFX: fal-ai/elevenlabs/sound-effects/v2 (text -> mp3), ~25 Tron-flavored effects.
Music: fal-ai/stable-audio-25/text-to-audio (text -> wav), 3 instrumental tracks.
Post: ffmpeg -> loudness-normalized OGG (mono SFX / stereo music with a seamless
crossfade loop splice: acrossfade(track, head) then drop the first fade window).
Outputs: audio/sfx/<name>.ogg, audio/music/<name>.ogg (all well under 5 MB).
"""
import io, os, subprocess, sys, tempfile, time
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")
H = {"Authorization": f"Key {os.environ['FALAI_KEY']}", "Content-Type": "application/json"}
SFX_EP = "https://queue.fal.run/fal-ai/elevenlabs/sound-effects/v2"
MUS_EP = "https://queue.fal.run/fal-ai/stable-audio-25/text-to-audio"
OUT_SFX = Path(__file__).parent / "audio" / "sfx"
OUT_MUS = Path(__file__).parent / "audio" / "music"
RAW = Path(tempfile.gettempdir()) / "exonix_audio_raw"
for d in (OUT_SFX, OUT_MUS, RAW):
    d.mkdir(parents=True, exist_ok=True)

FF = r"C:\Users\at-re\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"
if not Path(FF).exists():
    FF = "ffmpeg"

# ---------------------------------------------------------------- SFX table
# (name, seconds, loop, prompt) — Tron vocabulary: digital, glassy, synthetic.
SFX = [
    ("bounce_soft",   0.6, False, "Soft electronic blip, a smooth energy sphere bouncing off a glass wall, short clean synthetic pluck, sci-fi arcade"),
    ("bounce_hard",   0.8, False, "Heavy metallic electronic impact, a large energy sphere slamming into a barrier, deep synthetic thud with a short metallic ring, sci-fi"),
    ("smash",         0.9, False, "A drinking glass shattering on a hard floor: high-pitched brittle glass break, many small thin shards tinkling and scattering, bright fragile crystalline shatter, ONLY glass — no metal, no bang, no boom, no impact thud, short"),
    ("burn_start",    0.8, False, "Sharp electric spark igniting, a sudden sizzle of energy catching fire along a neon line, aggressive electronic zap"),
    ("burn_loop",     4.0, True,  "Continuous electric sizzle and crackle, a line of pure energy burning steadily like a fuse, menacing electronic fire hum, seamless loop"),
    ("saw_loop",      5.0, True,  "Continuous spinning saw blade grinding through a glass floor, high pitched metallic whirring with an electronic edge, sci-fi machine, seamless loop"),
    ("death",         1.8, False, "Player explosion, deep electronic boom with glitchy digital debris scattering, bass drop impact, dramatic sci-fi arcade death"),
    ("respawn",       1.6, False, "Small spacecraft descending fast with an airy whoosh then a soft mechanical landing touch, sci-fi hover vehicle arrival, clean"),
    ("cut_start",     0.5, False, "Quick digital swoosh, a light vehicle engaging its energy trail, subtle activation blip, sci-fi, very short"),
    ("cut_loop",      4.0, True,  "Smooth continuous hum of a futuristic light trail, warm soft synth drone with a gentle airy shimmer on top, steady quiet energy field tone, pleasant and unobtrusive, no harshness, seamless loop"),
    ("platform_rise", 1.2, False, "Magical soft energy swell rising, a warm luminous synth hum ascending quickly and settling with a faint glassy sparkle, like a light trail materializing into solid ground, gentle and pleasant, sci-fi"),
    ("pulse",         1.4, False, "A single deep soft energy pulse, a round warm sub bass womp expanding outward with an airy shimmer tail, gentle cosmic ripple through space, smooth and quiet, sci-fi"),
    ("capture_small", 1.2, False, "Satisfying crystalline chime with a synth shimmer, territory secured confirmation, ascending two note digital motif, arcade reward"),
    ("capture_big",   2.2, False, "Triumphant synth power chord with a rising sparkle arpeggio, big score reward in a sci-fi arcade game, punchy and bright"),
    ("obstacle_hit",  0.7, False, "Hard strike on a large crystal, a chip of gemstone cracking off with an electronic resonance, short"),
    ("obstacle_break",1.5, False, "Large crystal monument shattering into fragments, glassy explosion with a deep sub thump, sci-fi"),
    ("pickup_good",   0.8, False, "Gentle warm neon chime, a soft short ascending sparkle, light airy positive pickup tone, smooth modern sound design, pleasant, not harsh"),
    ("pickup_bad",    0.8, False, "Soft low descending neon tone, a gentle dark detune slide, light negative interface sting, smooth and rounded, not harsh"),
    ("pickup_surprise",0.9, False, "Soft curious two note neon motif, a playful gentle question sting, light airy shimmer, smooth futuristic sound design, quiet"),
    ("pickup_spawn",  0.6, False, "Soft digital materialization ping, a hologram appearing, subtle glassy pop, quiet and short"),
    ("pickup_boom",   0.8, False, "Small energy burst pop, a floating pickup destroyed by impact, quick electronic burst with fizz"),
    ("ui_move",       0.5, False, "Very soft neon interface pip, a gentle rounded digital tap, quiet airy futuristic UI tick, smooth light sound design, no harshness, very short"),
    ("ui_select",     0.6, False, "Soft warm confirmation tone, a gentle two-note neon interface chime, smooth light futuristic UI accept sound, pleasant and airy, short"),
    ("board_show",    1.0, False, "Smooth holographic panel sliding open, airy digital whoosh with a soft glassy settle, futuristic interface"),
    ("level_clear",   3.5, False, "Victorious short synthwave fanfare, sector complete, warm analog synth chords rising, eighties sci-fi triumph"),
    ("game_over",     3.0, False, "Dark power down sting, a digital system shutting down, descending pitch with a fading electric hum, somber sci-fi"),
    ("win_final",     5.0, False, "Epic final victory fanfare, heroic synthwave chord progression with shimmering arpeggios, grand eighties sci-fi finale"),
    ("ultimate",      1.8, False, "Massive dramatic electronic announcement sting: a deep powerful riser exploding into a bright triumphant synth hit with a long shimmering tail, epic rare game event unlocked, sci-fi arcade jackpot, cinematic and loud"),
    ("time_warn",     0.6, False, "Clear electronic countdown pulse, a round synthetic ping with a tense low undertone, clean futuristic warning tone, clearly audible and present but not shrill, no siren, no alarm, single short pulse"),
]

# ---------------------------------------------------------------- music table
# (name, seconds, prompt) — Tron: Legacy energy, instrumental, loop-friendly.
PLAIN = {"music_victory"}   # jingles: normalize only, keep the intro (no loop splice)
MUSIC = [
    ("music_victory", 18,
     "Triumphant ELECTRONIC victory jingle, punchy electronic drums and bright arpeggiated analog "
     "synths, euphoric rising digital melody, sparkling sequenced arps resolving in a joyful "
     "finale, futuristic sci-fi computer-world celebration, exciting and upbeat, level complete "
     "we-move-on energy, instrumental, no vocals"),
    ("music_menu", 76,
     "Dark brooding cinematic electronic score, slow pulsing analog bass, distant airy pads, "
     "sparse minimal percussion, mysterious digital world ambience, in the style of an eighties "
     "futuristic sci-fi film soundtrack, instrumental, steady hypnotic mood, no vocals"),
    ("music_play_a", 120,
     "Driving dark synthwave at 118 BPM, pulsing arpeggiated analog bassline, four on the floor "
     "electronic drums, soaring analog synth lead, relentless forward energy, neon grid racing "
     "through a digital world, cinematic sci-fi electro, instrumental, no vocals"),
    ("music_play_b", 128,
     "Intense dark electro at 128 BPM, aggressive analog bass stabs, industrial percussion, "
     "ominous synthetic string layers, rising tension, high stakes chase inside a computer world, "
     "cinematic eighties sci-fi electronic score, instrumental, no vocals"),
    # sectors 1-2: same neon world, zero danger — a welcoming glide (Stefan 2026-07-09)
    ("music_play_easy", 112,
     "Laid-back warm synthwave at 100 BPM, smooth gliding analog pads, gentle soft arpeggiated "
     "bassline, relaxed steady electronic drums, dreamy optimistic melody drifting over a calm neon "
     "grid, friendly and inviting, no tension, no danger, eighties sci-fi serenity, instrumental, "
     "no vocals"),
    # sectors 9-10: The Fall energy — pounding hybrid orchestral-electro, aggressive
    ("music_play_intense", 122,
     "Ferocious cinematic electro-orchestral hybrid at 124 BPM, pounding heavy taiko-like "
     "electronic percussion hits, dark relentless analog bass ostinato, urgent aggressive staccato "
     "synth-string stabs, distorted growling synth accents, menacing unstoppable drive, final "
     "showdown deep inside a machine world, epic eighties sci-fi film score, instrumental, no vocals"),
]


def fetch(url: str, tries: int = 4) -> bytes:
    for i in range(tries):
        try:
            return requests.get(url, timeout=300).content
        except Exception as e:
            if i == tries - 1:
                raise
            print(f"  retry {i + 1} after: {type(e).__name__}")
            time.sleep(4 * (i + 1))


def submit(url: str, payload: dict, name: str):
    r = requests.post(url, headers=H, json=payload, timeout=60)
    r.raise_for_status()
    j = r.json()
    return {"name": name, "s": j["status_url"], "r": j["response_url"]}


def poll(jobs: list, deadline_s: int) -> dict:
    """-> {name: response_json or None}"""
    done = {}
    end = time.time() + deadline_s
    while len(done) < len(jobs) and time.time() < end:
        time.sleep(6)
        for j in jobs:
            if j["name"] in done:
                continue
            try:
                st = requests.get(j["s"], headers=H, timeout=60).json()
            except Exception as e:
                print(f"  poll retry {j['name']}: {type(e).__name__}")
                continue
            if st.get("status") == "COMPLETED":
                done[j["name"]] = requests.get(j["r"], headers=H, timeout=120).json()
                print(f"  done: {j['name']}")
            elif st.get("status") in ("FAILED", "ERROR"):
                done[j["name"]] = None
                print(f"  FAIL: {j['name']}: {st}")
    for j in jobs:
        done.setdefault(j["name"], None)
    return done


def ff(args: list):
    p = subprocess.run([FF, "-y", "-hide_banner", "-loglevel", "error"] + args,
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"ffmpeg: {p.stderr[-400:]}")


def to_sfx_ogg(src: Path, dst: Path):
    ff(["-i", str(src), "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
        "-ac", "1", "-ar", "44100", "-c:a", "libvorbis", "-q:a", "5", str(dst)])


def to_music_plain_ogg(src: Path, dst: Path):
    ff(["-i", str(src), "-af", "loudnorm=I=-18:TP=-1.5:LRA=9",
        "-ar", "44100", "-c:a", "libvorbis", "-q:a", "6", str(dst)])


def to_music_loop_ogg(src: Path, dst: Path, xfade: float = 3.0):
    # normalize FIRST so the splice is built from settled gain, then:
    # acrossfade(track, head) and drop the first <xfade> seconds -> seamless loop.
    flt = (f"[0:a]loudnorm=I=-18:TP=-1.5:LRA=9,asplit=2[a][b];"
           f"[b]atrim=0:{xfade},asetpts=PTS-STARTPTS[h];"
           f"[a][h]acrossfade=d={xfade}[x];"
           f"[x]atrim={xfade},asetpts=PTS-STARTPTS[out]")
    ff(["-i", str(src), "-filter_complex", flt, "-map", "[out]",
        "-ar", "44100", "-c:a", "libvorbis", "-q:a", "6", str(dst)])


def audio_url(res: dict):
    a = (res or {}).get("audio") or {}
    return a.get("url")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""  # optional name filter

    # ---- submit everything up front
    sfx_jobs, mus_jobs = [], []
    for name, dur, loop, prompt in SFX:
        if only and only not in name:
            continue
        payload = {"text": prompt, "duration_seconds": dur,
                   "output_format": "mp3_44100_192"}
        if loop:
            payload["loop"] = True
        sfx_jobs.append(submit(SFX_EP, payload, name))
        print(f"queued sfx: {name}")
    for name, secs, prompt in MUSIC:
        if only and only not in name:
            continue
        mus_jobs.append(submit(MUS_EP, {"prompt": prompt, "seconds_total": secs}, name))
        print(f"queued music: {name}")

    ok, fail = [], []

    if sfx_jobs:
        print("-- polling SFX --")
        for name, res in poll(sfx_jobs, 600).items():
            url = audio_url(res)
            if not url:
                fail.append(name); continue
            raw = RAW / f"{name}.mp3"
            raw.write_bytes(fetch(url))
            try:
                to_sfx_ogg(raw, OUT_SFX / f"{name}.ogg")
                ok.append(name)
            except Exception as e:
                fail.append(name); print(f"  ffmpeg FAIL {name}: {e}")

    if mus_jobs:
        print("-- polling music (slow) --")
        for name, res in poll(mus_jobs, 1500).items():
            url = audio_url(res)
            if not url:
                fail.append(name); continue
            raw = RAW / f"{name}.wav"
            raw.write_bytes(fetch(url))
            try:
                if name in PLAIN:
                    to_music_plain_ogg(raw, OUT_MUS / f"{name}.ogg")
                else:
                    to_music_loop_ogg(raw, OUT_MUS / f"{name}.ogg")
                ok.append(name)
            except Exception as e:
                fail.append(name); print(f"  ffmpeg FAIL {name}: {e}")

    print(f"\nOK ({len(ok)}):", ", ".join(sorted(ok)))
    if fail:
        print(f"FAILED ({len(fail)}):", ", ".join(sorted(fail)))
    for f in sorted(list(OUT_SFX.glob("*.ogg")) + list(OUT_MUS.glob("*.ogg"))):
        print(f"  {f.relative_to(Path(__file__).parent)}  {f.stat().st_size/1024:.0f} KB")


if __name__ == "__main__":
    main()
