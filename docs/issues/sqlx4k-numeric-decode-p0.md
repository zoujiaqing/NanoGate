# sqlx4k P0 issue 草稿（待提交至 github.com/smyrgeorge/sqlx4k）

> 状态：草稿——由 owner 决定是否提交 issue/PR
> 影响：Neton 全生态（PostgreSQL 驱动可靠性）；NewGate 已以 VARCHAR 存储绕开

## Title

`postgres: NUMERIC column in prepared-statement result aborts the process (Utf8Error in column decode, panic=abort)`

## Body（英文提交用）

**Environment:** sqlx4k 1.12.0 (`sqlx4k-postgres`), Kotlin/Native macosArm64, PostgreSQL 16.

**Repro:**

1. `CREATE TABLE t (id BIGSERIAL PRIMARY KEY, v NUMERIC(10,4) NOT NULL DEFAULT 1.0);`
   `INSERT INTO t (v) VALUES (0.6);`
2. Run any parameterized query returning that column, e.g. `SELECT * FROM t WHERE id = $1`.
3. Process aborts:

```
called `Result::unwrap()` on an `Err` value: ColumnDecode { index: "2", source: Utf8Error { valid_up_to: 2, error_len: Some(1) } }
```

**Analysis:** parameterized queries use the extended protocol (binary result format). `NUMERIC`
has no decode dispatch, so the value falls through to `row.get_unchecked::<&str>` and the binary
numeric wire format fails UTF-8 validation. Because the crate builds with `panic = "abort"`, one
undecodable column kills the entire host process — the failure happens while iterating rows inside
`fetchAll`, before any result crosses the FFI boundary, so callers cannot catch it and custom
converters never run.

**Requested fixes (two independent parts):**

1. Type dispatch for `NUMERIC/DECIMAL` → decode via sqlx `bigdecimal`/`rust_decimal` → return text.
2. Make row decoding return `Result` through the existing FFI error path instead of panicking —
   `get_unchecked`, `CString::new`, and type decode errors must surface as a Kotlin exception,
   never abort the process.

**Suggested regression tests:** NUMERIC via bound-parameter query; parameterized query inside a
transaction; unsupported column type surfaces `Result.failure`; decode errors do not terminate the
native test process.

## Neton 侧后续（P1，登记）

- 建立 PostgreSQL/MySQL/SQLite 支持类型矩阵 + 真实 PG 集成测试（不只测 SQL 渲染）
- 长期：Row/adapter 按类型读取，摆脱「一律字符串化」；驱动缺陷期可提供列级 read expression（`amount::text AS amount`）
