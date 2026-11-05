class Provider
  module Metadata
    # provider_key => { region:, kinds:, maturity:, logo_text:, logo_color:, domain:, name: }
    REGISTRY = {}.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_color: nil }
    end

    # Brandfetch icon URL for the provider's own brand, or nil when the provider
    # has no domain or Brandfetch isn't configured. Unknown brands 404 instead of
    # returning Brandfetch's lettermark, so ProviderLogo keeps its own fallback.
    def self.logo_url(provider_key)
      domain = self.for(provider_key)[:domain]
      Setting.brand_fetch_icon_url(domain, fallback: "404")
    end
  end
end
