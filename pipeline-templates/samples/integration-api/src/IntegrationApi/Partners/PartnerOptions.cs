using System.ComponentModel.DataAnnotations;

namespace IntegrationApi.Partners;

/// <summary>Partner system connection, bound from the "Partner" section (per environment).</summary>
public sealed class PartnerOptions
{
    public const string Section = "Partner";

    /// <summary>Base URL of the partner system, e.g. https://partner.example.com/.</summary>
    [Required, Url]
    public string BaseUrl { get; set; } = "http://localhost:9090/";

    /// <summary>Secret – supplied as environment variable Partner__ApiKey (APP_ENV__INTEGRATION_API).</summary>
    public string? ApiKey { get; set; }

    [Range(1, 120)]
    public int TimeoutSeconds { get; set; } = 15;
}
