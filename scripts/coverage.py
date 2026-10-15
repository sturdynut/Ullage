#!/usr/bin/env python3
"""Report LLVM coverage for UllageCore after swift test --enable-code-coverage."""
import json
import os
from pathlib import Path
import shutil
import subprocess

MIN_LINE_COVERAGE = 85.0
ROOT = Path(__file__).resolve().parent.parent


def core_files(report):
    files = [file for data in report["data"] for file in data["files"]
             if "/Sources/UllageCore/" in file["filename"]]
    if not files or not sum(file["summary"]["lines"]["count"] for file in files):
        raise ValueError("No executable UllageCore lines found in the coverage report")
    return files


def summary(files):
    lines = ["## UllageCore coverage", "",
             "Executable core-library code only; excludes tests, CLI, and SwiftUI app.", "",
             "| Metric | Covered | Total | Coverage |", "| --- | ---: | ---: | ---: |"]
    for metric in ("lines", "functions", "regions"):
        covered = sum(file["summary"][metric]["covered"] for file in files)
        count = sum(file["summary"][metric]["count"] for file in files)
        lines.append(f"| {metric.title()} | {covered} | {count} | {covered / count * 100:.2f}% |")
    lines += ["", f"Required line coverage: **{MIN_LINE_COVERAGE:.0f}%**.", "",
              "| File | Line coverage |", "| --- | ---: |"]
    for file in sorted(files, key=lambda file: file["filename"]):
        path = file["filename"].split("/Sources/UllageCore/", 1)[1]
        lines.append(f"| `{path}` | {file['summary']['lines']['percent']:.2f}% |")
    return "\n".join(lines) + "\n"


def check_coverage(files):
    covered = sum(file["summary"]["lines"]["covered"] for file in files)
    count = sum(file["summary"]["lines"]["count"] for file in files)
    if covered / count * 100 < MIN_LINE_COVERAGE:
        raise ValueError(f"Core line coverage is below {MIN_LINE_COVERAGE}%")


def coverage_binaries(bin_dir):
    binaries = sorted(path for path in bin_dir.glob("*.xctest/Contents/MacOS/*")
                      if path.is_file() and os.access(path, os.X_OK))
    if not binaries:
        raise ValueError("No XCTest executables found")
    return binaries


def main():
    os.chdir(ROOT)
    report_path = Path(subprocess.check_output(
        ["swift", "test", "--enable-code-coverage", "--show-codecov-path"], text=True).strip())
    files = core_files(json.loads(report_path.read_text()))
    out = ROOT / "coverage"
    out.mkdir(exist_ok=True)
    shutil.copyfile(report_path, out / "llvm-coverage.json")
    markdown = summary(files)
    (out / "summary.md").write_text(markdown)
    print(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as step_summary:
            step_summary.write(markdown)

    bin_dir = report_path.parent.parent
    command = ["xcrun", "llvm-cov"]
    binaries = coverage_binaries(bin_dir)
    arguments = [str(binaries[0]), f"-instr-profile={report_path.parent / 'default.profdata'}"]
    for binary in binaries[1:]:
        arguments += ["-object", str(binary)]
    sources = [file["filename"] for file in files]
    subprocess.run(command + ["show"] + arguments + ["-format=html", f"-output-dir={out / 'html'}"]
                   + sources, check=True)
    with (out / "lcov.info").open("w") as lcov:
        subprocess.run(command + ["export"] + arguments + ["-format=lcov"] + sources,
                       stdout=lcov, check=True)
    check_coverage(files)


if __name__ == "__main__":
    main()
