#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Offline managed reviewer scenario quiz.

The quiz teaches the ReviewRun vocabulary used by docs/pr-review/architecture.md.
It does not call GitHub, Vercel, Anthropic, or production services.

Usage:
  uv run --script scripts/pr-reviewer-quiz.py
  uv run --script scripts/pr-reviewer-quiz.py --check-answer-key
  uv run --script scripts/pr-reviewer-quiz.py --answers A,B,C
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass


REQUIRED_TOPICS = {
    "pickup",
    "active-coalescing",
    "stale-output",
    "superseded-output",
    "failed-execution",
    "failed-projection",
    "repair-sweep",
    "health-output",
    "safe-retry",
}

VOCABULARY = {
    "ReviewRun",
    "coalesced",
    "current head",
    "superseded",
    "status",
    "projection_status",
    "review intent",
    "repair sweep",
    "WorkSpaces Managed Review",
}


@dataclass(frozen=True)
class Question:
    id: str
    topic: str
    prompt: str
    choices: tuple[str, str, str, str]
    answer: str
    explanation: str


QUESTIONS: tuple[Question, ...] = (
    Question(
        id="pickup-pending-status",
        topic="pickup",
        prompt=(
            "A PR is opened and the `WorkSpaces Managed Review` status appears "
            "as pending on the PR head, but no GitHub review has been posted yet. "
            "What has the system proved so far?"
        ),
        choices=(
            "The broker posted the managed review and GitHub is only slow to render it.",
            "A material trigger created a ReviewRun and the first GitHub-facing "
            "pickup indicator was projected.",
            "The managed agent completed and stored a validated review intent.",
            "The projection ledger has already marked every GitHub effect projected.",
        ),
        answer="B",
        explanation=(
            "Pending `WorkSpaces Managed Review` proves pickup: a material trigger "
            "created a ReviewRun and a pending status. It does not prove completed "
            "execution, review intent, or final projection."
        ),
    ),
    Question(
        id="pickup-missing-run",
        topic="pickup",
        prompt=(
            "An eligible synchronize event happened, but the ReviewRun report "
            "shows the PR key under `missingRuns`. Where should triage start?"
        ),
        choices=(
            "Repair projection, because a completed run must already exist.",
            "Retry execution from the run details page.",
            "Investigate ingress and trigger classification before looking for agent output.",
            "Mark the last successful run superseded.",
        ),
        answer="C",
        explanation=(
            "`missingRuns` means the source-of-truth ReviewRun row is absent for "
            "an eligible trigger. Triage pickup, ingress, and trigger classification "
            "before execution or projection paths."
        ),
    ),
    Question(
        id="active-coalescing-burst",
        topic="active-coalescing",
        prompt=(
            "A same-config run is active when two newer commits are pushed to the "
            "PR. What should happen?"
        ),
        choices=(
            "Start a parallel managed-agent session for every push.",
            "Cancel all managed review activity until a human restarts it.",
            "Record the latest coalesced head/trigger on the active ReviewRun, "
            "then create one follow-up run for the latest state.",
            "Post the active run's output even if it reviewed the first head.",
        ),
        answer="C",
        explanation=(
            "Active coalescing keeps one active ReviewRun, records the latest "
            "coalesced current head, suppresses stale output, and follows up once "
            "for the latest PR state."
        ),
    ),
    Question(
        id="stale-output-after-newer-review",
        topic="stale-output",
        prompt=(
            "A managed-agent session returns valid review intent for an older head, "
            "but a newer managed review already covers the current head. What should "
            "the broker do with the older run?"
        ),
        choices=(
            "Post the older review so every session has a visible GitHub review.",
            "Mark the older run superseded and avoid publishing stale output.",
            "Retry execution until it produces the same findings for the newer head.",
            "Convert the older review intent into a health audit failure.",
        ),
        answer="B",
        explanation=(
            "Stale output should be suppressed. A superseded ReviewRun is terminal "
            "because newer current-head work intentionally replaced it."
        ),
    ),
    Question(
        id="superseded-retry",
        topic="superseded-output",
        prompt=(
            "A details page shows `status=superseded` for a run after newer PR "
            "activity was reviewed. Which action is safe?"
        ),
        choices=(
            "Retry the superseded run so the old transcript is not wasted.",
            "Repair projection for the superseded run.",
            "Do not retry it; inspect the covering current-head run instead.",
            "Change the projection status to pending by hand.",
        ),
        answer="C",
        explanation=(
            "Superseded runs are terminal. Retrying or repairing them can revive "
            "outdated output; use the newer ReviewRun that covers the current head."
        ),
    ),
    Question(
        id="failed-execution-no-intent",
        topic="failed-execution",
        prompt=(
            "A run has `status=failed`, `projection_status=pending`, and no stored "
            "review intent because session output could not be read. What kind of "
            "failure is this?"
        ),
        choices=(
            "Failed execution.",
            "Failed projection.",
            "Successful projection with delayed status update.",
            "Superseded output.",
        ),
        answer="A",
        explanation=(
            "Failed execution happens before validated review intent exists. "
            "`status` owns the agent/session lifecycle; projection repair is not "
            "available until a completed ReviewRun has intent to project."
        ),
    ),
    Question(
        id="failed-projection-has-intent",
        topic="failed-projection",
        prompt=(
            "A run has `status=completed`, validated review intent, and "
            "`projection_status=failed` after GitHub rejected a review post. What "
            "is the correct recovery shape?"
        ),
        choices=(
            "Rerun the managed agent from scratch.",
            "Repair projection using the stored ReviewRun intent.",
            "Mark the run failed execution.",
            "Ignore it because completed status means GitHub was updated.",
        ),
        answer="B",
        explanation=(
            "A completed ReviewRun already has review intent. Failed projection is "
            "recovered by repairing GitHub effects from the stored intent, not by "
            "rerunning execution."
        ),
    ),
    Question(
        id="repair-sweep-purpose",
        topic="repair-sweep",
        prompt=(
            "What is the repair sweep designed to do?"
        ),
        choices=(
            "Re-run all managed agents whose reviews were unflattering.",
            "Apply or re-apply missing GitHub projection for completed ReviewRuns "
            "without rerunning the agent.",
            "Replay raw webhook payloads from production logs.",
            "Delete superseded runs from the database.",
        ),
        answer="B",
        explanation=(
            "A repair sweep is a projection recovery path. It reuses completed "
            "ReviewRun intent and the projection ledger to apply missing or failed "
            "GitHub effects."
        ),
    ),
    Question(
        id="health-run-report-vs-projection-audit",
        topic="health-output",
        prompt=(
            "The GitHub projection audit is green for active PRs. Which statement "
            "is still true?"
        ),
        choices=(
            "It proves ReviewRun ingestion, execution, and broker projection are "
            "all healthy.",
            "It only checks GitHub-facing drift; use the ReviewRun report for "
            "source-of-truth queue health.",
            "It means there are no superseded runs.",
            "It means retrying all failed execution rows is safe.",
        ),
        answer="B",
        explanation=(
            "Health has two lenses. The projection audit checks GitHub statuses and "
            "reviews; the ReviewRun report is the source of truth for pickup, "
            "execution, coalescing, failures, and projection-due rows."
        ),
    ),
    Question(
        id="health-bucket-completed-awaiting-projection",
        topic="health-output",
        prompt=(
            "The ReviewRun report lists a run under `completedAwaitingProjection`. "
            "What does that bucket mean?"
        ),
        choices=(
            "The managed agent has no session id yet.",
            "The run has completed review intent and the broker still needs to "
            "publish or repair GitHub projection.",
            "The run is too old to retry and must be superseded immediately.",
            "The webhook relay rejected the event before creating a row.",
        ),
        answer="B",
        explanation=(
            "`completedAwaitingProjection` is between execution and GitHub effects: "
            "the ReviewRun has completed intent, while projection_status or ledger "
            "work still needs the broker or repair sweep."
        ),
    ),
    Question(
        id="safe-retry-current-head",
        topic="safe-retry",
        prompt=(
            "A failed execution row is retryable and still targets the current PR "
            "head. What is the safe action?"
        ),
        choices=(
            "Retry execution from the run details surface.",
            "Repair projection even though no review intent exists.",
            "Mark the run superseded before trying again.",
            "Run the GitHub projection audit and ignore the ReviewRun failure.",
        ),
        answer="A",
        explanation=(
            "Safe retry requires a retryable execution failure on the current head. "
            "Because no review intent exists, retry execution is the right recovery."
        ),
    ),
    Question(
        id="safe-retry-older-head",
        topic="safe-retry",
        prompt=(
            "A failed execution row is marked retryable, but the PR has since moved "
            "to a newer head. What should an operator avoid?"
        ),
        choices=(
            "Starting or waiting for a current-head ReviewRun.",
            "Checking whether newer activity coalesced into an active run.",
            "Retrying the older-head run as though it still represented current code.",
            "Using ReviewRun health output to understand coverage.",
        ),
        answer="C",
        explanation=(
            "Retryability is not enough. Safe retry also requires current-head "
            "coverage; retrying an older-head ReviewRun can produce stale output."
        ),
    ),
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--answers",
        help=(
            "Comma-separated answers for non-interactive grading. "
            "Example: --answers A,B,C,D"
        ),
    )
    parser.add_argument(
        "--check-answer-key",
        action="store_true",
        help="Validate quiz data and grade the embedded answer key.",
    )
    parser.add_argument(
        "--show-answer-key",
        action="store_true",
        help="Print question ids and correct answers.",
    )
    return parser.parse_args(argv)


