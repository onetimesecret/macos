#!/usr/bin/env python3
"""Refuse a build when a running executable resolves inside its output directory."""
import ctypes
import errno
import os
from pathlib import Path
import sys
import subprocess


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
            count = self.library.proc_listpids(1, 0, buffer, size)
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
    paths = [Path(os.fsdecode(field[1:])) for raw in result.stdout.split(b"\0")
             if (field := raw.lstrip(b"\n")).startswith(b"n")]
    if result.returncode == 0 and paths:
        return paths
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return []
    raise OSError(f"cannot inspect executable mappings for process {pid}")


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
    detect_only = arguments and arguments[0] == "--running"
    directory = arguments[1] if detect_only else arguments[0]
    try:
        active = running_build(directory, ProcessPaths())
    except (OSError, RuntimeError) as error:
        print(f"Cannot inspect running build executables; no build or tests were started: {error}",
              file=sys.stderr)
        return 2 if detect_only else 1
    if detect_only:
        return 0 if active else 1
    if active:
        print(f"Refusing to rebuild {directory} while an executable from it is running.",
              file=sys.stderr)
        print("Close that development instance normally, then rerun the tests.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
