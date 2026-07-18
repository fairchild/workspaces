"""Per-run cost telemetry for the contributor runner.

Extracts token usage and cost from a Claude CLI `--output-format stream-json`
transcript. When FACTORY_TELEMETRY_DIR is set in the runner's process env, it
writes a redacted copy of the transcript and appends one cost row per model
invocation for CI to persist to the factory/ops-data branch; when unset (local
runs) it writes nothing. Cost is derived independently from per-model API
pricing because the CLI's reported total_cost_usd can read ~10x high on some
models (anthropics/claude-code#53371); the row keeps both values.
"""

from __future__ import annotations

import json
import os
import re
from collections import namedtuple
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from _helpers import log

# Per-MTok USD rates verified 2026-07-17 from the Anthropic pricing page
# (https://platform.claude.com/docs/en/docs/about-claude/pricing). cache_write
# is the 5-minute-TTL rate (1.25x base input); the stream-json
# cache_creation_input_tokens aggregate does not separate 5m/1h writes and the
# CLI defaults to 5-minute caching. cache_read is the cache-hit rate (0.1x base
# input). Keyed by model-id family substring. Sonnet uses the standard $3/$15
# tier (Sonnet 5's intro $2/$10 through 2026-08-31 derives a lower cost, which
# only widens the reported-vs-derived gap in the safe direction).
Rate = namedtuple("Rate", "input output cache_write cache_read")
MODEL_PRICING: tuple[tuple[str, Rate], ...] = (
    ("opus", Rate(5.0, 25.0, 6.25, 0.50)),
    ("sonnet", Rate(3.0, 15.0, 3.75, 0.30)),
    ("haiku", Rate(1.0, 5.0, 1.25, 0.10)),
    ("fable", Rate(10.0, 50.0, 12.50, 1.00)),
    ("mythos", Rate(10.0, 50.0, 12.50, 1.00)),
)

# Reported and derived cost may legitimately differ (rounding, cache-write TTL
# ambiguity); only a gap beyond this factor in either direction is treated as
# the known upstream inflation bug and resolved in favor of the derived value.
COST_DISAGREEMENT_FACTOR = 2.0

USAGE_KEYS = (
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)

# Literal values of these vars are scrubbed from transcripts before upload
# (the repo is public and artifacts are world-downloadable).
SECRET_ENV_VARS = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "EVIDENCE_UPLOAD_TOKEN",
)

CREDENTIAL_PATTERNS = (
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{22,}"),
    re.compile(r"gh[sour]_[A-Za-z0-9]{36}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{10,}"),
    re.compile(r"bearer [A-Za-z0-9._-]{20,}", re.IGNORECASE),
)

REDACTED = "[REDACTED]"


def _as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _int0(value: Any) -> int:
    return _as_int(value) or 0


def _as_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _usage_field(usage: Mapping[str, Any], *names: str) -> int:
    for name in names:
        if name in usage:
            return _int0(usage.get(name))
    return 0


def _normalize_usage(usage: Mapping[str, Any] | None) -> dict[str, int]:
    usage = usage or {}
    return {
        "input_tokens": _usage_field(usage, "input_tokens", "inputTokens"),
        "output_tokens": _usage_field(usage, "output_tokens", "outputTokens"),
        "cache_creation_input_tokens": _usage_field(
            usage, "cache_creation_input_tokens", "cacheCreationInputTokens"
        ),
        "cache_read_input_tokens": _usage_field(
            usage, "cache_read_input_tokens", "cacheReadInputTokens"
        ),
    }


def _normalize_model_usage(model_usage: Mapping[str, Any] | None) -> dict[str, dict[str, int]]:
    result: dict[str, dict[str, int]] = {}
    for model_id, usage in (model_usage or {}).items():
        if isinstance(usage, Mapping):
            result[str(model_id)] = _normalize_usage(usage)
    return result


def _sum_model_usage(model_usage: Mapping[str, dict[str, int]]) -> dict[str, int]:
    totals = {key: 0 for key in USAGE_KEYS}
    for usage in model_usage.values():
        for key in USAGE_KEYS:
            totals[key] += _int0(usage.get(key))
    return totals


def _match_pricing(model_id: str | None) -> Rate | None:
    if not model_id:
        return None
    lowered = model_id.lower()
    for family, rate in MODEL_PRICING:
        if family in lowered:
            return rate
    return None


def _price_usage(usage: Mapping[str, int], rate: Rate) -> float:
    return (
        _int0(usage.get("input_tokens")) * rate.input
        + _int0(usage.get("output_tokens")) * rate.output
        + _int0(usage.get("cache_creation_input_tokens")) * rate.cache_write
        + _int0(usage.get("cache_read_input_tokens")) * rate.cache_read
    ) / 1_000_000


def parse_result_event(raw_output: str) -> dict[str, Any] | None:
    """Return the stream-json `result` event, or None if the transcript has none."""
    result: dict[str, Any] | None = None
    for line in raw_output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("type") == "result":
            result = event
    return result


def _primary_model(model_usage: Mapping[str, dict[str, int]], raw_output: str) -> str | None:
    if model_usage:
        return max(model_usage.items(), key=lambda item: sum(item[1].values()))[0]
    for line in raw_output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("type") == "assistant":
            model = (event.get("message") or {}).get("model")
            if model:
                return str(model)
    return None


