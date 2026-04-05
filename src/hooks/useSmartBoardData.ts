/**
 * Hook for smart board data loading with pagination support
 *
 * Uses smart loading strategy:
 * - todo/inprogress columns: load all issues
 * - done column: load only recent issues (last 14 days by default)
 */

import { api } from "@convex/_generated/api";
import type { Id } from "@convex/_generated/dataModel";
import { useQuery } from "convex/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { EnrichedIssue } from "../../convex/lib/issueHelpers";

// Type for the smart query return data
interface SmartBoardQueryResult {
  issuesByStatus: Record<string, EnrichedIssue[]>;
  workflowStates: {
    id: string;
    name: string;
    category: "todo" | "inprogress" | "done";
    order: number;
  }[];
}

// Type for issue counts data
interface IssueCountsResult {
  byStatus: {
    total: Record<string, number>;
    visible: Record<string, number>;
    hidden: Record<string, number>;
  };
}

/** Type guard to validate EnrichedIssue array structure */
function isEnrichedIssueArray(data: unknown): data is EnrichedIssue[] {
  if (!Array.isArray(data)) return false;
  // Validate first item has required fields (lightweight check)
  if (data.length > 0) {
    const first = data[0];
    return (
      typeof first === "object" &&
      first !== null &&
      "_id" in first &&
      "status" in first &&
      "updatedAt" in first
    );
  }
  return true; // Empty array is valid
}

// Helper to group additional issues by status
function groupAdditionalIssues(additionalIssues: EnrichedIssue[]): Record<string, EnrichedIssue[]> {
  const grouped: Record<string, EnrichedIssue[]> = {};
  for (const issue of additionalIssues) {
    if (!grouped[issue.status]) {
      grouped[issue.status] = [];
    }
    grouped[issue.status].push(issue);
  }
  return grouped;
}

// Helper to merge a specific status group efficiently
function mergeStatusGroup(
  existingIssues: EnrichedIssue[] | undefined,
  newIssues: EnrichedIssue[],
): EnrichedIssue[] {
  const existingIds = new Set((existingIssues || []).map((i) => i._id));
  const uniqueNewIssues: EnrichedIssue[] = [];

  for (const issue of newIssues) {
    if (!existingIds.has(issue._id)) {
      existingIds.add(issue._id);
      uniqueNewIssues.push(issue);
    }
  }

  if (uniqueNewIssues.length === 0) {
    return existingIssues || [];
  }

  return [...(existingIssues || []), ...uniqueNewIssues];
}

export function mergeIssuesByStatus(
  smartIssues: Record<string, EnrichedIssue[]> | undefined,
  additionalIssues: EnrichedIssue[],
) {
  const result: Record<string, EnrichedIssue[]> = {};

  // 1. Start with issues from smart query
  if (smartIssues) {
    for (const [status, issues] of Object.entries(smartIssues)) {
      result[status] = issues;
    }
  }

  // If no additional issues to merge, return early
  if (additionalIssues.length === 0) {
    return result;
  }

  // 2. Group additional issues by status to batch processing
  const additionalByStatus = groupAdditionalIssues(additionalIssues);

  // 3. Merge grouped issues efficiently
  for (const [status, newIssues] of Object.entries(additionalByStatus)) {
    result[status] = mergeStatusGroup(result[status], newIssues);
  }

  return result;
}

export interface UseSmartBoardDataOptions {
  projectId?: Id<"projects">;
  teamId?: Id<"teams">;
  sprintId?: Id<"sprints">;
  doneColumnDays?: number;
}

export interface SmartBoardData {
  issuesByStatus: Record<string, EnrichedIssue[]>;
  statusCounts: Record<
    string,
    {
      total: number;
      loaded: number;
      hidden: number;
    }
  >;
  isLoading: boolean;
  doneStatusesWithMore: string[];
  loadMoreDone: (status: string) => void;
  isLoadingMore: boolean;
  hiddenDoneCount: number;
  workflowStates?: {
    id: string;
    name: string;
    category: "todo" | "inprogress" | "done";
    order: number;
  }[];
}

function calculateStatusCounts(
  countsData: IssueCountsResult | undefined,
  issuesByStatus: Record<string, EnrichedIssue[]>,
) {
  const result: Record<string, { total: number; loaded: number; hidden: number }> = {};

  if (countsData?.byStatus) {
    const { total, visible, hidden } = countsData.byStatus;

    // Get all unique statuses
    const allStatuses = new Set([
      ...Object.keys(total),
      ...Object.keys(visible),
      ...Object.keys(hidden),
    ]);

    for (const status of allStatuses) {
      const totalCount = total[status] || 0;
      const loadedInView = issuesByStatus[status]?.length || 0;
      const hiddenCount = Math.max(0, totalCount - loadedInView);

      result[status] = {
        total: totalCount,
        loaded: loadedInView,
        hidden: hiddenCount,
      };
    }
  }

  return result;
}

function getAllLoadedIssues(
  additionalDoneIssues: EnrichedIssue[],
  smartData?: SmartBoardQueryResult,
) {
  const issues: EnrichedIssue[] = [...additionalDoneIssues];
  if (smartData?.issuesByStatus) {
    for (const statusIssues of Object.values(smartData.issuesByStatus)) {
      issues.push(...(Array.isArray(statusIssues) ? statusIssues : []));
    }
  }
  return issues;
}

