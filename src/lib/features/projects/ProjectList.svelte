<script lang="ts">
  import type { ProjectDto } from '../../contracts/projects';
  import ProjectRow from './ProjectRow.svelte';

  interface Props {
    projects: readonly ProjectDto[];
    busy?: boolean;
    onEdit: (project: ProjectDto) => void;
    onArchive: (project: ProjectDto) => void;
  }

  let { projects, busy = false, onEdit, onArchive }: Props = $props();
</script>

<ul class="project-list" aria-label="项目列表">
  {#each projects as project (project.id)}
    <ProjectRow {project} {busy} {onEdit} {onArchive} />
  {/each}
</ul>

<style>
  .project-list {
    margin: 0;
    padding: 0;
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    box-shadow: var(--shadow-card);
    list-style: none;
    overflow: hidden;
  }
</style>
