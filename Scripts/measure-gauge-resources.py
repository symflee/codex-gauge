#!/usr/bin/env python3
"""Observe a real Gauge harness and only its direct children (macOS, stdlib only).

Usage (the caller builds the harness first):
  python3 Scripts/measure-gauge-resources.py \
    --harness .build/release/codex-gauge-performance \
    --duration 600 --interval-ms 50 --output /tmp/gauge-real-observed.json

The output must be a NEW .json file in an existing directory; it is created 0600.
The supplied executable is launched without a shell, with --mode real and the
requested duration. A logged-in GUI session and the existing Codex account are
needed. No builds, settings edits, authentication/configuration/database reads,
argv/environment inspection, ps subprocesses or network requests occur here.

Two sanitized progress records go to stdout. The report contains whitelisted
harness resources/counters, direct-child lifecycle observations, basename only,
and the observer's own CPU separately. Raw harness stdout is never saved; stderr
is discarded. Children expected to be App Server are labelled by basename and
the known harness mode; argv is deliberately NOT inspected or claimed verified.

50 ms is the default and maximum requested poll interval (10...50 allowed).
OS scheduling can delay polls; actual gaps are reported. Polling can miss an
entire short process or overlap. Observed starts/exits/max-concurrency supplement
the deterministic single-owner contract and must be compared with harness leases.
No tick history is retained: at most 1024 lifecycle records, 128 direct children,
128 KiB received stdout, and 64 KiB per pending line. Exceeding a limit stops the
measurement. Disappearance alone is not a confirmed exit: BSD zombie status,
ESRCH/ENOENT or a changed PID birth identity supplies the exit observation.

CPU: observer resource.RUSAGE_SELF is independent of harness RUSAGE_SELF and the
harness's reaped-child RUSAGE_CHILDREN. Per-child live CPU is NOT inferred from
lease counts or from an incomplete final sample. All CPU percentages use one core.

SIGINT/SIGTERM or duration+15s timeout requests TERM of the owned Popen harness,
which normally cleans up its children. After 5s, still-live, previously verified
owned children may receive TERM using a kernel audit token (PID version checked
atomically by libproc). There is NO kill-by-name, process-group kill, bare-PID
child kill, SIGKILL, or fallback to signalling a process with uncertain identity.
If task-name/audit-token access is denied, child signalling is skipped and reported.
After 15s of cleanup, remaining processes are reported as unconfirmed; success is
never claimed. SIGKILL of this observer cannot execute cleanup.

Exit: 0 = completed observation, matching lease starts, confirmed cleanup;
2 = interrupted/incomplete observation or mismatch; 64 = arguments/platform/setup.
Resource acceptance thresholds and the empty baseline are not changed here.

ABI references: installed macOS SDK libproc.h and sys/proc_info.h. In particular,
proc_listchildpids returns a PID COUNT, while its buffer size argument is bytes:
https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c
"""

import argparse
import ctypes
import errno
import json
import math
import os
from pathlib import Path
import re
import resource
import selectors
import signal
import stat
import subprocess
import sys
import time


MAX_CHILDREN = 128
MAX_RECORDS = 1024
MAX_STDOUT_BYTES = 128 * 1024
MAX_LINE_BYTES = 64 * 1024
PROC_PIDTBSDINFO = 3
SZOMB = 5
GONE_ERRORS = (errno.ESRCH, errno.ENOENT)


class ObserverFailure(Exception):
    """Only fixed reason codes, never exception text or paths, reach the report."""


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        raise ObserverFailure("invalid_arguments")


