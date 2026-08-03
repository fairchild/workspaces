# Script Tests

This directory contains executable UV test harnesses for standalone scripts in
`../`. The split is intentional: operational entry points stay in `scripts/`,
while their local stdlib or fixture tests live here.

Each test file should keep a module docstring that states:

- the policy or operational surface it protects
- why the test exists, not only which functions it imports
- whether it is safe to run without network, secrets, UI access, or live GitHub
  mutations

Use this directory for root script tests such as release gates, PR readiness,
security hardening, setup, Codespaces worker launch, and performance
tooling. Keep tests for `.agents/` skill internals next to those
skills unless the test is explicitly validating a root `scripts/` entry point.
