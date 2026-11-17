/**
 * 健康检查数据的展示格式化工具。
 *
 * 只做纯展示转换（不写 localStorage / IndexedDB，不缓存业务状态），
 * 方便 App.svelte 保持可读，也便于后续为这些纯函数补充单元测试。
 */

import type { RuntimeMode } from '../contracts/databaseHealth';

/** 运行模式的中文展示信息。 */
export interface RuntimeModeDescription {
  readonly label: string;
  readonly hint: string;
}

const RUNTIME_MODE_DESCRIPTIONS: Record<RuntimeMode, RuntimeModeDescription> = {
  release: {
    label: '正式便携模式',
    hint: '数据目录跟随 WorkManager.exe 所在目录，应用目录整体移动后自动重新定位。'
  },
  'debug-test': {
    label: '测试隔离模式',
    hint: '数据目录由测试专用环境变量指向的隔离目录，不会写入正式便携目录。'
  }
};

function isRuntimeMode(value: string): value is RuntimeMode {
  return value === 'release' || value === 'debug-test';
}

/**
 * 把后端运行模式转换为中文标签。
 *
 * 对未知模式做防御式展示（不抛异常），便于诊断前后端版本不一致的问题。
 */
export function describeRuntimeMode(mode: string): RuntimeModeDescription {
  if (isRuntimeMode(mode)) {
    return RUNTIME_MODE_DESCRIPTIONS[mode];
  }

  const trimmed = mode.trim();
  return {
    label: trimmed.length > 0 ? `未知模式（${trimmed}）` : '未知模式',
    hint: '后端返回了前端未识别的运行模式，请核对前后端版本是否一致。'
  };
}

const BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB'] as const;

/** 把字节数格式化为 B / KB / MB / GB / TB；非法输入返回“未知”。 */
export function formatByteSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return bytes === 0 ? '0 B' : '未知';
  }

  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < BYTE_UNITS.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  if (unitIndex === 0) {
    return `${value} B`;
  }

  const digits = value >= 100 ? 0 : 1;
  return `${value.toFixed(digits)} ${BYTE_UNITS[unitIndex]}`;
}

/**
 * 业务时区固定为 Asia/Shanghai：把 UTC RFC3339 时间格式化为北京时间展示。
 *
 * 解析失败时退化为原始字符串，绝不因为时间戳格式问题让页面渲染失败。
 */
const BEIJING_TIME_FORMATTER = new Intl.DateTimeFormat('zh-CN', {
  timeZone: 'Asia/Shanghai',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false
});

export function formatBeijingTime(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return '未知';
  }

  const timestamp = Date.parse(trimmed);
  if (Number.isNaN(timestamp)) {
    return trimmed;
  }

  try {
    return BEIJING_TIME_FORMATTER.format(new Date(timestamp));
  } catch {
    return trimmed;
  }
}
