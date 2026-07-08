# frozen_string_literal: true

require 'monitor'

module Ovh
  class Client
    # Holds the offset between the OVH server clock and the local clock and
    # supplies the signature timestamp. OVH rejects signatures whose timestamp
    # drifts too far, so on a skewed host the offset is measured once (against
    # OVH's /auth/time endpoint) and reused for every signed request.
    #
    # Every access to @delta/@synced goes through a lock so a value written by one
    # thread is visible to the others on runtimes without a global VM lock (JRuby,
    # TruffleRuby), where an unsynchronized read could otherwise sign a request with
    # a stale offset. The lock is a Monitor (reentrant), not a Mutex: {#ensure_synced}
    # holds it while invoking the syncer, and the syncer calls {#synchronize!}, which
    # re-acquires the same lock -- a plain Mutex would deadlock on that re-entry.
    class Clock
      # @param delta [Integer] initial offset in seconds
      # @param syncer [#call, nil] callable that measures and applies the offset;
      #   invoked at most once by {#ensure_synced}
      def initialize(delta: 0, syncer: nil)
        @delta   = delta
        @syncer  = syncer
        @synced  = false
        @monitor = Monitor.new
      end

      # @return [Integer] the OVH-aligned epoch used as the signature timestamp
      def now
        Time.now.to_i + @monitor.synchronize { @delta }
      end

      # @return [Integer] offset in seconds added to the local clock
      def delta
        @monitor.synchronize { @delta }
      end

      def synced?
        @monitor.synchronize { @synced }
      end

      # Record a freshly measured offset and mark the clock synced so lazy
      # synchronization won't run again.
      # @return [Integer] the applied delta
      def synchronize!(delta)
        @monitor.synchronize do
          @delta  = delta
          @synced = true
        end
        delta
      end

      # Run the syncer exactly once. Guarded by the monitor so concurrent first
      # requests trigger a single synchronization; the reentrant lock lets the
      # syncer call {#synchronize!} without deadlocking.
      def ensure_synced
        @monitor.synchronize do
          break if @synced || @syncer.nil?

          @syncer.call
          @synced = true
        end
      end
    end
  end
end
