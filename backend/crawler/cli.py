"""Command line:

    python -m crawler run [--orchestra ID] [--dry-run] [--limit N] [--no-llm]
    python -m crawler extract-file PATH [--orchestra ID] [--instrument cello]
    python -m crawler check-registry [PATH]

Without SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY the run is a dry run and writes
JSON under backend/crawler/out/. Without ANTHROPIC_API_KEY pages are still fetched
and change-tracked, but nothing is extracted.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from . import __version__
from .config import Settings
from .fetcher import PoliteFetcher
from .llm import ExtractionClient, LLMFatal, make_client
from .mapping import Catalogue
from .pipeline import Pipeline
from .policy import HostPolicy
from .registry import Registry, RegistryError, load_registry
from .store import DryRunWriter, StoreError, SupabaseWriter, Writer

log = logging.getLogger("auditioner.crawler")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m crawler", description="Auditioner audition-feed crawler")
    parser.add_argument("--version", action="version", version=f"auditioner-crawler {__version__}")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="crawl the registry (nightly job)")
    run.add_argument("--orchestra", metavar="ID", help="only this registry id")
    run.add_argument("--limit", type=int, metavar="N", help="stop after N orchestras")
    run.add_argument("--dry-run", action="store_true", help="write JSON files instead of Supabase")
    run.add_argument("--no-llm", action="store_true", help="fetch and detect changes only; call no model")
    run.add_argument("--registry", type=Path, help="registry file (default: content/registry/orchestras.json)")
    run.add_argument("--out", type=Path, help="dry-run output folder (default: backend/crawler/out)")

    extract = sub.add_parser("extract-file", help="extract a list from a local PDF/DOCX/HTML/text file")
    extract.add_argument("path", type=Path)
    extract.add_argument("--orchestra", metavar="ID", help="registry id the list belongs to")
    extract.add_argument("--instrument", help="instrument hint, e.g. cello")
    extract.add_argument("--registry", type=Path)
    extract.add_argument("--out", type=Path)

    check = sub.add_parser("check-registry", help="validate the registry file and list problems")
    check.add_argument("path", nargs="?", type=Path)
    return parser


def _settings(args: argparse.Namespace) -> Settings:
    settings = Settings.from_env()
    overrides: dict[str, Any] = {}
    if getattr(args, "registry", None):
        overrides["registry_path"] = args.registry
    if getattr(args, "out", None):
        overrides["out_dir"] = args.out
    if overrides:
        settings = Settings(**{**settings.__dict__, **overrides})
    return settings


def _writer(settings: Settings, *, dry_run: bool) -> tuple[Writer, bool]:
    if not dry_run and settings.has_supabase:
        return SupabaseWriter(settings.supabase_url or "", settings.supabase_service_role_key or ""), False
    if not dry_run:
        log.warning("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set — dry run, writing JSON to %s", settings.out_dir)
    return DryRunWriter(settings.out_dir), True


def _llm(settings: Settings, *, disabled: bool) -> ExtractionClient | None:
    if disabled:
        return None
    if not settings.anthropic_api_key_present:
        log.warning("ANTHROPIC_API_KEY not set — pages are fetched and compared, nothing is extracted")
        return None
    return ExtractionClient(
        make_client(),
        extraction_model=settings.extraction_model,
        triage_model=settings.triage_model,
        extraction_effort=settings.extraction_effort,
        extraction_max_tokens=settings.extraction_max_tokens,
        triage_max_tokens=settings.triage_max_tokens,
        refusal_fallback=settings.refusal_fallback,
        pdf_block_max_bytes=settings.pdf_block_max_bytes,
        pdf_block_max_pages=settings.pdf_block_max_pages,
        max_source_lines=settings.max_source_lines,
    )


def _registry(settings: Settings) -> Registry:
    registry = load_registry(settings.registry_path)
    for problem in registry.problems:
        log.warning("registry: %s", problem)
    for note in registry.notes:
        log.info("registry: %s", note)
    return registry


def cmd_run(args: argparse.Namespace) -> int:
    settings = _settings(args)
    try:
        registry = _registry(settings)
    except RegistryError as exc:
        log.error("%s", exc)
        return 2
    writer, dry_run = _writer(settings, dry_run=args.dry_run)
    try:
        llm = _llm(settings, disabled=args.no_llm)
    except LLMFatal as exc:
        log.error("%s", exc)
        return 2
    catalogue = Catalogue.load(settings.catalog_dir)
    fetcher = PoliteFetcher(
        policy=HostPolicy(registry.hosts),
        state=writer,
        user_agent=settings.user_agent,
        min_gap_seconds=settings.min_host_gap_seconds,
        max_bytes=settings.max_document_bytes,
        timeout_seconds=settings.request_timeout_seconds,
        max_retry_after_sleep=settings.max_retry_after_sleep_seconds,
    )
    pipeline = Pipeline(settings=settings, registry=registry, fetcher=fetcher, writer=writer, catalogue=catalogue,
                        llm=llm, dry_run=dry_run)
    try:
        report = pipeline.run(orchestra_id=args.orchestra, limit=args.limit)
    finally:
        fetcher.close()
    print(json.dumps(report.to_dict(), indent=2, ensure_ascii=False))
    if report.fatal:
        return 1
    return 0


def cmd_extract_file(args: argparse.Namespace) -> int:
    settings = _settings(args)
    orchestra = None
    if args.orchestra:
        try:
            orchestra = _registry(settings).get(args.orchestra)
        except RegistryError as exc:
            log.error("%s", exc)
            return 2
        if orchestra is None:
            log.error("orchestra '%s' is not in the registry", args.orchestra)
            return 2
    try:
        llm = _llm(settings, disabled=False)
    except LLMFatal as exc:
        log.error("%s", exc)
        return 2
    if llm is None:
        log.error("extract-file needs ANTHROPIC_API_KEY")
        return 2
    writer = DryRunWriter(settings.out_dir)
    fetcher = PoliteFetcher(policy=HostPolicy([]), state=writer, user_agent=settings.user_agent)
    pipeline = Pipeline(settings=settings, registry=Registry(), fetcher=fetcher, writer=writer,
                        catalogue=Catalogue.load(settings.catalog_dir), llm=llm, dry_run=True)
    try:
        records, report = pipeline.extract_file(args.path, orchestra=orchestra, instrument_hint=args.instrument)
    except LLMFatal as exc:
        log.error("%s", exc)
        return 2
    finally:
        fetcher.close()
    print(json.dumps({"report": report.to_dict(), "vacancies": [r.to_dict() for r in records]}, indent=2, ensure_ascii=False))
    return 0 if not report.errors else 1


def cmd_check_registry(args: argparse.Namespace) -> int:
    settings = _settings(args)
    path = args.path or settings.registry_path
    try:
        registry = load_registry(path)
    except RegistryError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2
    print(json.dumps({
        "ok": not registry.problems,
        "orchestras": len(registry.orchestras),
        "withAddress": sum(1 for o in registry.orchestras if o.start_url),
        "hosts": sorted(registry.hosts),
        "problems": registry.problems,
        "notes": registry.notes,
    }, indent=2))
    return 0 if not registry.problems else 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        if args.command == "run":
            return cmd_run(args)
        if args.command == "extract-file":
            return cmd_extract_file(args)
        if args.command == "check-registry":
            return cmd_check_registry(args)
    except StoreError as exc:
        log.error("%s", exc)
        return 1
    parser.print_help()
    return 2