class BSDInfo(ctypes.Structure):
    _fields_ = [
        (name, ctypes.c_uint32) for name in (
            "flags", "status", "exit_status", "pid", "ppid", "uid", "gid",
            "ruid", "rgid", "saved_uid", "saved_gid", "reserved"
        )
    ] + [
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
    ] + [
        (name, ctypes.c_uint32) for name in (
            "files", "group", "job_control", "terminal", "terminal_group"
        )
    ] + [
        ("nice", ctypes.c_int32),
        ("start_seconds", ctypes.c_uint64),
        ("start_microseconds", ctypes.c_uint64),
    ]

    @property
    def identity(self):
        return (self.pid, self.start_seconds, self.start_microseconds)


class AuditToken(ctypes.Structure):
    _fields_ = [("values", ctypes.c_uint32 * 8)]


class NativeProcesses:
    def __init__(self):
        if ctypes.sizeof(BSDInfo) != 136:
            raise ObserverFailure("unsupported_libproc_layout")
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.library.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.library.proc_listchildpids.restype = ctypes.c_int
        self.library.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int
        ]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int
        self.pid_buffer = (ctypes.c_int * MAX_CHILDREN)()
        self.path_buffer = ctypes.create_string_buffer(4096)
        self.audit_available = False
        # Optional, public task-name access. Failure only disables child signalling.
        try:
            self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            self.self_task = ctypes.c_uint32.in_dll(self.system, "mach_task_self_").value
            self.system.task_name_for_pid.argtypes = [
                ctypes.c_uint32, ctypes.c_int, ctypes.POINTER(ctypes.c_uint32)
            ]
            self.system.task_name_for_pid.restype = ctypes.c_int
            self.system.task_info.argtypes = [
                ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_uint32)
            ]
            self.system.task_info.restype = ctypes.c_int
            self.system.mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            self.system.mach_port_deallocate.restype = ctypes.c_int
            self.library.proc_signal_with_audittoken.argtypes = [
                ctypes.POINTER(AuditToken), ctypes.c_int
            ]
            self.library.proc_signal_with_audittoken.restype = ctypes.c_int
            self.audit_available = True
        except (AttributeError, ValueError, OSError):
            pass

    def bsd(self, pid):
        info = BSDInfo()
        ctypes.set_errno(0)
        size = self.library.proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
        )
        if size != ctypes.sizeof(info):
            return None, ctypes.get_errno()
        return info, 0

    def children(self, parent_pid):
        ctypes.set_errno(0)
        count = self.library.proc_listchildpids(
            parent_pid, self.pid_buffer, ctypes.sizeof(self.pid_buffer)
        )
        error = ctypes.get_errno()
        if count < 0 or (count == 0 and error):
            return None
        if count >= MAX_CHILDREN:
            raise ObserverFailure("direct_child_buffer_limit")
        return [self.pid_buffer[index] for index in range(count) if self.pid_buffer[index] > 0]

    def basename(self, pid):
        self.path_buffer.value = b""
        size = self.library.proc_pidpath(pid, self.path_buffer, ctypes.sizeof(self.path_buffer))
        if size <= 0:
            return "unavailable"
        # No full path is retained in any record, exception or log.
        basename = self.path_buffer.value.rsplit(b"/", 1)[-1]
        ctypes.memset(self.path_buffer, 0, ctypes.sizeof(self.path_buffer))
        if re.fullmatch(rb"[A-Za-z0-9_.+-]{1,80}", basename) is None:
            return "redacted"
        return basename.decode("ascii")

    def audit_token(self, original):
        if not self.audit_available:
            return None
        port = ctypes.c_uint32()
        if self.system.task_name_for_pid(self.self_task, original.pid, ctypes.byref(port)) != 0:
            return None
        try:
            token = AuditToken()
            count = ctypes.c_uint32(8)
            result = self.system.task_info(port.value, 15, ctypes.byref(token), ctypes.byref(count))
            current, _ = self.bsd(original.pid)
            if (result != 0 or count.value != 8 or token.values[5] != original.pid
                    or current is None or current.identity != original.identity
                    or current.ppid != original.ppid or current.uid != os.getuid()):
                return None
            return token
        finally:
            self.system.mach_port_deallocate(self.self_task, port.value)

    def terminate_owned_child(self, record):
        current, error = self.bsd(record["pid"])
        if current is None:
            return "already_gone" if error in GONE_ERRORS else "identity_unavailable"
        if current.identity != record["identity"]:
            return "original_pid_identity_gone"
        if current.status == SZOMB:
            return "already_exited"
        if current.uid != os.getuid() or record["audit_token"] is None:
            return "identity_safe_signal_unavailable"
        # The kernel compares the audit-token PID version, so PID reuse between
        # this check and signalling cannot target a replacement process.
        result = self.library.proc_signal_with_audittoken(
            ctypes.byref(record["audit_token"]), signal.SIGTERM
        )
        if result == 0:
            return "term_sent"
        if result in GONE_ERRORS:
            return "already_gone"
        return "term_failed"


