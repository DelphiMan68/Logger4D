<div align="center">
  <img src="Assets/banner.png" alt="Logger4D — A professional, thread-safe logging library for Delphi and Free Pascal." width="100%" />
</div>

# Logger4D

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A professional, thread-safe logging library for **Delphi (XE2+)** and **Free Pascal (3.2+)**.
One code base, no external dependencies, Windows / Linux / macOS.

## Features

- Six levels: `Trace`, `Debug`, `Info`, `Warn`, `Error`, `Fatal` (+ `llOff`)
- Printf-style overloads (`Log.Info('User %s', ['bob'])`) that cost nothing when the level is disabled
- Exception overloads (`Log.Error('Save failed', E)`)
- Structured properties: `ForContext('user', 'bob')`, plus global properties on every entry
- Hierarchical per-logger levels (`Hub.SetLoggerLevel('App.Db', llWarn)` covers `App.Db.Query`)
- Appenders: console (colored), file (UTF-8, size + daily rolling), debug output, memory ring buffer, event callback,
  **Syslog** (RFC 5424 over UDP), **HTTP** (batched JSON POST with retries), **SQLite** (queryable rows)
- `TAsyncAppender`: background-thread decorator with overflow policies (block / drop newest / drop oldest)
- Formatters: pattern-based text and JSON lines
- Per-appender minimum level and custom filter callback
- Built-in operation timer: `Scope := Log.Timed('Import')`
- Logging never raises into your code; appender failures are reported via `Hub.OnInternalError`
- Independent hubs (`CreateHub`) for libraries and unit tests

## Layout

```
Logger4D/
  LICENSE
  README.md
  Source/
    Logger4D.inc          compiler settings
    Logger4D.Types.pas    types and interfaces
    Logger4D.Utils.pas    helpers
    Logger4D.Formatters.pas
    Logger4D.Appenders.pas
    Logger4D.Async.pas
    Logger4D.Appenders.Syslog.pas   optional
    Logger4D.Appenders.Http.pas     optional
    Logger4D.Appenders.SQLite.pas   optional
    Logger4D.pas          hub + logger + global helpers
  Examples/
    Delphi/       BasicExample.dpr, AdvancedExample.dpr, ExtraAppendersExample.dpr
    FreePascal/   BasicExample.lpr, AdvancedExample.lpr, ExtraAppendersExample.lpr, build.sh, build.cmd
```

## Quick start

```pascal
uses Logger4D.Types, Logger4D.Appenders, Logger4D;

begin
  DefaultHub.Level := llDebug;
  DefaultHub.AddAppender(TConsoleAppender.Create);

  GetLogger('App').Info('Hello %s', ['world']);
end.
```

**Delphi:** add `Source` to the project search path (or use the `in '...'` clauses as in the examples).
**Free Pascal:** compile with `-Fu<path>/Source`. On Unix, put `cthreads` first in your `uses` clause.
The units select `{$MODE DELPHIUNICODE}` automatically.

## Optional appenders and their dependencies

The three network/database appenders live in separate units, so the core library
stays dependency free. Add a unit to your `uses` clause only if you need it.

| Appender | Unit | Delphi | Free Pascal |
|---|---|---|---|
| `TSyslogAppender` | `Logger4D.Appenders.Syslog` | Indy (ships with Delphi) | RTL `sockets` (+ `winsock2` on Windows / `netdb` elsewhere for host names) |
| `THttpAppender` | `Logger4D.Appenders.Http` | XE8+ (`System.Net.HttpClient`) | `fphttpclient` + `opensslsockets` (OpenSSL needed for https) |
| `TSQLiteAppender` | `Logger4D.Appenders.SQLite` | FireDAC + SQLite | SQLDB + sqlite3 library |

```pascal
// Syslog: warnings and above to a local syslog daemon
Syslog := TSyslogAppender.Create('127.0.0.1', 514, 'MyApp', sfLocal0);
Syslog.MinLevel := llWarn;
DefaultHub.AddAppender(Syslog);

// HTTP: batched JSON, sent from a background thread
Http := THttpAppender.Create('https://logs.example.com/ingest');
Http.Headers.Values['Authorization'] := 'Bearer TOKEN';
Http.OnError := MyErrorHandler;
DefaultHub.AddAppender(Http);

// SQLite: wrap in TAsyncAppender so one background thread owns the connection
Db := TSQLiteAppender.Create('logs/logs.db');
Db.MaxRows := 100000;
DefaultHub.AddAppender(TAsyncAppender.Create(Db));
```

Notes:
- Syslog: if Free Pascal cannot find `netdb` / `winsock2`, define `LOGGER4D_NO_DNS` in the project options; the host must then be an IP address or `localhost`.
- Syslog uses UDP only; structured properties are sent as RFC 5424 structured data.
- The HTTP appender drops a batch (and calls `OnError`) after `MaxRetries` failures, and drops the oldest entries beyond `MaxBuffered`.
- SQLite columns: `id, ts, level, level_name, logger, message, thread_id, process_id, host, props, exception`.

## Pattern tokens

| Token | Meaning |
|---|---|
| `{ts}` / `{ts:FORMAT}` | timestamp (`FormatDateTime` format, default `yyyy-mm-dd hh:nn:ss.zzz`) |
| `{level}` / `{level:N}` | level, optionally padded to width N |
| `{logger}` `{msg}` `{tid}` `{pid}` `{host}` | logger name, message, thread id, process id, computer name |
| `{props}` / `{props:FMT}` | `key=value` pairs, optionally wrapped with a Format string, e.g. `{props: [%s]}` |
| `{exc}` / `{exc:FMT}` | exception class and message, e.g. `{exc: - %s}` |
| `{nl}` | line break |
| `{{` | literal `{` |

Default pattern: `{ts} {level:5} [{tid}] {logger} - {msg}{props: | %s}{exc: | %s}`

## Notes

- After `AddAppender` the hub owns the appender (reference counted). Do not free it yourself.
- Configure appender properties (`MaxFileSize`, `MinLevel`, `Formatter`, ...) before adding them to the hub.
- Event callbacks (`TEventAppender`, `OnFilter`) run on the logging thread; marshal to the UI thread yourself.
- `TAsyncAppender.Close` / `ShutdownLogging` drain the queue, so no entries are lost at exit (except with the drop policies when the queue overflowed; see `DroppedCount`).

## Author and license

Created by **Shaahin Ashayeri** ([@DelphiMan68](https://github.com/DelphiMan68)).

Logger4D is released under the [MIT License](LICENSE). Copyright (c) 2026 Shaahin Ashayeri.