def normalized_answers(raw: str) -> list[str]:
    return [part.strip().upper() for part in raw.split(",") if part.strip()]


def answer_key() -> list[str]:
    return [question.answer for question in QUESTIONS]


def validate_questions() -> list[str]:
    errors: list[str] = []
    ids: set[str] = set()
    topics = {question.topic for question in QUESTIONS}

    if len(QUESTIONS) < 10:
        errors.append("quiz must include at least ten questions")

    missing_topics = REQUIRED_TOPICS - topics
    if missing_topics:
        errors.append(f"missing required topics: {', '.join(sorted(missing_topics))}")

    for index, question in enumerate(QUESTIONS, start=1):
        if question.id in ids:
            errors.append(f"duplicate question id: {question.id}")
        ids.add(question.id)

        if len(question.choices) != 4:
            errors.append(f"{question.id}: expected exactly four choices")

        if question.answer not in {"A", "B", "C", "D"}:
            errors.append(f"{question.id}: answer must be A, B, C, or D")
        elif ord(question.answer) - ord("A") >= len(question.choices):
            errors.append(f"{question.id}: answer points past available choices")

        if not question.prompt.strip():
            errors.append(f"{question.id}: prompt is empty")

        if len(question.explanation.split()) < 12:
            errors.append(f"{question.id}: explanation is too short")

        if not any(term in question.explanation for term in VOCABULARY):
            errors.append(f"{question.id}: explanation should use managed reviewer vocabulary")

        if question.id != question.id.strip().lower():
            errors.append(f"question {index}: id must be lowercase and trimmed")

    return errors


