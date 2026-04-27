# impala-to-doris

> An [Agent Skill](https://skills.sh/) for migrating PHP projects from Impala (ThriftSQL / impala-shell) to Apache Doris (MySQL protocol).

## What this skill does

When you have a PHP project running on Impala and want to move it to Apache Doris, this skill walks an AI agent through:

- Replacing `ThriftSQL` / `impala-shell` connection layer with PHP `mysqli`
- Converting Impala-specific SQL syntax (`UPSERT`, `from_timestamp`, `trunc`, `months_between`, Java-style date format strings) to Doris equivalents
- Rewriting `UPDATE` statements (Doris requires explicit target table, FROM excludes target, ON conditions move to WHERE)
- Handling the most subtle correctness issue: `min(id) + GROUP BY` based "first record" inserts must add `LEFT ANTI JOIN <target>` to stay idempotent on rerun
- Configuring partial column updates (`enable_unique_key_partial_update`) on UNIQUE KEY tables
- Running a post-migration verification checklist (§5) of `grep` commands that should all produce empty output

## Why use a skill (vs. just docs)

This isn't just a reference. It is structured as an **imperative checklist** an agent must complete in order, plus a final self-verification command pack. Practical experience shows that even with detailed conversion rules, agents tend to:

- Miss nested-function date format strings (`'%YMMdd'` left after a partial replace)
- Forget `LEFT ANTI JOIN` when migrating `min(id)` based inserts → silent duplicate inserts on rerun
- Get the parameter order of `months_between` → `timestampdiff(MONTH, ...)` reversed
- Drop `INTERVAL ... DAY` from `date_add(x, -N)` calls

The skill encodes these traps as named "陷阱 1-13" and provides a **post-completion grep pack** so any miss is detectable.

## Installation

### Cherry Studio

Drop the `impala-to-doris/` folder into your Cherry Studio Skills directory:

- macOS / Linux: `~/Library/Application Support/CherryStudio/Data/Skills/`
- Windows: `%APPDATA%\CherryStudio\Data\Skills\`

The skill triggers automatically when conversation mentions Impala→Doris migration, ThriftSQL, impala-shell, or related patterns.

### Claude Code / generic agents

```bash
mkdir -p ~/.claude/skills/
cp -r impala-to-doris/ ~/.claude/skills/
```

### `npx skills` (Skills CLI)

```bash
npx skills add github:<your-username>/impala-to-doris
```

## What's inside

- `SKILL.md` — the full migration guide (~900 lines, Chinese):
  - §1-2: Connection layer + cleanup
  - §3.1-3.12: Section-by-section SQL syntax conversion (UPSERT, UPDATE, date format strings, `from_timestamp`, `trunc`, `year/weekofyear`, `months_between`, `date_add`, comma JOIN, **LEFT ANTI JOIN for first-record inserts**, INSERT template)
  - **⚠️ 关键陷阱 1-13** — the 13 most common bugs an agent will introduce, with examples and fixes
  - **§5 完工自检命令包** — the post-migration `grep` checklist
  - Final 23-step ordered conversion checklist

## Caveats

- **Doris version**: tested patterns target Doris 1.2+. For older versions, `LEFT ANTI JOIN` is replaced with `LEFT JOIN ... IS NULL` or `NOT EXISTS` (see §3.11.1).
- **PHP-only**: the connection-layer rewrite assumes PHP. The SQL conversion rules are language-agnostic.
- **Not a SQL parser**: the skill works via grep/regex level guidance plus AI judgment. It is not a deterministic transpiler. The post-completion `grep` pack is what makes the result verifiable.
- **Not affiliated with Apache Doris** or VeloDB.

## Related tools

- [Doris SQL Convertor](https://doris.apache.org/docs/3.x/lakehouse/sql-convertor/sql-convertor-overview/) — official SQL-dialect converter built into Doris 2.1+. Supports Presto/Trino/Hive/ClickHouse/PostgreSQL/Spark **but not Impala**, and does not handle PHP code or `min(id)+ANTI JOIN` semantics. Complementary to this skill.
- [Addax](https://github.com/wgzhao/Addax) — ETL tool for cross-database data movement (Impala/Hive/MySQL/Doris).

## License

MIT
