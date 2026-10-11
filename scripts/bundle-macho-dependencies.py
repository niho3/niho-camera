#!/usr/bin/env python3
"""Bundle recursive non-system Mach-O dependencies beside an executable."""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
from pathlib import Path


SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
SYSTEM_SWIFT_RPATH = "/usr/lib/swift"
EXECUTABLE_FRAMEWORKS_RPATH = "@executable_path/../Frameworks"
LICENSE_FILE = re.compile(
    r"^(licen[cs]e|copying|copyright|notice)([._-].*)?$", re.IGNORECASE
)


def run(*arguments: object) -> str:
    return subprocess.run(
        [str(argument) for argument in arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def load_commands(path: Path) -> list[str]:
    return run("otool", "-l", path).splitlines()


def command_values(path: Path, command: str, key: str) -> list[str]:
    lines = load_commands(path)
    values: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() != f"cmd {command}":
            continue
        for following in lines[index + 1:index + 6]:
            match = re.match(rf"\s*{key} (.*?)(?: \(offset \d+\))?$", following)
            if match:
                values.append(match.group(1))
                break
    return values


def rpaths(path: Path) -> list[str]:
    return command_values(path, "LC_RPATH", "path")


def install_id(path: Path) -> str | None:
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(path: Path) -> list[str]:
    own = install_id(path)
    result: list[str] = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        reference = line.strip().split(" (compatibility version")[0].strip()
        if reference and not reference.endswith(":") and reference != own:
            result.append(reference)
    return result


def is_system(reference: str) -> bool:
    return reference.startswith(SYSTEM_PREFIXES)


def expand_rpath(value: str, referrer: Path, executable: Path) -> Path:
    expanded = value.replace("@loader_path", str(referrer.parent))
    expanded = expanded.replace("@executable_path", str(executable.parent))
    return Path(expanded)


def resolve(reference: str, referrer: Path, executable: Path) -> Path | None:
    if reference.startswith("@loader_path/"):
        return (referrer.parent / reference.removeprefix("@loader_path/")).resolve()
    if reference.startswith("@executable_path/"):
        return (executable.parent / reference.removeprefix("@executable_path/")).resolve()
    if reference.startswith("@rpath/"):
        name = reference.removeprefix("@rpath/")
        for value in rpaths(referrer) + rpaths(executable):
            if value == SYSTEM_SWIFT_RPATH:
                continue
            candidate = expand_rpath(value, referrer, executable) / name
            if candidate.exists():
                return candidate.resolve()
        if name.startswith("libswift"):
            return None
        raise SystemExit(f"{referrer}: cannot resolve {reference}")
    return Path(reference).resolve()


def keg_for(path: Path) -> tuple[str, str, Path] | None:
    parts = path.parts
    if "Cellar" not in parts:
        return None
    index = parts.index("Cellar")
    if len(parts) <= index + 2:
        return None
    return parts[index + 1], parts[index + 2], Path(*parts[:index + 3])


def copy_licenses(
    bundled: dict[str, Path], licenses: Path
) -> None:
    kegs: dict[tuple[str, str, Path], list[str]] = {}
    for name, original in sorted(bundled.items()):
        keg = keg_for(original)
        if keg is None:
            raise SystemExit(
                f"{name} ({original}) is not from a Homebrew keg; "
                "its license must be supplied explicitly"
            )
        kegs.setdefault(keg, []).append(name)

    index_lines = [
        "NIHO camera に同梱した第三者ライブラリ（Homebrew bottle）とライセンス",
        "",
    ]
    for (formula, version, keg_root), names in sorted(kegs.items()):
        candidates = [
            path for path in keg_root.iterdir()
            if path.is_file() and LICENSE_FILE.match(path.name)
        ]
        documentation = keg_root / "share" / "doc"
        if documentation.is_dir():
            candidates += [
                path for path in sorted(documentation.rglob("*"))
                if path.is_file()
                and (LICENSE_FILE.match(path.name) or path.name == "README.ijg")
            ]
        destination = licenses / f"{formula}-{version}"
        destination.mkdir(parents=True, exist_ok=True)
        copied_hashes: set[str] = set()
        copied_names: list[str] = []
        for candidate in candidates:
            digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
            if digest in copied_hashes:
                continue
            target_name = candidate.name
            if (destination / target_name).exists():
                target_name = f"{candidate.parent.name}-{candidate.name}"
            shutil.copy2(candidate, destination / target_name)
            (destination / target_name).chmod(0o644)
            copied_hashes.add(digest)
            copied_names.append(target_name)
        if not copied_names:
            raise SystemExit(f"no license text found in {keg_root}")
        index_lines += [
            f"{formula} {version}",
            "  dylib: " + ", ".join(f"Frameworks/{name}" for name in names),
            "  license: " + ", ".join(
                f"{destination.name}/{name}" for name in sorted(copied_names)
            ),
            "",
        ]
    (licenses / "INDEX.txt").write_text("\n".join(index_lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--frameworks", required=True, type=Path)
    parser.add_argument("--licenses", required=True, type=Path)
    parser.add_argument("--sign", required=True)
    parser.add_argument("--info-plist", type=Path)
    arguments = parser.parse_args()

    executable = arguments.executable.resolve()
    frameworks = arguments.frameworks.resolve()
    licenses = arguments.licenses.resolve()
    frameworks.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)

    bundled: dict[str, Path] = {}
    origin_names: dict[Path, str] = {}
    rewrites: dict[Path, dict[str, str]] = {}
    queue: list[tuple[Path, Path]] = [(executable, executable)]
    while queue:
        target, original = queue.pop(0)
        changes = rewrites.setdefault(target, {})
        for reference in dependencies(original):
            if is_system(reference):
                continue
            resolved = resolve(reference, original, executable)
            if resolved is None:
                continue
            if not resolved.is_file():
                raise SystemExit(f"{original}: dependency does not exist: {resolved}")
            name = origin_names.get(resolved)
            if name is None:
                name = Path(install_id(resolved) or resolved.name).name
                if name in bundled and bundled[name] != resolved:
                    raise SystemExit(
                        f"two different libraries named {name}: "
                        f"{bundled[name]} and {resolved}"
                    )
                bundled[name] = resolved
                origin_names[resolved] = name
                copy = frameworks / name
                shutil.copy2(resolved, copy)
                copy.chmod(0o644)
                queue.append((copy, resolved))
            if reference != f"@rpath/{name}":
                changes[reference] = f"@rpath/{name}"

    for target, changes in rewrites.items():
        tool_arguments: list[str] = []
        for old, new in sorted(changes.items()):
            tool_arguments += ["-change", old, new]
        for value in sorted(set(rpaths(target))):
            if value != SYSTEM_SWIFT_RPATH:
                tool_arguments += ["-delete_rpath", value]
        if target == executable:
            tool_arguments += ["-add_rpath", EXECUTABLE_FRAMEWORKS_RPATH]
        else:
            tool_arguments += ["-id", f"@rpath/{target.name}"]
        if tool_arguments:
            subprocess.run(
                ["install_name_tool", *tool_arguments, str(target)],
                check=True,
                capture_output=True,
            )

    problems: list[str] = []
    for target in [executable] + sorted(frameworks.iterdir()):
        for reference in dependencies(target):
            if is_system(reference) or reference.startswith("@rpath/libswift"):
                continue
            if not reference.startswith("@rpath/"):
                problems.append(f"{target.name} -> {reference}")
                continue
            if not (frameworks / reference.removeprefix("@rpath/")).is_file():
                problems.append(f"{target.name} -> {reference} (missing)")
        allowed = {SYSTEM_SWIFT_RPATH}
        if target == executable:
            allowed.add(EXECUTABLE_FRAMEWORKS_RPATH)
        actual_rpaths = set(rpaths(target))
        if actual_rpaths - allowed:
            problems.append(f"{target.name} rpaths {sorted(actual_rpaths)}")
        if target == executable and EXECUTABLE_FRAMEWORKS_RPATH not in actual_rpaths:
            problems.append(f"{target.name} lacks {EXECUTABLE_FRAMEWORKS_RPATH}")
    if problems:
        raise SystemExit("references outside the bundle remain:\n  " + "\n  ".join(problems))

    copy_licenses(bundled, licenses)
    for library in sorted(frameworks.iterdir()):
        subprocess.run(
            [
                "codesign", "--force", "--sign", arguments.sign,
                "--timestamp=none", str(library),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["codesign", "--verify", "--strict", str(library)],
            check=True,
            capture_output=True,
        )

    if arguments.info_plist:
        # Bottles may require a newer OS than the package's source target.
        # Advertise the highest actual minimum before signing the app.
        with arguments.info_plist.open("rb") as stream:
            info = plistlib.load(stream)
        minimums = [info.get("LSMinimumSystemVersion", "14.0")]
        for binary in [executable] + sorted(frameworks.iterdir()):
            minimums += command_values(binary, "LC_BUILD_VERSION", "minos")
            minimums += command_values(binary, "LC_VERSION_MIN_MACOSX", "version")
        minimum = max(minimums, key=lambda value: tuple(int(part) for part in value.split(".")))
        info["LSMinimumSystemVersion"] = minimum
        with arguments.info_plist.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=False)
        print(f"app minimum macOS: {minimum}")

    print(f"bundled {len(bundled)} dylibs: {', '.join(sorted(bundled))}")


if __name__ == "__main__":
    main()
