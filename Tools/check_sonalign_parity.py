#!/usr/bin/env python3
"""Compare released Sonalign with the current Swift spectral oracle.

Inputs are shared cached PCEN features, not decoded audio. Cold entries reset the
matcher/tracker only; resampling and feature-extractor parity are out of scope.
No third-party Python packages are required. Local audio/features stay untracked.
"""

import argparse
import array
import bisect
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FEATURES = ROOT / "LocalFixtures/ambient-sync-voice-memos/.spectral-sync-20260909/features"
BASELINE = "82381d34e8166050531919b070131117bb1e13ee"
SONALIGN_VERSION = "0.1.0"
HOP = 512 / 48_000 * 1000
OPTIONAL_KEYS = {
    "withholdReason", "estimate", "firstProvisionalLockElapsedMS", "confirmedLockElapsedMS",
    "finalLockElapsedMS", "competingPeakMargin", "offsetStabilityMS", "trackInnovationMS",
}
EVENT_KEYS = {
    "endpointMS", "elapsedMS", "state", "phase", "stage", "withholdReason", "estimate", "confidence",
    "firstProvisionalLockElapsedMS", "confirmedLockElapsedMS", "finalLockElapsedMS", "spectral",
    "queryDurationMS", "activeFrameFraction", "coarseAmbiguous", "denseMargin", "offsetStabilityMS",
    "trackInnovationMS", "trackCount", "offsetTrackerConfirmed", "offsetTrackerStable", "candidates",
}


def read_array(path, dtype):
    values = array.array(dtype)
    values.frombytes(Path(path).read_bytes())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def write_array(path, dtype, values):
    result = array.array(dtype, values)
    if sys.byteorder != "little":
        result.byteswap()
    Path(path).write_bytes(result.tobytes())


def descriptor(base, name, hop=None):
    item = {"timesPath": str(base / (name + ".times.f64")), "pcenPath": str(base / (name + ".pcen.f32"))}
    if hop is not None:
        item.update(name=name, hopMS=hop)
    return item


def schedule(times, cadence=1000, entry=0, duration=None, window=5000, tracking_window=None):
    first = bisect.bisect_left(times, entry)
    end = len(times) if duration is None else bisect.bisect_right(times, entry + duration)
    if first >= end:
        return []
    calls, start, next_time = [], first, -math.inf
    for index in range(first, end):
        endpoint = times[index]
        if endpoint < next_time and index != end - 1:
            continue
        next_time = endpoint + cadence
        width = tracking_window if tracking_window is not None and endpoint - entry >= 8000 else window
        while start < index and times[start] < endpoint - width:
            start += 1
        calls.append({"startIndex": start, "endIndex": index, "elapsedMS": endpoint - entry})
    return calls


