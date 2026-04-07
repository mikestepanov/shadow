from __future__ import annotations

import json
import re
import shlex
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import DataTable, Footer, Header, Static


def timer_unit_name(unit: str) -> str:
    return unit.removesuffix(".timer")

ROOT = Path(__file__).resolve().parents[2]
TERMINAL_AUTOMATION_SCRIPT = ROOT / "scripts" / "terminal-automation"
OPENCODECTL = ROOT / "scripts" / "opencodectl"
CLI_PREF_FILE = ROOT / "terminal-cli-preference.json"
AUTO_NIXELO_STATE_FILE = ROOT / "auto-nixelo-enabled.json"


INTERVAL_STEPS = ["1m", "2m", "3m", "5m", "10m", "15m", "20m", "30m", "1h"]


@dataclass(frozen=True)
class ManagedItem:
    key: str
    item_type: Literal["timer", "cron"]
    name: str
    status: str
    enabled: str
    target: str
    cron_id: str | None = None
    schedule: str | None = None


def run_command(command: list[str]) -> tuple[int, str]:
    proc = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output.strip()


def get_timer_state(unit: str) -> tuple[str, str, str | None]:
    """Returns (active, enabled, interval)."""
    active_code, active_out = run_command(["systemctl", "--user", "is-active", unit])
    enabled_code, enabled_out = run_command(["systemctl", "--user", "is-enabled", unit])
    active = active_out.splitlines()[0] if active_out else f"exit:{active_code}"
    enabled = enabled_out.splitlines()[0] if enabled_out else f"exit:{enabled_code}"

    # Parse interval from TimersCalendar property
    _, show_out = run_command(["systemctl", "--user", "show", unit, "--property=TimersCalendar"])
    interval = _parse_timer_interval(show_out)
    if interval is None:
        interval = _parse_interval_from_unit_file(unit)
    return active, enabled, interval


ONCALENDAR_TO_HUMAN: dict[str, str] = {
    "*-*-* *:*:00": "every 1m",
    "*-*-* *:00/2:00": "every 2m",
    "*-*-* *:00/3:00": "every 3m",
    "*-*-* *:00/5:00": "every 5m",
    "*-*-* *:00/10:00": "every 10m",
    "*-*-* *:00/15:00": "every 15m",
    "*-*-* *:00/20:00": "every 20m",
    "*-*-* *:00/30:00": "every 30m",
    "*-*-* *:00:00": "every 1h",
}


def _parse_timer_interval(show_out: str) -> str | None:
    # Format: TimersCalendar={ OnCalendar=*-*-* *:*:00 ; next_elapse=... }
    m = re.search(r"OnCalendar=([^;}\s]+(?:\s+[^;}\s]+)*)", show_out)
    if not m:
        return None
    cal = m.group(1).strip()
    return ONCALENDAR_TO_HUMAN.get(cal, cal)


def _parse_interval_from_unit_file(unit: str) -> str | None:
    """Fallback: read OnCalendar from source unit file when systemd can't report it."""
    for base in [
        ROOT / "systemd",
        Path.home() / ".config" / "systemd" / "user",
        Path.home() / ".local" / "share" / "systemd" / "user",
    ]:
        path = base / unit
        if path.exists():
            text = path.read_text()
            m = re.search(r"OnCalendar=(.+)", text)
            if m:
                cal = m.group(1).strip()
                return ONCALENDAR_TO_HUMAN.get(cal, cal)
    return None


def load_cron_map() -> dict[str, tuple[str, str, str | None]]:
    code, output = run_command([str(OPENCODECTL), "cron", "list", "--all", "--json"])
    if code != 0:
        return {}
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return {}

    jobs = payload.get("jobs", []) if isinstance(payload, dict) else []
    statuses: dict[str, tuple[str, str, str | None]] = {}
    for job in jobs:
        if not isinstance(job, dict):
            continue
        name = str(job.get("name", "")).strip()
        cron_id = str(job.get("id", "")).strip()
        if not name or not cron_id:
            continue
        status = str(job.get("status", "unknown")).strip()
        schedule_value = job.get("scheduleText")
        schedule = str(schedule_value) if isinstance(schedule_value, str) else None
        statuses[name] = (cron_id, status, schedule)
    return statuses


