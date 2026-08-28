#!/usr/bin/env python3
"""Executable fault/state oracle for v966's lazy-underground publication contract."""

from __future__ import annotations

import json
from dataclasses import dataclass


ROUTES = (
    "change-current-map-slot",
    "hud-map-switch",
    "unit-use-elevator",
    "construction-activate",
    "elevator-place-construction-site",
)


@dataclass
class State:
    name: str = "capture"
    committed: bool = False
    capsule_count: int = 0
    generation_count: int = 0
    map_allocated: bool = False
    exposed: bool = False

    def precommit(self, capture: bool = True, writer: bool = True) -> None:
        if not capture or not writer:
            self.name = "literal-eager"
            return
        self.committed = True
        self.name = "suppressed"

    def publish(self, plan: bool = True, objects: bool = True,
                marker_signs: bool = True, final_grid: bool = True) -> None:
        if not self.committed:
            return
        if not all((plan, objects, marker_signs, final_grid)):
            self.name = "blocked"
            return
        self.capsule_count = 2
        self.name = "ready"

    def access(self, route: str, reconstruct: bool = True, binder: bool = True,
               generate: bool = True, callback: bool = True, city: bool = True,
               stretch: bool = True, audit: bool = True) -> None:
        assert route in ROUTES
        if self.name == "complete":
            return
        if self.name != "ready":
            self.exposed = False
            return
        self.name = "generating"
        if reconstruct and binder and generate:
            self.map_allocated = True
            self.generation_count += 1
        complete = all((reconstruct, binder, generate, callback, city, stretch, audit))
        if complete and self.generation_count == 1 and self.capsule_count == 2:
            self.name = "complete"
            self.exposed = True
        else:
            self.name = "blocked"
            self.exposed = False

    def reload(self) -> None:
        if self.name == "generating":
            self.name = "blocked"
            self.exposed = False
        elif self.name == "ready":
            assert not self.map_allocated
        elif self.name == "complete":
            assert self.map_allocated and self.generation_count == 1


@dataclass
class EngineTarget:
    value: str = "original"
    mutate_then_throw_on_replace: bool = False
    restore_failures: int = 0

    def write(self, value: str) -> tuple[bool, bool]:
        if value == "wrapper" and self.mutate_then_throw_on_replace:
            self.value = value
            self.mutate_then_throw_on_replace = False
            return True, False
        if value == "original" and self.restore_failures > 0:
            self.restore_failures -= 1
            return False, False
        self.value = value
        return True, True


@dataclass
class RestoreToken:
    targets: list[EngineTarget]
    expected: str = "original"
    replacement: str = "wrapper"
    restored: bool = False

    def restore(self) -> bool:
        if self.restored:
            return True
        exact = True
        for target in reversed(self.targets):
            if target.value == self.expected:
                continue  # already restored by an earlier partial attempt
            if target.value != self.replacement:
                exact = False
                continue
            target.write(self.expected)
            exact = (target.value == self.expected) and exact
        self.restored = exact
        return exact


@dataclass
class RuntimeRestore:
    construction_values: list[str]
    passage: RestoreToken | None = None
    pending: list[RestoreToken] | None = None
    helper_present: bool = True
    callback_present: bool = True

    def restore(self) -> bool:
        binding_ok = self.passage is None or self.passage.restore()
        if binding_ok:
            self.passage = None
        pending_ok = True
        retained: list[RestoreToken] = []
        for token in self.pending or []:
            if not token.restore():
                pending_ok = False
                retained.append(token)
        self.pending = retained
        construction_ok = True
        for index, value in enumerate(self.construction_values):
            if value == "wrapper":
                self.construction_values[index] = "original"
            elif value != "original":
                construction_ok = False
        return binding_ok and pending_ok and construction_ok

    def reload_config_off(self) -> bool:
        restored = self.restore()
        if restored:
            self.callback_present = False
            self.helper_present = False
        return restored


def ready() -> State:
    state = State()
    state.precommit()
    state.publish()
    return state


