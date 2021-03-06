# Supercast Ruby Library

[![Maintainability](https://api.codeclimate.com/v1/badges/6397744dd3eebf6205f6/maintainability)](https://codeclimate.com/github/company-z/supercast-api-ruby/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/6397744dd3eebf6205f6/test_coverage)](https://codeclimate.com/github/company-z/supercast-api-ruby/test_coverage)

The Supercast Ruby library provides convenient access to the Supercast API from
applications written in the Ruby language. It includes a pre-defined set of
classes for API resources that initialize themselves dynamically from API
responses.

The library also provides other features. For example:

- Easy configuration path for fast setup and use.
- Helpers for pagination.
- Tracking of "fresh" values in API resources so that partial updates can be executed.
- Built-in mechanisms for the serialization of parameters according to the expectations of Supercast's API.

## Documentation

See the [API docs](http://api.supercast.tech/).

## Installation

You don't need this source code unless you want to modify the gem. If you just
want to use the package, just run:

```sh
gem install supercast
```

If you want to build the gem from source:

```sh
gem build supercast.gemspec
```

### Requirements

- Ruby 2.1+.

### Bundler

If you are installing via bundler, you should be sure to use the https rubygems
source in your Gemfile, as any gems fetched over http could potentially be
compromised in transit and alter the code of gems fetched securely over https:

```ruby
source 'https://rubygems.org'

gem 'rails'
gem 'supercast'
```

## Usage

The library needs to be configured with your channels's client secret which is
available in your Supercast Dashboard. Set `Supercast.api_key` to its
value:

```ruby
require 'supercast'

Supercast.api_key = "123abc..."

# list subscribers
Supercast::Subscriber.list()

# retrieve single episode
Supercast::Episode.retrieve(1)
```

Here are the methods available to use:

#### `Supercast::Channel`

- `Supercast::Channel.save(id, params)` Updates a Channel by ID.

#### `Supercast::Creator`

- `Supercast::Creator.list()` Lists all the Creators on the authenticated Channel.
- `Supercast::Creator.save(id, params)` Updates a Creator by UUID or Email.
- `Supercast::Creator.destroy(id)` Destroys a Creator by UUID or Email.

#### `Supercast::Episode`

- `Supercast::Episode.list()` Lists all the Episodes on the authenticated Channel.
- `Supercast::Episode.create(params)` Create a new Episode on the authenticated Channel.
- `Supercast::Episode.save(id, params)` Updates an Episode by ID.
- `Supercast::Episode.destroy(id)` Destroys an Episode by ID.

#### `Supercast::Feeds`

- `Supercast::Feeds.activate(id)` Activate a the feeds of a subscriber by UUID or Email.
- `Supercast::Feeds.suspend(id)` Activate a the feeds of a subscriber by UUID or Email.
- `Supercast::Feeds.deactivate(id)` Activate a the feeds of a subscriber by UUID or Email.

#### `Supercast::Role`

- `Supercast::Role.list()` Lists all the Roles on the authenticated Channel.
- `Supercast::Role.create(params)` Create a new Role on the authenticated Channel.
- `Supercast::Role.save(id, params)` Updates a Role by ID.
- `Supercast::Role.destroy(id)` Destroys a Role by ID.

#### `Supercast::Subscriber`

- `Supercast::Subscriber.list()` Lists all the Subscribers on the authenticated Channel.
- `Supercast::Subscriber.create(params)` Create a new Subscriber on the authenticated Channel.
- `Supercast::Subscriber.save(id, params)` Updates a Subscriber by UUID or Email.
- `Supercast::Subscriber.destroy(id)` Destroys a Subscriber by UUID or Email.

#### `Supercast::UsageAlert`

- `Supercast::UsageAlert.list()` Lists all the Subscribers on the authenticated Channel.
- `Supercast::UsageAlert.dismiss(params)` Dismiss the Usage Alert.
- `Supercast::UsageAlert.ignore(params)` Ignore further Usage Alerts from this user.
- `Supercast::UsageAlert.suspend(params)` Suspend the user associated with the Usage Alert.

### Configuring a Client

While a default HTTP client is used by default, it's also possible to have the
library use any client supported by [Faraday][faraday] by initializing a
`Supercast::Client` object and giving it a connection:

```ruby
conn = Faraday.new
client = Supercast::Client.new(conn)
episode, resp = client.request do
  Supercast::Episode.retrieve(1)
end
puts resp.data
```

### Configuring a proxy

A proxy can be configured with `Supercast.proxy`:

```ruby
Supercast.proxy = "https://user:pass@example.com:1234"
```

### Configuring an API Version

By default, the library will use the latest API version.
This can be overridden with this global option:

```ruby
Supercast.api_version = 'v2'
```

See versioning in the API reference for more information.

### Configuring CA Bundles

By default, the library will use its own internal bundle of known CA
certificates, but it's possible to configure your own:

```ruby
Supercast.ca_bundle_path = "path/to/ca/bundle"
```

### Configuring Automatic Retries

The library can be configured to automatically retry requests that fail due to
an intermittent network problem:

```ruby
Supercast.max_network_retries = 2
```

[Idempotency keys][idempotency-keys] are added to requests to guarantee that
retries are safe.

### Configuring Timeouts

Open and read timeouts are configurable:

```ruby
Supercast.open_timeout = 30 // in seconds
Supercast.read_timeout = 80
```

Please take care to set conservative read timeouts. Some API requests can take
some time, and a short timeout increases the likelihood of a problem within our
servers.

### Logging

The library can be configured to emit logging that will give you better insight
into what it's doing. The `info` logging level is usually most appropriate for
production use, but `debug` is also available for more verbosity.

There are a few options for enabling it:

1. Set the environment variable `SUPERCAST_LOG` to the value `debug` or `info`:

   ```sh
   $ export SUPERCAST_LOG=info
   ```

2. Set `Supercast.log_level`:

   ```ruby
   Supercast.log_level = Supercast::LEVEL_INFO
   ```

## Development

Run the linter:

```sh
rubocop
```

Update bundled CA certificates from the [Mozilla cURL release][curl]:

```sh
bundle exec rake update_certs
```
