"""Check report filtering and weighted totals without Swift or LLVM."""
import unittest
from pathlib import Path
import tempfile

from coverage import check_coverage, core_files, coverage_binaries, summary


def file(path, covered, count):
    metric = {"covered": covered, "count": count, "percent": covered / count * 100}
    return {"filename": path, "summary": dict.fromkeys(("lines", "functions", "regions"), metric)}


class CoverageTests(unittest.TestCase):
    def test_debug_symbol_directory_is_not_a_test_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "UllagePackageTests.xctest/Contents/MacOS/UllagePackageTests"
            binary.parent.mkdir(parents=True)
            binary.write_text("test executable")
            binary.chmod(0o755)
            binary.with_suffix(".dSYM").mkdir()
            self.assertEqual(coverage_binaries(root), [binary])
            app_binary = root / "UllageAppTests.xctest/Contents/MacOS/UllageAppTests"
            app_binary.parent.mkdir(parents=True)
            app_binary.write_text("app test executable")
            app_binary.chmod(0o755)
            self.assertEqual(coverage_binaries(root), sorted([binary, app_binary]))

    def test_missing_test_executables_fails(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            coverage_binaries(Path(directory))

    def test_excludes_tests_and_app_and_weights_by_executable_lines(self):
        report = {"data": [{"files": [
            file("/repo/Sources/UllageCore/A.swift", 1, 1),
            file("/repo/Sources/UllageCore/Harnesses/B.swift", 7, 9),
            file("/repo/Tests/Tests.swift", 100, 100),
            file("/repo/Sources/UllageApp/App.swift", 0, 100),
        ]}]}
        files = core_files(report)
        self.assertEqual(len(files), 2)
        self.assertIn("| Lines | 8 | 10 | 80.00% |", summary(files))
        self.assertIn("`Harnesses/B.swift`", summary(files))

    def test_missing_core_coverage_fails(self):
        with self.assertRaises(ValueError):
            core_files({"data": [{"files": [file("/repo/Tests/Test.swift", 1, 1)]}]})

    def test_line_coverage_floor(self):
        check_coverage([file("/repo/Sources/UllageCore/A.swift", 85, 100)])
        with self.assertRaises(ValueError):
            check_coverage([file("/repo/Sources/UllageCore/A.swift", 84, 100)])


if __name__ == "__main__":
    unittest.main()