def main() -> int:
    checks: dict[str, bool] = {}
    for fault in ("capture", "writer"):
        state = State()
        state.precommit(capture=fault != "capture", writer=fault != "writer")
        checks[f"precommit_{fault}_uses_literal_eager"] = (
            state.name == "literal-eager" and not state.committed
        )

    for fault in ("plan", "objects", "marker_signs", "final_grid"):
        state = State()
        state.precommit()
        kwargs = {name: True for name in ("plan", "objects", "marker_signs", "final_grid")}
        kwargs[fault] = False
        state.publish(**kwargs)
        checks[f"postcommit_{fault}_blocks_without_exposure"] = (
            state.name == "blocked" and state.committed and not state.exposed
        )

    for route in ROUTES:
        state = ready()
        state.access(route)
        state.access(route)
        checks[f"route_{route}_completes_exactly_once"] = (
            state.name == "complete" and state.exposed and state.generation_count == 1
        )

    for fault in ("reconstruct", "binder", "generate", "callback", "city", "stretch", "audit"):
        state = ready()
        kwargs = {name: True for name in (
            "reconstruct", "binder", "generate", "callback", "city", "stretch", "audit"
        )}
        kwargs[fault] = False
        state.access("change-current-map-slot", **kwargs)
        checks[f"first_access_{fault}_failure_never_exposes_partial"] = (
            state.name == "blocked" and not state.exposed
            and (state.map_allocated == (fault not in ("reconstruct", "binder", "generate")))
        )

    persisted_ready = ready()
    persisted_ready.reload()
    checks["ready_save_load_keeps_absent_map_and_recoverable_descriptor"] = (
        persisted_ready.name == "ready" and not persisted_ready.map_allocated
    )
    interrupted = ready()
    interrupted.name = "generating"
    interrupted.map_allocated = True
    interrupted.reload()
    checks["interrupted_save_load_is_sticky_blocked"] = (
        interrupted.name == "blocked" and not interrupted.exposed
    )
    completed = ready()
    completed.access("change-current-map-slot")
    completed.reload()
    checks["completed_save_load_retains_exactly_once_state"] = (
        completed.name == "complete" and completed.generation_count == 1
    )

    hot_reload = RuntimeRestore(
        construction_values=["wrapper", "wrapper"],
        passage=RestoreToken([EngineTarget(value="wrapper")]),
        pending=[],
    )
    hot_reload_ok = hot_reload.reload_config_off()
    checks["config_on_to_off_restores_before_helper_clear"] = (
        hot_reload_ok and hot_reload.construction_values == ["original", "original"]
        and hot_reload.passage is None and not hot_reload.helper_present
        and not hot_reload.callback_present
    )

    partial_targets = [
        EngineTarget(value="wrapper"),
        EngineTarget(value="wrapper", restore_failures=1),
    ]
    partial_runtime = RuntimeRestore(
        construction_values=["original", "original"],
        passage=RestoreToken(partial_targets),
        pending=[],
    )
    first_cleanup = partial_runtime.restore()
    retained_after_partial = partial_runtime.passage is not None
    second_cleanup = partial_runtime.restore()
    checks["partial_passage_cleanup_retains_token_then_retry_succeeds"] = (
        not first_cleanup and retained_after_partial and second_cleanup
        and partial_runtime.passage is None
        and all(target.value == "original" for target in partial_targets)
    )

    mutate_target = EngineTarget(
        value="original", mutate_then_throw_on_replace=True, restore_failures=1,
    )
    changed, acknowledged = mutate_target.write("wrapper")
    mutate_token = RestoreToken([mutate_target])
    first_rollback = mutate_token.restore()
    suppression_state = "eager" if first_rollback else "blocked"
    literal_eager = first_rollback
    pending_runtime = RuntimeRestore(
        construction_values=[], pending=[] if first_rollback else [mutate_token],
    )
    retry_rollback = pending_runtime.restore()
    checks["mutate_then_throw_incomplete_rollback_is_sticky_not_eager"] = (
        changed and not acknowledged and not first_rollback
        and suppression_state == "blocked" and not literal_eager
        and retry_rollback and mutate_target.value == "original"
        and pending_runtime.pending == []
    )

    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v966.lazy-underground-state-oracle.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "routes": list(ROUTES),
        "faults": 16,
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
