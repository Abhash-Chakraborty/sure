# Provider integration guidance

Read [architecture](architecture.md) for provider concepts, runtime registry
selection and `Provided` concerns. For a new securities price provider, follow
[the complete workflow](adding-a-securities-provider.md), including response
types, MIC mapping, currency handling, settings encryption, UI, locales and tests.

## Provider logos

A provider's logo comes from [`ProviderLogo`](../../app/components/provider_logo.rb): the
Brandfetch icon for the `domain` in its
[`Provider::Metadata::REGISTRY`](../../app/models/provider/metadata.rb) entry, falling back
to `logo_icon`, then `logo_text` initials on `logo_color`. Anything identifying a provider
renders `render ProviderLogo.new(provider_key: :<x>)` — the `_<x>_item` card on Accounts,
the Bank Sync cards and connection rows, and the connection rows in
`settings/providers/_<x>_panel` — rather than a hand-built badge or the first letter of a
connection name. A panel's setup form and instructions carry no logo.

Give each new provider a registry entry with a brand domain. Only a provider with no single
brand behind it omits the domain and sets `logo_icon` instead.
Institution logos are a separate concept and belong on accounts through
`Account#logo_url`, never on a provider.

## Support diagnostics

When a provider sync/import path encounters a recoverable error, suspicious partial
response or other support-relevant incident, prefer
[`DebugLogEntry.capture`](../../app/models/debug_log_entry.rb) over `Rails.logger.*`
so operators can inspect it in the super-admin `/settings/debug` UI.

- Include `category`, `level`, `message`, `source`, `provider_key` and useful
  structured `metadata`.
- Attach `family` and `account_provider` whenever available so support can filter
  and trace the affected connection. Account/user associations can add context.
- Reserve raw Rails logging for low-value local noise; incidents operators need
  to investigate belong in the debug log.

## Pending transactions and FX metadata

Store provider metadata on `Transaction#extra` under the provider namespace.
[`import_transaction`](../../app/models/account/provider_import_adapter.rb) deep-merges
that hash, so a key the provider stops sending keeps its previous value. A provider
that owns its namespace outright passes `replace_extra_namespaces: ["<key>"]`. When the
incoming payload includes that namespace, the existing namespace is replaced, so omitted
nested fields are removed. Send the provider's current namespace snapshot on every sync.
[`Transaction#pending?` and pending scopes](../../app/models/transaction.rb) share
`PENDING_PROVIDERS`, the list of namespaces whose `pending` flag counts. It is empty
in this fork; a provider that reports pending state adds its namespace there. The
UI shows a Pending badge when `transaction.pending?` is true. A provider that
supplies no pending metadata produces no badge; manual/CSV imports have no pending
concept.

## Exchange rate providers

Exchange rate providers include
[`Provider::ExchangeRateConcept`](../../app/models/provider/exchange_rate_concept.rb),
which validates their responses: a rate that `ExchangeRate.valid_rate?` rejects
(zero, negative, NaN, infinite or missing) turns a single lookup into a failed
response and is dropped from a series, with a `DebugLogEntry` in the
`exchange_rates` category. Providers do not need their own check. A database
constraint on `exchange_rates.rate` rejects anything that still gets through.

## Transaction naming

Where a provider supplies both a cleaned merchant name and the bank's own
description, combine them (`"#{merchant} - #{description}"`) rather than choosing
one. The merchant name alone collapses distinct transactions into one name, and
[rules](../../app/models/rule/condition.rb) match on `transaction_name`, so the
collapse removes the only signal that could separate them. Merchant records are
built from the cleaned name on a separate path, so grouping is unaffected.

Changing a name that rules already target has a cost: a `like` rule written
against the merchant name still matches the combined form, but an `=` rule would
stop matching and a `!=` rule would start matching what it was written to exclude.
