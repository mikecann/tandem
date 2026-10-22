"""Score Tandem's Bark transcripts against tandem-research spike 10's reference and timing.

The spike's reference is per disagreement between its five engines, so a new engine can't join its alignment
without changing every disagreement's ID. Instead each clip's reference becomes one word sequence (the agreed
words plus the judged, or majority, text of each disagreement) and an engine's errors are the edit distance to
it. Disagreements with no answer are left out of the reference, with the engine's words in their time span.
The spike's own SpeechAnalyzer and MLX Pro outputs are scored the same way, to show what the method gives.

Timing is the spike's: pauses of 0.4 s or more by Tandem's voice threshold, how much of them words cover,
where the words either side end and start, and the median start and end gap to SpeechAnalyzer's matching words.

  python -I tests/bark-check/score_bark.py <spike folder> <engine name>=<folder of transcripts>...
"""
import json
import os
import statistics
import sys

SPIKE = sys.argv[1]
sys.dont_write_bytecode = True  # the spike folder is read only to us
sys.path.insert(0, SPIKE)
import align as A  # noqa: E402
import score as S  # noqa: E402
import tandem_align  # noqa: E402
from textnorm import FILLERS, norm_words  # noqa: E402


def engines():
    out = {"SpeechAnalyzer (spike)": f"{SPIKE}/out/sa", "Bark Pro MLX (spike)": f"{SPIKE}/out/pro"}
    for arg in sys.argv[2:]:
        name, folder = arg.split("=", 1)
        out[name] = folder
    return out


def words_of(folder, clip):
    return json.load(open(f"{folder}/{clip}.json"))["words"]


def reference(clip, mode, judged):
    """[(tokens, span or None, known)] in order."""
    out = []
    for s in json.load(open(f"{SPIKE}/out/align/{clip}.json"))["segments"]:
        if "agreed" in s:
            out.append((s["agreed"], None, True))
            continue
        if mode == "judged":
            ref = judged[s["id"]]
        else:
            votes = {}
            for t in s["options"].values():
                votes[t] = votes.get(t, 0) + 1
            top, n = max(votes.items(), key=lambda kv: kv[1])
            ref = top if n >= 3 else "?"
        out.append((ref.split() if ref != "?" else [], s["t"], ref != "?"))
    return out


def errors(words, clip, mode, judged, faint, drop_fillers=False):
    ref = reference(clip, mode, judged)
    unknown = [span for _, span, known in ref if not known and span]
    kept = [w for w in words if not A.in_spans((w["start"] + w["end"]) / 2, faint)
            and not any(a - 0.05 <= (w["start"] + w["end"]) / 2 <= b + 0.05 for a, b in unknown)]
    r = [t for toks, _, known in ref if known for t in toks]
    h = [t for t, _ in norm_words(kept)]
    if drop_fillers:
        r = [t for t in r if t not in FILLERS]
        h = [t for t in h if t not in FILLERS]
    pairs = A.align_pair(r, h)
    wrong = sum(1 for i, j in pairs if i is None or j is None or r[i] != h[j])
    fill_hit = sum(1 for i, j in pairs if i is not None and j is not None and r[i] == h[j] and r[i] in FILLERS)
    return wrong, len(r), fill_hit, sum(t in FILLERS for t in r), sum(t in FILLERS for t in h)


