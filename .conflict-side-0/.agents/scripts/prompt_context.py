"""Shared prompt-context types for agent runtimes."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import Any


class ActorTrustLevel(StrEnum):
    OWNER = "owner"
    COLLABORATOR = "collaborator"
    PUBLIC = "public"
    BOT = "bot"


@dataclass(frozen=True)
class SelectionIndex:
    persona: str
    runner_platform: str
    stats: dict[str, Any]
    sections: list[dict[str, Any]]

    def to_prompt_dict(self) -> dict[str, Any]:
        return {
            "persona": self.persona,
            "runner_platform": self.runner_platform,
            "stats": self.stats,
            "sections": self.sections,
        }


@dataclass(frozen=True)
class UntrustedGitHubPayload:
    source_type: str
    identifier: str
    author_login: str
    trust_level: ActorTrustLevel
    title: str = ""
    body: str = ""
    created_at: str = ""
    url: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_prompt_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["trust_level"] = self.trust_level.value
        return payload


def normalize_trust_level(
    login: str,
    owner_login: str,
    *,
    author_association: str = "",
) -> ActorTrustLevel:
    normalized_login = (login or "").strip().casefold()
    normalized_owner = (owner_login or "").strip().casefold()
    association = (author_association or "").strip().upper()
    if normalized_login.endswith("[bot]") or association == "BOT":
        return ActorTrustLevel.BOT
    if normalized_owner and normalized_login == normalized_owner:
        return ActorTrustLevel.OWNER
    if association in {"OWNER"}:
        return ActorTrustLevel.OWNER
    if association in {"COLLABORATOR", "MEMBER"}:
        return ActorTrustLevel.COLLABORATOR
    return ActorTrustLevel.PUBLIC
