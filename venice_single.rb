#!/usr/bin/env ruby
# frozen_string_literal: true

# Venice - iTunes In-App Purchase Receipt Verification
# All logic consolidated into a single file
#
# This file contains all the Venice gem logic consolidated from multiple files:
# - lib/venice/version.rb
# - lib/venice/environment.rb
# - lib/venice/client.rb
# - lib/venice/in_app_receipt.rb
# - lib/venice/pending_renewal_info.rb
# - lib/venice/receipt.rb
#
# Usage:
#   require './venice_single'
#
#   data = '(Base64-Encoded Receipt Data)'
#   if receipt = Venice::Receipt.verify(data)
#     p receipt.to_h
#   end

require 'json'
require 'net/https'
require 'uri'
require 'time'

module Venice
  VERSION = '0.6.0'

  # Environment class defines production and development endpoints
  class Environment < Struct.new(:name, :endpoint)
    PRODUCTION = new('production', 'https://buy.itunes.apple.com/verifyReceipt')
    DEVELOPMENT = new('development', 'https://sandbox.itunes.apple.com/verifyReceipt')
  end

  # Client handles verification requests to Apple's servers
  class Client
    attr_accessor :verification_url, :environment
    attr_writer :shared_secret
    attr_writer :exclude_old_transactions

    class << self
      def development
        client = new
        client.verification_url = Environment::DEVELOPMENT.endpoint
        client.environment = Environment::DEVELOPMENT.name
        client
      end

      def production
        client = new
        client.verification_url = Environment::PRODUCTION.endpoint
        client.environment = Environment::PRODUCTION.name
        client
      end
    end

    def initialize
      @verification_url = ENV['IAP_VERIFICATION_ENDPOINT']
      @environment = ENV['IAP_VERIFICATION_ENVIRONMENT']
    end

    def verify!(data, options = {})
      @verification_url ||= Environment::DEVELOPMENT.endpoint
      @environment ||= Environment::DEVELOPMENT.name
      @shared_secret = options[:shared_secret] if options[:shared_secret]
      @exclude_old_transactions = options[:exclude_old_transactions] if options[:exclude_old_transactions]

      json = json_response_from_verifying_data(data, options)
      json['environment'] = environment if json

      case json['status'].to_i
      when 0, 21006
        Receipt.new(json)
      else
        raise Receipt::VerificationError, json
      end
    end

    private

    def json_response_from_verifying_data(data, options = {})
      parameters = {
        'receipt-data' => data
      }

      parameters['password'] = @shared_secret if @shared_secret
      parameters['exclude-old-transactions'] = @exclude_old_transactions if @exclude_old_transactions

      uri = URI(@verification_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER

      http.open_timeout = options[:open_timeout] if options[:open_timeout]
      http.read_timeout = options[:read_timeout] if options[:read_timeout]

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Accept'] = 'application/json'
      request['Content-Type'] = 'application/json'
      request.body = parameters.to_json

      begin
        response = http.request(request)
      rescue Timeout::Error
        raise TimeoutError
      end

      begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise InvalidResponseError
      end
    end
  end

  class Client::TimeoutError < Timeout::Error
    def message
      'The App Store timed out.'
    end
  end

  class Client::InvalidResponseError < StandardError
    def message
      'The App Store returned invalid response'
    end
  end

  # InAppReceipt represents an in-app purchase receipt
  class InAppReceipt
    # For detailed explanations on these keys/values, see
    # https://developer.apple.com/library/ios/releasenotes/General/ValidateAppStoreReceipt/Chapters/ReceiptFields.html#//apple_ref/doc/uid/TP40010573-CH106-SW12

    # Original JSON data returned from Apple for an InAppReceipt object.
    attr_reader :original_json_data

    # The number of items purchased. This value corresponds to the quantity property of
    # the SKPayment object stored in the transaction's payment property.
    attr_reader :quantity

    # The product identifier of the item that was purchased. This value corresponds to
    # the productIdentifier property of the SKPayment object stored in the transaction's
    # payment property.
    attr_reader :product_id

    # The transaction identifier of the item that was purchased. This value corresponds
    # to the transaction's transactionIdentifier property.
    attr_reader :transaction_id

    # The primary key for identifying subscription purchases. This value is a unique ID that identifies purchase events across devices, including subscription renewal purchase events.
    # When restoring purchase, transaction_id could change
    attr_reader :web_order_line_item_id

    # The date and time this transaction occurred. This value corresponds to the
    # transaction's transactionDate property.
    attr_reader :purchased_at

    # A string that the App Store uses to uniquely identify the application that created
    # the payment transaction. If your server supports multiple applications, you can use
    # this value to differentiate between them. Applications that are executing in the
    # sandbox do not yet have an app-item-id assigned to them, so this key is missing from
    # receipts created by the sandbox.
    attr_reader :app_item_id

    # An arbitrary number that uniquely identifies a revision of your application. This key
    # is missing in receipts created by the sandbox.
    attr_reader :version_external_identifier

    # For a transaction that restores a previous transaction, this is the original receipt
    attr_accessor :original

    # For auto-renewable subscriptions, returns the date the subscription will expire
    attr_reader :expires_at

    # For a transaction that was canceled by Apple customer support, the time and date of the cancellation.
    # For an auto-renewable subscription plan that was upgraded, the time and date of the upgrade transaction.
    attr_reader :cancellation_at

    # Only present for auto-renewable subscription receipts. Value is true if the customer's subscription is
    # currently in the free trial period, false if not, nil if key is not present on receipt.
    attr_reader :is_trial_period
    # Only present for auto-renewable subscription receipts. Value is true if the customer's subscription is
    # currently in an introductory price period, false if not, nil if key is not present on receipt.
    attr_reader :is_in_intro_offer_period

    def initialize(attributes = {})
      @original_json_data = attributes
      @quantity = Integer(attributes['quantity']) if attributes['quantity']
      @product_id = attributes['product_id']
      @transaction_id = attributes['transaction_id']
      @web_order_line_item_id = attributes['web_order_line_item_id']
      @purchased_at = DateTime.parse(attributes['purchase_date']) if attributes['purchase_date']
      @app_item_id = attributes['app_item_id']
      @version_external_identifier = attributes['version_external_identifier']
      @is_trial_period = attributes['is_trial_period'].to_s == 'true' if attributes['is_trial_period']
      @is_in_intro_offer_period = attributes['is_in_intro_offer_period'] == 'true' if attributes['is_in_intro_offer_period']

      # expires_date is in ms since the Epoch, Time.at expects seconds
      if attributes['expires_date_ms']
        @expires_at = Time.at(attributes['expires_date_ms'].to_i / 1000)
      elsif attributes['expires_date'] && is_number?(attributes['expires_date'])
        @expires_at = Time.at(attributes['expires_date'].to_i / 1000)
      end

      # cancellation_date is in ms since the Epoch, Time.at expects seconds
      @cancellation_at = Time.at(attributes['cancellation_date_ms'].to_i / 1000) if attributes['cancellation_date_ms']

      if attributes['original_transaction_id'] || attributes['original_purchase_date']
        original_attributes = {
          'transaction_id' => attributes['original_transaction_id'],
          'purchase_date' => attributes['original_purchase_date']
        }

        self.original = InAppReceipt.new(original_attributes)
      end
    end

    def to_hash
      {
        quantity: @quantity,
        product_id: @product_id,
        transaction_id: @transaction_id,
        web_order_line_item_id: @web_order_line_item_id,
        purchase_date: (@purchased_at.httpdate rescue nil),
        original_transaction_id: (@original.transaction_id rescue nil),
        original_purchase_date: (@original.purchased_at.httpdate rescue nil),
        app_item_id: @app_item_id,
        version_external_identifier: @version_external_identifier,
        is_trial_period: @is_trial_period,
        is_in_intro_offer_period: @is_in_intro_offer_period,
        expires_at: (@expires_at.httpdate rescue nil),
        cancellation_at: (@cancellation_at.httpdate rescue nil)
      }
    end
    alias_method :to_h, :to_hash

    def to_json
      to_hash.to_json
    end

    private

    def is_number?(string)
      !!(string && string.to_s =~ /^[0-9]+$/)
    end
  end

  # PendingRenewalInfo represents pending renewal information for auto-renewable subscriptions
  class PendingRenewalInfo
    # Original JSON data returned from Apple for a PendingRenewalInfo object.
    attr_reader :original_json_data

    # For an expired subscription, the reason for the subscription expiration.
    # This key is only present for a receipt containing an expired auto-renewable subscription.
    attr_reader :expiration_intent

    # The current renewal status for the auto-renewable subscription.
    # This key is only present for auto-renewable subscription receipts, for active or expired subscriptions
    attr_reader :auto_renew_status

    # The current renewal preference for the auto-renewable subscription.
    # The value for this key corresponds to the productIdentifier property of the product that the customer's subscription renews.
    attr_reader :auto_renew_product_id

    # For an expired subscription, whether or not Apple is still attempting to automatically renew the subscription.
    # If the customer's subscription failed to renew because the App Store was unable to complete the transaction, this value will reflect whether or not the App Store is still trying to renew the subscription.
    attr_reader :is_in_billing_retry_period

    # The product identifier of the item that was purchased.
    # This value corresponds to the productIdentifier property of the SKPayment object stored in the transaction's payment property.
    attr_reader :product_id

    # The current price consent status for a subscription price increase
    # This key is only present for auto-renewable subscription receipts if the subscription price was increased without keeping the existing price for active subscribers
    attr_reader :price_consent_status

    # For a transaction that was cancelled, the reason for cancellation.
    # Use this value along with the cancellation date to identify possible issues in your app that may lead customers to contact Apple customer support.
    attr_reader :cancellation_reason

    # The time at which the grace period for subscription renewals expires, in a date-time format similar to the ISO 8601.
    # This key is only present for apps that have Billing Grace Period enabled and when the user experiences a billing error at the time of renewal.
    attr_reader :grace_period_expires_at

    # The transaction identifier of the original purchase.
    attr_reader :original_transaction_id

    def initialize(attributes)
      @original_json_data = attributes
      @expiration_intent = Integer(attributes['expiration_intent']) if attributes['expiration_intent']
      @auto_renew_status = Integer(attributes['auto_renew_status']) if attributes['auto_renew_status']
      @auto_renew_product_id = attributes['auto_renew_product_id']

      if attributes['is_in_billing_retry_period']
        @is_in_billing_retry_period = (attributes['is_in_billing_retry_period'] == '1')
      end

      @product_id = attributes['product_id']

      @price_consent_status = Integer(attributes['price_consent_status']) if attributes['price_consent_status']
      @cancellation_reason = Integer(attributes['cancellation_reason']) if attributes['cancellation_reason']
      @grace_period_expires_at = DateTime.parse(attributes['grace_period_expires_date']) if attributes['grace_period_expires_date']
      @original_transaction_id = attributes['original_transaction_id'] if attributes['original_transaction_id']
    end

    def to_hash
      {
        expiration_intent: @expiration_intent,
        auto_renew_status: @auto_renew_status,
        auto_renew_product_id: @auto_renew_product_id,
        is_in_billing_retry_period: @is_in_billing_retry_period,
        product_id: @product_id,
        price_consent_status: @price_consent_status,
        cancellation_reason: @cancellation_reason,
        grace_period_expires_at: (@grace_period_expires_at.httpdate rescue nil),
        original_transaction_id: @original_transaction_id,
      }
    end

    alias_method :to_h, :to_hash

    def to_json
      to_hash.to_json
    end
  end

  # Receipt represents the complete receipt information from Apple
  class Receipt
    MAX_RE_VERIFY_COUNT = 3

    # For detailed explanations on these keys/values, see
    # https://developer.apple.com/library/ios/releasenotes/General/ValidateAppStoreReceipt/Chapters/ReceiptFields.html#//apple_ref/doc/uid/TP40010573-CH106-SW1

    # The app's bundle identifier.
    attr_reader :bundle_id

    # The app's version number.
    attr_reader :application_version

    # The receipt for an in-app purchase.
    attr_reader :in_app

    # The version of the app that was originally purchased.
    attr_reader :original_application_version

    # The original purchase date
    attr_reader :original_purchase_date

    # The date that the app receipt expires.
    attr_reader :expires_at

    # Non-Documented receipt keys/values
    attr_reader :receipt_type
    attr_reader :adam_id
    attr_reader :download_id
    attr_reader :requested_at
    attr_reader :receipt_created_at
    attr_reader :expiration_intent

    # Original json response from AppStore
    attr_reader :original_json_response

    attr_accessor :latest_receipt_info

    # Information about the status of the customer's auto-renewable subscriptions
    attr_reader :pending_renewal_info

    # The environment on which the receipt has verified against
    attr_reader :environment

    def initialize(original_json_response = {'receipt' => {}})
      attributes = original_json_response['receipt']

      @original_json_response = original_json_response
      @environment = original_json_response['environment']
      @bundle_id = attributes['bundle_id']
      @application_version = attributes['application_version']
      @original_application_version = attributes['original_application_version']
      if attributes['original_purchase_date']
        @original_purchase_date = DateTime.parse(attributes['original_purchase_date'])
      end
      if attributes['expiration_date']
        @expires_at = Time.at(attributes['expiration_date'].to_i / 1000).to_datetime
      end

      @receipt_type = attributes['receipt_type']
      @adam_id = attributes['adam_id']
      @download_id = attributes['download_id']
      @requested_at = DateTime.parse(attributes['request_date']) if attributes['request_date']
      @receipt_created_at = DateTime.parse(attributes['receipt_creation_date']) if attributes['receipt_creation_date']

      @expiration_intent = Integer(original_json_response['expiration_intent']) if original_json_response && original_json_response['expiration_intent']

      @in_app = []
      if attributes['in_app']
        attributes['in_app'].each do |in_app_purchase_attributes|
          @in_app << InAppReceipt.new(in_app_purchase_attributes)
        end
      end

      @pending_renewal_info = []
      if original_json_response && original_json_response['pending_renewal_info']
        original_json_response['pending_renewal_info'].each do |pending_renewal_attributes|
          @pending_renewal_info << PendingRenewalInfo.new(pending_renewal_attributes)
        end
      end

      # From Apple docs:
      # > Only returned for iOS 6 style transaction receipts for auto-renewable subscriptions.
      # > The JSON representation of the receipt for the most recent renewal
      if latest_receipt_info_attributes = original_json_response['latest_receipt_info']
        latest_receipt_info_attributes = [latest_receipt_info_attributes] if latest_receipt_info_attributes.is_a?(Hash)

        # AppStore returns 'latest_receipt_info' even if we use over iOS 6. Besides, its format is an Array.
        if latest_receipt_info_attributes.is_a?(Array)
          @latest_receipt_info = []
          latest_receipt_info_attributes.each do |latest_receipt_info_attribute|
            # latest_receipt_info format is identical with in_app
            @latest_receipt_info << InAppReceipt.new(latest_receipt_info_attribute)
          end
        else
          @latest_receipt_info = latest_receipt_info_attributes
        end
      end
    end

    def development?
      return false unless environment
      env_downcase = environment.downcase
      env_downcase == 'development' || env_downcase == 'sandbox'
    end

    def production?
      return false unless environment
      environment.downcase == 'production'
    end

    def to_hash
      {
        environment: @environment,
        bundle_id: @bundle_id,
        application_version: @application_version,
        original_application_version: @original_application_version,
        original_purchase_date: (@original_purchase_date.httpdate rescue nil),
        expires_at: (@expires_at.httpdate rescue nil),
        receipt_type: @receipt_type,
        adam_id: @adam_id,
        download_id: @download_id,
        requested_at: (@requested_at.httpdate rescue nil),
        receipt_created_at: (@receipt_created_at.httpdate rescue nil),
        in_app: @in_app.map(&:to_h),
        pending_renewal_info: @pending_renewal_info.map(&:to_h),
        latest_receipt_info: @latest_receipt_info
      }
    end
    alias_method :to_h, :to_hash

    def to_json
      to_hash.to_json
    end

    class << self
      def verify(data, options = {})
        verify!(data, options)
      rescue VerificationError, Client::TimeoutError
        false
      end

      def verify!(data, options = {})
        client = Client.production

        retry_count = 0
        begin
          client.verify!(data, options)
        rescue VerificationError => error
          case error.code
          when 21007
            client = Client.development
            retry
          when 21008
            client = Client.production
            retry
          else
            retry_count += 1
            if error.retryable? && retry_count <= MAX_RE_VERIFY_COUNT
              retry
            end

            raise error
          end
        rescue Net::ReadTimeout, Timeout::Error, OpenSSL::SSL::SSLError,
               Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE
          # verifyReceipt is idempotent so we can retry it.
          # Net::Http has retry logic for some idempotent http methods but it verifyReceipt is POST.
          retry_count += 1
          retry if retry_count <= MAX_RE_VERIFY_COUNT
          raise
        end
      end

      alias :validate :verify
      alias :validate! :verify!
    end

    class VerificationError < StandardError
      attr_accessor :json

      def initialize(json)
        @json = json
      end

      def code
        Integer(json['status'])
      end

      def retryable?
        json['is_retryable']
      end

      def message
        case code
        when 21000
          'The App Store could not read the JSON object you provided.'
        when 21002
          'The data in the receipt-data property was malformed.'
        when 21003
          'The receipt could not be authenticated.'
        when 21004
          'The shared secret you provided does not match the shared secret on file for your account.'
        when 21005
          'The receipt server is not currently available.'
        when 21006
          'This receipt is valid but the subscription has expired. When this status code is returned to your server, the receipt data is also decoded and returned as part of the response.'
        when 21007
          'This receipt is a sandbox receipt, but it was sent to the production service for verification.'
        when 21008
          'This receipt is a production receipt, but it was sent to the sandbox service for verification.'
        when 21010
          'This receipt could not be authorized. Treat this the same as if a purchase was never made.'
        when 21100..21199
          'Internal data access error.'
        else
          "Unknown Error: #{code}"
        end
      end
    end
  end
end
