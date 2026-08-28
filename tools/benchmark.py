#!/usr/bin/env python3
"""Small repeatable Hilbert toolchain benchmark.

This is not a leaderboard.  It measures one checkout on one machine and prints
enough context that two runs can be compared without inventing precision.
"""

from argparse import ArgumentParser
from pathlib import Path
from statistics import median
import json
import os
import platform
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HILBERT = ROOT / "build" / "hilbert"
HILMAKE = ROOT / "build" / "hilmake"
ENV = os.environ.copy()
ENV["PATH"] = str(ROOT / "build") + os.pathsep + ENV.get("PATH", "")


def run(command, *, cwd=ROOT):
    subprocess.run(
        [str(part) for part in command],
        cwd=cwd,
        check=True,
        env=ENV,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def sample(name, rounds, command, *, cwd=ROOT, prepare=None):
    values = []
    for index in range(rounds):
        if prepare is not None:
            prepare(index)
        started = time.perf_counter_ns()
        run(command, cwd=cwd)
        values.append((time.perf_counter_ns() - started) / 1_000_000)
    return {
        "name": name,
        "rounds": rounds,
        "median_ms": round(median(values), 3),
        "min_ms": round(min(values), 3),
        "max_ms": round(max(values), 3),
    }


def main():
    parser = ArgumentParser(description="measure this Hilbert checkout")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    if not HILBERT.is_file() or not HILMAKE.is_file():
        raise SystemExit("build/hilbert and build/hilmake are required; run make first")

    context = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "rounds": args.rounds,
    }
    results = []

    with tempfile.TemporaryDirectory(prefix="hilbert-bench-") as temp:
        work = Path(temp)
        run([HILBERT, "--version"])
        results.append(sample("compiler startup", args.rounds * 2, [HILBERT, "--version"]))

        results.append(sample(
            "small O0 compile+link",
            args.rounds,
            [HILBERT, "build", ROOT / "examples" / "hello.hil", "-O0",
             "--no-incremental", "--cache-dir", work / "small-cache",
             "--quiet", "-o", work / "hello"],
        ))
        hello_size = (work / "hello").stat().st_size

        results.append(sample(
            "multi-module O3 compile+link",
            args.rounds,
            [HILBERT, "build", ROOT / "tests" / "import_values.hil",
             "-I", ROOT / "tests", "-O3", "--no-incremental",
             "--cache-dir", work / "multi-cache", "--quiet",
             "-o", work / "multi"],
        ))

        for level in ("-O0", "-O3"):
            results.append(sample(
                f"{level[1:]} emit assembly",
                args.rounds,
                [HILBERT, "emit-asm", ROOT / "tests" / "optimizer_loop.hil",
                 "-I", ROOT / "tests", level, "--no-incremental",
                 "--cache-dir", work / f"asm-{level[1:]}",
                 "-o", work / f"optimizer-{level[1:]}.s"],
            ))

        project = work / "project"
        shutil.copytree(ROOT / "benchmarks" / "project", project)
        run([HILMAKE, "build", "-q"], cwd=project)

        def discard_link_stamp(_index):
            for stamp in (project / "build" / "cache").glob(".link.v1.*"):
                stamp.unlink()

        results.append(sample(
            "cached objects, forced relink",
            args.rounds,
            [HILMAKE, "build", "-q"],
            cwd=project,
            prepare=discard_link_stamp,
        ))
        results.append(sample(
            "no-op hilmake build", args.rounds, [HILMAKE, "build", "-q"], cwd=project
        ))
        dependency = project / "BenchDep.hil"
        dependency_source = dependency.read_text()

        def change_dependency(index):
            dependency.write_text(dependency_source + f"\n// benchmark edit {index}\n")

        results.append(sample(
            "dependency-triggered hilmake rebuild",
            args.rounds,
            [HILMAKE, "build", "-q"],
            cwd=project,
            prepare=change_dependency,
        ))

        workload = work / "workload"
        run([
            HILBERT, "build", ROOT / "benchmarks" / "Workload.hil", "-O3",
            "--cache-dir", work / "workload-cache", "--quiet", "-o", workload,
        ])
        results.append(sample("native integer workload", args.rounds, [workload]))

        native_sync = work / "native-sync"
        run([
            HILBERT, "build", ROOT / "tests" / "native_sync.hil", "-O3",
            "--cache-dir", work / "thread-cache", "--quiet", "-o", native_sync,
        ])
        results.append(sample("native thread+condition", args.rounds, [native_sync]))

        run(["make", "runtime-test"])
        results.append(sample(
            "GC stress workload", args.rounds, [ROOT / "build" / "runtime-gc-stress"]
        ))

        sizes = {
            "hello_O0_bytes": hello_size,
            "workload_O3_bytes": workload.stat().st_size,
            "native_sync_O3_bytes": native_sync.stat().st_size,
        }

    report = {"context": context, "timings": results, "sizes": sizes}
    if args.json:
        print(json.dumps(report, indent=2))
        return

    print(f"{context['platform']} ({context['machine']})")
    print("timings are wall-clock milliseconds; compare medians, not tiny differences")
    width = max(len(item["name"]) for item in results)
    for item in results:
        print(
            f"{item['name']:<{width}}  median {item['median_ms']:>9.3f}  "
            f"min {item['min_ms']:>9.3f}  max {item['max_ms']:>9.3f}  "
            f"n={item['rounds']}"
        )
    print("sizes")
    for name, size in sizes.items():
        print(f"  {name}: {size}")


if __name__ == "__main__":
    main()
