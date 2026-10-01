using IntegrationApi.Endpoints;
using IntegrationApi.Partners;
using IntegrationApi.Security;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Options;

var builder = WebApplication.CreateBuilder(args);

// ---- configuration: appsettings.json < appsettings.{Env}.json < environment variables (APP_ENV__*)
builder.Services.AddOptions<PartnerOptions>()
    .Bind(builder.Configuration.GetSection(PartnerOptions.Section))
    .ValidateDataAnnotations()
    .ValidateOnStart();
builder.Services.Configure<InboundAuthOptions>(builder.Configuration.GetSection(InboundAuthOptions.Section));

// ---- partner system client
builder.Services.AddHttpClient<IPartnerClient, PartnerClient>((sp, http) =>
{
    var o = sp.GetRequiredService<IOptions<PartnerOptions>>().Value;
    http.BaseAddress = new Uri(o.BaseUrl);
    http.Timeout = TimeSpan.FromSeconds(o.TimeoutSeconds);
    if (!string.IsNullOrEmpty(o.ApiKey))
    {
        http.DefaultRequestHeaders.Add("X-Api-Key", o.ApiKey);
    }
});

// ---- health: /health = process alive, /health/ready = partner reachable
builder.Services.AddHealthChecks()
    .AddCheck<PartnerHealthCheck>("partner", tags: ["ready"]);

builder.Services.AddOpenApi();
builder.Services.AddProblemDetails();
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear();
});

var app = builder.Build();

app.UseForwardedHeaders();
app.UseExceptionHandler();
app.UseStatusCodePages();

app.MapOpenApi();                                   // GET /openapi/v1.json
app.MapHealthChecks("/health", new HealthCheckOptions { Predicate = _ => false });
app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = c => c.Tags.Contains("ready") });

app.MapPartnerEndpoints();

app.Run();

/// <summary>Entry point (public for WebApplicationFactory in the tests).</summary>
public partial class Program;
