// P1-6 external process governance — Windows Job Object.
//
// `Process.kill()` only terminates the direct child. `cmd.exe` starts the
// real command (and it may start more children), so a timeout/cancel that
// kills only cmd.exe leaves the build/tool process running. A Job Object
// with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE + TerminateJobObject kills the
// whole tree, and closing the handle on app exit prevents orphans.
//
// Plain dart:ffi (kernel32 + msvcrt malloc) so no direct win32 dependency is
// required. Every entry point is best-effort: failures return null and the
// caller falls back to taskkill /T.
library;

import 'dart:ffi';
import 'dart:io';

const int _jobObjectExtendedLimitInformationClass = 9;
const int _jobObjectLimitKillOnJobClose = 0x2000;
const int _processTerminate = 0x0001;
const int _processSetQuota = 0x0100;
const int _processQueryLimitedInformation = 0x1000;

final class _JobBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @UintPtr()
  external int minimumWorkingSetSize;

  @UintPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

final class _JobExtendedLimitInformation extends Struct {
  external _JobBasicLimitInformation basicLimitInformation;

  external _IoCounters ioInfo;

  @UintPtr()
  external int processMemoryLimit;

  @UintPtr()
  external int jobMemoryLimit;

  @UintPtr()
  external int peakProcessMemoryUsed;

  @UintPtr()
  external int peakJobMemoryUsed;
}

typedef _CreateJobObjectNative = IntPtr Function(
  Pointer<Uint16>,
  Pointer<Uint16>,
);
typedef _CreateJobObjectDart = int Function(Pointer<Uint16>, Pointer<Uint16>);

typedef _SetInformationJobObjectNative = Int32 Function(
  IntPtr,
  Int32,
  Pointer<Void>,
  Uint32,
);
typedef _SetInformationJobObjectDart = int Function(
  int,
  int,
  Pointer<Void>,
  int,
);

typedef _AssignProcessToJobObjectNative = Int32 Function(IntPtr, IntPtr);
typedef _AssignProcessToJobObjectDart = int Function(int, int);

typedef _TerminateJobObjectNative = Int32 Function(IntPtr, Uint32);
typedef _TerminateJobObjectDart = int Function(int, int);

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

class _Win32JobApi {
  _Win32JobApi._(
    this.createJobObject,
    this.setInformationJobObject,
    this.assignProcessToJobObject,
    this.terminateJobObject,
    this.closeHandle,
    this.openProcess,
    this.malloc,
    this.free,
  );

  final _CreateJobObjectDart createJobObject;
  final _SetInformationJobObjectDart setInformationJobObject;
  final _AssignProcessToJobObjectDart assignProcessToJobObject;
  final _TerminateJobObjectDart terminateJobObject;
  final _CloseHandleDart closeHandle;
  final _OpenProcessDart openProcess;
  final _MallocDart malloc;
  final _FreeDart free;

  static _Win32JobApi? _instance;
  static bool _attempted = false;

  static _Win32JobApi? tryCreate() {
    if (_attempted) return _instance;
    _attempted = true;
    if (!Platform.isWindows) return null;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final msvcrt = DynamicLibrary.open('msvcrt.dll');
      _instance = _Win32JobApi._(
        kernel32.lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
          'CreateJobObjectW',
        ),
        kernel32.lookupFunction<
          _SetInformationJobObjectNative,
          _SetInformationJobObjectDart
        >('SetInformationJobObject'),
        kernel32.lookupFunction<
          _AssignProcessToJobObjectNative,
          _AssignProcessToJobObjectDart
        >('AssignProcessToJobObject'),
        kernel32
            .lookupFunction<_TerminateJobObjectNative, _TerminateJobObjectDart>(
              'TerminateJobObject',
            ),
        kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
          'CloseHandle',
        ),
        kernel32.lookupFunction<_OpenProcessNative, _OpenProcessDart>(
          'OpenProcess',
        ),
        msvcrt.lookupFunction<_MallocNative, _MallocDart>('malloc'),
        msvcrt.lookupFunction<_FreeNative, _FreeDart>('free'),
      );
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }
}

/// A Windows Job Object owning one spawned process tree.
class WindowsJobObject {
  WindowsJobObject._(this._handle, this._api);

  final int _handle;
  final _Win32JobApi _api;
  bool _closed = false;

  /// Create a job object, set kill-on-close, and assign [pid] to it.
  /// Returns null when any step fails; callers fall back to taskkill /T.
  static WindowsJobObject? createForProcess(int pid) {
    final api = _Win32JobApi.tryCreate();
    if (api == null) return null;

    final job = api.createJobObject(nullptr, nullptr);
    if (job == 0) return null;

    var assigned = false;
    Pointer<Void> memory = nullptr;
    try {
      memory = api.malloc(sizeOf<_JobExtendedLimitInformation>());
      if (memory == nullptr) return null;
      final size = sizeOf<_JobExtendedLimitInformation>();
      memory.cast<Uint8>().asTypedList(size).fillRange(0, size, 0);
      final info = memory.cast<_JobExtendedLimitInformation>();
      info.ref.basicLimitInformation.limitFlags = _jobObjectLimitKillOnJobClose;
      final configured = api.setInformationJobObject(
        job,
        _jobObjectExtendedLimitInformationClass,
        memory,
        size,
      );
      if (configured == 0) return null;

      final process = api.openProcess(
        _processSetQuota | _processTerminate | _processQueryLimitedInformation,
        0,
        pid,
      );
      if (process == 0) return null;
      try {
        if (api.assignProcessToJobObject(job, process) == 0) return null;
      } finally {
        api.closeHandle(process);
      }
      assigned = true;
      return WindowsJobObject._(job, api);
    } finally {
      if (memory != nullptr) api.free(memory);
      if (!assigned) api.closeHandle(job);
    }
  }

  /// Terminate every process in the job. Returns false when Windows refused
  /// (for example the process already exited).
  bool terminate() {
    if (_closed) return false;
    return _api.terminateJobObject(_handle, 1) != 0;
  }

  /// Close the handle. With kill-on-close this also terminates survivors.
  void close() {
    if (_closed) return;
    _closed = true;
    _api.closeHandle(_handle);
  }
}