def synthesize(base):
    """Small deterministic probes of actual regression boundaries in Swift."""
    base.mkdir(parents=True, exist_ok=True)

    def smooth(count, seed=1):
        return [[math.exp(0.5 * math.sin(i * (0.061 + (b + 3) * (seed + 7) * 0.00037) + (b + 3) * (seed + 7))
                          + 0.5 * math.sin(i * (0.113 + (b + 3) * (seed + 7) * 0.00019) + i * i * 0.00013))
                 for b in range(24)] for i in range(count)]

    def save(name, rows, times=None, energies=None, reference=False):
        times = [i * 20.0 for i in range(len(rows))] if times is None else times
        write_array(base / (name + ".pcen.f32"), "f", (v for row in rows for v in row))
        write_array(base / (name + ".times.f64"), "d", times)
        result = descriptor(base, name, 20 if reference else None)
        if energies is not None:
            path = base / (name + ".energy.f64")
            write_array(path, "d", energies)
            result["energyPath"] = str(path)
        return result, times

    rows = smooth(2500)
    ref, _ = save("reference", rows, reference=True)
    clean, times = save("clean", rows[100:1100])
    result = []

    def case(name, reference=ref, query=clean, calls=None, cadence=500):
        result.append({"id": "synthetic/" + name, "reference": reference, "query": query,
                       "calls": calls if calls is not None else schedule(read_array(query["timesPath"], "d"), cadence)})

    noisy_rows = [[max(0, (b % 4) * 0.3 + v * (0.5 + (b % 5) * 0.2)
                           + 0.15 * math.sin(i * (b + 17) * 0.123)) for b, v in enumerate(row)]
                  for i, row in enumerate(rows[200:1200])]
    noisy, _ = save("noisy", noisy_rows)
    for cadence in [100, 1000]:
        case("noise-" + str(cadence), query=noisy, cadence=cadence)
    stationary, _ = save("stationary", [[2] * 24 for _ in range(750)])
    case("stationary", query=stationary)
    wrong, _ = save("wrong", smooth(750, 97))
    case("unrelated", query=wrong)
    case("fast-reuse", cadence=20)
    same = {"startIndex": 0, "endIndex": 150, "elapsedMS": 3000}
    case("repeated-window", calls=[dict(same, elapsedMS=t) for t in range(3000, 10001, 100)])
    case("two-second-tracking", calls=schedule(times, 100, tracking_window=2000))
    regular = schedule(times[:451], 500)
    case("rewind", calls=regular + schedule(times[:501], 500))
    short_ref, _ = save("short-reference", rows[:300], reference=True)
    ending, _ = save("reference-ending", rows[50:300])
    case("reference-boundary", reference=short_ref, query=ending, cadence=100)
    seek, _ = save("seek", [rows[i + (100 if i < 400 else 700)] for i in range(900)])
    case("seek", query=seek, cadence=100)
    silence, _ = save("silence", rows[100:850], energies=[-20 if i < 400 else -120 for i in range(750)])
    case("silence-after-lock", query=silence, cadence=100)
    low_energy, _ = save("low-energy", rows[100:850], energies=[-80] * 750)
    case("low-energy", query=low_energy)
    inactive, _ = save("inactive", rows[100:850], energies=[-20 if i % 10 < 3 else -90 for i in range(750)])
    case("insufficient-active-frames", query=inactive)
    repeated_rows = rows[:500] + rows[:500]
    repeated_ref, _ = save("repeated-reference", repeated_rows, reference=True)
    repeated_query, _ = save("repeated-query", repeated_rows[100:450])
    case("ambiguous-repeat", reference=repeated_ref, query=repeated_query)
    skew, _ = save("skew", rows[100:850], times=[i * 20 * 1.04 for i in range(750)])
    case("invalid-time-grid", query=skew, cadence=100)
    invalid_ref, _ = save("invalid-reference", rows[:100] + rows[200:300],
                          times=[i * 20 for i in range(100)] + [i * 20 for i in range(200, 300)], reference=True)
    case("invalid-reference", reference=invalid_ref)
    for name, shift in [("rapid-invalid-after-lock", -1150), ("invalid-after-lock", 0)]:
        combined = rows[100:501] + rows[300:550]
        appended_times = [i * 20 for i in range(401)] + [4000 + i * 20 * 1.04 + shift for i in range(250)]
        query, _ = save(name, combined, times=appended_times)
        calls = schedule(appended_times[:401], 500)
        calls.append({"startIndex": 401, "endIndex": 650, "elapsedMS": 8050 if shift else 9200})
        case(name, query=query, calls=calls)
    discontinuity, _ = save("discontinuity", rows[100:600] + rows[800:1300],
                            times=[i * 20 for i in range(500)] + [15000 + i * 20 for i in range(500)])
    calls = schedule([i * 20 for i in range(500)], 500)
    calls += [dict(c, startIndex=c["startIndex"] + 500, endIndex=c["endIndex"] + 500, elapsedMS=c["elapsedMS"] + 15000)
              for c in schedule([i * 20 for i in range(500)], 500)]
    case("discontinuity", query=discontinuity, calls=calls)
    ambiguous_rows = [rows[i - 1000] if 1500 <= i < 2000 else row for i, row in enumerate(rows)]
    ambiguous_ref, _ = save("ambiguous-recovery-reference", ambiguous_rows, reference=True)
    unrelated = smooth(1000, 83)
    recovery, _ = save("ambiguous-recovery", [unrelated[i] if 400 <= i < 550 else ambiguous_rows[i + 100] for i in range(900)])
    case("ambiguous-recovery", reference=ambiguous_ref, query=recovery, cadence=100)
    return result