class ChildObservation:
    def __init__(self, native, harness_pid, started_at):
        self.native = native
        self.harness_pid = harness_pid
        self.started_at = started_at
        root, _ = native.bsd(harness_pid)
        self.root_identity = root.identity if root is not None and root.ppid == os.getpid() else None
        self.records = []
        self.by_identity = {}
        self.unresolved = {}
        self.maximum_simultaneous = 0
        self.current_direct_count = 0
        self.polls = 0
        self.read_errors = 0
        self.identity_races = 0
        self.previous_poll = None
        self.maximum_gap = 0.0
        self.gap_total = 0.0

    def sample(self):
        now = time.monotonic()
        elapsed = now - self.started_at
        if self.previous_poll is not None:
            gap = now - self.previous_poll
            self.maximum_gap = max(self.maximum_gap, gap)
            self.gap_total += gap
        self.previous_poll = now
        self.polls += 1
        root, error = self.native.bsd(self.harness_pid)
        if self.root_identity is None and root is not None and root.ppid == os.getpid():
            self.root_identity = root.identity
        if root is not None and root.identity == self.root_identity:
            pids = self.native.children(self.harness_pid)
            if pids is None:
                self.read_errors += 1
                return
        elif root is None and error not in GONE_ERRORS:
            self.read_errors += 1
            return
        else:
            pids = []
        seen = set()
        running = 0
        for pid in pids:
            info, error = self.native.bsd(pid)
            if info is None:
                if error not in GONE_ERRORS:
                    self.read_errors += 1
                continue
            if info.ppid != self.harness_pid or info.uid != os.getuid():
                self.identity_races += 1
                continue
            identity = info.identity
            seen.add(identity)
            record = self.by_identity.get(identity)
            if record is None:
                if len(self.records) >= MAX_RECORDS:
                    raise ObserverFailure("lifecycle_record_limit")
                basename = self.native.basename(pid)
                # Confirm metadata acquisition did not cross a PID reuse.
                verified, _ = self.native.bsd(pid)
                if verified is not None and verified.identity != identity:
                    basename = "unavailable"
                    self.identity_races += 1
                record = {
                    "ordinal": len(self.records) + 1, "pid": pid, "identity": identity,
                    "audit_token": self.native.audit_token(info),
                    "executable_basename": basename,
                    "classification": "codex_app_server_expected_argv_not_inspected"
                    if basename == "codex" else "unclassified_direct_child",
                    "first_observed_seconds": elapsed, "last_observed_seconds": elapsed,
                    "exit_observed_seconds": None, "departure_observed_seconds": None,
                    "exit_evidence": None, "term_result": None,
                }
                self.records.append(record)
                self.by_identity[identity] = record
                self.unresolved[identity] = record
            record["last_observed_seconds"] = elapsed
            if info.status == SZOMB:
                self.mark_exit(record, elapsed, "bsd_zombie")
            else:
                running += 1
        self.current_direct_count = running
        self.maximum_simultaneous = max(self.maximum_simultaneous, running)
        # Recheck only previously owned unresolved identities, never unrelated PIDs.
        for identity, record in list(self.unresolved.items()):
            if identity in seen:
                continue
            info, error = self.native.bsd(record["pid"])
            if info is None and error in GONE_ERRORS:
                self.mark_exit(record, elapsed, "pid_absent")
            elif info is not None and info.identity != identity:
                self.mark_exit(record, elapsed, "pid_reused_original_exited")
            elif info is not None and info.status == SZOMB:
                self.mark_exit(record, elapsed, "bsd_zombie")
            elif info is not None and info.ppid != self.harness_pid:
                if record["departure_observed_seconds"] is None:
                    record["departure_observed_seconds"] = elapsed
            else:
                self.read_errors += 1

    def mark_exit(self, record, elapsed, evidence):
        if record["exit_observed_seconds"] is None:
            record["exit_observed_seconds"] = elapsed
            record["exit_evidence"] = evidence
        self.unresolved.pop(record["identity"], None)
        record["audit_token"] = None

    def terminate_remaining(self):
        for record in list(self.unresolved.values()):
            if record["term_result"] is None:
                record["term_result"] = self.native.terminate_owned_child(record)

    def report(self):
        allowed = (
            "ordinal", "pid", "executable_basename", "classification",
            "first_observed_seconds", "last_observed_seconds", "exit_observed_seconds",
            "departure_observed_seconds", "exit_evidence", "term_result"
        )
        times = sorted(record["first_observed_seconds"] for record in self.records)
        intervals = [later - earlier for earlier, later in zip(times, times[1:])]
        return {
            "scope": "launched_harness_direct_children_only",
            "identity": "pid_plus_kernel_birth_time_no_argv_inspection",
            "observed_starts": len(self.records),
            "observed_exits": sum(record["exit_observed_seconds"] is not None for record in self.records),
            "maximum_simultaneous_observed_direct_children": self.maximum_simultaneous,
            "unconfirmed_owned_processes": len(self.unresolved),
            "minimum_observed_start_interval_seconds": min(intervals) if intervals else None,
            "maximum_observed_start_interval_seconds": max(intervals) if intervals else None,
            "polls": self.polls, "native_read_errors": self.read_errors,
            "identity_races": self.identity_races,
            "maximum_actual_poll_gap_seconds": self.maximum_gap,
            "mean_actual_poll_gap_seconds": self.gap_total / max(1, self.polls - 1),
            "records": [{key: record[key] for key in allowed} for record in self.records],
        }


