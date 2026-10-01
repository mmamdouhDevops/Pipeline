using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using IntegrationApi.Partners;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;

namespace IntegrationApi.Tests;

public sealed class PartnerEndpointsTests : IClassFixture<PartnerApiFactory>
{
    private readonly PartnerApiFactory _factory;
    private readonly HttpClient _client;

    public PartnerEndpointsTests(PartnerApiFactory factory)
    {
        _factory = factory;
        _factory.Partner.Reset();
        _client = factory.CreateClient();
        _client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", PartnerApiFactory.InboundKey);
    }

    [Fact]
    public async Task Liveness_is_healthy_without_partner()
    {
        var res = await _factory.CreateClient().GetAsync(new Uri("/health", UriKind.Relative));
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
    }

    [Fact]
    public async Task Readiness_reflects_partner_health()
    {
        _factory.Partner.Given(Request.Create().WithPath("/health").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200));
        Assert.Equal(HttpStatusCode.OK, (await _client.GetAsync(new Uri("/health/ready", UriKind.Relative))).StatusCode);

        _factory.Partner.Reset();
        _factory.Partner.Given(Request.Create().WithPath("/health").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(503));
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await _client.GetAsync(new Uri("/health/ready", UriKind.Relative))).StatusCode);
    }

    [Fact]
    public async Task Get_order_forwards_api_key_and_maps_body()
    {
        _factory.Partner.Given(Request.Create().WithPath("/orders/42").WithHeader("X-Api-Key", "partner-secret").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(200).WithBodyAsJson(
                new { id = "42", status = "Shipped", amount = 99.5m, updatedAt = "2026-01-01T10:00:00Z" }));

        var order = await _client.GetFromJsonAsync<PartnerOrder>(new Uri("/api/v1/partner/orders/42", UriKind.Relative));

        Assert.NotNull(order);
        Assert.Equal("Shipped", order.Status);
        Assert.Equal(99.5m, order.Amount);
    }

    [Fact]
    public async Task Unknown_order_returns_404()
    {
        _factory.Partner.Given(Request.Create().WithPath("/orders/missing").UsingGet())
            .RespondWith(Response.Create().WithStatusCode(404));
        var res = await _client.GetAsync(new Uri("/api/v1/partner/orders/missing", UriKind.Relative));
        Assert.Equal(HttpStatusCode.NotFound, res.StatusCode);
    }

    [Fact]
    public async Task Missing_or_wrong_key_is_rejected()
    {
        var anonymous = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized,
            (await anonymous.GetAsync(new Uri("/api/v1/partner/orders/1", UriKind.Relative))).StatusCode);

        anonymous.DefaultRequestHeaders.Add("X-Api-Key", "wrong");
        Assert.Equal(HttpStatusCode.Unauthorized,
            (await anonymous.GetAsync(new Uri("/api/v1/partner/orders/1", UriKind.Relative))).StatusCode);
    }

    [Fact]
    public async Task Sync_validates_and_forwards_batch()
    {
        var empty = await _client.PostAsJsonAsync(new Uri("/api/v1/partner/tasks/sync", UriKind.Relative),
            new TaskSyncRequest([]));
        Assert.Equal(HttpStatusCode.BadRequest, empty.StatusCode);

        _factory.Partner.Given(Request.Create().WithPath("/tasks/batch").UsingPost())
            .RespondWith(Response.Create().WithStatusCode(200).WithBodyAsJson(
                new { accepted = 2, rejected = 0, partnerBatchId = "b-1" }));

        var res = await _client.PostAsJsonAsync(new Uri("/api/v1/partner/tasks/sync", UriKind.Relative), new TaskSyncRequest(
        [
            new TaskSyncItem(Guid.NewGuid(), "Write docs", "Open", null),
            new TaskSyncItem(Guid.NewGuid(), "Ship v1", "Done", DateTimeOffset.UtcNow),
        ]));

        res.EnsureSuccessStatusCode();
        var result = await res.Content.ReadFromJsonAsync<TaskSyncResult>();
        Assert.Equal(2, result!.Accepted);
        Assert.Equal("b-1", result.PartnerBatchId);
    }

    [Fact]
    public async Task OpenApi_document_lists_partner_endpoints()
    {
        var doc = await _client.GetStringAsync(new Uri("/openapi/v1.json", UriKind.Relative));
        Assert.Contains("/api/v1/partner/orders/{id}", doc, StringComparison.Ordinal);
        Assert.Contains("/api/v1/partner/tasks/sync", doc, StringComparison.Ordinal);
    }
}
