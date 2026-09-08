"""Start the scoped Ralph runner detached from the interactive agent's Windows job.

No global Codex configuration changes, no game launch here, no iteration cap.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[2]
WORKSPACE = PROJECT / "_ralph/runs/reoptimize-under-70s"
HARNESS = Path(r"D:\PROJS\SMR\smr-harness")
CODEX = Path(r"C:\Users\fazevedo\AppData\Local\OpenAI\Codex\bin\8e5b6932251c2c1c\codex.exe")


def main():
    if os.name != "nt" or not CODEX.is_file():
        raise RuntimeError("This launcher requires the verified local Windows Codex CLI")
    command = [sys.executable, "-u", str(HARNESS / "loop.py"), "--agent", "codex",
               "--codex-model", "gpt-5.6-sol", "--codex-escalation-model", "gpt-6-astra",
               "--project", str(PROJECT), "--task-name", "reoptimize-under-70s",
               "--pause-seconds", "5"]
    environment = dict(os.environ)
    environment["PATH"] = str(CODEX.parent) + os.pathsep + environment.get("PATH", "")
    # One shared game/debug port: refuse another loop or game before starting work.
    check = subprocess.run([
        "powershell", "-NoProfile", "-Command",
        "@(Get-CimInstance Win32_Process | Where-Object { "
        "$_.Name -eq 'MarsDebug.exe' -or "
        "($_.Name -match '^python(w)?\\.exe$' -and $_.CommandLine -match 'loop\\.py') "
        "} | Select-Object ProcessId,Name,CommandLine) | ConvertTo-Json -Compress"
    ], capture_output=True, text=True, check=True)
    existing = json.loads(check.stdout) if check.stdout.strip() else []
    if existing:
        raise RuntimeError(f"Existing loop/game must be inspected; refusing launch: {existing}")
    subprocess.run(command + ["--dry-run"], cwd=PROJECT, env=environment, check=True,
                   stdout=subprocess.DEVNULL)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    stdout_path = WORKSPACE / ("runner-" + stamp + ".log")
    stderr_path = WORKSPACE / ("runner-" + stamp + ".err.log")
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    flags = (subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
             | subprocess.CREATE_BREAKAWAY_FROM_JOB)
    # Exclusive files and no fallback to a job-bound or visible process.
    with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
        process = subprocess.Popen(command, cwd=PROJECT, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                   startupinfo=startup, creationflags=flags, close_fds=True)
    launch = {"pid": process.pid, "started_utc": datetime.now(timezone.utc).isoformat(),
              "command": command, "stdout": str(stdout_path), "stderr": str(stderr_path),
              "detached": True, "breakaway_from_job": True}
    with (WORKSPACE / ("launch-" + stamp + ".json")).open("x", encoding="utf-8") as stream:
        json.dump(launch, stream, indent=2)
    time.sleep(2)
    if process.poll() is not None:
        raise RuntimeError(f"Runner exited immediately ({process.returncode}); inspect {stderr_path}")
    print(json.dumps(launch, indent=2))


if __name__ == "__main__":
    main()
