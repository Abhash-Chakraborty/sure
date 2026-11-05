class Provider::Registry
  include ActiveModel::Validations

  Error = Class.new(StandardError)

  CONCEPTS = %i[exchange_rates securities llm property_valuations classification]

  validates :concept, inclusion: { in: CONCEPTS }

  class << self
    def for_concept(concept)
      new(concept.to_sym)
    end

    def get_provider(name)
      send(name)
    rescue NoMethodError
      raise Error.new("Provider '#{name}' not found in registry")
    end

    # Resolves the LLM provider for batch/PDF flows, honoring Setting.llm_provider
    # the way chat does: prefer the configured provider, but fall back to whichever
    # one actually has credentials so an install that swaps providers (or has only
    # one configured) keeps working. Returns nil when neither is configured —
    # callers guard on that.
    def preferred_llm_provider
      llm_provider_order.each do |name|
        provider = get_provider(name)
        return provider if provider
      end
      nil
    end

    def llm_provider_order
      Setting.llm_provider == "anthropic" ? %i[anthropic openai] : %i[openai anthropic]
    end

    private
      def stripe
        secret_key = ENV["STRIPE_SECRET_KEY"]
        webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]

        return nil unless secret_key.present? && webhook_secret.present?

        Provider::Stripe.new(secret_key:, webhook_secret:)
      end

      def github
        Provider::Github.new
      end

      def openai
        access_token = ENV["OPENAI_ACCESS_TOKEN"].presence || Setting.openai_access_token

        return nil unless access_token.present?

        uri_base = ENV["OPENAI_URI_BASE"].presence || Setting.openai_uri_base
        model = ENV["OPENAI_MODEL"].presence || Setting.openai_model

        if uri_base.present? && model.blank?
          Rails.logger.error("Custom OpenAI provider configured without a model; please set OPENAI_MODEL or Setting.openai_model")
          return nil
        end

        Provider::Openai.new(access_token, uri_base: uri_base, model: model)
      end

      def anthropic
        access_token = ENV["ANTHROPIC_ACCESS_TOKEN"].presence ||
                       ENV["ANTHROPIC_API_KEY"].presence ||
                       Setting.anthropic_access_token

        return nil unless access_token.present?

        base_url = ENV["ANTHROPIC_BASE_URL"].presence || Setting.anthropic_base_url
        model = ENV["ANTHROPIC_MODEL"].presence || Setting.anthropic_model

        Provider::Anthropic.new(access_token, base_url: base_url, model: model)
      end

      def jev
        api_key = Provider::Jev.api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Jev.new(
          api_key,
          endpoint: Provider::Jev.effective_endpoint,
          model: Provider::Jev.effective_model
        )
      end

      def yahoo_finance
        Provider::YahooFinance.new
      end

      def mfapi
        Provider::Mfapi.new
      end

      def binance_public
        Provider::BinancePublic.new
      end

      def frankfurter
        Provider::Frankfurter.new
      end
  end

  def initialize(concept)
    @concept = concept
    validate!
  end

  def providers
    available_providers.map { |p| self.class.send(p) }.compact
  end

  # Returns the list of provider key names (symbols) registered for this concept.
  def provider_keys
    available_providers
  end

  def get_provider(name)
    provider_method = available_providers.find { |p| p == name.to_sym }

    raise Error.new("Provider '#{name}' not found for concept: #{concept}") unless provider_method.present?

    self.class.send(provider_method)
  end

  private
    attr_reader :concept

    def available_providers
      case concept
      when :exchange_rates
        %i[yahoo_finance frankfurter]
      when :securities
        %i[yahoo_finance mfapi binance_public]
      when :llm
        %i[openai anthropic]
      when :classification
        # Only providers implementing Provider::ClassificationConcept#decide
        # belong here. OpenAI and Anthropic can auto-categorize but cannot
        # answer typed questions, so they stay under :llm — the eval runner
        # builds them by name when benchmarking against Jev.
        %i[jev]
      when :property_valuations
        []
      else
        %i[github openai anthropic]
      end
    end
end