def grade(answers: list[str], *, quiet: bool = False) -> int:
    if len(answers) != len(QUESTIONS):
        raise ValueError(f"expected {len(QUESTIONS)} answers, got {len(answers)}")

    correct = 0
    for index, (question, answer) in enumerate(
        zip(QUESTIONS, answers, strict=True),
        start=1,
    ):
        normalized = answer.upper()
        if normalized not in {"A", "B", "C", "D"}:
            raise ValueError(f"answer {index} must be A, B, C, or D")
        is_correct = normalized == question.answer
        correct += int(is_correct)
        if quiet:
            continue
        result = (
            "correct"
            if is_correct
            else f"incorrect; correct answer is {question.answer}"
        )
        print(f"{index}. {question.id}: {result}")
        print(f"   {question.explanation}")

    if not quiet:
        print()
        print(f"Score: {correct}/{len(QUESTIONS)} ({correct / len(QUESTIONS):.0%})")
    return correct


def run_interactive() -> int:
    answers: list[str] = []
    for index, question in enumerate(QUESTIONS, start=1):
        print(f"\n{index}. {question.prompt}")
        for offset, choice in enumerate(question.choices):
            letter = chr(ord("A") + offset)
            print(f"   {letter}. {choice}")
        while True:
            answer = input("Answer [A-D]: ").strip().upper()
            if answer in {"A", "B", "C", "D"}:
                answers.append(answer)
                break
            print("Please enter A, B, C, or D.")

    print()
    grade(answers)
    return 0


def check_answer_key() -> int:
    errors = validate_questions()
    if errors:
        for error in errors:
            print(f"answer-key check failed: {error}", file=sys.stderr)
        return 1

    correct = grade(answer_key(), quiet=True)
    if correct != len(QUESTIONS):
        print("answer-key check failed: embedded key did not score 100%", file=sys.stderr)
        return 1

    print(f"answer-key check passed: {correct}/{len(QUESTIONS)} questions")
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.show_answer_key:
        for question in QUESTIONS:
            print(f"{question.id}: {question.answer}")
        return 0

    if args.check_answer_key:
        return check_answer_key()

    if args.answers:
        answers = normalized_answers(args.answers)
        try:
            correct = grade(answers)
        except ValueError as error:
            print(error, file=sys.stderr)
            return 2
        return 0 if correct == len(QUESTIONS) else 1

    return run_interactive()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
