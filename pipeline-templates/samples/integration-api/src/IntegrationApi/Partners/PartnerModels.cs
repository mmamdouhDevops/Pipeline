namespace IntegrationApi.Partners;

/// <summary>An order as returned by the partner system.</summary>
public sealed record PartnerOrder(string Id, string Status, decimal Amount, DateTimeOffset UpdatedAt);

/// <summary>A TaskManager task pushed to the partner system.</summary>
public sealed record TaskSyncItem(Guid TaskId, string Title, string Status, DateTimeOffset? DueDate);

/// <summary>Batch of tasks to push.</summary>
public sealed record TaskSyncRequest(IReadOnlyList<TaskSyncItem> Tasks);

/// <summary>Partner answer to a batch push.</summary>
public sealed record TaskSyncResult(int Accepted, int Rejected, string? PartnerBatchId);
