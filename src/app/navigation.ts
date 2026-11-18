/**
 * 应用壳导航定义（唯一导航来源）。
 *
 * 一级导航固定采用 UI-DESIGN-SPEC V1.1 的六个入口，不增加截图未包含的一级导航项。
 * 项目管理与数据库诊断属于设置页内的二级页面（T1-02 任务说明 2.4）。
 */

/** 一级导航页面标识。 */
export type PrimaryPageId =
  | 'overview'
  | 'today'
  | 'upcoming'
  | 'history'
  | 'reports'
  | 'settings';

/** 应用当前可展示的全部页面标识。 */
export type PageId = PrimaryPageId | 'projects' | 'diagnostics';

/** 线性图标名称；图标由 Sidebar 使用内联 SVG 绘制，禁止混用 emoji。 */
export type NavigationIcon = 'overview' | 'today' | 'upcoming' | 'history' | 'reports' | 'settings';

export interface NavigationItem {
  readonly id: PrimaryPageId;
  readonly label: string;
  readonly icon: NavigationIcon;
}

/** 固定一级导航（工作总览为默认首页）。 */
export const PRIMARY_NAVIGATION: readonly NavigationItem[] = [
  { id: 'overview', label: '工作总览', icon: 'overview' },
  { id: 'today', label: '今日工作', icon: 'today' },
  { id: 'upcoming', label: '未来 7 天', icon: 'upcoming' },
  { id: 'history', label: '历史记录', icon: 'history' },
  { id: 'reports', label: '报告', icon: 'reports' },
  { id: 'settings', label: '设置', icon: 'settings' }
];

/**
 * 二级页面归属的一级导航：用于保持侧边栏选中态。
 * `projects` / `diagnostics` 从“设置”进入。
 */
export function activePrimaryPage(page: PageId): PrimaryPageId {
  return page === 'projects' || page === 'diagnostics' ? 'settings' : page;
}