def generate_cases(features, output, suites):
    cases = []
    if "synthetic" in suites:
        cases += synthesize(output / "synthetic-features")
    if suites - {"synthetic"}:
        manifest = json.loads((features / "manifest.json").read_text())
        references = sorted({item["reference"] for item in manifest})
        for item in manifest:
            name = item["fixture"]
            query = descriptor(features, name)
            times = read_array(query["timesPath"], "d")
            reference = descriptor(features, item["reference"], HOP)
            if "fixtures" in suites:
                cases.append({"id": "fixture/" + name, "reference": reference, "query": query, "calls": schedule(times)})
            if "entries" in suites:
                for entry in [30000, 90000]:
                    if times[-1] >= entry + 30000:
                        cases.append({"id": f"entry/{name}/{entry}", "reference": reference, "query": query,
                                      "calls": schedule(times, entry=entry, duration=30000)})
            if "stress" in suites and "queen-world-created" in name:
                cases.append({"id": "stress/queen-entry30-cadence100", "reference": reference, "query": query,
                              "calls": schedule(times, cadence=100, entry=30000, duration=30000)})
            if "wrong" in suites:
                for other in references:
                    if other == item["reference"]:
                        continue
                    for cadence in [500, 1000]:
                        cases.append({"id": f"wrong/{name}/{other}/{cadence}",
                                      "reference": descriptor(features, other, HOP), "query": query,
                                      "calls": schedule(times, cadence=cadence)})
    return cases


def swift_sources():
    services = ROOT / "Sources/PulsefieldCore/Services/AmbientSync"
    return ([ROOT / "Sources/PulsefieldCore/Domain/AmbientSyncDomain.swift"]
            + sorted(services.glob("AmbientSyncEngine*.swift"))
            + [services / (name + ".swift") for name in ["AmbientSyncOffsetHistogram", "AmbientSyncOffsetTracker",
                                                        "AmbientSyncSpectralEngine", "AmbientSyncSpectralMatcher"]]
            + [ROOT / "Tools/swift_sync_parity.swift"])


