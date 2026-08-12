# Spree Square

[![Gem Version](https://img.shields.io/gem/v/spree_square.svg)](https://rubygems.org/gems/spree_square)
[![GitHub Release](https://img.shields.io/github/v/release/amitkssolanki/spree_square)](https://github.com/amitkssolanki/spree_square/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.md)

This is a Square extension for [Spree Commerce](https://spreecommerce.org), an open source e-commerce platform built with Ruby on Rails.

## Installation

1. Add this extension to your Gemfile with this line:

    ```ruby
    bundle add spree_square
    ```

2. Run the install generator

    ```ruby
    bundle exec rails g spree_square:install
    ```

3. Restart your server

  If your server was running, restart it so that it can find the assets properly.

## Connecting to Square

Two ways to authenticate, in order of preference:

### OAuth — "Connect to Square" (recommended)

Lets a store owner connect their own Square account from the Spree admin, without you
hand-generating an access token for them. This is also the auth model Square requires before
an app can be listed on the App Marketplace — personal access tokens are explicitly disallowed
for multi-merchant use.

One-time setup, per environment (sandbox and production each need their own app):

1. Go to the [Square Developer Dashboard](https://developer.squareup.com/apps) and open (or
   create) an Application.
2. On its **OAuth** page, add a redirect URL:
   `https://your-store.example.com/admin/square_oauth/callback` (must be `https` in production;
   `http://localhost:3000/admin/square_oauth/callback` is fine for local dev).
3. Copy the **Application ID** (same value you'd use for `SQUARE_APPLICATION_ID`) and the
   **Application Secret**, and set both in `.env`:

   ```
   SQUARE_APPLICATION_ID=sandbox-sq0idb-...
   SQUARE_APPLICATION_SECRET=sq0csp-...
   ```

4. Recreate (not just restart) the container so the new `.env` values actually load —
   `docker compose up -d web`, not `docker compose restart web`; Compose only re-reads `.env` on
   the former.
5. In the Spree admin, go to **Square Connection** in the sidebar and click **Connect to
   Square**.

Tokens are stored per-store in `SpreeSquare::Credential`, encrypted at rest (Active Record
Encryption — keys generated once via `bin/rails db:encryption:init`, wired up in
`lib/spree_square/engine.rb`, sourced from `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` /
`_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT` in `.env`). `SpreeSquare::Client` refreshes the
access token automatically whenever it's within Square's recommended 7-day renewal window
(tokens expire every 30 days) — no cron job or manual step needed once connected.

### `SQUARE_ACCESS_TOKEN` — direct token (dev/sandbox fallback)

The original single-tenant path: generate a token yourself from the Developer Dashboard and set
`SQUARE_ACCESS_TOKEN` in `.env`. `SpreeSquare::Client` falls back to this automatically for any
store that hasn't connected via OAuth — convenient for local development, but not something
Square allows for real multi-merchant production use.

## Developing

1. Create a dummy app

    ```bash
    bundle update
    bundle exec rake test_app
    ```

2. Add your new code
3. Run tests

    ```bash
    bundle exec rspec
    ```

When testing your applications integration with this extension you may use it's factories.
Simply add this require statement to your spec_helper:

```ruby
require 'spree_square/factories'
```

## Releasing a new version

```shell
bundle exec gem bump -p -t
bundle exec gem release
```

For more options please see [gem-release README](https://github.com/svenfuchs/gem-release)

## Contributing

If you'd like to contribute, please take a look at the
[instructions](CONTRIBUTING.md) for installing dependencies and crafting a good
pull request.
