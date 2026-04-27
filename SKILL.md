---
name: impala-to-doris
description: >
  将 PHP 项目中 Impala SQL 迁移到 Doris（Apache Doris）的技能。
  包含连接层替换、SQL 语法转换、自定义函数替换等完整迁移指南。
  当用户提到 Impala 迁移 Doris、Impala 转 Doris、替换 Impala、impala-shell 改 Doris、MySQL 协议连接 Doris 时触发。
  即使没有明确说要迁移整个项目，只要出现 Impala SQL、ThriftSQL、impala-shell、from_unixtime+yyyy 等模式，就考虑调用此技能。
---

# Impala → Doris 迁移指南

## 概述

将 PHP + Impala (ThriftSQL/impala-shell) 项目迁移到 PHP + Doris (MySQL 协议) 项目。
Doris 兼容 MySQL 协议，可以使用 PHP 的 `mysqli`/`PDO` 直接连接。

## 迁移步骤

### 1. 连接层替换

**Impala（原始代码）：**
```php
// ThriftSQL 客户端方式
$impala = new \ThriftSQL\Impala('<IMPALA_HOST>', 21000, '<USER>', null, 60 * 60 * 60);
$impala = $impala->connect();
$impala->setOption('MEM_LIMIT', '4gb');

// 查询方式
$result = $impala->queryAndFetchAll($sql);
return $result[0][0];

// impala-shell CLI 方式
system("impala-shell -u <USER> -i <IMPALA_HOST> -d etl -q \"$sql\"", $retval);
```

**Doris（改造后代码）：**
```php
// Doris 连接配置（MySQL 协议）
$doris_host = '<DORIS_HOST>';
$doris_port = 9030;
$doris_user = '<USER>';
$doris_password = '<PASSWORD>';
$doris_db = 'etl';

// 使用 MySQLi
$conn = mysqli_connect($doris_host, $doris_user, $doris_password, $doris_db, $doris_port);

// 查询方式
$result = mysqli_query($conn, $sql);
$row = mysqli_fetch_assoc($result);
return $row['total_number'];

// 执行 SQL（无返回值）
// 注意：UPDATE 语句前自动执行 SET enable_unique_key_partial_update = true
function querySql($sql) {
    global $conn;
    $sql = preg_replace('/[\s\n]+/', ' ', $sql);
    // ...重连逻辑...
    if (stripos(trim($sql), 'update') === 0) {
        mysqli_query($conn, "SET enable_unique_key_partial_update = true");
    }
    $result = mysqli_query($conn, $sql);
    $retval = $result ? 0 : 1;
    if ($retval != '0') {
        die("SQL执行失败: " . mysqli_error($conn));
    }
}

// 查询并返回多行（替代 Impala 的 queryAndFetchAll）
function _query_fetch($sql) {
    global $conn;
    $result = mysqli_query($conn, $sql);
    if (!$result) {
        die("SQL执行失败: " . mysqli_error($conn));
    }
    $rows = [];
    while ($row = mysqli_fetch_row($result)) {
        $rows[] = $row;
    }
    return $rows;
}
```

### 2. include.php 清理

**移除**不再需要的依赖：
```php
// ❌ 移除
require_once __DIR__ . '/php-thrift-sql/ThriftSQL.phar';
```

### 3. Doris 部分列更新配置

Doris UNIQUE KEY 模型表进行部分列更新（即不更新全部列）时需要开启 session 变量。**推荐在 `querySql()` 函数中自动处理：**

```php
// 在 querySql() 中检测 UPDATE 语句并自动执行
if (stripos(trim($sql), 'update') === 0) {
    mysqli_query($conn, "SET enable_unique_key_partial_update = true");
}
```

这样所有 UPDATE 语句自动获得部分列更新能力，无需手动在每个 SQL 前加 SET。

---

## SQL 语法对照表

| 语法 | Impala | Doris |
|------|--------|-------|
| **UPERT/UPSERT** | `upsert into tbl(...) select ...` | `insert into tbl(...) select ...` |
| **INSERT** | `insert into tbl(...) select ...` | `insert into tbl(...) select ...`（相同） |
| **UPDATE ... FROM** | `update a set a.col=b.col from tbl a, tbl2 b where cond` | `update tbl a set a.col=b.col from tbl2 b where cond`（目标表从 FROM 移除） |
| **隐式逗号 JOIN** | `from a, b where a.id=b.id` | 推荐改显式 `from a join b on a.id=b.id`，但逗号写法兼容 |
| **时间格式** | `from_unixtime(ts, 'yyyy-MM-dd')` | `from_unixtime(ts, '%Y-%m-%d')` |
| **时间戳解析** | `unix_timestamp(str, 'yyyyMMdd')` | `unix_timestamp(str, '%Y%m%d')` |
| **自定义函数** | `log.diff(a, b)` | `DATEDIFF(...)` |
| **from_timestamp** | `from_timestamp(x, 'fmt')` | `date_format(x, 'fmt')` ← 直接替换 |
| **日期截断** | `trunc(x, 'MONTH')` | `date_trunc(x, 'month')` ← 函数名不同，单位小写 |
| **year(x)** | `year(from_unixtime(unix_timestamp(cast(x as string),'%Y%m%d'),'%Y-%m-%d'))` | `year(cast(x as date))` |
| **weekofyear(x)** | `weekofyear(from_unixtime(unix_timestamp(cast(x as string),'%Y%m%d'),'%Y-%m-%d'))` | `weekofyear(cast(x as date))` |
| **now()** | `now()` | `now()`（相同） |
| **日期加减** | `date_add(x, -N)` | `date_add(x, interval -N day)` |
| **月份差** | `months_between(a, b)` | `timestampdiff(MONTH, b, a)` ← **参数顺序反转** |
| **日期差** | `datediff(a, b)` | `datediff(a, b)`（相同；都返回 a-b 的天数） |

