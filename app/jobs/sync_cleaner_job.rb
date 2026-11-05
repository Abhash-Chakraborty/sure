class SyncCleanerJob < ApplicationJob
  queue_as :scheduled

  # Sweeps records whose background job died without finalizing them. A hard
  # worker kill (OOM, SIGKILL during deploy) loses in-flight Sidekiq jobs
  # permanently, leaving records wedged in non-terminal statuses. Each sweep is
  # isolated so one failing model doesn't block the others.
  def perform
    sweep("syncs") { Sync.clean }
    sweep("imports") { Import.clean }
    sweep("import_sessions") { ImportSession.clean }
    sweep("family_exports") { FamilyExport.clean }
    sweep("pdf_imports") { PdfImport.clean }
  end

  private
    def sweep(label)
      yield
    rescue => e
      Rails.logger.error("SyncCleanerJob sweep #{label} failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) do |scope|
        scope.set_tags(sweep: label)
      end
    end
end
