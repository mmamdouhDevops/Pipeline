using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using WireMock.Server;

namespace IntegrationApi.Tests;

/// <summary>Starts the API in memory and points it at a WireMock "partner system".</summary>
public sealed class PartnerApiFactory : WebApplicationFactory<Program>
{
    public const string InboundKey = "test-inbound-key";
    public WireMockServer Partner { get; } = WireMockServer.Start();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("Partner:BaseUrl", Partner.Url + "/");
        builder.UseSetting("Partner:ApiKey", "partner-secret");
        builder.UseSetting("Partner:TimeoutSeconds", "5");
        builder.UseSetting("Inbound:ApiKeys:0", InboundKey);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            Partner.Stop();
            Partner.Dispose();
        }
        base.Dispose(disposing);
    }
}
