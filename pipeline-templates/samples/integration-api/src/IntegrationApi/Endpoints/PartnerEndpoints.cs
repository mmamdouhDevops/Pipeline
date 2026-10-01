using IntegrationApi.Partners;
using IntegrationApi.Security;

namespace IntegrationApi.Endpoints;

internal static class PartnerEndpoints
{
    public const int MaxBatch = 500;

    public static IEndpointRouteBuilder MapPartnerEndpoints(this IEndpointRouteBuilder app)
    {
        var v1 = app.MapGroup("/api/v1/partner")
            .WithTags("Partner")
            .AddEndpointFilter<ApiKeyFilter>();

        v1.MapGet("/orders/{id}", async Task<IResult> (string id, IPartnerClient partner, CancellationToken ct) =>
            {
                var order = await partner.GetOrderAsync(id, ct);
                return order is null ? TypedResults.NotFound() : TypedResults.Ok(order);
            })
            .WithName("GetPartnerOrder")
            .WithSummary("Get an order from the partner system")
            .Produces<PartnerOrder>()
            .Produces(StatusCodes.Status404NotFound)
            .Produces(StatusCodes.Status401Unauthorized);

        v1.MapPost("/tasks/sync", async Task<IResult> (TaskSyncRequest request, IPartnerClient partner, CancellationToken ct) =>
            {
                if (request.Tasks is null || request.Tasks.Count == 0)
                {
                    return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["tasks"] = ["At least one task is required."] });
                }
                if (request.Tasks.Count > MaxBatch)
                {
                    return TypedResults.ValidationProblem(new Dictionary<string, string[]> { ["tasks"] = [$"At most {MaxBatch} tasks per call."] });
                }
                return TypedResults.Ok(await partner.SyncTasksAsync(request, ct));
            })
            .WithName("SyncTasksToPartner")
            .WithSummary("Push TaskManager tasks to the partner system")
            .Produces<TaskSyncResult>()
            .ProducesValidationProblem()
            .Produces(StatusCodes.Status401Unauthorized);

        return app;
    }
}
