<script lang="ts">
  import Button from '../../ui/components/Button.svelte';
  import type { ProjectDto } from '../../contracts/projects';
  import { formatBeijingDate } from '../../presentation/projectFormat';

  interface Props {
    project: ProjectDto;
    busy?: boolean;
    onEdit: (project: ProjectDto) => void;
    onArchive: (project: ProjectDto) => void;
  }

  let { project, busy = false, onEdit, onArchive }: Props = $props();
</script>

<li class="project-row" data-project-id={project.id}>
  <div class="project-main">
    <div class="project-title-line">
      <span class="project-name" title={project.name}>{project.name}</span>
      {#if project.isArchived}
        <span class="status-badge">已归档</span>
      {/if}
    </div>
    <p class="project-meta">
      创建于 {formatBeijingDate(project.createdAt)}
      {#if project.isArchived}
        · 归档项目仅用于历史展示
      {/if}
    </p>
  </div>

  <div class="project-actions">
    {#if project.isArchived}
      <span class="archived-hint">不可编辑</span>
    {:else}
      <Button variant="secondary" size="sm" onclick={() => onEdit(project)} disabled={busy}>
        编辑
      </Button>
      <Button variant="danger" size="sm" onclick={() => onArchive(project)} disabled={busy}>
        归档
      </Button>
    {/if}
  </div>
</li>

<style>
  .project-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-4);
    padding: var(--space-3) var(--space-4);
    border-bottom: 1px solid var(--color-divider);
  }

  .project-row:last-child {
    border-bottom: 0;
  }

  .project-row:hover {
    background-color: var(--color-surface-muted);
  }

  .project-main {
    flex: 1 1 auto;
    min-width: 0;
  }

  .project-title-line {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
  }

  .project-name {
    display: -webkit-box;
    min-width: 0;
    overflow: hidden;
    color: var(--color-text-primary);
    font-size: var(--font-size-item-title);
    font-weight: 600;
    line-height: 1.4;
    overflow-wrap: anywhere;
    word-break: break-word;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
  }

  .status-badge {
    flex-shrink: 0;
    padding: 2px 8px;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-pill);
    background-color: var(--color-surface-muted);
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
    font-weight: 600;
  }

  .project-meta {
    margin-top: 2px;
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
  }

  .project-actions {
    display: flex;
    flex-shrink: 0;
    align-items: center;
    gap: var(--space-1);
  }

  .archived-hint {
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
  }

  @media (max-width: 720px) {
    .project-row {
      align-items: flex-start;
    }

    .project-actions {
      flex-direction: column;
      align-items: flex-end;
    }
  }
</style>
