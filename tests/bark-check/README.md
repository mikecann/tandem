# Checking Bark against the transcription spike

How Tandem's Bark 3.0 Pro transcripts were checked against tandem-research
spike 10 (`~/dev/me/tandem-research/spikes/10-bark`): its four 150 s clips,
its reference words and its timing measures. docs/MEDIA.md has the results.

`tandem-bark-check` runs Bark the way Tandem's transcript job does and writes
each file's `transcript.json` to a folder. `score_bark.py` scores folders of
those against the spike, next to the spike's own SpeechAnalyzer and MLX Pro
outputs scored the same way. It reads the spike folder and writes nothing
there.

```bash
swift build -c release --product tandem-bark-check
SPIKE=~/dev/me/tandem-research/spikes/10-bark
MODEL=~/dev/me/voice-type-benchmark/models/Underdog-Bark-3.0-Pro/coreml
.build/release/tandem-bark-check --models $MODEL --compiled "$TMPDIR/bark-compiled" \
  --out tests/bark-check/out/bark $SPIKE/audio/*.wav
~/dev/me/voice-type-benchmark/.venv-bark/bin/python -I tests/bark-check/score_bark.py $SPIKE \
  "Bark Swift (Tandem)=tests/bark-check/out/bark"
```

Without `--models` it uses the model Tandem downloads (and downloads it if
it isn't there). `--download` fetches into a `--models` folder too, which
tries the real download without touching Tandem's copy:
`tandem-bark-check --models "$TMPDIR/bark-dl" --download --out "$TMPDIR/o" <wav>`. `--whole` hands each file to FluidAudio in one go instead,
so its own long-audio chunking cuts it. `TANDEM_BARK_UNITS=cpu` runs the
encoder on the CPU, for machines or sandboxes without the Neural Engine.