---

## 关键语法替换详解

### 3.1 UPSERT → INSERT

Doris 的 UNIQUE KEY 模型表使用 `insert into` 即具备 upsert 语义。

**Impala：**
```sql
upsert into report.daily_income(...) select ...
```

**Doris：**
```sql
insert into report.daily_income(...) select ...
```

### 3.2 UPDATE 语法 — 目标表必须明确指定

Doris UPDATE 语法与 Impala 有根本差异。**目标表必须在 UPDATE 子句中明确写出表名（不能用别名替代），且目标表不能出现在 FROM 子句中。**

**Doris UPDATE 语法：**
```sql
UPDATE target_table [table_alias]
SET col1 = val1, ...
[FROM additional_tables]
WHERE condition
```

**关键规则：**
1. `UPDATE table_name alias` — 表名必须写，**不能只写别名**（`update a` ❌ → `update raw_user a` ✅）
2. 目标表**不能出现在 FROM 子句**中
3. WHERE 子句**必须存在**（即使无条件也要 `where true`）
4. FROM 可省略（当没有额外表时）

**迁移示例：**

```sql
-- ❌ Impala 原写法（Doris 不兼容）
update a set a.col=b.col from raw_user a, active_user b where a.id=b.id

-- ✅ Doris 正确写法（逗号 JOIN 模式）
update raw_user a set a.col=b.col from active_user b where a.id=b.id

-- ❌ Impala 原写法 — JOIN 模式（Doris 不兼容）
update a set a.source=b.source from app_db.order a
join etl.raw_user b on a.source_id=b.id and b.source is not null
where b.cday >= 20211002

-- ✅ Doris 正确写法（JOIN 模式 — ON 条件移到 WHERE）
update app_db.order a set a.source=b.source
from etl.raw_user b
where a.source_id=b.id and b.source is not null and b.cday >= 20211002
```

**迁移步骤：**
1. 从 `update alias` 提取别名
2. 在 FROM 子句中查找 `table_name alias` 对，提取表名
3. 将 `update alias` 改为 `update table_name alias`
4. 从 FROM 中移除目标表
5. 如果目标是 FROM 中唯一表 → 移除整个 FROM
6. 如果目标表后跟 JOIN → 保留 JOIN 的表，ON 条件移到 WHERE

### 3.3 时间函数格式字符串

Impala 使用 Java SimpleDateFormat 格式（`yyyy-MM-dd`），Doris 使用 MySQL 格式（`%Y-%m-%d`）。

| 含义 | Impala | Doris |
|------|--------|-------|
| 年月日 | `yyyy-MM-dd` | `%Y-%m-%d` |
| 年月日时 | `yyyy-MM-dd HH:mm:ss` | `%Y-%m-%d %H:%i:%s` |
| 年月日(无分隔符) | `yyyyMMdd` | `%Y%m%d` |
| 年月(无分隔符) | `yyyyMM` | `%Y%m` |
| 年 | `yyyy` | `%Y` |
| 小时 | `HH` | `%H` |
| 分钟 | `mm` | `%i` |
| 秒 | `ss` | `%s` |

### 3.4 from_timestamp → date_format

**Impala 独有函数** `from_timestamp(timestamp, format)`，Doris 中替换为 `date_format(date, format)`。

```sql
-- Impala
from_timestamp(date_add(now(), interval -60 day), '%Y%m%d')

-- Doris
date_format(date_add(now(), interval -60 day), '%Y%m%d')
```

### 3.5 trunc → date_trunc

Doris 的 `trunc` 只用于数值截断，日期截断使用 `date_trunc`。且单位必须小写。

```sql
-- Impala
trunc(from_unixtime(unix_timestamp(cast(cday as string),'%Y%m%d'),'%Y-%m-%d'),'MONTH')

-- Doris
date_trunc(cast(cday as date), 'month')
```

不同截断级别对照：

| 截断 | Impala | Doris |
|------|--------|-------|
| 天 | `trunc(x, 'DAY')` | `date_trunc(x, 'day')` |
| 月 | `trunc(x, 'MONTH')` | `date_trunc(x, 'month')` |
| 年 | `trunc(x, 'YEAR')` | `date_trunc(x, 'year')` |

**简化规则（要小心）：**

- ✅ 截断到天 + 入参已是 `date` 类型 → 可省略 `date_trunc`，因为对 date 类型本就是空操作。
- ⚠️ 截断到天 + 入参是 `datetime` / `timestamp` → **不要省略**，会保留时分秒。
- ⚠️ 截断到月/年 → **绝不能省略**。

**最常见误区（改完后 GROUP BY 不一致）：**

