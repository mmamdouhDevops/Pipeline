using System.Net;
using System.Net.Http.Json;

namespace IntegrationApi.Partners;

/// <summary>Typed client for the partner system.</summary>
public interface IPartnerClient
{
    Task<PartnerOrder?> GetOrderAsync(string id, CancellationToken ct);
    Task<TaskSyncResult> SyncTasksAsync(TaskSyncRequest request, CancellationToken ct);
    Task<bool> PingAsync(CancellationToken ct);
}

internal sealed partial class PartnerClient(HttpClient http, ILogger<PartnerClient> log) : IPartnerClient
{
    public async Task<PartnerOrder?> GetOrderAsync(string id, CancellationToken ct)
    {
        using var res = await http.GetAsync(new Uri($"orders/{Uri.EscapeDataString(id)}", UriKind.Relative), ct);
        if (res.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
        res.EnsureSuccessStatusCode();
        return await res.Content.ReadFromJsonAsync<PartnerOrder>(ct);
    }

    public async Task<TaskSyncResult> SyncTasksAsync(TaskSyncRequest request, CancellationToken ct)
    {
        using var res = await http.PostAsJsonAsync(new Uri("tasks/batch", UriKind.Relative), request, ct);
        res.EnsureSuccessStatusCode();
        var result = await res.Content.ReadFromJsonAsync<TaskSyncResult>(ct)
                     ?? throw new InvalidOperationException("Partner returned an empty body");
        LogSynced(log, result.Accepted, request.Tasks.Count, result.PartnerBatchId);
        return result;
    }

    public async Task<bool> PingAsync(CancellationToken ct)
    {
        try
        {
            using var res = await http.GetAsync(new Uri("health", UriKind.Relative), ct);
            return res.IsSuccessStatusCode;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            LogPingFailed(log, ex);
            return false;
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Synced {Accepted}/{Total} tasks (batch {Batch})")]
    private static partial void LogSynced(ILogger logger, int accepted, int total, string? batch);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Partner health check failed")]
    private static partial void LogPingFailed(ILogger logger, Exception ex);
}