def derive_cost(
    model_usage: Mapping[str, dict[str, int]],
    top_usage: Mapping[str, int],
    primary_model: str | None,
) -> tuple[float, bool]:
    """Price token usage against the API rate table.

    Returns (derived_cost_usd, all_priced). all_priced is False when a model
    with non-zero usage has no known pricing family, so the caller can fall
    back to the reported value rather than trust a partial derivation.
    """
    if model_usage:
        total = 0.0
        all_priced = True
        for model_id, usage in model_usage.items():
            rate = _match_pricing(model_id)
            if rate is None:
                all_priced = False
                continue
            total += _price_usage(usage, rate)
        return total, all_priced
    rate = _match_pricing(primary_model)
    if rate is None:
        has_usage = any(_int0(top_usage.get(key)) for key in USAGE_KEYS)
        return 0.0, not has_usage
    return _price_usage(top_usage, rate), True


def _select_cost(reported: float, derived: float, all_priced: bool) -> tuple[float, str]:
    if not all_priced:
        return reported, "reported_unpriced"
    if _disagrees(reported, derived):
        return derived, "derived"
    return reported, "reported"


def _disagrees(reported: float, derived: float) -> bool:
    if reported <= 0 and derived <= 0:
        return False
    if reported <= 0 or derived <= 0:
        return True
    ratio = reported / derived
    return ratio > COST_DISAGREEMENT_FACTOR or ratio < 1 / COST_DISAGREEMENT_FACTOR


def redact_secrets(text: str, env: Mapping[str, str]) -> str:
    """Scrub known secret env values and credential-shaped patterns from text."""
    for name in SECRET_ENV_VARS:
        value = (env.get(name) or "").strip()
        if len(value) >= 8:
            text = text.replace(value, REDACTED)
    for pattern in CREDENTIAL_PATTERNS:
        text = pattern.sub(REDACTED, text)
    return text


def _run_row_id(env: Mapping[str, str], phase: str) -> str:
    run_id = env.get("GITHUB_RUN_ID") or "local"
    run_attempt = env.get("GITHUB_RUN_ATTEMPT") or "0"
    return f"{run_id}-{run_attempt}-{phase}"


def build_cost_row(raw_output: str, phase: str, env: Mapping[str, str]) -> dict[str, Any]:
    """Fold a stream-json transcript into one cost row (schema 1)."""
    event = parse_result_event(raw_output) or {}
    model_usage = _normalize_model_usage(event.get("modelUsage") or event.get("model_usage"))
    top_usage = _normalize_usage(event.get("usage"))
    primary_model = _primary_model(model_usage, raw_output)
    reported = _as_float(event.get("total_cost_usd"))
    derived, all_priced = derive_cost(model_usage, top_usage, primary_model)
    cost, source = _select_cost(reported, derived, all_priced)
    totals = top_usage if any(top_usage.values()) else _sum_model_usage(model_usage)
    return {
        "schema": 1,
        "id": _run_row_id(env, phase),
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "lane": env.get("FACTORY_TELEMETRY_LANE") or None,
        "workflow": env.get("GITHUB_WORKFLOW") or None,
        "run_id": _as_int(env.get("GITHUB_RUN_ID")),
        "run_attempt": _as_int(env.get("GITHUB_RUN_ATTEMPT")),
        "phase": phase,
        "issue": _as_int(env.get("ISSUE_NUMBER")),
        "pr": _as_int(env.get("PR_NUMBER")),
        "reviewer": env.get("FACTORY_TELEMETRY_REVIEWER") or None,
        "model": primary_model,
        "model_usage": model_usage,
        "input_tokens": totals.get("input_tokens", 0),
        "output_tokens": totals.get("output_tokens", 0),
        "cache_creation_input_tokens": totals.get("cache_creation_input_tokens", 0),
        "cache_read_input_tokens": totals.get("cache_read_input_tokens", 0),
        "cost_usd": round(cost, 6),
        "cost_usd_reported": round(reported, 6),
        "cost_usd_derived": round(derived, 6),
        "cost_source": source,
        "duration_ms": _int0(event.get("duration_ms")),
        "num_turns": _int0(event.get("num_turns")),
        "result_subtype": str(event.get("subtype") or ""),
    }


def _write_transcript(raw_output: str, phase: str, telemetry_dir: Path, env: Mapping[str, str]) -> None:
    transcripts = telemetry_dir / "transcripts"
    transcripts.mkdir(parents=True, exist_ok=True)
    seq = sum(1 for _ in transcripts.glob("*.jsonl")) + 1
    redacted = redact_secrets(raw_output, env)
    (transcripts / f"{seq:04d}-{phase}.jsonl").write_text(redacted, encoding="utf-8")


def _append_cost_row(raw_output: str, phase: str, telemetry_dir: Path, env: Mapping[str, str]) -> None:
    row = build_cost_row(raw_output, phase, env)
    telemetry_dir.mkdir(parents=True, exist_ok=True)
    line = json.dumps(row, ensure_ascii=False)
    with (telemetry_dir / "cost-rows.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def record_run_telemetry(
    raw_output: str,
    *,
    phase: str,
    env: Mapping[str, str] | None = None,
) -> None:
    """Persist a redacted transcript and a cost row when telemetry is enabled.

    Reads FACTORY_TELEMETRY_DIR and context from the runner's own process env
    (not the sanitized model-subprocess env). Never raises: a telemetry failure
    must not fail the contributor run.
    """
    env = os.environ if env is None else env
    telemetry_dir = (env.get("FACTORY_TELEMETRY_DIR") or "").strip()
    if not telemetry_dir:
        return
    try:
        path = Path(telemetry_dir)
        _write_transcript(raw_output, phase, path, env)
        _append_cost_row(raw_output, phase, path, env)
    except Exception as exc:  # telemetry is best-effort
        log(f"telemetry: skipped for phase={phase} ({exc})")