```sql
-- ❌ 错误：把所有 trunc 都删掉，GROUP BY 直接用原列
GROUP BY cday          -- 实际按天分组，不是按月

-- ✅ 正确：按月分组保留 date_trunc
GROUP BY date_trunc(cast(cday as date), 'month')
```

### 3.6 year/weekofyear 链简化

Impala 中常见模式是将 YYYYMMDD 格式 int 先 cast 成 string，再解析成 timestamp，再取 year/week。

```sql
-- Impala（复杂链）
year(from_unixtime(unix_timestamp(cast(a.cday as string),'%Y%m%d'),'%Y-%m-%d'))
weekofyear(from_unixtime(unix_timestamp(cast(a.cday as string),'%Y%m%d'),'%Y-%m-%d'))

-- Doris(直接简化)
year(cast(a.cday as date))
weekofyear(cast(a.cday as date))
```

> Doris 的 `cast(int as date)` 能识别 YYYYMMDD 格式整数（例如 20240301 → 2024-03-01）。
>
> **⚠️ 注意 NULL/异常值：** 如果 `cday` 可能存在不是合法 8 位日期的值（例如 0、20240230、1900000、NULL），`cast as date` 会返回 NULL，导致 `year()`/`weekofyear()` 也返回 NULL。如果原 Impala SQL 在外层依赖 `is null` 判断，请确认行为一致；必要时保留 `from_unixtime(unix_timestamp(...))` 链以保持容错。

### 3.7 复杂日期计算链

**Impala（典型嵌套链）：**
```sql
cast(from_unixtime(unix_timestamp(date_add(
    from_unixtime(unix_timestamp(cast(b.cday as string),'yyyyMMdd'),'yyyy-MM-dd'), -1
)), 'yyyyMMdd') as int)
```

**Doris（简化写法）：**
```sql
cast(date_format(date_add(cast(b.cday as date), interval -1 day), '%Y%m%d') as int)
```

或者如果结果就是减一天后的 cday：
```sql
b.cday - 1
```

### 3.8 from_timestamp(trunc(...), 'fmt') 完整链

**Impala：**
```sql
cast(from_timestamp(trunc(from_unixtime(unix_timestamp(cast(cday as string),'%Y%m%d'),'%Y-%m-%d'),'DAY'),'%Y%m%d') as int)
```

**Doris：**
```sql
cast(date_format(date_trunc(cast(cday as date), 'day'), '%Y%m%d') as int)
```

进一步简化（截断到天对 date 是空操作）：
```sql
cast(date_format(cast(cday as date), '%Y%m%d') as int)
```

### 3.8.1 months_between → timestampdiff（参数顺序反转）

Doris 没有 `months_between` 函数，必须改用 `timestampdiff(MONTH, ...)`。**关键陷阱：参数顺序相反。**

| 函数 | 语义 | 参数顺序 |
|------|------|---------|
| Impala `months_between(a, b)` | 返回 `a - b` 的月数 | a 在前，b 在后 |
| Doris `timestampdiff(MONTH, a, b)` | 返回 `b - a` 的月数 | a 在前但减法方向相反 |

**等价转换：**

```sql
-- Impala
months_between(cmonth, import_month) = 6   -- cmonth 比 import_month 多 6 个月

-- Doris（参数顺序反过来）
timestampdiff(MONTH, import_month, cmonth) = 6
```

**典型误转（保持原顺序）：**
```sql
-- ❌ 这样写正负号反了！
timestampdiff(MONTH, cmonth, import_month) = 6  -- 实际算的是 import_month - cmonth
```

**完整迁移示例：**

```sql
-- Impala
case when months_between(cmonth, import_month) = 0 then amount end

-- Doris
case when timestampdiff(MONTH, import_month, cmonth) = 0 then amount end
```

> 周和天的差也类似：`Impala datediff(a,b) = a-b` 和 `Doris datediff(a,b) = a-b` 顺序相同（不需翻转），但 `timestampdiff(unit, a, b) = b-a`，要看是哪个函数。

### 3.9 log.diff() 替换

**Impala：**
```sql
log.diff(b.cday, a.cday) = 6
```

**Doris：**
```sql
DATEDIFF(cast(b.cday as date), cast(a.cday as date)) = 6
```

### 3.9.1 date_add 必须显式 interval ... day

Doris 的 `date_add(x, N)` 第二参数虽然能接受整数，但**部分版本对负数和表达式（如 `-($a-1)`）支持不稳定**，且与项目其他位置写法不一致会造成混乱。**强制全部改成 `interval ... day` 写法**。

| Impala 写法 | Doris 写法 |
|-------------|-----------|
| `date_add(now(), -1)` | `date_add(now(), interval -1 day)` |
| `date_add(now(), -7)` | `date_add(now(), interval -7 day)` |
| `date_add(<date_expr>, -1)` | `date_add(<date_expr>, interval -1 day)` |
| `date_add(<date_expr>, -($a-1))` | `date_add(<date_expr>, interval -($a-1) day)` |

**典型嵌套场景（最容易漏改）：**