RESOURCE_FIELDS = (
    "appUserCPUSeconds", "appSystemCPUSeconds", "appResidentBytes", "appPeakResidentBytes",
    "terminatedOwnedChildrenUserCPUSeconds", "terminatedOwnedChildrenSystemCPUSeconds"
)
DELTA_FIELDS = (
    "elapsedSeconds", "appCPUSeconds", "appAverageCPUPercentOfOneCore",
    "terminatedOwnedChildrenCPUSeconds", "terminatedOwnedChildrenAverageCPUPercentOfOneCore"
)
SESSION_FIELDS = (
    "created", "startAttempts", "successfulStarts", "reads", "successfulReads", "failedReads",
    "confirmedStops", "unconfirmedStops", "activeLeases", "maximumActiveLeases",
    "activeReads", "maximumActiveReads", "minimumReadStartIntervalSeconds",
    "maximumReadStartIntervalSeconds"
)


def numeric_fields(value, allowed):
    if not isinstance(value, dict):
        return {}
    return {
        key: number for key in allowed if key in value
        for number in [value[key]]
        if type(number) in (int, float) and 0 <= number <= 1e20 and math.isfinite(number)
    }


class HarnessOutput:
    def __init__(self):
        self.pending = bytearray()
        self.received_bytes = 0
        self.invalid_records = 0
        self.initial = None
        self.final = None

    def consume(self, chunk):
        self.received_bytes += len(chunk)
        if self.received_bytes > MAX_STDOUT_BYTES:
            raise ObserverFailure("harness_output_limit")
        self.pending.extend(chunk)
        while b"\n" in self.pending:
            line, _, remainder = self.pending.partition(b"\n")
            self.pending = bytearray(remainder)
            if len(line) > MAX_LINE_BYTES:
                raise ObserverFailure("harness_line_limit")
            self.parse_line(line)
        if len(self.pending) > MAX_LINE_BYTES:
            raise ObserverFailure("harness_line_limit")

    def parse_line(self, line):
        try:
            value = json.loads(line)
        except (ValueError, UnicodeError, RecursionError):
            self.invalid_records += 1
            return
        if not isinstance(value, dict) or not isinstance(value.get("metadata"), dict):
            self.invalid_records += 1
            return
        if value["metadata"].get("mode") != "real":
            self.invalid_records += 1
            return
        if value.get("event") == "initial" and self.initial is None:
            self.initial = {"resources": numeric_fields(value.get("resources"), RESOURCE_FIELDS)}
        elif value.get("event") == "final" and self.final is None:
            self.final = {
                "scenarioCompleted": value.get("scenarioCompleted") is True,
                "cleanupConfirmed": value.get("cleanupConfirmed") is True,
                "measurement": numeric_fields(value.get("measurement"), DELTA_FIELDS),
                "measurementIncludingCleanup": numeric_fields(value.get("measurementIncludingCleanup"), DELTA_FIELDS),
                "resourcesBeforeCleanup": numeric_fields(value.get("resourcesBeforeCleanup"), RESOURCE_FIELDS),
                "resourcesAfterCleanup": numeric_fields(value.get("resourcesAfterCleanup"), RESOURCE_FIELDS),
                "sessionsBeforeCleanup": numeric_fields(value.get("sessionsBeforeCleanup"), SESSION_FIELDS),
                "sessionsAfterCleanup": numeric_fields(value.get("sessionsAfterCleanup"), SESSION_FIELDS),
            }
        else:
            self.invalid_records += 1


