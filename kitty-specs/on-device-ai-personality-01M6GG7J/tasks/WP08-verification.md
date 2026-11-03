---
work_package_id: WP08
title: Verification & PR Notes
dependencies: ['WP04', 'WP05', 'WP06', 'WP07']
requirement_refs:
- NFR-001
- NFR-002
- NFR-003
- NFR-004
- FR-013
planning_base_branch: feat/20-on-device-ai-personality
merge_target_branch: feat/20-on-device-ai-personality
branch_strategy: Planning artifacts for this mission were generated on feat/20-on-device-ai-personality. During /spec-kitty.implement this WP may branch from a dependency-specific base, but completed changes must merge back into feat/20-on-device-ai-personality unless the human explicitly redirects the landing branch.
subtasks:
- T027
- T028
- T029
- T030
phase: Phase 5 - Quality
history: []
authoritative_surface: docs/
execution_mode: code_change
create_intent:
- docs/PERSONALITY_BACKEND_DECISION.md
owned_files:
- docs/ARCHITECTURE.md
- docs/PERSONALITY_BACKEND_DECISION.md
tags: []
task_type: implement
tracker_refs: []
---

# Work Package Prompt: WP08 – Verification & PR Notes

## Objectives & Success Criteria
Prove the budgets and document the decision. Satisfies: NFR-001, NFR-002, NFR-003, NFR-004, FR-013 (see spec.md).

## Subtasks
- **T027**: Run full `xcrun swift test` with zero failures.
- **T028**: Package release and verify idle CPU < 2% and RAM < 70 MB with Settings closed (commands in AGENTS.md section 2.8), feature on, model unloaded.
- **T029**: Assert no network use from the feature (code inspection plus a test that the service has no URLSession dependency); optionally confirm with `nettop`.
- **T030**: Write `docs/PERSONALITY_BACKEND_DECISION.md` (Foundation Models vs MLX vs llama.cpp vs Ollama) and update `docs/ARCHITECTURE.md`; prepare PR with `Closes #20` and `refs #20`.

## Notes & Risks
Follow AGENTS.md invariants (Swift 6, no new dependencies, isolated UserDefaults in tests, Xcode toolchain). Run `xcrun swift test` before finishing.