```sql
-- Impala
cast(from_unixtime(unix_timestamp(date_add(
    from_unixtime(unix_timestamp(cast(b.cday as string),'yyyyMMdd'),'yyyy-MM-dd'),
    -1
)),'yyyyMMdd') as int)

-- Doris（推荐：直接简化）
cast(date_format(date_add(cast(b.cday as date), interval -1 day), '%Y%m%d') as int)

-- Doris（不简化时也至少要补 interval ... day）
cast(date_format(date_add(
    cast(b.cday as date),
    interval -1 day
), '%Y%m%d') as int)
```

**自检命令：**

```bash
# 找出所有 date_add 缺 interval 的位置（应为空）
grep -rEn "date_add\([^)]+,\s*-?[\d\$\(]" include/ | grep -v "interval"
```

### 3.10 逗号 JOIN → 显式 JOIN/ON

Impala 中的隐式逗号 JOIN（`from a, b where a.id=b.id`）在 Doris 中虽然兼容，但推荐转为显式 JOIN 以提高可读性和兼容性。

**三种转换模式：**

**Pattern 1（两表 JOIN）：**
```sql
-- 转换前
select a.*, b.col from table_a a, table_b b where a.id = b.id
-- 转换后
select a.*, b.col from table_a a join table_b b on a.id = b.id
```

**Pattern 2（表 + 子查询）：**
```sql
-- 转换前
select * from table_a a, (select id, max(val) mv from table_b group by id) b where a.id=b.id
-- 转换后
select * from table_a a join (select id, max(val) mv from table_b group by id) b on a.id=b.id
```

**Pattern 3（多表交叉 JOIN）：**
```sql
-- 转换前
select * from a, b, c where a.id=b.aid and b.id=c.bid
-- 转换后（链式 JOIN）
select * from a join b on a.id=b.aid join c on b.id=c.bid
```

> **UPDATE 语句例外：** 当逗号 JOIN 出现在 UPDATE 语句的外层 FROM 中时，**不要转换**。因为 Doris UPDATE 的 FROM 仍然支持逗号分隔表（配合 WHERE 连接条件）。只需确保目标表已从 FROM 中移除。

### 3.11 LEFT ANTI JOIN — min(id)+GROUP BY 去重插入

**这是 Doris 迁移中最重要的去重机制。** 原来的 Impala 代码中 `min(id) + GROUP BY` 模式用于"每组取第一条"，重跑时依赖 `upsert` 语义覆盖旧数据。迁移到 Doris 后改用 `insert into`，同一批数据重跑时会重复插入。**必须在 INSERT 末尾加 `LEFT ANTI JOIN target_table` 来阻止重复。**

#### 原始 Impala 模式（迁移前）

```sql
insert into uniq_user(...)
select b.*
from (
    select min(id) as id
    from app_db.session
    where id >= {$startId} and id <= {$endId}
    group by group_id, user_id              -- GROUP BY 的列 = 表唯一键
) a, app_db.session b
where a.id = b.id
    and b.id >= {$startId} and b.id <= {$endId}
```

#### Doris 正确写法（迁移后）

```sql
INSERT INTO uniq_user(...)
SELECT
    a.id,
    a.group_id,
    a.user_id,
    ...
FROM app_db.session a                            -- 主表用 a 别名, 直接在 FROM
JOIN (
    SELECT min(id) min_id                         -- 用 min_id 别名, 不是 id
    FROM app_db.session
    WHERE id >= {$startId} and id <= {$endId}
    GROUP BY group_id, user_id                    -- 必须与 ANTI JOIN 的键对齐
) b ON a.id = b.min_id
LEFT ANTI JOIN uniq_user t                        -- t 是目标表别名
ON a.group_id = t.group_id
    AND a.user_id = t.user_id                     -- ANTI JOIN 键 = GROUP BY 键 = 表唯一键
WHERE a.id >= {$startId} AND a.id <= {$endId}
```

#### 转换规则（核心顺序不可乱）

1. **主表提升到 FROM：** 从 `from (子查询)a, table b` 改为 `FROM table a JOIN (子查询)b ON a.id = b.min_id`
2. **子查询列别名：** `min(id)` 必须用 `min_id`（不用 `id`），避免与主表的 `a.id` 冲突
3. **加 LEFT ANTI JOIN：** 目标表别名用 `t`，连接条件严格取 **GROUP BY 的列**（即表唯一键）
4. **WHERE 过滤移到主查询：** 原来 `and b.id >= ` 条件改为 `WHERE a.id >= `

#### 完整对照示例

以 `order_role` 为例（`<TARGET>/include/units/order_role.php`）：

```sql
-- ✅ Doris 迁移后
INSERT INTO dim.order_role(id, cday, group_id, app_id, source, user_id, server_id, role_id, ctime)
SELECT
    a.id, a.cday, a.group_id, a.app_id, a.source,
    NVL(a.user_id, 0), a.server_id, a.role_id, a.ctime
FROM app_db.order a
JOIN (
    SELECT min(id) min_id
    FROM app_db.order
    WHERE id >= {$startId} and id <= {$endId}
    GROUP BY group_id, user_id, role_id            -- 唯一键：[group_id, user_id, role_id]
) b ON a.id = b.min_id
LEFT ANTI JOIN dim.order_role t
ON a.group_id = t.group_id
    AND a.user_id = t.user_id                       -- ANTI JOIN 键与 GROUP BY 严格对齐
    AND a.role_id = t.role_id
WHERE a.id >= {$startId} and a.id <= {$endId}
```