function getSmartQueryArgs(
  isTeamMode: boolean,
  isProjectMode: boolean,
  teamId?: Id<"teams">,
  projectId?: Id<"projects">,
  sprintId?: Id<"sprints">,
  doneColumnDays?: number,
) {
  if (isTeamMode && teamId) {
    return { teamId, doneColumnDays };
  }
  if (isProjectMode && projectId) {
    return { projectId, sprintId, doneColumnDays };
  }
  return "skip";
}

function getLoadMoreArgs(
  isTeamMode: boolean,
  loadMoreCursor: { timestamp: number; id: string } | undefined,
  projectId?: Id<"projects">,
  sprintId?: Id<"sprints">,
) {
  if (!isTeamMode && loadMoreCursor !== undefined && projectId) {
    return {
      projectId,
      sprintId,
      beforeTimestamp: loadMoreCursor.timestamp,
      beforeId: loadMoreCursor.id,
      limit: 50,
    };
  }
  return "skip";
}

export function useSmartBoardData({
  projectId,
  teamId,
  sprintId,
  doneColumnDays = 14,
}: UseSmartBoardDataOptions): SmartBoardData {
  const [additionalDoneIssues, setAdditionalDoneIssues] = useState<EnrichedIssue[]>([]);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [loadMoreCursor, setLoadMoreCursor] = useState<
    { timestamp: number; id: string } | undefined
  >(undefined);
  const loadingRef = useRef(false);

  // Determine which mode we are in
  const isTeamMode = !!teamId;
  const isProjectMode = !!projectId;

  const queryArgs = getSmartQueryArgs(
    isTeamMode,
    isProjectMode,
    teamId,
    projectId,
    sprintId,
    doneColumnDays,
  );

  // Fetch smart-loaded issues
  const smartData = useQuery(
    isTeamMode ? api.issues.listByTeamSmart : api.issues.listByProjectSmart,
    queryArgs,
  ) as SmartBoardQueryResult | undefined;

  const countsData = useQuery(
    isTeamMode ? api.issues.getTeamIssueCounts : api.issues.getIssueCounts,
    queryArgs,
  ) as IssueCountsResult | undefined;

  const moreDoneData = useQuery(
    api.issues.loadMoreDoneIssues,
    getLoadMoreArgs(isTeamMode, loadMoreCursor, projectId, sprintId),
  );

  // When more done issues arrive, merge them
  useEffect(() => {
    if (moreDoneData && isEnrichedIssueArray(moreDoneData)) {
      setAdditionalDoneIssues((prev) => [...prev, ...moreDoneData]);
      setIsLoadingMore(false);
      loadingRef.current = false;
    }
  }, [moreDoneData]);

  // Reset additional issues when project/sprint changes (Derived State Pattern)
  const currentKey = `${projectId || ""}-${sprintId || ""}-${teamId || ""}`;
  const [prevKey, setPrevKey] = useState(currentKey);

  if (currentKey !== prevKey) {
    setPrevKey(currentKey);
    setAdditionalDoneIssues([]);
    setLoadMoreCursor(undefined);
  }

  // Build issues by status
  const issuesByStatus = useMemo(() => {
    return mergeIssuesByStatus(smartData?.issuesByStatus, additionalDoneIssues);
  }, [smartData, additionalDoneIssues]);

  // Build status counts from countsData.byStatus
  const statusCounts = useMemo(() => {
    return calculateStatusCounts(countsData, issuesByStatus);
  }, [countsData, issuesByStatus]);

  // Find done statuses that have more items to load
  const doneStatusesWithMore = useMemo(() => {
    const result: string[] = [];
    for (const [status, counts] of Object.entries(statusCounts)) {
      if (counts.hidden > 0) {
        result.push(status);
      }
    }
    return result;
  }, [statusCounts]);

  // Calculate total hidden done count from accurate statusCounts
  const hiddenDoneCount = useMemo(() => {
    let total = 0;
    for (const counts of Object.values(statusCounts)) {
      total += counts.hidden;
    }
    return total;
  }, [statusCounts]);

  // Helper for loadMoreDone
  const findOldestIssue = useCallback(() => {
    const allLoadedIssues = getAllLoadedIssues(additionalDoneIssues, smartData);
    if (allLoadedIssues.length === 0) return undefined;

    const oldest = allLoadedIssues.reduce((min: EnrichedIssue, issue: EnrichedIssue) =>
      issue.updatedAt < min.updatedAt ? issue : min,
    );
    return { timestamp: oldest.updatedAt, id: oldest._id.toString() };
  }, [additionalDoneIssues, smartData]);

  const loadMoreDone = useCallback(
    (_status: string) => {
      // Double-check with ref and state to prevent race conditions from rapid clicks
      if (loadingRef.current || isLoadingMore) return;

      loadingRef.current = true;
      setIsLoadingMore(true);
      setLoadMoreCursor(findOldestIssue());
    },
    [isLoadingMore, findOldestIssue],
  );

  return {
    issuesByStatus,
    statusCounts,
    isLoading: smartData === undefined || countsData === undefined,
    doneStatusesWithMore,
    loadMoreDone,
    isLoadingMore,
    hiddenDoneCount,
    workflowStates: smartData?.workflowStates,
  };
}