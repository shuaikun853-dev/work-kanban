/**
 * 项目数据的纯展示格式化（无副作用、无数据库访问）。
 */

const BEIJING_DATE_FORMATTER = new Intl.DateTimeFormat('zh-CN', {
  timeZone: 'Asia/Shanghai',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit'
});

/** 把 UTC RFC3339 时间格式化为北京时间日期（YYYY/MM/DD）；解析失败退化为原文。 */
export function formatBeijingDate(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return '未知时间';
  }

  const timestamp = Date.parse(trimmed);
  if (Number.isNaN(timestamp)) {
    return trimmed;
  }

  try {
    return BEIJING_DATE_FORMATTER.format(new Date(timestamp));
  } catch {
    return trimmed;
  }
}