#### ANTI JOIN 键对齐原则

| 表 | GROUP BY 列 | LEFT ANTI JOIN ON 列 |
|----|------------|---------------------|
| uniq_user | group_id, user_id | a.g_id=t.g_id AND a.user_id=t.user_id |
| uniq_device | group_id, device_id | a.g_id=t.g_id AND a.device_id=t.device_id |
| daily_login_user | group_id, user_id, cday | a.g_id=t.g_id AND a.user_id=t.user_id AND a.cday=t.cday |
| daily_login_role | cday, group_id, user_id, role_id | a.cday=t.cday AND a.g_id=t.g_id AND a.user_id=t.user_id AND a.role_id=t.role_id |
| order_role | group_id, user_id, role_id | a.g_id=t.g_id AND a.user_id=t.user_id AND a.role_id=t.role_id |
| server_day | group_id, server_id | a.g_id=t.g_id AND a.server_id=t.server_id |

> **关键：** LEFT ANTI JOIN 的 ON 列必须**严格等于 GROUP BY 列**——因为 GROUP BY 定义了该表中的唯一性边界，ANTI JOIN 按同样边界去重。

#### INSERT 无 min(id) 但需要去重的场景

有些 INSERT 不属于 min(id) 模式，但如果需要"首次插入"语义，也需要 LEFT ANTI JOIN：

```sql
-- 带聚合子查询的 INSERT（如 daily_paying_user）
INSERT INTO etl.daily_paying_user(cday, group_id, source, user_id, amount)
SELECT
    a.import_day, a.group_id, a.source, a.user_id, cast(sum(a.amount) as int)
FROM (
    SELECT ... FROM app_db.order ...
) a
LEFT ANTI JOIN etl.daily_paying_user t
ON a.import_day = t.cday
    AND a.group_id = t.group_id
    AND a.user_id = t.user_id
GROUP BY a.import_day, a.group_id, a.source, a.user_id
```

> **不是所有 INSERT 都要加 ANTI。** 已经写了 ANTI 还重复插入，说明 ANTI 条件没对齐表唯一键。查表 DDL 把缺少的列补上去。

### 3.11.1 LEFT ANTI JOIN 的替代写法（旧版 Doris 兼容）

如果 Doris 版本 < 1.2 不支持 `LEFT ANTI JOIN`，可用以下两种等价写法替代：

**A. LEFT JOIN ... IS NULL：**

```sql
INSERT INTO dim.daily_login_role (id, cday, group_id, user_id, role_id, ...)
SELECT a.id, a.cday, a.group_id, a.user_id, a.role_id, ...
FROM app_db.role_session a
JOIN (
    SELECT min(id) min_id FROM app_db.role_session
    WHERE id >= {$startId} AND id <= {$endId}
    GROUP BY cday, group_id, user_id, role_id
) b ON a.id = b.min_id
LEFT JOIN dim.daily_login_role t
    ON a.group_id = t.group_id
    AND a.user_id = t.user_id
    AND a.role_id = t.role_id
    AND a.cday = t.cday
WHERE a.id >= {$startId} AND a.id <= {$endId}
  AND t.id IS NULL          -- 必须用目标表主键（非 NULL 列）判断
```

**B. NOT EXISTS：**

```sql
INSERT INTO dim.daily_login_role (id, cday, group_id, user_id, role_id, ...)
SELECT a.id, a.cday, a.group_id, a.user_id, a.role_id, ...
FROM app_db.role_session a
JOIN (
    SELECT min(id) min_id FROM app_db.role_session
    WHERE id >= {$startId} AND id <= {$endId}
    GROUP BY cday, group_id, user_id, role_id
) b ON a.id = b.min_id
WHERE a.id >= {$startId} AND a.id <= {$endId}
  AND NOT EXISTS (
      SELECT 1 FROM dim.daily_login_role t
      WHERE t.group_id = a.group_id
        AND t.user_id = a.user_id
        AND t.role_id = a.role_id
        AND t.cday = a.cday
  )
```

**优先级：** Doris 1.2+ 用 `LEFT ANTI JOIN`（最快）；旧版才用 LEFT JOIN/NOT EXISTS 兼容。

### 3.12 完整 INSERT 结构模板（最常用）

```sql
INSERT INTO target_table (col1, col2, ...)
SELECT
    a.col1,
    a.col2,
    ...                          -- 值全部来自 a（主表）
FROM source_table a
JOIN (
    SELECT min(id) min_id
    FROM source_table
    WHERE id >= {$startId} and id <= {$endId}
    GROUP BY key1, key2, ...     -- 表唯一键
) b ON a.id = b.min_id
LEFT ANTI JOIN target_table t
ON a.key1 = t.key1               -- 与 GROUP BY 对齐
    AND a.key2 = t.key2
    AND ...
WHERE a.id >= {$startId} AND a.id <= {$endId}
```

**要点速记：**
- 主表别名 `a`，子查询别名 `b`，ANTI 别名 `t`
- 子查询里 `min_id`，不用 `id`
- ANTI ON 的列 = GROUP BY 的列
- 原来的 `and b.id >= ...` 改为 `WHERE a.id >= ...`
- 如果原代码多表逗号 JOIN(如 `) a, session b, uniq_user c`)，先按 3.10 转成显式 JOIN 再加 ANTI

