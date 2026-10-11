"""Settings for the crawler, read from the environment (never from the repo).

Secrets (ANTHROPIC_API_KEY, SUPABASE_SERVICE_ROLE_KEY) are only ever read from the
environment — on Cloud Run they arrive from Secret Manager. Nothing here logs them.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from . import USER_AGENT

REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_EXTRACTION_MODEL = "claude-opus-5-5"
DEFAULT_TRIAGE_MODEL = "claude-haiku-5-5"


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _as_int(value: str | None, default: int, minimum: int = 0) -> int:
    try:
        parsed = int(str(value).strip()) if value not in (None, "") else default
    except ValueError:
        parsed = default
    return max(minimum, parsed)


def _as_float(value: str | None, default: float, minimum: float = 0.0) -> float:
    try:
        parsed = float(str(value).strip()) if value not in (None, "") else default
    except ValueError:
        parsed = default
    return max(minimum, parsed)


@dataclass(frozen=True)
class Settings:
    registry_path: Path = REPO_ROOT / "content" / "registry" / "orchestras.json"
    catalog_dir: Path = REPO_ROOT / "content" / "catalog"
    out_dir: Path = REPO_ROOT / "backend" / "crawler" / "out"
    user_agent: str = USER_AGENT

    # Politeness (docs/BOT.md)
    min_host_gap_seconds: float = 10.0
    request_timeout_seconds: float = 30.0
    max_document_bytes: int = 15 * 1024 * 1024
    max_retry_after_sleep_seconds: float = 120.0
    max_subpages_per_orchestra: int = 8
    max_documents_per_orchestra: int = 12
    # Most time spent on one site per night. A long robots.txt Crawl-delay is honoured in
    # full; what gives is the number of requests (pipeline._request_budget).
    per_host_time_budget_seconds: float = 1200.0
    concurrency: int = 1

    # Extraction
    extraction_model: str = DEFAULT_EXTRACTION_MODEL
    triage_model: str = DEFAULT_TRIAGE_MODEL
    extraction_effort: str = "high"
    extraction_max_tokens: int = 20000
    triage_max_tokens: int = 2048
    max_source_lines: int = 4000
    pdf_block_max_bytes: int = 10 * 1024 * 1024
    pdf_block_max_pages: int = 100
    refusal_fallback: bool = True
    anthropic_api_key_present: bool = False

    # Storage
    supabase_url: str | None = None
    supabase_service_role_key: str | None = None

    extra: dict[str, str] = field(default_factory=dict)

    @property
    def has_supabase(self) -> bool:
        return bool(self.supabase_url and self.supabase_service_role_key)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        registry = env.get("CRAWLER_REGISTRY") or str(cls.registry_path)
        catalog = env.get("CATALOG_DIR") or str(cls.catalog_dir)
        out = env.get("CRAWLER_OUT_DIR") or str(cls.out_dir)
        supabase_url = (env.get("SUPABASE_URL") or "").strip().rstrip("/") or None
        service_key = (env.get("SUPABASE_SERVICE_ROLE_KEY") or "").strip() or None
        return cls(
            registry_path=Path(registry),
            catalog_dir=Path(catalog),
            out_dir=Path(out),
            min_host_gap_seconds=_as_float(env.get("CRAWLER_MIN_HOST_GAP_SECONDS"), 10.0, minimum=10.0),
            request_timeout_seconds=_as_float(env.get("CRAWLER_TIMEOUT_SECONDS"), 30.0, minimum=5.0),
            max_document_bytes=min(
                _as_int(env.get("CRAWLER_MAX_DOCUMENT_BYTES"), 15 * 1024 * 1024, minimum=1024),
                15 * 1024 * 1024,
            ),
            max_subpages_per_orchestra=_as_int(env.get("CRAWLER_MAX_SUBPAGES"), 8),
            max_documents_per_orchestra=_as_int(env.get("CRAWLER_MAX_DOCUMENTS"), 12),
            per_host_time_budget_seconds=_as_float(env.get("CRAWLER_HOST_TIME_BUDGET_SECONDS"), 1200.0, minimum=0.0),
            concurrency=_as_int(env.get("CRAWLER_CONCURRENCY"), 1, minimum=1),
            extraction_model=env.get("CRAWLER_EXTRACTION_MODEL") or DEFAULT_EXTRACTION_MODEL,
            triage_model=env.get("CRAWLER_TRIAGE_MODEL") or DEFAULT_TRIAGE_MODEL,
            extraction_effort=env.get("CRAWLER_EXTRACTION_EFFORT") or "high",
            max_source_lines=_as_int(env.get("CRAWLER_MAX_SOURCE_LINES"), 4000, minimum=100),
            refusal_fallback=_as_bool(env.get("CRAWLER_REFUSAL_FALLBACK"), True),
            anthropic_api_key_present=bool((env.get("ANTHROPIC_API_KEY") or "").strip()),
            supabase_url=supabase_url,
            supabase_service_role_key=service_key,
        )
