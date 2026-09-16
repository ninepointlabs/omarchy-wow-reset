import QtQuick
import Quickshell.Io

// One bin/wow-reset-ops run at a time. argv comes from Model.helperCommand
// (a trusted absolute python3 running bin/bounded-run), the request goes over
// stdin, and the session environment is replaced by `jobEnvironment`.
// jobFinished fires exactly once per start, including when the interpreter
// could not be started at all (reported as 127).
Process {
  id: job

  property var jobEnvironment: ({})
  signal jobFinished(int exitCode, string stdoutText, string stderrText)

  property bool _started: false
  property bool _settled: true
  property string _out: ""
  property string _err: ""

  running: false
  command: []
  clearEnvironment: true
  environment: jobEnvironment
  workingDirectory: "/"
  stdinEnabled: true
  stdout: StdioCollector { id: jobStdout; waitForEnd: true; onStreamFinished: job._out = text }
  stderr: StdioCollector { id: jobStderr; waitForEnd: true; onStreamFinished: job._err = text }

  function start(argv, payload) {
    if (running || !argv || argv.length === 0) return false
    _started = false
    _settled = false
    _out = ""
    _err = ""
    command = argv
    running = true
    write(payload)
    stdinEnabled = false
    stdinEnabled = true
    return true
  }

  onStarted: _started = true

  onExited: function(exitCode) {
    if (_settled) return
    _settled = true
    jobFinished(exitCode, String(jobStdout.text || _out || ""), String(jobStderr.text || _err || ""))
  }

  // An interpreter that is not on disk never starts, so `running` falls back
  // to false without an exit.
  onRunningChanged: {
    if (running || _settled || _started) return
    _settled = true
    jobFinished(127, "", "")
  }
}