---

## ⚠️ 关键陷阱

### 陷阱 1：嵌套函数中的格式字符串（必做两遍替换）

**这是迁移中漏改最多的问题。** 简单 regex 只能匹配最外层 `from_unixtime(x, 'yyyy-MM-dd')`，嵌套版本（多个 `from_unixtime` 套娃）会因为内部逗号导致匹配失败，留下残留的 Java 风格格式串。

**典型残留代码（多次嵌套，外层 regex 改不掉里层）：**
```sql
from_unixtime(unix_timestamp(from_unixtime(unix_timestamp(cast(cday as string),'%Y%m%d'),'yyyy-MM-dd')),'yyyyMM')
```

**强制 checklist —— 必须按顺序做完三步：**

```
✅ Step 1: 全局文本替换（不限于函数内）
   'yyyy' → '%Y'

✅ Step 2: 二次清理（Step 1 会留下中间产物，必须再扫一遍）
   '%YMMddHH'  → '%Y%m%d%H'
   '%YMMdd'    → '%Y%m%d'
   '%YMM'      → '%Y%m'
   '%Y-MM-dd'  → '%Y-%m-%d'
   '%Y-MM'     → '%Y-%m'
   'dd'        → '%d'   (注意：仅当作为日期格式串时；不要误改 PHP 变量等)
   'HH:mm:ss'  → '%H:%i:%s'

✅ Step 3: 验证残留（应全部为空）
   grep -rEn "'%[Yy]?[Mm]"  include/    # 应无输出
   grep -rEn "'yyyy"        include/    # 应无输出
   grep -rEn "'dd'"         include/    # 仅 'dd' 当格式串残留
```

**为什么 Step 2 必须做：** Step 1 把 `'yyyyMMdd'` 变成 `'%YMMdd'`，但 `MM` 和 `dd` 仍是 Java 风格。Doris 必须用 `%m` 和 `%d`（小写带百分号）。漏掉 Step 2 的 SQL 在 Doris 上 `from_unixtime` / `unix_timestamp` 都返回 NULL，整个表达式失效。

> **观察**：实战中即使 SKILL 写了「再处理残留」，AI 还是会跳过 Step 2。所以这里写成强制 checklist + 自检命令。

### 陷阱 2：隐式类型转换

Doris 的 `cast(string as date)` 需要字符串格式符合要求，而 Impala 更宽容。用 `cast(cday as date)` 处理 YYYYMMDD 格式 int 是安全的。

### 陷阱 3：UPDATE alias 不能省略表名

Doris UPDATE 语法**要求明确写出目标表名**，不能用别名替代。这是最常见的迁移问题。

**错误（Impala 兼容，Doris 不兼容）：**
```sql
update a set a.col=b.col from raw_user a, active_user b where a.id=b.id
```

**正确（Doris）：**
```sql
update raw_user a set a.col=b.col from active_user b where a.id=b.id
```

同时目标表**不能出现在 FROM 子句**中，所以 `raw_user a` 必须从 FROM 中移除。

### 陷阱 4：UPDATE JOIN → FROM + WHERE

当 Impala UPDATE 使用 `from a join b on cond` 模式时，不能直接保留 `join ... on`。需要：
1. 目标表从 FROM 移除
2. 保留的额外表不带 JOIN 关键字
3. ON 条件移到 WHERE 子句

**错误（直接去掉目标表，保留 join）：**
```sql
-- from join 开头是无效语法！
update app_db.order a set ... from join etl.raw_user b on a.id=b.id where ...
```

**正确：**
```sql
update app_db.order a set ... from etl.raw_user b where a.id=b.id and ...
```

### 陷阱 5：子查询中的 WHERE 被误匹配

在查找 UPDATE 的 FROM-WHERE 边界时，如果 FROM 子句中包含子查询且子查询内有 `where` 关键字，简单正则 `from ... where` 的非贪婪匹配会停在子查询内的 WHERE 而非外层 WHERE。

**解决：** 使用括号深度跟踪，只匹配深度为 0 的 WHERE 关键字。

### 陷阱 6：UPDATE 外层的逗号 JOIN 不能转换

逗号 JOIN 转换默认将所有 `from a, b where cond` 转为 `from a join b on cond`，但在 UPDATE 语句中，Doris 的 FROM 子句仍然使用逗号分隔表（配合 WHERE 连接条件），不应转为 JOIN。

**解决：** 跳过 UPDATE 的外层 FROM，仅转换 SELECT / 子查询里的逗号 JOIN。

### 陷阱 7：`DATE_FORMAT` 必须两个参数

`DATE_FORMAT` 在 Doris/MySQL **必须有 2 个参数**，而非 1 个。

**错误写法（自动转换容易踩的坑）：**
```sql
DATEDIFF(DATE_FORMAT(a.cday), DATE_FORMAT(b.cday))
```

**正确写法：**
```sql
DATEDIFF(cast(a.cday as date), cast(b.cday as date))
```

> 原因是 `log.diff(a.cday, b.cday)` 被自动替换为 `DATEDIFF(DATE_FORMAT(a.cday), DATE_FORMAT(b.cday))`，但 `DATE_FORMAT` 不能单参数使用。