def parse_options(arguments):
    parser = SafeParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--harness", required=True, metavar="BINARY")
    parser.add_argument("--output", required=True, metavar="NEW_JSON")
    parser.add_argument("--duration", type=int, default=600, metavar="SECONDS")
    parser.add_argument("--interval-ms", type=int, default=50, metavar="10_TO_50")
    options = parser.parse_args(arguments)
    if not 1 <= options.duration <= 86_400 or not 10 <= options.interval_ms <= 50:
        raise ObserverFailure("invalid_arguments")
    binary = Path(options.harness).resolve(strict=True)
    if not stat.S_ISREG(binary.stat().st_mode) or not os.access(binary, os.X_OK):
        raise ObserverFailure("invalid_harness_executable")
    output = Path(options.output).absolute()
    if output.suffix != ".json" or not output.parent.is_dir():
        raise ObserverFailure("invalid_output")
    options.harness = str(binary)
    options.output = str(output)
    return options


def emit_progress(event, **values):
    print(json.dumps({"event": event, **values}, allow_nan=False, sort_keys=True), flush=True)


def run_observation(options, native):
    started_at = time.monotonic()
    cpu_before = resource.getrusage(resource.RUSAGE_SELF)
    harness = subprocess.Popen(
        [options.harness, "--mode", "real", "--duration", str(options.duration)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        bufsize=0, close_fds=True, start_new_session=True
    )
    observation = None
    try:
        observation = ChildObservation(native, harness.pid, started_at)
        return observe_harness(options, native, harness, started_at, cpu_before, observation)
    except (Exception, KeyboardInterrupt):
        # Includes failures during selector/handler setup, before the main loop's
        # own finally block exists. Do not leave a newly launched harness running.
        emergency_cleanup(native, harness, observation)
        raise
    finally:
        harness.stdout.close()


def emergency_cleanup(native, harness, observation=None):
    deadline = time.monotonic() + 15
    if observation is None:
        observation = ChildObservation(native, harness.pid, time.monotonic())
    if harness.poll() is None:
        try:
            harness.terminate()
        except ProcessLookupError:
            pass
    while time.monotonic() < deadline:
        try:
            observation.sample()
            observation.terminate_remaining()
        except (ObserverFailure, OSError):
            pass
        if harness.poll() is not None and not observation.unresolved:
            return
        time.sleep(0.05)


def observe_harness(options, native, harness, started_at, cpu_before, observation):
    output = HarnessOutput()
    selector = selectors.DefaultSelector()
    os.set_blocking(harness.stdout.fileno(), False)
    selector.register(harness.stdout, selectors.EVENT_READ)
    cancelled = False
    reason = "completed"
    cleanup_started = None
    previous_handlers = {}

    def request_cancel(number, frame):
        nonlocal cancelled
        cancelled = True

    for number in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[number] = signal.signal(number, request_cancel)
    emit_progress("observer_started", harness_pid=harness.pid, mode="real", interval_ms=options.interval_ms)
    next_poll = time.monotonic()
    try:
        while True:
            now = time.monotonic()
            if cancelled and cleanup_started is None:
                reason = "interrupted"
                cleanup_started = now
            if now - started_at >= options.duration + 15 and cleanup_started is None:
                reason = "harness_timeout"
                cleanup_started = now
            if cleanup_started is not None:
                # Popen still owns an unreaped child PID, preventing PID reuse while
                # signalling. No other thread or SIGCHLD handler reaps this child.
                if harness.poll() is None and now - cleanup_started < options.interval_ms / 1000:
                    harness.terminate()
                if now - cleanup_started >= 5:
                    observation.terminate_remaining()
                if now - cleanup_started >= 15:
                    break
            if now >= next_poll:
                try:
                    observation.sample()
                except ObserverFailure as failure:
                    if cleanup_started is None:
                        reason = str(failure)
                        cleanup_started = time.monotonic()
                        if harness.poll() is None:
                            harness.terminate()
                # The requested period includes sampling work, rather than adding
                # 50 ms of sleep after every native query. No catch-up backlog.
                next_poll = now + options.interval_ms / 1000
            return_code = harness.poll()
            if return_code is not None and not observation.unresolved and not selector.get_map():
                break
            if return_code is not None and cleanup_started is None and observation.unresolved:
                reason = "owned_children_outlived_harness"
                cleanup_started = time.monotonic()
            timeout = max(0, next_poll - time.monotonic())
            for key, _ in selector.select(timeout):
                try:
                    chunk = os.read(key.fd, 8192)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                try:
                    output.consume(chunk)
                except ObserverFailure as failure:
                    if cleanup_started is None:
                        reason = str(failure)
                        cleanup_started = time.monotonic()
                        if harness.poll() is None:
                            harness.terminate()
                    # Stop retaining output after a limit, but drain the pipe so the
                    # child cannot deadlock while attempting normal termination.
                    output.pending.clear()
        if output.pending:
            output.parse_line(bytes(output.pending))
        try:
            observation.sample()
        except ObserverFailure as failure:
            reason = str(failure)
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
        selector.close()
        # The caller owns emergency cleanup if any setup/loop/finalization fails.

    elapsed = time.monotonic() - started_at
    cpu_after = resource.getrusage(resource.RUSAGE_SELF)
    user_cpu = cpu_after.ru_utime - cpu_before.ru_utime
    system_cpu = cpu_after.ru_stime - cpu_before.ru_stime
    final = output.final or {}
    lease_starts = final.get("sessionsAfterCleanup", {}).get("startAttempts")
    starts_match = lease_starts == len(observation.records) if lease_starts is not None else None
    if harness.poll() is not None and harness.returncode != 0 and reason == "completed":
        reason = "harness_failed"
    cleanup_confirmed = (
        harness.poll() is not None and not observation.unresolved
        and final.get("cleanupConfirmed") is True
    )
    complete = (
        reason == "completed" and harness.returncode == 0 and cleanup_confirmed
        and final.get("scenarioCompleted") is True and starts_match is True
        and observation.root_identity is not None and observation.read_errors == 0
        and observation.identity_races == 0 and output.invalid_records == 0
    )
    report = {
        "schema_version": 1, "mode": "real", "requested_duration_seconds": options.duration,
        "requested_poll_interval_ms": options.interval_ms, "elapsed_seconds": elapsed,
        "harness_pid": harness.pid, "harness_exit_code": harness.returncode,
        "completion_reason": reason, "observation_completed": complete,
        "cleanup_confirmed": cleanup_confirmed,
        "limits": {"lifecycle_records": MAX_RECORDS, "direct_children": MAX_CHILDREN,
                   "stdout_bytes": MAX_STDOUT_BYTES, "pending_line_bytes": MAX_LINE_BYTES},
        "limitations": [
            "polling_can_miss_short_processes_and_overlap",
            "actual_poll_gaps_can_exceed_requested_interval",
            "direct_child_enumeration_is_not_an_atomic_process_snapshot",
            "observed_exit_time_is_detection_time_not_exact_exit_time",
            "argv_not_inspected_codex_basename_is_not_app_server_argument_verification",
            "child_cpu_is_harness_reported_reaped_owned_children_not_live_per_pid_cpu",
            "observer_cpu_and_wakeups_are_external_measurement_overhead",
            "counts_supplement_deterministic_ownership_tests_do_not_replace_them"
        ],
        "observer_cpu": {
            "scope": "python_observer_rusage_self_only", "user_seconds": user_cpu,
            "system_seconds": system_cpu, "total_seconds": user_cpu + system_cpu,
            "average_percent_of_one_core": 100 * (user_cpu + system_cpu) / max(elapsed, 0.001),
            "process_lifetime_total_seconds": cpu_after.ru_utime + cpu_after.ru_stime,
        },
        "native_children": observation.report(),
        "lease_comparison": {
            "harness_start_attempts": lease_starts,
            "observed_starts": len(observation.records), "starts_match": starts_match,
            "harness_maximum_active_leases": final.get("sessionsAfterCleanup", {}).get("maximumActiveLeases"),
            "overlapping_direct_children_observed": observation.maximum_simultaneous > 1,
            "difference_can_include_missed_short_processes_or_failed_start_attempts": True,
        },
        "harness_initial": output.initial, "harness_final": output.final,
        "discarded_invalid_harness_records": output.invalid_records,
    }
    return report, 0 if complete else 2


def main(arguments=None):
    report_file = None
    measurement_started = False
    try:
        options = parse_options(sys.argv[1:] if arguments is None else arguments)
        if sys.platform != "darwin":
            raise ObserverFailure("macos_required")
        native = NativeProcesses()
        descriptor = os.open(options.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        report_file = os.fdopen(descriptor, "w", encoding="utf-8")
        measurement_started = True
        report, exit_code = run_observation(options, native)
        json.dump(report, report_file, allow_nan=False, sort_keys=True, indent=2)
        report_file.write("\n")
        emit_progress("observer_finished", exit_code=exit_code, cleanup_confirmed=report["cleanup_confirmed"])
        return exit_code
    except (Exception, KeyboardInterrupt):
        # No exception strings, executable paths or raw output may be emitted.
        error = {"event": "observer_error", "reason": "setup_or_observation_failed"}
        if report_file is not None:
            try:
                json.dump(error, report_file, sort_keys=True)
                report_file.write("\n")
            except OSError:
                pass
        try:
            emit_progress(**error)
        except OSError:
            pass
        return 2 if measurement_started else 64
    finally:
        if report_file is not None:
            try:
                report_file.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