def timing(folder, sa_folder):
    r = {"sil": 0.0, "cov": 0.0, "pauses": 0, "seen": 0, "on": [], "off": [], "ds": [], "de": [], "sds": [], "sde": [], "ds_al": [], "de_al": []}
    for clip in A.CLIPS:
        faint = json.load(open(f"{SPIKE}/out/align/{clip}.json"))["faint"]
        peaks = A.peaks(A.read_wave(clip))
        sil = S.silences(tandem_align.voiced_runs(tandem_align.levels_of(peaks)), faint)
        ours = [x for x in words_of(folder, clip) if not A.in_spans((x["start"] + x["end"]) / 2, faint)]
        sa = [x for x in words_of(sa_folder, clip) if not A.in_spans((x["start"] + x["end"]) / 2, faint)]
        r["sil"] += sum(b - a for a, b in sil)
        r["cov"] += S.covered(ours, sil)
        ws = sorted(ours, key=lambda w: w["start"])
        for a, b in sil:
            before = [w for w in ws if w["start"] < a]
            after = [w for w in ws if w["end"] > b]
            if before and a - before[-1]["start"] < 3:
                r["off"].append(before[-1]["end"] - a)
            if after and after[0]["end"] - b < 3:
                r["on"].append(after[0]["start"] - b)
        r["pauses"] += len(sil)
        r["seen"] += sum(1 for a, b in sil if (b - a) - S.covered(ours, [(a, b)]) >= 0.3)
        for x, y in S.matched(sa, ours):
            r["ds"].append(abs(x["start"] - y["start"])); r["de"].append(abs(x["end"] - y["end"]))
            r["sds"].append(y["start"] - x["start"]); r["sde"].append(y["end"] - x["end"])
        for x, y in S.matched(tandem_align.align(sa, peaks), tandem_align.align(ours, peaks)):
            r["ds_al"].append(abs(x["start"] - y["start"])); r["de_al"].append(abs(x["end"] - y["end"]))
    return r


def main():
    judged = S.judgements()
    md = lambda xs: statistics.median(xs) * 1000 if xs else float("nan")
    mda = lambda xs: md([abs(x) for x in xs])
    print(f"{'engine':24s} {'judged':>7s} {'no fill':>8s} {'majority':>9s}  {'per clip (mike13, mike16, ianC002, ianC003)':44s} "
          f"{'fillers':>8s} {'extra':>6s}")
    for name, folder in engines().items():
        tot = {"judged": [0, 0], "nofill": [0, 0], "majority": [0, 0]}
        per, fill = [], [0, 0, 0]
        for clip in A.CLIPS:
            faint = json.load(open(f"{SPIKE}/out/align/{clip}.json"))["faint"]
            w = words_of(folder, clip)
            e, n, fh, fr, fw = errors(w, clip, "judged", judged, faint)
            tot["judged"][0] += e; tot["judged"][1] += n
            per.append(e / n * 100)
            fill[0] += fh; fill[1] += fr; fill[2] += fw
            e, n, *_ = errors(w, clip, "judged", judged, faint, drop_fillers=True)
            tot["nofill"][0] += e; tot["nofill"][1] += n
            e, n, *_ = errors(w, clip, "majority", judged, faint)
            tot["majority"][0] += e; tot["majority"][1] += n
        pcs = "  ".join(f"{p:5.1f}%" for p in per)
        print(f"{name:24s} {tot['judged'][0] / tot['judged'][1] * 100:6.1f}% {tot['nofill'][0] / tot['nofill'][1] * 100:7.1f}% "
              f"{tot['majority'][0] / tot['majority'][1] * 100:8.1f}%  {pcs:44s} {fill[0]:3d}/{fill[1]:<3d} {max(0, fill[2] - fill[0]):6d}"
              f"   ({tot['judged'][0]} of {tot['judged'][1]})")
    print()
    print(f"{'engine':24s} {'silence covered':>16s} {'seen':>8s} {'end at pause':>22s} {'start after':>22s} "
          f"{'|start|/|end| vs SA':>20s} {'signed vs SA':>13s} {'aligned':>10s} {'matched':>8s}")
    sa = f"{SPIKE}/out/sa"
    for name, folder in engines().items():
        r = timing(folder, sa)
        print(f"{name:24s} {r['cov']:7.1f}/{r['sil']:5.1f}s {r['seen']:4d}/{r['pauses']:3d} "
              f"{mda(r['off']):7.0f} ms (signed {md(r['off']):+5.0f}) {mda(r['on']):7.0f} ms (signed {md(r['on']):+5.0f}) "
              f"{md(r['ds']):9.0f}/{md(r['de']):4.0f} ms {md(r['sds']):+5.0f}/{md(r['sde']):+4.0f} ms "
              f"{md(r['ds_al']):5.0f}/{md(r['de_al']):4.0f} {len(r['ds']):8d}")


if __name__ == "__main__":
    main()
