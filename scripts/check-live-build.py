#!/usr/bin/env python3
"""Inspect current-user executables and unlinked text mappings. Requires Python 3.9+."""
import ctypes
import errno
import os
from pathlib import Path
import sys
import subprocess


PROC_UID_ONLY = 4


class ProcessPaths:
    def __init__(self):
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.library.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                             ctypes.c_void_p, ctypes.c_int]
        self.library.proc_listpids.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int

    def pids(self):
        capacity = 1024
        while True:
            buffer = (ctypes.c_int * capacity)()
            size = ctypes.sizeof(buffer)
            count = self.library.proc_listpids(PROC_UID_ONLY, os.getuid(), buffer, size)
            if count <= 0:
                raise OSError(ctypes.get_errno(), "proc_listpids failed")
            if count < size:
                return [pid for pid in buffer[:count // ctypes.sizeof(ctypes.c_int)] if pid > 0]
            capacity *= 2

    def executable(self, pid):
        buffer = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            code = ctypes.get_errno()
            if code == errno.ESRCH:
                return None
            raise OSError(code, f"cannot inspect executable for process {pid}")
        return Path(bytes(buffer.value).decode(sys.getfilesystemencoding(), errors="surrogateescape"))


def mapped_paths(pid):
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-Fpn0"],
                            capture_output=True)
    fields = [raw.lstrip(b"\n") for raw in result.stdout.split(b"\0")]
    paths = [Path(os.fsdecode(field[1:])) for field in fields if field.startswith(b"n")]
    if result.returncode == 0 and paths:
        return paths
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return []
    raise OSError(errno.EIO, f"cannot inspect executable mappings for process {pid}")


def running_build(build_directory, processes):
    build_directory = Path(build_directory).resolve()
    for pid in processes.pids():
        try:
            executable = processes.executable(pid)
            paths = [executable] if executable is not None else []
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise
            # An unlinked executable can lose its vnode path while retaining text mappings.
            paths = mapped_paths(pid)
        if any(path.resolve().is_relative_to(build_directory) for path in paths):
            return True
    return False


def main(arguments):
    if sys.version_info < (3, 9):
        print("Process inspection requires Python 3.9 or later; no build or tests were started.",
              file=sys.stderr)
        return 2
    detect_only = bool(arguments and arguments[0] == "--running")
    if len(arguments) != (2 if detect_only else 1) or (not detect_only and arguments[0].startswith("-")):
        print("Usage: check-live-build.py [--running] DIRECTORY", file=sys.stderr)
        return 2
    directory = arguments[1] if detect_only else arguments[0]
    try:
        active = running_build(directory, ProcessPaths())
    except (OSError, RuntimeError) as error:
        print(f"Cannot inspect running build executables; no build or tests were started: {error}",
              file=sys.stderr)
        return 2
    if detect_only:
        return 0 if active else 1
    if active:
        print(f"Refusing to rebuild {directory} while an executable from it is running.",
              file=sys.stderr)
        print("Close that instance normally, then rerun the command.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