### 陷阱 8：`pointId()` 中的 `$db_name` 变量

自动转换 connect.php 时，如果原 Impala 代码写死了库名（如 `etl.t_point`），转换脚本可能替换为 `{$db_name}.t_point`，但 `$db_name` **未定义**。

**错误：**
```php
$sql = "select id from {$db_name}.t_point where table_name=('$pointTable') ";
```

**正确：**
```php
$sql = "select id from {$doris_db}.t_point where table_name=('$pointTable') ";
```

### 陷阱 9：`_query_fetch` 函数被嵌套在 `pointId()` 内部

自动转换往 `connect.php` 追加 `_query_fetch()` 函数时，如果插入位置选在 `pointId()` 函数体之后，但解析 `pointId` 结束位置出错（例如 `pointId` 末尾有多余的空行或缩进不匹配），会导致 `_query_fetch` **被嵌入 `pointId` 内部**。

**后果：**
- `_query_fetch` 只有先调用过 `pointId()` 后才会被 PHP 注册为全局函数
- 业务代码先调 `_query_fetch` 再调 `pointId()` 时 → **致命错误：未定义函数**
- `pointId()` 内也缺少 `global $doris_db`，SQL 拼接出 `select id from .t_point` → 语法错误

**检查方法：**
```bash
# 确认 _query_fetch 不在 pointId 内部（两个函数平级）
# 搜索 "function _query_fetch" 应在 "function pointId" 的闭合 } 之后
```

**正确结构：**
```php
function pointId($pointTable) {
    global $conn, $doris_db;
    // ...
    return $row['id'];
}
// ← _query_fetch 在这里，与 pointId 平级
function _query_fetch($sql) {
    global $conn;
    // ...
    return $rows;
}
```

### 陷阱 10：迁移 min(id) 插入时遗漏 LEFT ANTI JOIN

**这是迁移后最严重的逻辑错误。** 原来的 Impala `upsert into` 在 Doris 中改为 `insert into`，如果没有 LEFT ANTI JOIN，重跑任务会重复插入数据（而非覆盖）。

**检查方法：**
```bash
# 搜所有 min(id)+GROUP BY 的插入, 确认后面有 LEFT ANTI JOIN
grep -rl "min(id)" <TARGET>/include/units/ | xargs grep -L "left anti join"
```

**错误（迁移后少了 ANTI）：**
```sql
-- 该去重但没去重, 重跑会重复插入
INSERT INTO uniq_user(...) SELECT b.*
FROM (SELECT min(id) id ... GROUP BY group_id, user_id) a
JOIN app_db.session b ON a.id = b.id
```

**正确：** 见 §3.11。

### 陷阱 11：ANTI JOIN 键与 GROUP BY 不对齐

ANTI JOIN 的键列数、列序必须**严格等于 GROUP BY 的子句**。少一个列就会漏插多一个列就会误跳过。反例：

```sql
-- GROUP BY group_id, user_id
-- ANTI 写成 a.user_id = t.user_id  -- 缺 group_id, 会漏掉同 user 跨 group 的插入
LEFT ANTI JOIN t ON a.user_id = t.user_id  -- ❌
LEFT ANTI JOIN t ON a.group_id = t.group_id AND a.user_id = t.user_id  -- ✅
```

### 陷阱 12：months_between 参数顺序反转

Doris 没有 `months_between` 函数，必须改用 `timestampdiff(MONTH, ...)`。**两者参数顺序相反**：

```sql
-- Impala months_between(a, b) 返回 a-b
months_between(cmonth, import_month)

-- Doris 必须写成（参数顺序反过来）
timestampdiff(MONTH, import_month, cmonth)
```

如果保持原顺序写成 `timestampdiff(MONTH, cmonth, import_month)`，所有正负号都反了，业务逻辑全部出错。

> 详见 §3.8.1。

### 陷阱 13：date_add 必须显式 interval ... day

Doris 部分版本对 `date_add(x, -N)` 这种纯整数参数支持不稳定，**必须显式写 `interval ... day`**：

```sql
-- ❌
date_add(now(), -1)
date_add(cast(b.cday as date), -7)

-- ✅
date_add(now(), interval -1 day)
date_add(cast(b.cday as date), interval -7 day)
```

> 详见 §3.9.1。

---

## §5 完工自检命令包

**所有迁移完成后必须运行下列命令，输出应全部为空（或仅剩可解释的占位）。** 任何一条非空都意味着有遗漏。

⚠️ 把下方 `<TARGET>` 替换为实际迁移目录（如 `your_project/include/units/`）。

### 5.1 Impala 残留语法

```bash
# 1. UPSERT（应已全部改成 INSERT）
grep -rEn "upsert\s+into" <TARGET> -i

# 2. ThriftSQL / impala-shell / $impala 引用
grep -rEn "ThriftSQL|impala-shell|\\\$impala" <TARGET>

# 3. log.diff (Impala 自定义)
grep -rEn "log\.diff" <TARGET>

# 4. from_timestamp (Impala 专用)
grep -rEn "from_timestamp\(" <TARGET>

# 5. months_between (Impala 专用)
grep -rEn "months_between\(" <TARGET>

# 6. trunc(x, 'DAY/MONTH/YEAR') (Impala 大写单位 / 数值 trunc 除外)
grep -rEn "trunc\([^,]+,\s*'(DAY|MONTH|YEAR|HOUR|MINUTE|SECOND|WEEK)'" <TARGET>
```

