# Changelog

All notable changes to Liquid Stoolap are documented here.

## Unreleased

- No user-facing changes yet.

## 0.1.8 - 2026-07-15

- Added graceful shutdown handling: the server now waits for active HTTP requests and busy Stoolap handles before closing the connection pool.
- Added `server.max_result_rows`; large result sets are capped and returned with `"truncated": true`.
- Hardened public readiness and internal-error responses to avoid leaking filesystem paths or internal exception details.
- Added issued-token pruning and `auth.max_issued_tokens` to prevent unbounded token growth.
- Tightened read-only SQL classification and multi-statement scanning for quoted identifiers and SQL comments.
- Improved CLI table output with human-readable floating-point formatting by default and `.float human` / `.float raw` interactive commands.
- Updated API schemas, Python SDK models, configuration examples, and user documentation for truncated result sets.

## 0.1.7 - 2026-07-14

- Added JSON nesting-depth validation before request parsing.
- Enforced configured SQL timeout ceilings so client-provided `timeout_ms` cannot exceed the server policy.

## 0.1.6 - 2026-07-13

- Switched SQL command parameters to native Stoolap parameter binding instead of SQL text materialization.
- Hardened read-only SQL gating, bearer-token generation and validation, empty password handling, and JSON log escaping.
- Added regression smoke tests for command parameter injection, read-only `WITH` rejection, SQL log newline escaping, and ARMHF runtime.

## 0.1.4 - 2026-07-12

- Fixed command-parameter handling and Node-RED login authentication.
- Documented Docker container upgrade workflow.
- Added the interactive SQL CLI.

## 0.1.3 - 2026-07-12

- Serialized timestamp values as ISO-8601 strings instead of raw nanosecond integers.
- Reverted telemetry-specific compatibility hooks from the generic server project.

## 0.1.2 - 2026-07-12

- Fixed UTF-8 handling across supported architectures.

## 0.1.1 - 2026-07-12

- Preserved UTF-8 text correctly across the Stoolap FFI boundary.

## 0.1.0 - 2026-07-12

- Initial public release.
- Added the Free Pascal HTTP server with real Stoolap C FFI integration.
- Added Python SDK, Node-RED connector, OpenAPI/JSON Schema contracts, configuration examples, and user documentation.
- Added server unit and smoke tests, SDK tests, and Node-RED package/runtime checks.
- Added concurrent request limiting and backend timeout configuration.
- Added SQL logging with redaction.
- Added x86 and Raspberry Pi ARM benchmark results.