def compare(swift_path, rust_path, cases):
    maxima, mismatches, counts = defaultdict(float), [], Counter()
    candidate_maxima, candidate_differences = defaultdict(float), []
    counts.update({"mismatches": 0, "diagnosticCandidateDifferences": 0, "unexplainedDiagnosticCandidateDifferences": 0,
                   "swiftWrongReferenceAcquisitions": 0, "rustWrongReferenceAcquisitions": 0})
    times = {"swift": defaultdict(list), "rust": defaultdict(list)}
    raw_cache = {}

    def cached(path, dtype=None):
        key = (path, dtype)
        if key not in raw_cache:
            raw_cache[key] = read_array(path, dtype) if dtype else Path(path).read_bytes()
        return raw_cache[key]

    def identical_support(item, call, left, right):
        # A duplicate can replace a low-ranked diagnostic alternative after tiny
        # floating-point reduction differences. Verify the actual reference
        # samples supporting the full centered correlation, not just its score.
        if abs(left["score"] - right["score"]) > 1e-6:
            return False
        hop = item["reference"].get("hopMS", HOP)
        radius = max(1, math.floor(250 / hop + 0.5))
        count = call["endIndex"] - call["startIndex"] + 1 - 2 * radius
        if count <= 0:
            return False
        query_times = cached(item["query"]["timesPath"], "d")
        reference_times = cached(item["reference"]["timesPath"], "d")
        origin = query_times[call["startIndex"] + radius] - reference_times[0]
        starts = [math.floor((origin + candidate["offsetMS"]) / hop + 0.5) for candidate in [left, right]]
        if starts[0] == starts[1] or any(start < radius or start + count + radius > len(reference_times) for start in starts):
            return False
        data = cached(item["reference"]["pcenPath"])
        stride = item.get("bands", 24) * 4
        segments = [data[(start - radius) * stride:(start + count + radius) * stride] for start in starts]
        return segments[0] == segments[1]

    def compare_candidates(item, call, index, left, right):
        if len(left) != len(right):
            counts["diagnosticCandidateDifferences"] += 1
            counts["unexplainedDiagnosticCandidateDifferences"] += 1
            candidate_differences.append({"case": item["id"], "event": index, "field": "length",
                                          "swift": len(left), "rust": len(right), "equalStrengthDuplicate": False})
        for rank, (a, b) in enumerate(zip(left, right)):
            differences = {}
            for field, tolerance in [("offsetMS", 0.05), ("score", 1e-5)]:
                if field not in a or field not in b:
                    differences[field] = {"swift": a.get(field), "rust": b.get(field)}
                    continue
                delta = abs(a[field] - b[field])
                candidate_maxima[field] = max(candidate_maxima[field], delta)
                if not math.isfinite(delta) or delta > tolerance:
                    differences[field] = {"swift": a[field], "rust": b[field]}
            if differences:
                # The leading peak is never exempted. Other alternatives can
                # exchange rank when their scores are indistinguishable at the
                # reduction tolerance, but each offset/score must still exist.
                def contains_candidate(candidates, expected):
                    return any(abs(other["offsetMS"] - expected["offsetMS"]) <= 0.05
                               and abs(other["score"] - expected["score"]) <= 1e-5 for other in candidates[1:])

                permutation = (rank >= 1 and set(differences) == {"offsetMS"}
                               and abs(a["score"] - b["score"]) <= 1e-6
                               and contains_candidate(right, a) and contains_candidate(left, b))
                duplicate = rank >= 2 and set(differences) == {"offsetMS"} and identical_support(item, call, a, b)
                equivalent = permutation or duplicate
                counts["diagnosticCandidateDifferences"] += 1
                counts["unexplainedDiagnosticCandidateDifferences"] += int(not equivalent)
                candidate_differences.append({"case": item["id"], "event": index, "rank": rank,
                                              "fields": differences, "swiftScore": a.get("score"), "rustScore": b.get("score"),
                                              "equalStrengthDuplicate": duplicate, "equalStrengthPermutation": permutation})

    def mismatch(case_id, path, left, right):
        counts["mismatches"] += 1
        if len(mismatches) < 40:
            mismatches.append({"case": case_id, "field": path, "swift": left, "rust": right})

    def walk(case_id, path, left, right):
        if isinstance(left, bool) or isinstance(right, bool):
            if left is not right:
                mismatch(case_id, path, left, right)
        elif isinstance(left, (int, float)) and isinstance(right, (int, float)):
            delta = abs(left - right)
            field = path.split(".")[-1]
            # Times identifying a call/milestone must be unchanged. Correlation
            # reduction order may differ across Accelerate and portable SIMD.
            tolerance = 0.05 if field in {"offsetMS", "referenceTimeMS", "offsetStabilityMS", "trackInnovationMS"} else 1e-5
            maxima[field] = max(maxima[field], delta)
            if not math.isfinite(delta) or delta > tolerance:
                mismatch(case_id, path, left, right)
        elif isinstance(left, dict) and isinstance(right, dict):
            for key in set(left) | set(right):
                if key in OPTIONAL_KEYS:
                    walk(case_id, path + "." + key, left.get(key), right.get(key))
                elif key not in left or key not in right:
                    mismatch(case_id, path + "." + key, left.get(key, "<missing>"), right.get(key, "<missing>"))
                else:
                    walk(case_id, path + "." + key, left[key], right[key])
        elif isinstance(left, list) and isinstance(right, list):
            if len(left) != len(right):
                mismatch(case_id, path + ".length", len(left), len(right))
            for index, (a, b) in enumerate(zip(left, right)):
                walk(case_id, path + f"[{index}]", a, b)
        elif left != right:
            mismatch(case_id, path, left, right)

    with swift_path.open() as swift_file, rust_path.open() as rust_file:
        for item in cases:
            case_id = item["id"]
            group = case_id.split("/")[0]
            left_line, right_line = swift_file.readline(), rust_file.readline()
            if not left_line or not right_line:
                mismatch(case_id, "case", "present" if left_line else "missing", "present" if right_line else "missing")
                continue
            left, right = json.loads(left_line), json.loads(right_line)
            if left.get("id") != case_id or right.get("id") != case_id:
                mismatch(case_id, "id", left.get("id"), right.get("id"))
            for language, row in [("swift", left), ("rust", right)]:
                if len(row["events"]) != len(item["calls"]):
                    mismatch(case_id, language + ".eventCount", len(item["calls"]), len(row["events"]))
                for event in row["events"]:
                    times[language][group].append(event["processNS"] / 1e6)
                if group == "wrong" and any(e["state"] in {"confirmed", "locked"} for e in row["events"]):
                    counts[language + "WrongReferenceAcquisitions"] += 1
                if group in {"fixture", "entry"}:
                    if any(e["state"] in {"confirmed", "locked"} for e in row["events"]):
                        counts[language + group.title() + "Acquisitions"] += 1
                    if row["events"] and row["events"][-1]["state"] == "locked":
                        counts[language + group.title() + "EndingLocked"] += 1
            for index, (a, b) in enumerate(zip(left["events"], right["events"])):
                for key in EVENT_KEYS:
                    if key not in OPTIONAL_KEYS and (key not in a or key not in b):
                        mismatch(case_id, f"events[{index}].{key}", a.get(key, "<missing>"), b.get(key, "<missing>"))
                    elif key != "candidates":
                        walk(case_id, f"events[{index}].{key}", a.get(key), b.get(key))
                if "candidates" in a and "candidates" in b:
                    compare_candidates(item, item["calls"][index], index, a["candidates"], b["candidates"])
                counts["events"] += 1
            counts["cases"] += 1
            counts[group + "Cases"] += 1
        if swift_file.readline() or rust_file.readline():
            mismatch("<extra>", "caseCount", "unexpected trailing cases", "unexpected trailing cases")

    def timing(values):
        ordered = sorted(values)
        return {"calls": len(values), "totalMS": sum(values), "p50MS": ordered[(len(ordered) - 1) // 2],
                "p95MS": ordered[math.ceil(len(ordered) * 0.95) - 1], "maxMS": ordered[-1]}

    return {"passed": counts["mismatches"] == 0 and counts["unexplainedDiagnosticCandidateDifferences"] == 0,
            "behavioralParityPassed": counts["mismatches"] == 0,
            "diagnosticCandidateParityPassed": counts["diagnosticCandidateDifferences"] == 0, "counts": dict(counts),
            "maximumAbsoluteDeltas": dict(sorted(maxima.items())), "firstMismatches": mismatches,
            "maximumDiagnosticCandidateDeltas": dict(candidate_maxima), "diagnosticCandidateDifferences": candidate_differences,
            "timing": {language: {group: timing(values) for group, values in groups.items()} for language, groups in times.items()},
            "tolerances": {"offsetAndProjectionMS": 0.05, "otherNumbers": 1e-5,
                           "statePhaseStageReasonsAndOptionalPresence": "exact"},
            "diagnosticPolicy": "All diagnostic differences are reported. Nonleading alternatives may exchange rank only with scores within 1e-6 and both original offsets/scores retained within normal tolerances. Ranks 2+ may substitute a same-strength duplicate only with complete byte-identical reference PCEN support. The leading candidate, published estimates, scores, margins and behavior have no exemption."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--features", type=Path, default=DEFAULT_FEATURES)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/sonalign-parity")
    parser.add_argument("--sonalign-bin", "--rust-bin", dest="rust_bin", type=Path,
                        default=ROOT / ".build/sonalign/bin/sonalign-replay",
                        help="Released sonalign-replay CLI; defaults to .build/sonalign/bin/sonalign-replay")
    parser.add_argument("--suites", default="synthetic,fixtures,entries,stress,wrong")
    parser.add_argument("--prepare-only", action="store_true", help="Generate inputs and compile/run Swift only")
    parser.add_argument("--compare-only", action="store_true", help="Compare existing traces without rebuilding/running")
    parser.add_argument("--filter", default="", help="Run cases whose ID contains this string")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.features = args.features.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    suites = set(args.suites.split(","))
    if not suites <= {"synthetic", "fixtures", "entries", "stress", "wrong"}:
        parser.error("Unknown suite")
    if not args.prepare_only and not args.compare_only and not args.rust_bin.is_file():
        parser.error(f"Install Sonalign with: cargo install sonalign --version {SONALIGN_VERSION} --locked "
                     "--root .build/sonalign; or provide --sonalign-bin")
    cases_path = args.output / "cases.jsonl"
    swift_path, rust_path = args.output / "swift.jsonl", args.output / "rust.jsonl"
    metadata_path = args.output / "inputs.json"
    if args.compare_only:
        cases = [json.loads(line) for line in cases_path.read_text().splitlines()]
        metadata = json.loads(metadata_path.read_text())
    else:
        cases = [item for item in generate_cases(args.features, args.output, suites) if args.filter in item["id"]]
        if not cases:
            parser.error("No cases selected")
        cases_path.write_text("".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in cases))
        sources = swift_sources()
        evidence_sources = sources + [Path(__file__).resolve()]
        metadata = {"baselineCommit": BASELINE, "currentCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    "expectedSonalignRelease": {"version": SONALIGN_VERSION, "repository": "https://github.com/Pulsefield/sonalign"},
                    "scope": "Shared cached PCEN features; cold matcher/tracker entries; excludes decoding/resampling/feature extraction",
                    "recordingEnergy": "Exports omit energy; fixture frames use -20 dBFS; synthetic energy files test readiness",
                    "timingScope": "Optimized engine.process only; excludes allocation of input windows, decoding, features and index construction",
                    "platform": platform.platform(), "machine": platform.machine(), "suites": sorted(suites),
                    "cases": len(cases), "calls": sum(len(c["calls"]) for c in cases),
                    "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in evidence_sources if p.is_file()},
                    "casesSHA256": hashlib.sha256(cases_path.read_bytes()).hexdigest()}
        if args.rust_bin.is_file():
            metadata["rustReplayBinary"] = str(args.rust_bin.resolve())
            metadata["rustReplayBinarySHA256"] = hashlib.sha256(args.rust_bin.read_bytes()).hexdigest()
            metadata["rustReplayCommand"] = [str(args.rust_bin.resolve()), "--cases", str(cases_path), "--output", str(rust_path)]
        feature_paths = {entry[key] for case in cases for entry in [case["reference"], case["query"]]
                         for key in ["timesPath", "pcenPath", "energyPath"] if key in entry}
        metadata["featureSHA256"] = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in sorted(feature_paths)}
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
        binary = args.output / "swift-sync-replay"
        print(f"Compiling current Swift oracle; {len(cases)} cases, {metadata['calls']} calls", flush=True)
        subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-parse-as-library", *map(str, sources), "-o", str(binary)], check=True)
        subprocess.run([str(binary), "--cases", str(cases_path), "--output", str(swift_path)], check=True)
        if args.prepare_only:
            print(f"Prepared {cases_path}; Swift trace: {swift_path}")
            return
        subprocess.run([str(args.rust_bin.resolve()), "--cases", str(cases_path), "--output", str(rust_path)], check=True)
    result = compare(swift_path, rust_path, cases)
    result["inputs"] = metadata
    result["comparatorSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (args.output / "summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: result[key] for key in ["passed", "behavioralParityPassed", "diagnosticCandidateParityPassed", "counts",
                                                 "maximumAbsoluteDeltas", "firstMismatches", "diagnosticCandidateDifferences", "timing"]}, indent=2))
    sys.exit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