def load_items() -> list[ManagedItem]:
    cron_map = load_cron_map()

    timer_units = [
        ("manual-terminal-nixelo.timer", "nixelo"),
        ("manual-terminal-starthub.timer", "starthub"),
        ("agent-terminal-nixelo.timer", "nixelo"),
        ("agent-terminal-starthub.timer", "starthub"),
    ]

    items: list[ManagedItem] = []
    for unit, target in timer_units:
        active, enabled, interval = get_timer_state(unit)
        items.append(
            ManagedItem(
                key=f"timer:{unit}",
                item_type="timer",
                name=timer_unit_name(unit),
                status=active,
                enabled=enabled,
                target=target,
                schedule=interval,
            )
        )

    # --- Synthetic: Auto Nixelo (composite of manual-terminal-nixelo + pr-ci-nixelo) ---
    nixelo_manual_on = any(
        i.status == "active" and i.enabled == "enabled"
        for i in items
        if i.name == "manual-terminal-nixelo"
    )
    nixelo_prci_on = False  # will be set after cron parsing

    cron_targets = {
        "pr-ci-nixelo": "nixelo",
        "pr-ci-starthub": "starthub",
        "Heartbeat": "global",
        "Morning Sub-Agent Report": "global",
        "Nightly Sub-Agent Report": "global",
    }

    for cron_name in ["pr-ci-nixelo", "pr-ci-starthub", "Heartbeat", "Morning Sub-Agent Report", "Nightly Sub-Agent Report"]:
        cron_info = cron_map.get(cron_name)
        cron_id = cron_info[0] if cron_info else None
        status = cron_info[1] if cron_info else "missing"
        schedule = cron_info[2] if cron_info else None
        if cron_name == "pr-ci-nixelo" and status not in ("disabled", "missing"):
            nixelo_prci_on = True

        items.append(
            ManagedItem(
                key=f"cron:{cron_name}",
                item_type="cron",
                name=cron_name,
                status=status,
                enabled="n/a",
                target=cron_targets[cron_name],
                cron_id=cron_id,
                schedule=schedule,
            )
        )

    # Synthetic Auto Nixelo row — ON/OFF follows explicit state file only.
    auto_nixelo_on = _read_auto_nixelo_state()
    phase = "manual" if nixelo_manual_on else ("pr-ci" if nixelo_prci_on else "idle")

    # Derive interval from active phase
    auto_nixelo_schedule: str | None = None
    if nixelo_manual_on:
        auto_nixelo_schedule = next((i.schedule for i in items if i.name == "manual-terminal-nixelo"), None)
    elif nixelo_prci_on:
        auto_nixelo_schedule = next((i.schedule for i in items if i.name == "pr-ci-nixelo"), None)
    else:
        auto_nixelo_schedule = next((i.schedule for i in items if i.name == "manual-terminal-nixelo"), None)

    items.insert(
        0,
        ManagedItem(
            key="synthetic:auto-nixelo",
            item_type="cron",
            name="⚡ Auto Nixelo",
            status="on" if auto_nixelo_on else "off",
            enabled=f"phase:{phase}",
            target="nixelo",
            cron_id=None,
            schedule=auto_nixelo_schedule,
        ),
    )

    return items


def extract_plan_id(output: str) -> str | None:
    match = re.search(r"PLAN\s+([0-9]+-[0-9]+)", output)
    return match.group(1) if match else None


def _write_auto_nixelo_state(enabled: bool) -> None:
    AUTO_NIXELO_STATE_FILE.write_text(json.dumps({"enabled": enabled}) + "\n")


def _read_auto_nixelo_state() -> bool:
    if not AUTO_NIXELO_STATE_FILE.exists():
        return False
    try:
        data = json.loads(AUTO_NIXELO_STATE_FILE.read_text())
        return bool(data.get("enabled", False))
    except Exception:
        return False


def load_cli_preferences() -> dict[str, dict[str, str]]:
    """Load CLI preferences. New format: {session: {manual: cli, pr_ci: cli}}.
    Migrates old flat format {session: cli} on read."""
    if not CLI_PREF_FILE.exists():
        return {}
    try:
        data = json.loads(CLI_PREF_FILE.read_text())
        if not isinstance(data, dict):
            return {}
        # Migrate old flat format -> new nested format
        migrated = False
        result: dict[str, dict[str, str]] = {}
        for k, v in data.items():
            if isinstance(v, str):
                # Old format: "nixelo": "cc" -> "nixelo": {"manual": "cdx", "pr_ci": "cc"}
                # Default manual to cdx, pr_ci to cc (safe defaults)
                result[k] = {"manual": "cdx", "pr_ci": "cc"}
                migrated = True
            elif isinstance(v, dict):
                result[k] = {str(dk): str(dv) for dk, dv in v.items()}
            else:
                continue
        if migrated:
            save_cli_preferences(result)
        return result
    except Exception:
        return {}


