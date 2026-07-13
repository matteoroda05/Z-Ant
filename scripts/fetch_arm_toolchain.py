#!/usr/bin/env python3
"""Download and install Z-Ant's pinned managed Arm GNU Toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import posixpath
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
MANIFEST_PATH = SCRIPT_DIR / "toolchains" / "arm_gnu_toolchain_15_2_rel1.json"
INSTALL_ROOT = REPO_ROOT / "third_party" / "toolchains"
DOWNLOAD_CHUNK_SIZE = 1024 * 1024


class FetchError(RuntimeError):
    """A user-facing managed-toolchain installation error."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Download and verify Z-Ant's pinned Arm GNU Toolchain 15.2.Rel1 "
            "for the current host."
        ),
        epilog=(
            "Supported hosts: Linux x86-64/AArch64, macOS Apple silicon, and "
            "Windows x86/x86-64. The release is intentionally fixed. "
            "Cortex-M profiles select a multilib from this installation later "
            "during the Z-Ant build."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="download and reinstall 15.2.Rel1 even if a valid copy already exists",
    )
    return parser.parse_args()


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as manifest_file:
            manifest = json.load(manifest_file)
    except FileNotFoundError as error:
        raise FetchError(f"toolchain manifest is missing: {path}") from error
    except json.JSONDecodeError as error:
        raise FetchError(f"toolchain manifest is invalid JSON: {error}") from error

    if not isinstance(manifest, dict):
        raise FetchError("toolchain manifest root must be a JSON object")
    if manifest.get("schema_version") != 1:
        raise FetchError("unsupported toolchain manifest schema")
    if manifest.get("release") != "15.2.Rel1":
        raise FetchError("toolchain manifest must describe the pinned 15.2.Rel1 release")
    if manifest.get("target") != "arm-none-eabi":
        raise FetchError("toolchain manifest must describe the arm-none-eabi target")
    if not isinstance(manifest.get("hosts"), dict):
        raise FetchError("toolchain manifest does not contain a hosts object")
    return manifest


def detect_host() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    machine_aliases = {
        "amd64": "x86_64",
        "x64": "x86_64",
        "i386": "x86",
        "i686": "x86",
        "x86": "x86",
        "arm64": "aarch64",
    }
    machine = machine_aliases.get(machine, machine)

    host_keys = {
        ("linux", "x86_64"): "linux-x86_64",
        ("linux", "aarch64"): "linux-aarch64",
        ("darwin", "aarch64"): "macos-arm64",
        ("windows", "x86_64"): "windows-x86_64",
        ("windows", "x86"): "windows-x86",
    }
    host_key = host_keys.get((system, machine))
    if host_key is None:
        raise FetchError(
            "unsupported host "
            f"{platform.system()} {platform.machine()}; run --help to see supported hosts"
        )
    return host_key


def validate_host_entry(host_key: str, entry: Any) -> dict[str, str]:
    if not isinstance(entry, dict):
        raise FetchError(f"manifest entry for {host_key} must be an object")

    required_fields = (
        "archive",
        "archive_type",
        "url",
        "sha256",
        "install_directory",
        "compiler",
    )
    validated: dict[str, str] = {}
    for field in required_fields:
        value = entry.get(field)
        if not isinstance(value, str) or not value:
            raise FetchError(f"manifest entry for {host_key} has invalid {field}")
        validated[field] = value

    if validated["archive_type"] not in {"tar.xz", "zip"}:
        raise FetchError(
            f"manifest entry for {host_key} uses unsupported archive type "
            f"{validated['archive_type']}"
        )
    if len(validated["sha256"]) != 64 or any(
        character not in "0123456789abcdef" for character in validated["sha256"]
    ):
        raise FetchError(f"manifest entry for {host_key} has an invalid SHA-256 value")
    if Path(validated["archive"]).name != validated["archive"]:
        raise FetchError(f"manifest entry for {host_key} has an unsafe archive name")
    if Path(validated["install_directory"]).name != validated["install_directory"]:
        raise FetchError(f"manifest entry for {host_key} has an unsafe install directory")
    if Path(validated["compiler"]).is_absolute() or ".." in Path(
        validated["compiler"]
    ).parts:
        raise FetchError(f"manifest entry for {host_key} has an unsafe compiler path")
    return validated


