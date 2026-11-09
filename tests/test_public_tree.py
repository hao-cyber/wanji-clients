"""Keep the public source boundary intact as the private product evolves."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def public_files():
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    return [Path(p) for p in output.decode().split("\0") if p]


def test_public_tree_excludes_private_product_artifacts():
    blocked_suffixes = {
        ".m4a", ".aac", ".wav", ".mp3", ".mp4", ".log", ".db",
        ".p8", ".p12", ".pem", ".key", ".jks", ".keystore", ".cer",
        ".mobileprovision", ".keychain-db", ".apk", ".aab", ".hap", ".ipa",
    }
    offenders = []
    for path in public_files():
        if (
            path.parts[0] in {"server", "kb"}
            or "audit" in path.parts
            or path.name in {"Secrets.ets", ".env", "local.properties"}
            or path.suffix in blocked_suffixes
            or "HANDOFF" in path.name
        ):
            offenders.append(str(path))
    assert not offenders, f"private artifacts in public tree: {offenders}"


def test_signing_configuration_is_not_bound_to_a_personal_team():
    for name in ("project.yml", "Wanji.xcodeproj/project.pbxproj"):
        text = (ROOT / "app/wanji-ios" / name).read_text()
        assert "DEVELOPMENT_TEAM" not in text
        assert "DevelopmentTeam" not in text


def test_source_package_is_self_contained():
    for path in public_files():
        if path.suffix not in {".swift", ".java", ".ets", ".kts", ".sh", ".yml"}:
            continue
        text = (ROOT / path).read_text()
        assert "/Users/" not in text, path
        assert "/home/dutyai" not in text, path
        assert "server/wanji-api" not in text, path


def test_installer_requires_explicit_target_without_touching_a_device():
    result = subprocess.run(
        ["bash", str(ROOT / "app/android-watch/install_watch.sh")],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    assert "Usage:" in result.stdout
