using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace IntegrationApi.Partners;

internal sealed class PartnerHealthCheck(IPartnerClient partner) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
        => await partner.PingAsync(cancellationToken)
            ? HealthCheckResult.Healthy("Partner reachable")
            : HealthCheckResult.Unhealthy("Partner not reachable");
}
