using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

namespace IntegrationApi.Security;

/// <summary>Keys our callers send as "Authorization: Bearer &lt;key&gt;" or "X-Api-Key: &lt;key&gt;".
/// Supplied per environment as Inbound__ApiKeys__0, Inbound__ApiKeys__1 … (APP_ENV__INTEGRATION_API).
/// When no key is configured (local development) requests are allowed.</summary>
public sealed class InboundAuthOptions
{
    public const string Section = "Inbound";
    public IList<string> ApiKeys { get; } = [];
}

internal sealed class ApiKeyFilter(IOptionsMonitor<InboundAuthOptions> options) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var keys = options.CurrentValue.ApiKeys;
        if (keys.Count == 0)
        {
            return await next(context);
        }

        var headers = context.HttpContext.Request.Headers;
        string? presented = headers["X-Api-Key"].FirstOrDefault();
        var auth = headers.Authorization.FirstOrDefault();
        if (presented is null && auth is not null && auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            presented = auth["Bearer ".Length..].Trim();
        }

        return presented is not null && keys.Any(k => FixedTimeEquals(k, presented))
            ? await next(context)
            : Results.Unauthorized();
    }

    private static bool FixedTimeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));
}