def compiler_version(toolchain_dir: Path, compiler_relative_path: str) -> str:
    compiler = toolchain_dir / compiler_relative_path
    if not compiler.is_file():
        raise FetchError(f"toolchain compiler is missing: {compiler}")
    if os.name != "nt" and not os.access(compiler, os.X_OK):
        raise FetchError(f"toolchain compiler is not executable: {compiler}")

    try:
        result = subprocess.run(
            [str(compiler), "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise FetchError(f"could not run {compiler}: {error}") from error

    output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    first_line = output.splitlines()[0] if output else "no version output"
    if result.returncode != 0:
        raise FetchError(
            f"toolchain compiler verification failed with exit code "
            f"{result.returncode}: {first_line}"
        )
    if "15.2" not in output:
        raise FetchError(
            f"toolchain compiler is not the pinned 15.2 release: {first_line}"
        )
    return first_line


def report_download_progress(downloaded: int, total: int | None, final: bool) -> None:
    if total:
        percent = min(100, downloaded * 100 // total)
        message = f"Downloading: {percent:3d}% ({downloaded // (1024 * 1024)} MiB)"
    else:
        message = f"Downloading: {downloaded // (1024 * 1024)} MiB"
    print(f"\r{message}", end="\n" if final else "", flush=True)


def download_archive(url: str, destination: Path, expected_sha256: str) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Z-Ant managed Arm toolchain fetcher"},
    )
    digest = hashlib.sha256()
    downloaded = 0
    last_reported_percent = -1
    last_reported_bytes = 0

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            length_header = response.headers.get("Content-Length")
            total = int(length_header) if length_header and length_header.isdigit() else None
            with destination.open("wb") as archive_file:
                while True:
                    chunk = response.read(DOWNLOAD_CHUNK_SIZE)
                    if not chunk:
                        break
                    archive_file.write(chunk)
                    digest.update(chunk)
                    downloaded += len(chunk)

                    if total:
                        percent = downloaded * 100 // total
                        if percent >= last_reported_percent + 5:
                            report_download_progress(downloaded, total, final=False)
                            last_reported_percent = percent
                    elif downloaded >= last_reported_bytes + 64 * 1024 * 1024:
                        report_download_progress(downloaded, total, final=False)
                        last_reported_bytes = downloaded
    except (OSError, urllib.error.URLError) as error:
        destination.unlink(missing_ok=True)
        raise FetchError(f"failed to download {url}: {error}") from error

    report_download_progress(downloaded, total, final=True)
    actual_sha256 = digest.hexdigest()
    if actual_sha256 != expected_sha256:
        destination.unlink(missing_ok=True)
        raise FetchError(
            "downloaded archive checksum mismatch: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )
    print(f"SHA-256 verified: {actual_sha256}")


def is_safe_archive_path(path: str) -> bool:
    if not path or "\\" in path:
        return False
    pure_path = PurePosixPath(path)
    normalized = posixpath.normpath(path)
    return (
        not pure_path.is_absolute()
        and normalized != ".."
        and not normalized.startswith("../")
    )


def validate_tar_members(members: list[tarfile.TarInfo]) -> None:
    for member in members:
        if not is_safe_archive_path(member.name):
            raise FetchError(f"archive contains an unsafe path: {member.name}")
        if member.isdev() or member.isfifo():
            raise FetchError(f"archive contains an unsupported special file: {member.name}")
        if member.issym() or member.islnk():
            link_name = member.linkname
            if not link_name or PurePosixPath(link_name).is_absolute():
                raise FetchError(f"archive contains an unsafe link: {member.name}")
            if member.issym():
                link_target = posixpath.normpath(
                    posixpath.join(posixpath.dirname(member.name), link_name)
                )
            else:
                link_target = posixpath.normpath(link_name)
            if link_target == ".." or link_target.startswith("../"):
                raise FetchError(f"archive link escapes extraction root: {member.name}")


def extract_tar_xz(archive_path: Path, destination: Path) -> None:
    try:
        with tarfile.open(archive_path, mode="r:xz") as archive:
            members = archive.getmembers()
            validate_tar_members(members)
            if sys.version_info >= (3, 12):
                archive.extractall(destination, members=members, filter="data")
            else:
                archive.extractall(destination, members=members)
    except (OSError, tarfile.TarError) as error:
        raise FetchError(f"could not extract {archive_path.name}: {error}") from error


def extract_zip(archive_path: Path, destination: Path) -> None:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            for member in archive.infolist():
                if not is_safe_archive_path(member.filename):
                    raise FetchError(
                        f"archive contains an unsafe path: {member.filename}"
                    )
                unix_mode = (member.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(unix_mode):
                    raise FetchError(
                        f"ZIP archive contains an unsupported link: {member.filename}"
                    )
            archive.extractall(destination)
    except (OSError, zipfile.BadZipFile) as error:
        raise FetchError(f"could not extract {archive_path.name}: {error}") from error


def extract_archive(archive_path: Path, archive_type: str, destination: Path) -> None:
    destination.mkdir()
    if archive_type == "tar.xz":
        extract_tar_xz(archive_path, destination)
    elif archive_type == "zip":
        extract_zip(archive_path, destination)
    else:
        raise FetchError(f"unsupported archive type: {archive_type}")


def install_staged_toolchain(staged_dir: Path, final_dir: Path) -> None:
    if not final_dir.exists():
        staged_dir.rename(final_dir)
        return

    backup_dir = final_dir.parent / f".{final_dir.name}.backup-{uuid.uuid4().hex}"
    final_dir.rename(backup_dir)
    try:
        staged_dir.rename(final_dir)
    except OSError:
        backup_dir.rename(final_dir)
        raise
    else:
        shutil.rmtree(backup_dir)


def fetch_toolchain(force: bool) -> None:
    manifest = load_manifest(MANIFEST_PATH)
    host_key = detect_host()
    entry = validate_host_entry(host_key, manifest["hosts"].get(host_key))

    final_dir = INSTALL_ROOT / entry["install_directory"]
    print(f"Managed toolchain: Arm GNU Toolchain {manifest['release']}")
    print(f"Host package: {host_key}")
    print(f"Installation: {final_dir}")

    if final_dir.exists() and not force:
        try:
            version = compiler_version(final_dir, entry["compiler"])
        except FetchError as error:
            raise FetchError(
                f"existing managed installation is invalid: {error}. "
                "Run again with --force to replace it."
            ) from error
        print(f"Already installed and valid: {version}")
        return

    INSTALL_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".arm-toolchain-fetch-", dir=INSTALL_ROOT
    ) as temporary_directory:
        work_dir = Path(temporary_directory)
        archive_path = work_dir / entry["archive"]
        extract_dir = work_dir / "extract"

        print(f"Source: {entry['url']}")
        download_archive(entry["url"], archive_path, entry["sha256"])
        print(f"Extracting {entry['archive']}...")
        extract_archive(archive_path, entry["archive_type"], extract_dir)

        staged_dir = extract_dir / entry["install_directory"]
        if not staged_dir.is_dir():
            raise FetchError(
                "archive did not contain the expected top-level directory: "
                f"{entry['install_directory']}"
            )
        staged_version = compiler_version(staged_dir, entry["compiler"])
        print(f"Staged compiler verified: {staged_version}")

        try:
            install_staged_toolchain(staged_dir, final_dir)
        except OSError as error:
            raise FetchError(f"could not install toolchain at {final_dir}: {error}") from error

    installed_version = compiler_version(final_dir, entry["compiler"])
    print(f"Managed toolchain ready: {installed_version}")


def main() -> int:
    args = parse_args()
    try:
        fetch_toolchain(force=args.force)
    except FetchError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
