# frozen_string_literal: true

module TIMEx
  module Strategies
    # Default strategy: runs the block, then performs a final {#Deadline#check!}
    # so purely CPU-bound work still observes expiry at cooperative points only.
    #
    # @see Base
    class Cooperative < Base

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object] block result after post-check
      # @raise [Expired] when past deadline after the block returns
      def run(deadline)
        result = yield(deadline)
        deadline.check!(strategy: :cooperative)
        result
      end

    end
  end
end

TIMEx::Registry.register(:cooperative, TIMEx::Strategies::Cooperative)