def save_cli_preferences(prefs: dict[str, dict[str, str]]) -> None:
    CLI_PREF_FILE.write_text(json.dumps(prefs, indent=2) + "\n")


class AutomationCtlApp(App[None]):
    TITLE = "automationctl"
    SUB_TITLE = "Terminal/Cron control panel"

    BINDINGS = [
        Binding("r", "refresh", "Refresh"),
        Binding("e", "enable_selected", "Enable"),
        Binding("d", "disable_selected", "Disable"),
        Binding("c", "toggle_cli", "Toggle CLI"),
        Binding("=,+", "interval_up", "Interval =", priority=True),
        Binding("-", "interval_down", "Interval-", priority=True),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._items: list[ManagedItem] = []
        self._inflight: set[str] = set()
        self._cli_prefs: dict[str, str] = load_cli_preferences()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal():
            with Vertical(id="left"):
                yield DataTable(id="table")
            with Vertical(id="right"):
                yield Static("No action yet.", id="log")
        yield Static("Select row, press [e]nable / [d]isable. Actions execute immediately.", id="status")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("Item", "State", "Target", "Interval", "CLI")
        table.cursor_type = "row"
        self.action_refresh()
        self.set_interval(2.0, self._auto_refresh)

    def _selected_item(self) -> ManagedItem | None:
        table = self.query_one(DataTable)
        if table.row_count == 0:
            return None
        row_key = table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value
        return next((item for item in self._items if item.key == row_key), None)

    def _state_label(self, item: ManagedItem) -> str:
        if item.key in self._inflight:
            return "PENDING"
        if item.key == "synthetic:auto-nixelo":
            return "ON" if item.status == "on" else "OFF"
        if item.item_type == "timer":
            timer_on = item.status == "active" and item.enabled == "enabled"
            return "ON" if timer_on else "OFF"
        cron_off = item.status in {"disabled", "missing"}
        return "OFF" if cron_off else "ON"

    def _cli_label(self, item: ManagedItem) -> str:
        lane = self._lane_key(item)
        if lane is None:
            return "-"
        mode = self._mode_key(item)
        lane_prefs = self._cli_prefs.get(lane, {})
        if isinstance(lane_prefs, str):
            return lane_prefs  # legacy fallback
        return lane_prefs.get(mode, "cdx")

    def _mode_key(self, item: ManagedItem) -> str:
        """Return 'manual' or 'pr_ci' based on item type."""
        if item.name.startswith("pr-ci-") or item.name == "pr-ci-nixelo" or item.name == "pr-ci-starthub":
            return "pr_ci"
        return "manual"

    def _interval_label(self, item: ManagedItem) -> str:
        if item.schedule:
            return item.schedule
        return "-"

    def _render(self) -> None:
        table = self.query_one(DataTable)
        table.clear()
        for item in self._items:
            if item.key == "synthetic:auto-nixelo":
                phase = item.enabled.removeprefix("phase:")
                table.add_row(item.name, self._state_label(item), item.target, self._interval_label(item), phase, key=item.key)
            else:
                table.add_row(item.name, self._state_label(item), item.target, self._interval_label(item), self._cli_label(item), key=item.key)

    def _render_in_place(self) -> None:
        """Update cell values without clearing/re-adding rows (preserves cursor)."""
        table = self.query_one(DataTable)
        for idx, item in enumerate(self._items):
            try:
                row_key = table.get_row(item.key)  # noqa: check row exists
            except Exception:
                continue
            if item.key == "synthetic:auto-nixelo":
                phase = item.enabled.removeprefix("phase:")
                vals = (item.name, self._state_label(item), item.target, self._interval_label(item), phase)
            else:
                vals = (item.name, self._state_label(item), item.target, self._interval_label(item), self._cli_label(item))
            col_keys = list(table.columns.keys())
            for ci, col_key in enumerate(col_keys):
                table.update_cell(item.key, col_key, vals[ci])

    def _refresh_preserve_cursor(self) -> None:
        """Full data reload but restore cursor position."""
        table = self.query_one(DataTable)
        cursor_row = table.cursor_coordinate.row if table.row_count > 0 else 0
        self._items = load_items()
        self._cli_prefs = load_cli_preferences()
        self._render()
        if table.row_count > 0:
            table.move_cursor(row=min(cursor_row, table.row_count - 1), column=0)

    def _set_log(self, text: str) -> None:
        self.query_one("#log", Static).update(text)

    def _set_status(self, text: str) -> None:
        self.query_one("#status", Static).update(text)

    def _refresh(self, announce: bool) -> None:
        table = self.query_one(DataTable)
        previous_key: str | None = None
        if table.row_count > 0:
            previous_key = table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value

        self._items = load_items()
        self._cli_prefs = load_cli_preferences()
        self._render()

        if previous_key is not None:
            try:
                table.move_cursor(row=table.get_row_index(previous_key), column=0)
            except Exception:
                pass

        if announce:
            self._set_status("Refreshed. Select row, [e]/[d] executes immediately.")

    def action_refresh(self) -> None:
        self._refresh(announce=True)

    def _auto_refresh(self) -> None:
        self._refresh_preserve_cursor()

    def _execute_selected(self, action: str) -> None:
        item = self._selected_item()
        if item is None:
            self._set_status("No row selected.")
            return
        if item.key in self._inflight:
            self._set_status(f"{item.name} already pending.")
            return

        self._inflight.add(item.key)
        self._render_in_place()
        self._set_status(f"Queued {action} for {item.name} (async).")

        threading.Thread(target=self._run_action_async, args=(action, item), daemon=True).start()

    def _run_action_async(self, action: str, item: ManagedItem) -> None:
        out = self._run_action(action, item)
        self.call_from_thread(self._on_action_done, action, item, out)

    def _on_action_done(self, action: str, item: ManagedItem, out: str) -> None:
        self._inflight.discard(item.key)
        self._set_log(f"[{action.upper()}] {item.name}\n\n{out}")
        self._refresh_preserve_cursor()
        self._set_status(f"Done: {action} {item.name}")

    def action_enable_selected(self) -> None:
        self._execute_selected("enable")

    def action_disable_selected(self) -> None:
        self._execute_selected("disable")

    def _adjust_interval(self, direction: int) -> None:
        item = self._selected_item()
        if item is None:
            self._set_status("No row selected.")
            return
        if item.key == "synthetic:auto-nixelo":
            self._set_status("Select the underlying timer/cron to adjust interval.")
            return
        if not item.schedule or not item.schedule.startswith("every "):
            self._set_status(f"Cannot adjust: {item.schedule or 'no interval'}")
            return

        current = item.schedule.removeprefix("every ")
        try:
            idx = INTERVAL_STEPS.index(current)
        except ValueError:
            self._set_status(f"Unknown interval '{current}', can't adjust.")
            return

        new_idx = idx + direction
        if new_idx < 0 or new_idx >= len(INTERVAL_STEPS):
            self._set_status(f"Already at {'minimum' if direction < 0 else 'maximum'} interval.")
            return

        new_val = INTERVAL_STEPS[new_idx]
        self._inflight.add(item.key)
        self._render_in_place()
        self._set_status(f"Changing {item.name} interval: {current} → {new_val}")

        if item.item_type == "cron" and item.cron_id:
            def _do() -> None:
                cmd = [str(OPENCODECTL), "cron", "edit", item.cron_id, "--every", new_val]
                code, output = run_command(cmd)
                marker = "OK" if code == 0 else "FAILED"
                result = f"{marker}: {item.name} interval {current} → {new_val}"
                self.call_from_thread(self._on_interval_done, item, result)
        elif item.item_type == "timer":
            unit = item.name + ".timer"
            def _do() -> None:
                result = self._set_timer_interval(unit, new_val, current)
                self.call_from_thread(self._on_interval_done, item, result)
        else:
            self._inflight.discard(item.key)
            self._set_status("Cannot adjust this item.")
            return

        threading.Thread(target=_do, daemon=True).start()

    HUMAN_TO_ONCALENDAR: dict[str, str] = {
        "1m": "*-*-* *:*:00",
        "2m": "*-*-* *:00/2:00",
        "3m": "*-*-* *:00/3:00",
        "5m": "*-*-* *:00/5:00",
        "10m": "*-*-* *:00/10:00",
        "15m": "*-*-* *:00/15:00",
        "20m": "*-*-* *:00/20:00",
        "30m": "*-*-* *:00/30:00",
        "1h": "*-*-* *:00:00",
    }

    def _set_timer_interval(self, unit: str, new_val: str, old_val: str) -> str:
        oncal = self.HUMAN_TO_ONCALENDAR.get(new_val)
        if not oncal:
            return f"FAILED: no OnCalendar mapping for {new_val}"

        # Update both source and installed unit files
        source = ROOT / "systemd" / unit
        installed = Path.home() / ".config" / "systemd" / "user" / unit
        parts: list[str] = []

        for path in [source, installed]:
            if not path.exists():
                parts.append(f"SKIP: {path} not found")
                continue
            text = path.read_text()
            new_text = re.sub(r"OnCalendar=.*", f"OnCalendar={oncal}", text)
            new_text = re.sub(
                r"(Description=.*every )\S+",
                lambda m: m.group(1) + new_val,
                new_text,
            )
            path.write_text(new_text)
            parts.append(f"Updated {path}")

        # Reload systemd
        run_command(["systemctl", "--user", "daemon-reload"])

        # Restart if active
        active_code, active_out = run_command(["systemctl", "--user", "is-active", unit])
        if active_out.strip() == "active":
            run_command(["systemctl", "--user", "restart", unit])
            parts.append("Restarted active timer")

        return f"OK: {unit} interval {old_val} → {new_val}\n" + "\n".join(parts)

    def _on_interval_done(self, item: ManagedItem, result: str) -> None:
        self._inflight.discard(item.key)
        self._set_log(result)
        self._refresh_preserve_cursor()
        self._set_status(result)

    def action_interval_up(self) -> None:
        self._adjust_interval(1)

    def action_interval_down(self) -> None:
        self._adjust_interval(-1)

    def action_toggle_cli(self) -> None:
        item = self._selected_item()
        if item is None:
            self._set_status("No row selected.")
            return
        lane = self._lane_key(item)
        if lane is None:
            self._set_status("CLI mode applies only to nixelo/starthub lanes.")
            return

        mode = self._mode_key(item)
        if lane not in self._cli_prefs:
            self._cli_prefs[lane] = {"manual": "cdx", "pr_ci": "cc"}
        lane_prefs = self._cli_prefs[lane]
        if isinstance(lane_prefs, str):
            # Migrate inline
            lane_prefs = {"manual": "cdx", "pr_ci": "cc"}
            self._cli_prefs[lane] = lane_prefs

        current = lane_prefs.get(mode, "cdx")
        next_cli = "cc" if current == "cdx" else "cdx"
        lane_prefs[mode] = next_cli
        save_cli_preferences(self._cli_prefs)
        self._render_in_place()
        self._set_status(f"CLI for {lane}.{mode}: {current} -> {next_cli}")
        self._set_log(f"Updated {CLI_PREF_FILE}: {lane}.{mode}={next_cli}")

    def _terminal_plan_execute(self, action: str, scope: str) -> str:
        plan_cmd = [str(TERMINAL_AUTOMATION_SCRIPT), "plan", action, scope]
        code, output = run_command(plan_cmd)
        if code != 0:
            return f"PLAN FAILED\n$ {' '.join(shlex.quote(p) for p in plan_cmd)}\n\n{output}"

        plan_id = extract_plan_id(output)
        if not plan_id:
            return f"PLAN ID MISSING\n{output}"

        exec_cmd = [str(TERMINAL_AUTOMATION_SCRIPT), "execute", plan_id]
        exec_code, exec_out = run_command(exec_cmd)
        marker = "OK" if exec_code == 0 else "FAILED"
        return (
            f"PLAN\n$ {' '.join(shlex.quote(p) for p in plan_cmd)}\n\n{output}\n\n"
            f"EXECUTE ({marker})\n$ {' '.join(shlex.quote(p) for p in exec_cmd)}\n\n{exec_out}"
        )

    def _ensure_timer_installed(self, unit: str) -> str:
        timer_unit = unit if unit.endswith(".timer") else f"{unit}.timer"
        install_cmd = [str(ROOT / "scripts" / "timers-install"), "--install-only", timer_unit_name(timer_unit)]
        code, output = run_command(install_cmd)
        if code != 0:
            return f"FAILED to install missing timer unit\n$ {' '.join(shlex.quote(p) for p in install_cmd)}\n\n{output}"
        return f"Installed canonical timer unit\n$ {' '.join(shlex.quote(p) for p in install_cmd)}\n\n{output}"

    def _set_systemd_timer(self, unit: str, enable: bool) -> str:
        if enable:
            unmask_cmd = ["systemctl", "--user", "unmask", unit]
            unmask_code, unmask_out = run_command(unmask_cmd)
            cmd = ["systemctl", "--user", "enable", "--now", unit]
            enable_code, enable_out = run_command(cmd)
            code = 0 if unmask_code == 0 and enable_code == 0 else 1
            output = (
                f"$ {' '.join(shlex.quote(p) for p in unmask_cmd)}\n\n{unmask_out}\n\n"
                f"$ {' '.join(shlex.quote(p) for p in cmd)}\n\n{enable_out}"
            )
        else:
            install_log = self._ensure_timer_installed(unit)
            stop_cmd = ["systemctl", "--user", "stop", unit]
            stop_code, stop_out = run_command(stop_cmd)
            mask_cmd = ["systemctl", "--user", "mask", unit]
            mask_code, mask_out = run_command(mask_cmd)
            code = 0 if stop_code == 0 and mask_code == 0 else 1
            cmd = mask_cmd
            output = (
                f"{install_log}\n\n$ {' '.join(shlex.quote(p) for p in stop_cmd)}\n\n{stop_out}\n\n"
                f"$ {' '.join(shlex.quote(p) for p in mask_cmd)}\n\n{mask_out}"
            )
        marker = "OK" if code == 0 else "FAILED"
        return f"{marker}\n$ {' '.join(shlex.quote(p) for p in cmd)}\n\n{output}"

    def _set_cron_enabled(self, cron_id: str, enable: bool) -> str:
        action = "enable" if enable else "disable"
        cmd = [str(OPENCODECTL), "cron", action, cron_id]
        code, output = run_command(cmd)
        marker = "OK" if code == 0 else "FAILED"
        return f"{marker}\n$ {' '.join(shlex.quote(p) for p in cmd)}\n\n{output}"

    def _lane_key(self, item: ManagedItem) -> str | None:
        if item.name.endswith("-nixelo") or item.name == "pr-ci-nixelo":
            return "nixelo"
        if item.name.endswith("-starthub") or item.name == "pr-ci-starthub":
            return "starthub"
        return None

    def _is_lane_automation_item(self, item: ManagedItem) -> bool:
        if item.item_type == "timer":
            return item.name.startswith("manual-terminal-") or item.name.startswith("agent-terminal-")
        return item.name in {"pr-ci-nixelo", "pr-ci-starthub"}

    def _is_on(self, item: ManagedItem) -> bool:
        return self._state_label(item) == "ON"

    def _validate_enable_gate(self, item: ManagedItem) -> str | None:
        lane = self._lane_key(item)
        if lane is None or not self._is_lane_automation_item(item):
            return None

        conflicts = [
            other.name
            for other in self._items
            if other.key != item.key
            and self._is_lane_automation_item(other)
            and self._lane_key(other) == lane
            and self._is_on(other)
        ]
        if not conflicts:
            return None
        return (
            f"BLOCKED: {item.name} cannot be enabled while other automation in {lane} is ON.\n"
            f"Turn OFF first: {', '.join(conflicts)}"
        )

    def _run_action(self, action: str, item: ManagedItem) -> str:
        enable = action == "enable"

        # Synthetic Auto Nixelo: controls only the auto-transition kill switch.
        # It must NOT directly toggle manual/pr-ci runtime states.
        if item.key == "synthetic:auto-nixelo":
            _write_auto_nixelo_state(enable)
            return f"Auto Nixelo kill switch set to {'ON' if enable else 'OFF'} (no runtime timers/crons changed)."

        if enable:
            gate_err = self._validate_enable_gate(item)
            if gate_err:
                return gate_err

        if item.item_type == "timer":
            install_log = self._ensure_timer_installed(item.name) if enable else ""
            if item.name.startswith("manual-terminal-"):
                scope = "nixelo" if "nixelo" in item.name else "starthub"
                mapped = "enable-manual" if enable else "disable-manual"
                out = self._terminal_plan_execute(mapped, scope)
                return f"{install_log}\n\n{out}".strip()
            if item.name.startswith("agent-terminal-"):
                out = self._set_systemd_timer(item.name, enable)
                return f"{install_log}\n\n{out}".strip()
            return "Unsupported timer item."

        if item.item_type == "cron":
            if not item.cron_id:
                return f"Cron id not found for {item.name}. Refresh and try again."
            return self._set_cron_enabled(item.cron_id, enable)

        return "Unsupported item type."


if __name__ == "__main__":
    AutomationCtlApp().run()
