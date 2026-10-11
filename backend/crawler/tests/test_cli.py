from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from crawler.cli import build_parser, main
from crawler.config import Settings

from .conftest import FIXTURE_REGISTRY

BACKEND = Path(__file__).resolve().parents[2]


def test_parser_accepts_the_documented_commands():
    parser = build_parser()
    run = parser.parse_args(["run", "--orchestra", "x", "--dry-run", "--limit", "3", "--no-llm"])
    assert run.command == "run" and run.orchestra == "x" and run.dry_run and run.limit == 3 and run.no_llm
    extract = parser.parse_args(["extract-file", "list.pdf", "--instrument", "cello"])
    assert extract.command == "extract-file" and extract.path == Path("list.pdf") and extract.instrument == "cello"
    check = parser.parse_args(["check-registry"])
    assert check.command == "check-registry"


def test_check_registry_reports_problems(capsys, tmp_path: Path):
    assert main(["check-registry", str(FIXTURE_REGISTRY)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] and out["orchestras"] == 2 and "www.example-phil.org" in out["hosts"]
    broken = tmp_path / "r.json"
    broken.write_text(json.dumps([{"id": "Bad", "name": "x"}]))
    assert main(["check-registry", str(broken)]) == 1
    assert main(["check-registry", str(tmp_path / "missing.json")]) == 2


def test_module_entry_point_runs_as_a_separate_process():
    result = subprocess.run([sys.executable, "-m", "crawler", "--version"], cwd=BACKEND, capture_output=True, text=True,
                            env={**os.environ, "PYTHONPATH": str(BACKEND)})
    assert result.returncode == 0 and "auditioner-crawler" in result.stdout


def test_settings_come_from_the_environment_and_never_hold_the_key():
    settings = Settings.from_env({
        "ANTHROPIC_API_KEY": "sk-ant-secret", "SUPABASE_URL": "https://abc.supabase.co/", "SUPABASE_SERVICE_ROLE_KEY": "srk",
        "CRAWLER_MIN_HOST_GAP_SECONDS": "2", "CRAWLER_MAX_DOCUMENT_BYTES": "999999999", "CRAWLER_CONCURRENCY": "0",
        "CRAWLER_REFUSAL_FALLBACK": "false", "CRAWLER_EXTRACTION_MODEL": "claude-opus-5-5",
    })
    assert settings.anthropic_api_key_present and "sk-ant" not in json.dumps(settings.__dict__, default=str)
    assert settings.supabase_url == "https://abc.supabase.co" and settings.has_supabase
    assert settings.min_host_gap_seconds == 10.0  # floor
    assert settings.max_document_bytes == 15 * 1024 * 1024  # ceiling
    assert settings.concurrency == 1
    assert settings.refusal_fallback is False
    assert Settings.from_env({}).has_supabase is False and Settings.from_env({}).triage_model == "claude-haiku-5-5"


def test_run_without_supabase_env_is_a_dry_run_that_needs_no_network(tmp_path: Path, capsys, monkeypatch):
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    empty_registry = tmp_path / "registry.json"
    empty_registry.write_text("[]")
    code = main(["run", "--registry", str(empty_registry), "--out", str(tmp_path / "out"), "--no-llm"])
    assert code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["dryRun"] is True and report["llmEnabled"] is False and report["totals"]["orchestras"] == 0
