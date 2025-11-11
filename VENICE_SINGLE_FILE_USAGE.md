# Venice Single File Usage

This document explains how to use the consolidated single-file version of the Venice gem.

## Overview

All the logic from the Venice gem has been extracted into a single Ruby file: `venice_single.rb`

This file contains all the functionality from:
- `lib/venice/version.rb` - Version constant
- `lib/venice/environment.rb` - Environment configuration
- `lib/venice/client.rb` - HTTP client for Apple verification
- `lib/venice/in_app_receipt.rb` - In-app receipt model
- `lib/venice/pending_renewal_info.rb` - Pending renewal information model
- `lib/venice/receipt.rb` - Receipt model and verification logic

## Usage

### Basic Usage

```ruby
# Load the single file
require_relative 'venice_single'

# Verify a receipt
data = '(Base64-Encoded Receipt Data)'
if receipt = TrxnVerification::Receipt.verify(data)
  puts receipt.to_h
  
  # Access receipt properties
  puts "Bundle ID: #{receipt.bundle_id}"
  puts "App Version: #{receipt.application_version}"
  puts "Environment: #{receipt.environment}"
  
  # You can refer to the original JSON response via the Receipt instance
  case receipt.original_json_response['status'].to_i
    when 0     then puts "Valid receipt"
    when 21006 then puts "Receipt valid but subscription expired"
  end
end
```

### Auto-Renewable Subscriptions

```ruby
require_relative 'venice_single'

data = '(Base64-Encoded Receipt Data)'

# You must pass shared secret when verification on Auto-Renewable subscriptions
# To generate a shared secret, go to App Store Connect -> My Apps > (Your app) > In-App Purchases > View or generate a shared secret
opts = { shared_secret: 'your key' }

if receipt = TrxnVerification::Receipt.verify(data, opts)
  # Renewed receipts are added into `latest_receipt_info` array
  puts receipt.latest_receipt_info.map(&:expires_at)
  # => [2016-05-19 20:35:59 +0000, 2016-06-18 20:35:59 +0000, 2016-07-18 20:35:59 +0000]
end
```

### Error Handling

```ruby
require_relative 'venice_single'

data = '(Base64-Encoded Receipt Data)'

begin
  receipt = TrxnVerification::Receipt.verify!(data)
  puts "Receipt verified: #{receipt.bundle_id}"
rescue TrxnVerification::Receipt::VerificationError => e
  puts "Verification failed: #{e.message}"
  puts "Error code: #{e.code}"
rescue TrxnVerification::Client::TimeoutError => e
  puts "Request timed out: #{e.message}"
rescue TrxnVerification::Client::InvalidResponseError => e
  puts "Invalid response: #{e.message}"
end
```

## Available Classes

### TrxnVerification::Receipt
Main class for verifying receipts. 

**Class Methods:**
- `verify(data, options = {})` - Verify receipt, returns false on error
- `verify!(data, options = {})` - Verify receipt, raises exception on error

**Instance Methods:**
- `development?` - Check if receipt is from sandbox/development environment (returns true for both 'development' and 'sandbox', case-insensitive)
- `production?` - Check if receipt is from production environment (case-insensitive)
- `to_hash` / `to_h` - Convert to hash
- `to_json` - Convert to JSON

**Properties:**
- `bundle_id` - App's bundle identifier
- `application_version` - App's version number
- `in_app` - Array of InAppReceipt objects
- `original_application_version` - Original purchased version
- `original_purchase_date` - Original purchase date
- `expires_at` - Expiration date
- `receipt_type` - Receipt type
- `environment` - Verification environment

### TrxnVerification::InAppReceipt
Represents an in-app purchase receipt.

**Properties:**
- `quantity` - Number of items purchased
- `product_id` - Product identifier
- `transaction_id` - Transaction identifier
- `purchased_at` - Purchase date
- `expires_at` - Expiration date (subscriptions)
- `is_trial_period` - Whether in trial period
- `is_in_intro_offer_period` - Whether in intro offer period

### TrxnVerification::PendingRenewalInfo
Information about pending renewals for auto-renewable subscriptions.

**Properties:**
- `auto_renew_status` - Current renewal status
- `auto_renew_product_id` - Product ID for renewal
- `expiration_intent` - Reason for expiration
- `product_id` - Product identifier

### TrxnVerification::Client
HTTP client for communicating with Apple's servers.

**Class Methods:**
- `development` - Create development client
- `production` - Create production client

**Instance Methods:**
- `verify!(data, options = {})` - Verify receipt data

### TrxnVerification::Environment
Contains endpoint URLs for Apple's verification services.

**Constants:**
- `PRODUCTION` - Production environment
- `DEVELOPMENT` - Development (sandbox) environment

## Dependencies

The single file only requires Ruby standard library:
- `json` - JSON parsing
- `net/https` - HTTPS communication
- `uri` - URI parsing
- `time` - Time/DateTime handling

No external gems are required to use `venice_single.rb`.

## Testing

A test script is included at `/tmp/test_single_file.rb` that verifies all functionality:

```bash
ruby /tmp/test_single_file.rb
```

All 54 original specs pass when using the single file.

## Comparison with Original

### Original Structure
```
lib/
├── venice.rb (loader)
└── venice/
    ├── version.rb
    ├── environment.rb
    ├── client.rb
    ├── in_app_receipt.rb
    ├── pending_renewal_info.rb
    └── receipt.rb
```

### Single File Structure
```
venice_single.rb (all logic consolidated)
```

Both provide identical functionality - the single file version just consolidates everything into one file for easier deployment and distribution.
