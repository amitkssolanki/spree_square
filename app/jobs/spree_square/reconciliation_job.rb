module SpreeSquare
  # Deprecating shim (plan step 18): the real job moved to
  # SpreePos::ReconciliationJob (zero-argument, same behavior). Kept so any
  # code still enqueuing `SpreeSquare::ReconciliationJob` by name keeps
  # working unchanged — spree_host's config/recurring.yml has been
  # repointed at SpreePos::ReconciliationJob directly as part of this same
  # step, so nothing currently enqueues this shim, but it is kept in case
  # anything else still refers to the old class name.
  class ReconciliationJob < BaseJob
    def perform = SpreePos::ReconciliationJob.perform_now
  end
end