### 5.2 日期格式串残留（Java 风格）

```bash
# 必须全部为空
grep -rEn "'yyyy"      <TARGET>
grep -rEn "'%YMM"      <TARGET>
grep -rEn "'%Y-MM"     <TARGET>
grep -rEn "'MM-dd'"    <TARGET>
grep -rEn "'HH:mm"     <TARGET>
grep -rEn "'dd'"       <TARGET>   # 仅指作为格式串残留时
```

### 5.3 Doris 语法不合法的写法

```bash
# 1. date_add 缺 interval ... day
grep -rEn "date_add\([^)]*,\s*-?[\d\$\(]" <TARGET> | grep -v "interval"

# 2. DATE_FORMAT 单参调用（应只有 2 参版本）
grep -rEn "DATE_FORMAT\([^,)]+\)" <TARGET>

# 3. UPDATE 缺 WHERE
grep -rEnB1 "^update\s+\w" <TARGET> | grep -iv "where"   # 人工巡查
```

### 5.4 LEFT ANTI JOIN 漏改（最严重）

```bash
# 所有出现 min(id) 的文件，必须同时出现 left anti join
grep -rln "min(id)" <TARGET> | xargs grep -L "left anti join"
# ↑ 输出非空 = 重跑会重复插入数据
```

### 5.5 connect.php 关键检查

```bash
# 1. _query_fetch 必须与 pointId 平级（不嵌套）
#    人工读 connect.php，确认两个 function 的大括号互不嵌套

# 2. pointId 内部使用 $doris_db 而非 $db_name
grep -n '\$db_name' <TARGET>/connect.php   # 应为空

# 3. UPDATE 前是否设置 partial_update（如有用到部分列更新）
grep -rEn "set enable_unique_key_partial_update" <TARGET>
```

> **强制原则**：每条命令都跑一遍，零输出才算迁移完成。哪怕 SKILL 写得再详细，AI 在长上下文里也会漏改 —— 自检命令是唯一可信的验证手段。

---

## 转换 checklist（按顺序）

1. **connect.php** — 替换为 MySQLi 连接（含 `_query_fetch()`、`querySql()` 含 UPDATE 前 SET partial_update）
2. **include.php** — 移除 ThriftSQL.phar 引用
3. 全局搜索 `upsert into` → `insert into`（注意大小写 UPSERT/Upsert）
4. 全局搜索 `log.diff` → `DATEDIFF(cast(a.cday as date), cast(b.cday as date))`
5. 全局搜索 `$impala->queryAndFetchAll` → `_query_fetch` 或内联 mysqli
6. 全局搜索 `global $impala` → 移除
7. 全局搜索 `from_timestamp` → `date_format`
8. 全局搜索 `'yyyy` → `'%Y`（文本替换，不限于函数内部）
9. **二次清理日期格式串残留**（**容易漏改，必须全部跑一遍**）：
   - `'%YMMddHH'`  → `'%Y%m%d%H'`
   - `'%YMMdd'`    → `'%Y%m%d'`
   - `'%YMM'`      → `'%Y%m'`
   - `'%Y-MM-dd'`  → `'%Y-%m-%d'`
   - `'%Y-MM'`     → `'%Y-%m'`
   - `'dd'`        → `'%d'`（注意只改格式串，避免误伤变量名）
   - `'HH:mm:ss'`  → `'%H:%i:%s'`
10. 全局搜索 `trunc(X, 'UNIT')` → `date_trunc(X, 'unit')`（**注意 GROUP BY / 别名也要改**）
11. 全局搜索 `year(from_unixtime(unix_timestamp(cast(` → `year(cast(X as date))`
12. 全局搜索 `weekofyear(from_unixtime(unix_timestamp(cast(` → `weekofyear(cast(X as date))`
13. 全局搜索 `months_between(a, b)` → `timestampdiff(MONTH, b, a)`（**参数顺序反转**）
14. 全局搜索 `date_add(X, -N)` / `date_add(X, $var)` → `date_add(X, interval -N day)` / `date_add(X, interval $var day)`
15. **逗号 JOIN 转换** → `from a, b where a.id=b.id` 转为 `from a join b on a.id=b.id`
16. **UPDATE 语法修复** → `update alias` → `update table_name alias`，目标表从 FROM 移除
17. 确认所有 UPDATE 都有 WHERE 子句
18. **⭐LEFT ANTI JOIN 去重** → 所有 `min(id) + GROUP BY` 的 INSERT 必须加 `LEFT ANTI JOIN target_table t ON <GROUP BY 列>`（见 §3.11）
19. 确认其他 `INSERT INTO` 如需要去重语义，也加 LEFT ANTI JOIN（见 §3.11 末尾）
20. 全局搜索 `DATE_FORMAT(` → 确认没有单参数调用
21. 检查 `connect.php` 中 `pointId()` 函数的 `$db_name` → `$doris_db`
22. 确认 `connect.php` 中 `_query_fetch()` 与 `pointId` 平级
23. **运行 §5 完工自检命令包**，所有命令应零输出（或仅剩注释中可解释的占位）
