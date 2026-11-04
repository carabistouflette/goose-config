#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Acceptance tests for the optional live-reloading worker application."""
import argparse
import contextlib
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ENV_NAMES = ("NAME", "PREFIX", "QUEUES", "MIN_BYTES", "MAX_BYTES", "ENABLED")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def replace(path, text):
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


class Worker:
    def __init__(self, command, env, timeout=15):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, env=env, start_new_session=True,
                                        bufsize=0)
        self.pending = b""
        self.timeout = timeout
        os.set_blocking(self.process.stdin.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def line(self, expected):
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            require(remaining > 0 and self.selector.select(max(remaining, 0)),
                    f"worker response timeout; expected {expected!r}")
            chunk = os.read(self.process.stdout.fileno(), 4096)
            require(chunk, f"worker closed stdout; expected {expected!r}")
            self.pending += chunk
            require(len(self.pending) <= 16384, "worker response exceeded output budget")
        line, self.pending = self.pending.split(b"\n", 1)
        require(line.decode("ascii") == expected,
                f"worker response {line!r}; expected {expected!r}")

    def send(self, command, expected):
        data = command.encode("ascii") + b"\n"
        written = 0
        deadline = time.monotonic() + self.timeout
        with selectors.DefaultSelector() as writable:
            writable.register(self.process.stdin, selectors.EVENT_WRITE)
            while written < len(data):
                remaining = deadline - time.monotonic()
                require(remaining > 0 and writable.select(max(remaining, 0)),
                        "worker stdin write timeout")
                try:
                    count = os.write(self.process.stdin.fileno(), data[written:])
                except BlockingIOError:
                    continue
                require(count > 0, "worker stdin closed during write")
                written += count
        self.line(expected)

    def finish(self):
        self.send("quit", "bye")
        self.process.stdin.close()
        require(self.process.wait(timeout=15) == 0, "worker exited unsuccessfully")
        require(not self.pending and not self.process.stdout.read(1), "unexpected trailing output")
        self.errors.seek(0)
        require(not self.errors.read(4096), "worker wrote unexpected stderr")

    def close(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=15)
        self.selector.close()
        self.process.stdin.close()
        self.process.stdout.close()
        self.errors.close()


@contextlib.contextmanager
def running(command, env):
    worker = Worker(command, env)
    try:
        worker.line("ready generation=1")
        yield worker
        worker.finish()
    finally:
        worker.close()


def status(generation, *, name="demo", minimum=1, maximum=32, enabled="true",
           prefix_source="worker.json", max_source="worker.toml"):
    return (f"status generation={generation} worker={name} min={minimum} max={maximum} "
            f"enabled={enabled} prefix-source={prefix_source} max-source={max_source}")


def acceptance(binary, base):
    env = os.environ.copy()
    for name in ENV_NAMES:
        env.pop("GOOSE_WORKER_" + name, None)
    toml, overlay = base / "policy with spaces.toml", base / "overlay with spaces.json"
    original = '[worker]\nname="demo"\nprefix="T:"\nmax_bytes=32\nqueues=["default","priority"]\n'
    replace(toml, original)
    replace(overlay, '{"worker":{"prefix":"J:"}}')
    command = [str(binary), str(toml), str(overlay)]
    with running(command, env) as worker:
        worker.send("status", status(1))
        worker.send("job priority hello", "done generation=1 worker=demo queue=priority J:hello")
        worker.send("job other hello", "job rejected queue")
        worker.send("job default " + "x" * 33, "job rejected size")
        worker.send("job priority " + "x" * 32,
                    "done generation=1 worker=demo queue=priority J:" + "x" * 32)
        worker.send("job default ", "job rejected size")
        worker.send("job", "command rejected syntax")
        worker.send("job default a\x1bb", "job rejected syntax")
        worker.send("x" * 8193, "command rejected size")

        # Every failed candidate changes other fields too, catching partial
        # application publication after either schema or business validation.
        invalid = [
            '{"worker":{"name":"changed","prefix":"BAD:","max_bytes":0}}',
            '{"worker":{"name":"changed","prefix":"BAD:","min_bytes":33,"enabled":false}}',
            '{"worker":{"name":"changed","prefix":"BAD:","queues":[]}}',
            '{"worker":{"name":"changed","prefix":"BAD:","queues":["dup","dup"]}}',
            '{"worker":{"name":"changed","prefix":"BAD:","queues":["bad queue"]}}',
            '{"worker":{"name":"changed","prefix":"BAD:\\n"}}',
            '{"worker":{"name":"bad name","prefix":"BAD:"}}',
            '{"worker":{"name":"changed","prefix":"BAD:","unknown":"SECRET_VALUE"}}',
            '{"worker":{"name":"changed","prefix":"BAD:","max_bytes":"SECRET_VALUE"}}',
            '{"worker":{"prefix":"one","prefix":"SECRET_VALUE"}}',
            '{"worker":',
            " " * 65537,
        ]
        for document in invalid:
            replace(overlay, document)
            worker.send("reload", "reload rejected")
            worker.send("status", status(1))
            worker.send("job priority hello", "done generation=1 worker=demo queue=priority J:hello")
        overlay.unlink()
        worker.send("reload", "reload rejected")
        overlay.mkdir()
        worker.send("reload", "reload rejected")
        overlay.rmdir()
        overlay.symlink_to(toml)
        worker.send("reload", "reload rejected")
        overlay.unlink()
        worker.send("status", status(1))

        # Removing upper definitions exposes current lower layers, not history.
        replace(toml, '[worker]\nname="fresh"\nprefix="N:"\nmax_bytes=12\nqueues=["fresh"]\n')
        replace(overlay, '{}')
        worker.send("reload", "reloaded generation=2")
        worker.send("status", status(2, name="fresh", maximum=12, prefix_source="worker.toml"))
        worker.send("job priority hello", "job rejected queue")
        worker.send("job fresh hello", "done generation=2 worker=fresh queue=fresh N:hello")
        replace(toml, '[worker]\nname="minimal"\n')
        worker.send("reload", "reloaded generation=3")
        worker.send("status", status(3, name="minimal", maximum=256,
                                     prefix_source="defaults", max_source="defaults"))
        worker.send("job fresh hello", "job rejected queue")
        worker.send("job default hello", "done generation=3 worker=minimal queue=default done:hello")
        replace(toml, '[worker]\nprefix="SECRET_VALUE"\n')
        worker.send("reload", "reload rejected")
        worker.send("status", status(3, name="minimal", maximum=256,
                                     prefix_source="defaults", max_source="defaults"))

    replace(toml, original)
    replace(overlay, '{"worker":{"prefix":"J:"}}')
    upper_env = dict(env, GOOSE_WORKER_MAX_BYTES="8", GOOSE_WORKER_PREFIX="E:",
                     GOOSE_WORKER_QUEUES="envA,envB")
    with running(command, upper_env) as worker:
        worker.send("status", status(1, maximum=8, prefix_source="GOOSE_WORKER_PREFIX",
                                     max_source="GOOSE_WORKER_MAX_BYTES"))
        worker.send("job envA hello", "done generation=1 worker=demo queue=envA E:hello")
        worker.send("job priority hello", "job rejected queue")
    cli = ["--max-bytes=6", "--prefix=C:", "--queue", "cliA", "--queue=cliB"]
    with running(command + cli, upper_env) as worker:
        worker.send("status", status(1, maximum=6, prefix_source="--prefix", max_source="--max-bytes"))
        worker.send("job cliB hello", "done generation=1 worker=demo queue=cliB C:hello")
        worker.send("job cliA toolong", "job rejected size")
        replace(overlay, '{"worker":{"enabled":false,"max_bytes":4096,"prefix":"F:"}}')
        worker.send("reload", "reloaded generation=2")
        worker.send("status", status(2, maximum=6, enabled="false", prefix_source="--prefix", max_source="--max-bytes"))
        worker.send("job cliA hello", "job rejected disabled")
        replace(overlay, '{}')
        worker.send("reload", "reloaded generation=3")
        worker.send("job cliA hello", "done generation=3 worker=demo queue=cliA C:hello")
    with running([str(binary), "-", "-", "--name=cli"], env) as worker:
        worker.send("job default hello", "done generation=1 worker=cli queue=default done:hello")
    replace(overlay, '{"worker":{"prefix":"' + 'P' * 64 + '"}}')
    # Exact document cap is accepted; one byte above fails without publication.
    replace(overlay, overlay.read_text() + " " * (65536 - overlay.stat().st_size))
    with running(command + ["--min-bytes=3", "--max-bytes=3"], env) as worker:
        worker.send("job default xx", "job rejected size")
        worker.send("job default xxx", "done generation=1 worker=demo queue=default " + "P" * 64 + "xxx")
        worker.send("job default xxxx", "job rejected size")
        replace(overlay, " " * 65537)
        worker.send("reload", "reload rejected")
        worker.send("job default xxx", "done generation=1 worker=demo queue=default " + "P" * 64 + "xxx")
    replace(overlay, '{}')
    for arguments, extra in [(["-", "-"], {}),
                             ([str(toml), str(overlay)], {"GOOSE_WORKER_MAX_BYTES": "SECRET_VALUE"}),
                             ([str(toml), str(overlay), "--max-bytes=32"], {"GOOSE_WORKER_MAX_BYTES": "SECRET_VALUE"}),
                             ([str(toml), str(overlay), "--unknown=SECRET_VALUE"], {}),
                             ([str(toml), str(overlay), "--name=a", "--name=b"], {}),
                             ([], {})]:
        result = subprocess.run([str(binary), *arguments], input="job default hello\n",
                                env=dict(env, **extra), capture_output=True, text=True, timeout=15)
        require(result.returncode in (1, 2) and not result.stdout and
                "SECRET_VALUE" not in result.stderr and
                (result.stderr == "worker: startup configuration rejected\n" or
                 result.stderr == "usage: worker TOML_PATH_OR_- JSON_PATH_OR_- [--name NAME ...]\n"),
                "invalid startup did not fail without exposing inputs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("--cc", choices=("gcc", "clang"), default="gcc")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="worker acceptance ", dir=ROOT / ".build") as tmp:
        base = Path(tmp)
        binary = base / "configured worker"
        command = [str(compiler), "build", "examples/worker.goose", "-o", str(binary)]
        env = dict(os.environ)
        if args.sanitize:
            command += ["--standalone", "--debug", "--no-bce", "--cc", str(ROOT / "scripts/sanitizer-cc.sh")]
            env.update(SANITIZER_CC=args.cc, SANITIZER_OPT="-O2")
        else:
            command += ["--cc", args.cc, "-O2"]
        build = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True)
        try:
            require(build.wait(timeout=180) == 0, "worker build failed")
        except subprocess.TimeoutExpired:
            try:
                os.killpg(build.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            build.wait(timeout=15)
            raise RuntimeError("worker build timeout") from None
        acceptance(binary, base)
    print(f"worker acceptance: {args.cc}{' ASan/UBSan' if args.sanitize else ' -O2'} passed", flush=True)


if __name__ == "__main__":
    main()
