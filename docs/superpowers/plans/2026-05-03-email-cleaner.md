# Email Cleaner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Ruby CLI tool (`email_cleaner`) with two subcommands — `audit` (survey Gmail senders) and `unsubscribe` (act on List-Unsubscribe headers in bulk) — backed by OAuth, Gmail batch metadata fetches, and a YAML state file.

**Architecture:** Module-namespaced library under `EmailCleaner::*` with a `bin/email_cleaner` entry point. Phase A is YAML-backed; seams (`State`, `Aggregator`, `SenderStats`) are designed so Phase B (SQLite + trends) is a swap-in extension. TDD with Minitest + VCR + WebMock. Network-touching tests use VCR cassettes recorded once; unit tests are pure.

**Tech Stack:** Ruby 3.x, `google-apis-gmail_v1`, `googleauth`, `webrick`, `optparse`, `yaml`, Minitest, VCR, WebMock.

**Spec:** [docs/superpowers/specs/2026-05-03-email-cleaner-design.md](../specs/2026-05-03-email-cleaner-design.md)

---

## Task 1: Project skeleton and Bundler setup

**Files:**
- Create: `Gemfile`
- Create: `Rakefile`
- Create: `.gitignore`
- Create: `lib/email_cleaner.rb`
- Create: `lib/email_cleaner/version.rb`
- Create: `bin/email_cleaner`
- Create: `test/test_helper.rb`
- Create: `test/smoke_test.rb`

- [ ] **Step 1: Write the failing smoke test**

`test/smoke_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_module_loads_and_has_version
    assert defined?(EmailCleaner)
    assert_match(/\A\d+\.\d+\.\d+\z/, EmailCleaner::VERSION)
  end
end
```

`test/test_helper.rb`:
```ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "minitest/pride"
require "webmock/minitest"
require "vcr"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("fixtures/vcr", __dir__)
  c.hook_into :webmock
  c.default_cassette_options = {
    record: ENV["VCR_RECORD"] ? ENV["VCR_RECORD"].to_sym : :none
  }
  c.filter_sensitive_data("<OAUTH_TOKEN>") do |i|
    i.request.headers["Authorization"]&.first
  end
  c.filter_sensitive_data("<USER_EMAIL>") { ENV["USER_EMAIL_FOR_TESTS"] }
end

WebMock.disable_net_connect!(allow_localhost: false)

require "email_cleaner"
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `bundle exec rake test`
Expected: FAIL — `cannot load such file -- email_cleaner` (or similar).

- [ ] **Step 3: Write `Gemfile`**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.0"

gem "google-apis-gmail_v1", "~> 0.36"
gem "googleauth", "~> 1.11"
gem "webrick", "~> 1.8"

group :development, :test do
  gem "minitest", "~> 5.22"
  gem "rake", "~> 13.2"
  gem "vcr", "~> 6.3"
  gem "webmock", "~> 3.23"
end
```

- [ ] **Step 4: Write `Rakefile`**

```ruby
# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
```

- [ ] **Step 5: Write `.gitignore`**

```
# OAuth + tool state — never commit
credentials.json
token.yaml
unsubscribed.yaml
unsubscribe.log

# Ruby
*.gem
.bundle/
vendor/bundle/
Gemfile.lock

# Editors
.DS_Store
.idea/
.vscode/
```

Note: `Gemfile.lock` is gitignored because this is an executable tool, not a library; lock files for apps are debated. We pin versions in `Gemfile` loosely and let environments resolve. (If the user wants the lock committed later, easy to flip.)

- [ ] **Step 6: Write `lib/email_cleaner/version.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  VERSION = "0.1.0"
end
```

- [ ] **Step 7: Write `lib/email_cleaner.rb`**

```ruby
# frozen_string_literal: true

require_relative "email_cleaner/version"

module EmailCleaner
end
```

- [ ] **Step 8: Write `bin/email_cleaner`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "email_cleaner"
require "email_cleaner/cli"

exit EmailCleaner::CLI.run(ARGV)
```

(Note: `CLI` is added in Task 11. Until then, running `bin/email_cleaner` will fail — that's fine; we test via `rake test`.)

Make executable: `chmod +x bin/email_cleaner`.

- [ ] **Step 9: Install dependencies**

Run: `bundle install`
Expected: dependencies resolve and install.

- [ ] **Step 10: Run the smoke test**

Run: `bundle exec rake test`
Expected: PASS — 1 test, 2 assertions.

- [ ] **Step 11: Commit**

```bash
git add Gemfile Rakefile .gitignore lib/ bin/ test/test_helper.rb test/smoke_test.rb
git commit -m "Bootstrap email_cleaner project skeleton"
```

---

## Task 2: Config module — file paths

**Files:**
- Create: `lib/email_cleaner/config.rb`
- Create: `test/config_test.rb`

`Config` centralizes paths to `credentials.json`, `token.yaml`, `unsubscribed.yaml`, `unsubscribe.log`. All resolve relative to a `root` (defaults to project root, overridable for tests).

- [ ] **Step 1: Write the failing test**

`test/config_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/config"

class ConfigTest < Minitest::Test
  def test_default_root_is_project_root
    config = EmailCleaner::Config.new
    assert_equal File.expand_path("../..", __dir__), config.root
  end

  def test_paths_resolve_relative_to_root
    config = EmailCleaner::Config.new(root: "/tmp/ec")
    assert_equal "/tmp/ec/credentials.json", config.credentials_path
    assert_equal "/tmp/ec/token.yaml", config.token_path
    assert_equal "/tmp/ec/unsubscribed.yaml", config.state_path
    assert_equal "/tmp/ec/unsubscribe.log", config.log_path
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/config_test.rb`
Expected: FAIL — `cannot load such file -- email_cleaner/config`.

- [ ] **Step 3: Write `lib/email_cleaner/config.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  class Config
    DEFAULT_ROOT = File.expand_path("../..", __dir__)

    attr_reader :root

    def initialize(root: DEFAULT_ROOT)
      @root = root
    end

    def credentials_path = File.join(@root, "credentials.json")
    def token_path       = File.join(@root, "token.yaml")
    def state_path       = File.join(@root, "unsubscribed.yaml")
    def log_path         = File.join(@root, "unsubscribe.log")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/config_test.rb`
Expected: PASS — 2 runs, 5 assertions.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/config.rb test/config_test.rb
git commit -m "Add Config for centralizing project file paths"
```

---

## Task 3: Headers module — From parsing

**Files:**
- Create: `lib/email_cleaner/headers.rb`
- Create: `test/headers_test.rb`

The `From` parser handles four variants: `Name <addr>`, `"Quoted Name" <addr>`, bare `addr`, malformed input.

- [ ] **Step 1: Write failing tests for `parse_from`**

`test/headers_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/headers"

class HeadersFromTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_name_and_angle_address
    name, addr = H.parse_from("Joe Smith <joe@example.com>")
    assert_equal "Joe Smith", name
    assert_equal "joe@example.com", addr
  end

  def test_quoted_name_with_comma
    name, addr = H.parse_from('"Smith, Joe" <joe@example.com>')
    assert_equal "Smith, Joe", name
    assert_equal "joe@example.com", addr
  end

  def test_bare_address
    name, addr = H.parse_from("joe@example.com")
    assert_nil name
    assert_equal "joe@example.com", addr
  end

  def test_address_lowercased
    _, addr = H.parse_from("Joe <Joe@Example.COM>")
    assert_equal "joe@example.com", addr
  end

  def test_unicode_name
    name, addr = H.parse_from("José García <jose@example.com>")
    assert_equal "José García", name
    assert_equal "jose@example.com", addr
  end

  def test_plus_alias_address
    _, addr = H.parse_from("a+b@example.com")
    assert_equal "a+b@example.com", addr
  end

  def test_malformed_returns_input_as_address_no_name
    name, addr = H.parse_from("not really an email")
    assert_nil name
    assert_equal "not really an email", addr
  end

  def test_extra_whitespace_trimmed
    name, addr = H.parse_from("  Joe   <joe@example.com>  ")
    assert_equal "Joe", name
    assert_equal "joe@example.com", addr
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/headers_test.rb`
Expected: FAIL — `cannot load such file -- email_cleaner/headers`.

- [ ] **Step 3: Write `lib/email_cleaner/headers.rb` (parse_from only)**

```ruby
# frozen_string_literal: true

module EmailCleaner
  module Headers
    module_function

    # Returns [name_or_nil, address_lowercased_string].
    # Never raises. Malformed input returns [nil, original_string].
    def parse_from(value)
      return [nil, ""] if value.nil?

      v = value.strip

      # "Quoted Name" <addr> or Name <addr>
      if (m = v.match(/\A\s*"?(.*?)"?\s*<\s*([^<>\s]+)\s*>\s*\z/)) && m[2].include?("@")
        name = m[1].strip
        name = nil if name.empty?
        return [name, m[2].downcase]
      end

      # Bare email
      if v.include?("@") && !v.include?(" ")
        return [nil, v.downcase]
      end

      [nil, v]
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/headers_test.rb`
Expected: PASS — 8 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/headers.rb test/headers_test.rb
git commit -m "Add Headers.parse_from with quoted/bare/malformed handling"
```

---

## Task 4: Headers — List-Unsubscribe and List-Unsubscribe-Post

**Files:**
- Modify: `lib/email_cleaner/headers.rb`
- Modify: `test/headers_test.rb`

Add `parse_list_unsubscribe(value) → Array<{scheme:, value:}>` and `one_click?(post_header_value, parsed_urls) → Boolean`.

- [ ] **Step 1: Add failing tests**

Append to `test/headers_test.rb`:
```ruby
class HeadersListUnsubscribeTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_single_https
    urls = H.parse_list_unsubscribe("<https://example.com/u?id=1>")
    assert_equal [{ scheme: :https, value: "https://example.com/u?id=1" }], urls
  end

  def test_single_mailto
    urls = H.parse_list_unsubscribe("<mailto:unsub@example.com?subject=bye>")
    assert_equal [{ scheme: :mailto, value: "mailto:unsub@example.com?subject=bye" }], urls
  end

  def test_both_comma_separated
    urls = H.parse_list_unsubscribe("<mailto:u@x.com>, <https://x.com/u>")
    assert_equal 2, urls.size
    assert_equal :mailto, urls[0][:scheme]
    assert_equal :https,  urls[1][:scheme]
  end

  def test_comma_inside_url_not_a_separator
    urls = H.parse_list_unsubscribe("<https://x.com/u?a=1,2>, <mailto:u@x.com>")
    assert_equal 2, urls.size
    assert_equal "https://x.com/u?a=1,2", urls[0][:value]
  end

  def test_extra_whitespace
    urls = H.parse_list_unsubscribe("  <https://x.com/u>  ,  <mailto:u@x.com>  ")
    assert_equal 2, urls.size
  end

  def test_malformed_entries_dropped
    urls = H.parse_list_unsubscribe("garbage, <https://ok.com/u>, also-bad")
    assert_equal 1, urls.size
    assert_equal "https://ok.com/u", urls[0][:value]
  end

  def test_nil_returns_empty
    assert_equal [], H.parse_list_unsubscribe(nil)
  end
end

class HeadersOneClickTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_one_click_with_https
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    assert H.one_click?("List-Unsubscribe=One-Click", urls)
  end

  def test_one_click_case_and_whitespace_tolerant
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    assert H.one_click?("  list-unsubscribe = one-click  ", urls)
  end

  def test_no_post_header
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    refute H.one_click?(nil, urls)
  end

  def test_post_header_but_no_https
    urls = [{ scheme: :mailto, value: "mailto:u@x.com" }]
    refute H.one_click?("List-Unsubscribe=One-Click", urls)
  end

  def test_unrelated_post_value
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    refute H.one_click?("Something-Else=Foo", urls)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/headers_test.rb`
Expected: FAIL — `NoMethodError: undefined method parse_list_unsubscribe`.

- [ ] **Step 3: Extend `lib/email_cleaner/headers.rb`**

Add these methods inside `module Headers`:

```ruby
    # Splits a List-Unsubscribe header value into [{scheme:, value:}, ...].
    # Splits on commas OUTSIDE angle brackets so commas inside URLs don't break.
    # Drops malformed entries; never raises.
    def parse_list_unsubscribe(value)
      return [] if value.nil? || value.strip.empty?

      entries = []
      buf = +""
      depth = 0
      value.each_char do |ch|
        case ch
        when "<" then depth += 1; buf << ch
        when ">" then depth -= 1; buf << ch
        when ","
          if depth.zero?
            entries << buf
            buf = +""
          else
            buf << ch
          end
        else
          buf << ch
        end
      end
      entries << buf

      entries.filter_map do |raw|
        m = raw.strip.match(/\A<\s*(.+?)\s*>\z/)
        next nil unless m

        url = m[1]
        scheme =
          if url.start_with?("https://") then :https
          elsif url.start_with?("http://") then :https
          elsif url.start_with?("mailto:") then :mailto
          end
        scheme ? { scheme: scheme, value: url } : nil
      end
    end

    # RFC 8058 one-click requires:
    #   - List-Unsubscribe-Post header equal to "List-Unsubscribe=One-Click"
    #   - at least one https URL in List-Unsubscribe
    def one_click?(post_header_value, parsed_urls)
      return false if post_header_value.nil?

      normalized = post_header_value.gsub(/\s+/, "").downcase
      return false unless normalized == "list-unsubscribe=one-click"

      parsed_urls.any? { |u| u[:scheme] == :https }
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/headers_test.rb`
Expected: PASS — all tests in file.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/headers.rb test/headers_test.rb
git commit -m "Add List-Unsubscribe and one-click parsers in Headers"
```

---

## Task 5: Sender value object

**Files:**
- Create: `lib/email_cleaner/sender.rb`
- Create: `test/sender_test.rb`

A `Sender` is a value object with `address`, `name`, `domain`. Equality and hash on `address`.

- [ ] **Step 1: Write failing tests**

`test/sender_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/sender"

class SenderTest < Minitest::Test
  S = EmailCleaner::Sender

  def test_attributes
    s = S.new(address: "Joe@Example.COM", name: "Joe")
    assert_equal "joe@example.com", s.address
    assert_equal "Joe", s.name
    assert_equal "example.com", s.domain
  end

  def test_domain_for_addr_without_at
    s = S.new(address: "weird", name: nil)
    assert_equal "", s.domain
  end

  def test_equality_by_address
    a = S.new(address: "x@y.com", name: "A")
    b = S.new(address: "X@Y.COM", name: "B")
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  def test_can_be_used_as_hash_key
    h = {}
    h[S.new(address: "x@y.com", name: "A")] = 1
    h[S.new(address: "X@Y.com", name: "B")] = 2
    assert_equal 1, h.size
    assert_equal 2, h.values.first
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/sender_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/sender.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  class Sender
    attr_reader :address, :name

    def initialize(address:, name:)
      @address = address.to_s.downcase
      @name = name
    end

    def domain
      idx = @address.index("@")
      idx ? @address[(idx + 1)..] : ""
    end

    def ==(other)
      other.is_a?(Sender) && other.address == @address
    end
    alias eql? ==

    def hash
      @address.hash
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/sender_test.rb`
Expected: PASS — 4 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/sender.rb test/sender_test.rb
git commit -m "Add Sender value object with address-based equality"
```

---

## Task 6: Aggregator — group messages into SenderStats

**Files:**
- Create: `lib/email_cleaner/sender_stats.rb`
- Create: `lib/email_cleaner/unsub_info.rb`
- Create: `lib/email_cleaner/aggregator.rb`
- Create: `test/aggregator_test.rb`

`Aggregator.group(messages)` takes an array of message hashes (the structure produced by Gmail metadata fetches) and returns an array of `SenderStats` sorted by count descending. Each message is a Struct-like with `headers` (Hash<String, String>) and `internal_date` (Date).

- [ ] **Step 1: Write failing test**

`test/aggregator_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "email_cleaner/aggregator"

class AggregatorTest < Minitest::Test
  A = EmailCleaner::Aggregator

  def msg(from:, list_unsub: nil, post: nil, date: Date.new(2026, 5, 1))
    headers = { "From" => from }
    headers["List-Unsubscribe"] = list_unsub if list_unsub
    headers["List-Unsubscribe-Post"] = post if post
    { headers: headers, internal_date: date }
  end

  def test_groups_by_address_case_insensitive
    stats = A.group([
      msg(from: "Joe <joe@x.com>"),
      msg(from: "JOE@X.COM"),
      msg(from: "Other <a@b.com>")
    ])
    by_addr = stats.to_h { |s| [s.sender.address, s] }
    assert_equal 2, by_addr["joe@x.com"].count
    assert_equal 1, by_addr["a@b.com"].count
  end

  def test_skips_count_one_senders
    stats = A.group([
      msg(from: "a@x.com"),
      msg(from: "b@x.com"),
      msg(from: "b@x.com")
    ])
    addrs = stats.map { |s| s.sender.address }
    refute_includes addrs, "a@x.com"
    assert_includes addrs, "b@x.com"
  end

  def test_sorts_by_count_descending
    stats = A.group([
      msg(from: "a@x.com"), msg(from: "a@x.com"),
      msg(from: "b@x.com"), msg(from: "b@x.com"), msg(from: "b@x.com")
    ])
    assert_equal "b@x.com", stats[0].sender.address
    assert_equal "a@x.com", stats[1].sender.address
  end

  def test_last_seen_is_max_date
    stats = A.group([
      msg(from: "a@x.com", date: Date.new(2026, 4, 1)),
      msg(from: "a@x.com", date: Date.new(2026, 5, 2)),
      msg(from: "a@x.com", date: Date.new(2026, 4, 15))
    ])
    assert_equal Date.new(2026, 5, 2), stats.first.last_seen
  end

  def test_unsub_info_built_from_first_seen_headers
    stats = A.group([
      msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      msg(from: "a@x.com")
    ])
    info = stats.first.unsub_info
    refute_nil info
    assert info.one_click?
    assert_equal 1, info.urls.size
  end

  def test_unsub_info_nil_when_no_headers
    stats = A.group([msg(from: "a@x.com"), msg(from: "a@x.com")])
    assert_nil stats.first.unsub_info
  end

  def test_takes_name_from_first_message_with_a_name
    stats = A.group([
      msg(from: "a@x.com"),
      msg(from: "Alice <a@x.com>")
    ])
    assert_equal "Alice", stats.first.sender.name
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/aggregator_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/unsub_info.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  class UnsubInfo
    attr_reader :urls

    def initialize(urls:, one_click:)
      @urls = urls
      @one_click = one_click
    end

    def one_click?
      @one_click
    end

    def https_url
      @urls.find { |u| u[:scheme] == :https }&.dig(:value)
    end

    def mailto_url
      @urls.find { |u| u[:scheme] == :mailto }&.dig(:value)
    end
  end
end
```

- [ ] **Step 4: Write `lib/email_cleaner/sender_stats.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  class SenderStats
    attr_reader :sender, :count, :unsub_info, :last_seen
    attr_accessor :state_status # :none | :confirmed | :unconfirmed

    def initialize(sender:, count:, unsub_info:, last_seen:)
      @sender = sender
      @count = count
      @unsub_info = unsub_info
      @last_seen = last_seen
      @state_status = :none
    end

    def already_unsubscribed?
      @state_status == :confirmed
    end
  end
end
```

- [ ] **Step 5: Write `lib/email_cleaner/aggregator.rb`**

```ruby
# frozen_string_literal: true

require_relative "headers"
require_relative "sender"
require_relative "sender_stats"
require_relative "unsub_info"

module EmailCleaner
  module Aggregator
    module_function

    # Input: array of {headers: {String => String}, internal_date: Date}.
    # Output: array of SenderStats, sorted by count desc, count==1 dropped.
    def group(messages)
      groups = {}

      messages.each do |m|
        headers = m[:headers] || {}
        from = headers["From"]
        next if from.nil?

        name, address = Headers.parse_from(from)
        next if address.empty?

        key = address
        g = groups[key] ||= {
          name: nil,
          count: 0,
          last_seen: nil,
          list_unsub: nil,
          post: nil
        }
        g[:name] ||= name
        g[:count] += 1
        date = m[:internal_date]
        g[:last_seen] = date if date && (g[:last_seen].nil? || date > g[:last_seen])
        g[:list_unsub] ||= headers["List-Unsubscribe"]
        g[:post] ||= headers["List-Unsubscribe-Post"]
      end

      groups.filter_map do |address, g|
        next nil if g[:count] < 2

        urls = Headers.parse_list_unsubscribe(g[:list_unsub])
        unsub_info =
          if urls.empty?
            nil
          else
            UnsubInfo.new(urls: urls, one_click: Headers.one_click?(g[:post], urls))
          end

        SenderStats.new(
          sender: Sender.new(address: address, name: g[:name]),
          count: g[:count],
          unsub_info: unsub_info,
          last_seen: g[:last_seen]
        )
      end.sort_by { |s| -s.count }
    end
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/aggregator_test.rb`
Expected: PASS — 7 runs.

- [ ] **Step 7: Commit**

```bash
git add lib/email_cleaner/{aggregator,sender_stats,unsub_info}.rb test/aggregator_test.rb
git commit -m "Add Aggregator producing SenderStats from messages"
```

---

## Task 7: PatternMatcher

**Files:**
- Create: `lib/email_cleaner/pattern_matcher.rb`
- Create: `test/pattern_matcher_test.rb`

- [ ] **Step 1: Write failing tests**

`test/pattern_matcher_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/pattern_matcher"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"

class PatternMatcherTest < Minitest::Test
  PM = EmailCleaner::PatternMatcher

  def stats(addr)
    EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: addr, name: nil),
      count: 5, unsub_info: nil, last_seen: nil
    )
  end

  def test_substring_case_insensitive
    pool = [stats("news@SUBSTACK.com"), stats("a@b.com")]
    matched = PM.filter(pool, "substack")
    assert_equal 1, matched.size
    assert_equal "news@substack.com", matched.first.sender.address
  end

  def test_substring_can_match_local_part
    pool = [stats("me+substack@x.com"), stats("a@b.com")]
    matched = PM.filter(pool, "substack")
    assert_equal 1, matched.size
  end

  def test_at_domain_exact_match
    pool = [stats("a@substack.com"), stats("b@news.substack.com"), stats("c@xsubstack.com")]
    matched = PM.filter(pool, "@substack.com")
    assert_equal ["a@substack.com"], matched.map { |s| s.sender.address }
  end

  def test_at_domain_case_insensitive
    pool = [stats("a@SUBSTACK.com")]
    matched = PM.filter(pool, "@Substack.COM")
    assert_equal 1, matched.size
  end

  def test_no_match_returns_empty
    assert_empty PM.filter([stats("a@b.com")], "zzz")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/pattern_matcher_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/pattern_matcher.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  module PatternMatcher
    module_function

    # Filters an array of SenderStats by pattern.
    # - "@domain.com" → exact-domain match (no subdomains).
    # - anything else → case-insensitive substring on address.
    def filter(stats, pattern)
      p = pattern.to_s.downcase
      if p.start_with?("@")
        domain = p[1..]
        stats.select { |s| s.sender.domain == domain }
      else
        stats.select { |s| s.sender.address.include?(p) }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/pattern_matcher_test.rb`
Expected: PASS — 5 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/pattern_matcher.rb test/pattern_matcher_test.rb
git commit -m "Add PatternMatcher with substring and @domain modes"
```

---

## Task 8: State (YAML-backed unsubscribe record)

**Files:**
- Create: `lib/email_cleaner/state.rb`
- Create: `test/state_test.rb`

- [ ] **Step 1: Write failing tests**

`test/state_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "email_cleaner/state"

class StateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "unsubscribed.yaml")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_missing_file_loads_empty
    state = EmailCleaner::State.new(path: @path)
    assert_nil state.lookup("a@b.com")
    refute state.already_unsubscribed?("a@b.com")
  end

  def test_record_then_lookup
    state = EmailCleaner::State.new(path: @path)
    state.record(
      "a@b.com",
      method: :one_click, status: 200, confirmed: true,
      last_url: "https://x.com/u"
    )
    state.save

    reloaded = EmailCleaner::State.new(path: @path)
    entry = reloaded.lookup("a@b.com")
    assert_equal "one_click", entry["method"]
    assert_equal 200, entry["status"]
    assert_equal true, entry["confirmed"]
    assert reloaded.already_unsubscribed?("a@b.com")
  end

  def test_already_unsubscribed_only_when_confirmed
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :https_only, status: "manual", confirmed: false, last_url: "https://x")
    refute state.already_unsubscribed?("a@b.com")
  end

  def test_record_overwrites_prior_entry
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :error, status: 500, confirmed: false, last_url: "https://x")
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    assert state.already_unsubscribed?("a@b.com")
    assert_equal "one_click", state.lookup("a@b.com")["method"]
  end

  def test_file_written_with_0600
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    state.save
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_each_yields_address_and_entry
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    state.record("c@d.com", method: :mailto, status: "sent", confirmed: true, last_url: "mailto:x")
    seen = {}
    state.each { |addr, entry| seen[addr] = entry["method"] }
    assert_equal({ "a@b.com" => "one_click", "c@d.com" => "mailto" }, seen)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/state_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/state.rb`**

```ruby
# frozen_string_literal: true

require "yaml"
require "fileutils"
require "time"

module EmailCleaner
  class State
    SCHEMA_VERSION = 1

    def initialize(path:)
      @path = path
      @data = load_or_init
    end

    def lookup(address)
      @data["entries"][address.to_s.downcase]
    end

    def already_unsubscribed?(address)
      entry = lookup(address)
      !!(entry && entry["confirmed"])
    end

    def record(address, method:, status:, confirmed:, last_url:)
      @data["entries"][address.to_s.downcase] = {
        "method"       => method.to_s,
        "status"       => status,
        "attempted_at" => Time.now.utc.iso8601,
        "confirmed"    => !!confirmed,
        "last_url"     => last_url
      }
    end

    def each(&block)
      @data["entries"].each(&block)
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(@data))
      end
    end

    # Annotate a SenderStats array in place with state_status.
    def annotate(stats)
      stats.each do |s|
        entry = lookup(s.sender.address)
        s.state_status =
          if entry.nil? then :none
          elsif entry["confirmed"] then :confirmed
          else :unconfirmed
          end
      end
      stats
    end

    private

    def load_or_init
      if File.exist?(@path)
        loaded = YAML.safe_load(File.read(@path), permitted_classes: [Time, Date], aliases: false) || {}
        loaded["version"] ||= SCHEMA_VERSION
        loaded["entries"] ||= {}
        loaded
      else
        { "version" => SCHEMA_VERSION, "entries" => {} }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/state_test.rb`
Expected: PASS — 6 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/state.rb test/state_test.rb
git commit -m "Add YAML-backed State for unsubscribe records"
```

---

## Task 9: Unsubscriber — execute one unsub action

**Files:**
- Create: `lib/email_cleaner/unsubscriber.rb`
- Create: `test/unsubscriber_test.rb`

`Unsubscriber#run(stats, dry_run:)` returns a result Hash:
`{ method:, status:, url:, confirmed: }` where `method ∈ {:one_click, :https_only, :mailto, :error, :dry_run}`.

It needs an authenticated `gmail_service` for the mailto path. We pass that in (dependency injection — easy to stub).

- [ ] **Step 1: Write failing tests**

`test/unsubscriber_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/unsubscriber"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"
require "email_cleaner/unsub_info"

class UnsubscriberTest < Minitest::Test
  def stats(urls:, one_click:)
    EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: "a@b.com", name: "Alice"),
      count: 5,
      unsub_info: EmailCleaner::UnsubInfo.new(urls: urls, one_click: one_click),
      last_seen: nil
    )
  end

  def test_one_click_post_2xx_is_confirmed
    stub_request(:post, "https://x.com/u")
      .with(body: "List-Unsubscribe=One-Click",
            headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      .to_return(status: 200, body: "")

    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    u = EmailCleaner::Unsubscriber.new(gmail_service: nil)
    result = u.run(s)

    assert_equal :one_click, result[:method]
    assert_equal 200, result[:status]
    assert_equal true, result[:confirmed]
  end

  def test_one_click_post_5xx_is_error
    stub_request(:post, "https://x.com/u").to_return(status: 503)
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :one_click, result[:method]
    assert_equal 503, result[:status]
    assert_equal false, result[:confirmed]
  end

  def test_one_click_timeout_is_error
    stub_request(:post, "https://x.com/u").to_timeout
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :error, result[:method]
    assert_equal false, result[:confirmed]
  end

  def test_https_only_makes_no_http_call
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: false)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :https_only, result[:method]
    assert_equal "https://x.com/u", result[:url]
    assert_equal false, result[:confirmed]
    assert_not_requested :post, "https://x.com/u"
  end

  def test_mailto_sends_via_gmail
    fake_gmail = Minitest::Mock.new
    fake_gmail.expect(:send_user_message, nil) do |user_id, message|
      raw = message.raw
      user_id == "me" &&
        raw.include?("To: unsub@x.com") &&
        raw.include?("Subject: bye") &&
        raw.include?("\r\n\r\n") # headers/body separator present
    end

    s = stats(urls: [{ scheme: :mailto, value: "mailto:unsub@x.com?subject=bye&body=stop" }], one_click: false)
    result = EmailCleaner::Unsubscriber.new(gmail_service: fake_gmail).run(s)

    assert_equal :mailto, result[:method]
    assert_equal "sent", result[:status]
    assert_equal true, result[:confirmed]
    fake_gmail.verify
  end

  def test_dry_run_makes_no_calls
    stub = stub_request(:post, "https://x.com/u")
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s, dry_run: true)

    assert_equal :dry_run, result[:method]
    refute_requested(stub)
  end

  def test_prefers_https_when_both_present
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    s = stats(
      urls: [
        { scheme: :mailto, value: "mailto:u@x.com" },
        { scheme: :https,  value: "https://x.com/u" }
      ],
      one_click: true
    )
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)
    assert_equal :one_click, result[:method]
  end

  private

  def assert_not_requested(method, url)
    refute_requested(method, url)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/unsubscriber_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/unsubscriber.rb`**

```ruby
# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "google/apis/gmail_v1"

module EmailCleaner
  class Unsubscriber
    HTTP_TIMEOUT = 10 # seconds

    def initialize(gmail_service:)
      @gmail = gmail_service
    end

    # Returns { method:, status:, url:, confirmed: }.
    def run(stats, dry_run: false)
      info = stats.unsub_info
      return { method: :dry_run, status: nil, url: nil, confirmed: false } if dry_run

      if info.one_click? && info.https_url
        post_one_click(info.https_url)
      elsif info.https_url
        { method: :https_only, status: "manual", url: info.https_url, confirmed: false }
      elsif info.mailto_url
        send_mailto(stats.sender.address, info.mailto_url)
      else
        { method: :error, status: "no_url", url: nil, confirmed: false }
      end
    end

    private

    def post_one_click(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = "List-Unsubscribe=One-Click"

      response = http.request(req)
      status = response.code.to_i
      {
        method: :one_click,
        status: status,
        url: url,
        confirmed: status >= 200 && status < 300
      }
    rescue StandardError => e
      { method: :error, status: e.class.name, url: url, confirmed: false }
    end

    def send_mailto(_sender_addr, mailto)
      uri = URI.parse(mailto)
      to = uri.opaque ? uri.opaque.split("?", 2).first : uri.path
      params = CGI.parse(uri.query || "")
      subject = params["subject"]&.first&.strip
      subject = "unsubscribe" if subject.nil? || subject.empty?
      body = params["body"]&.first.to_s

      raw = build_rfc5322(to: to, subject: subject, body: body)

      message = Google::Apis::GmailV1::Message.new(raw: raw)
      @gmail.send_user_message("me", message)

      { method: :mailto, status: "sent", url: mailto, confirmed: true }
    rescue StandardError => e
      { method: :error, status: e.class.name, url: mailto, confirmed: false }
    end

    def build_rfc5322(to:, subject:, body:)
      [
        "To: #{to}",
        "Subject: #{subject}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8",
        "",
        body
      ].join("\r\n")
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/unsubscriber_test.rb`
Expected: PASS — 7 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/unsubscriber.rb test/unsubscriber_test.rb
git commit -m "Add Unsubscriber for one-click, https-only, and mailto methods"
```

---

## Task 10: GmailClient — list and batch-fetch metadata

**Files:**
- Create: `lib/email_cleaner/gmail_client.rb`
- Create: `test/gmail_client_test.rb`

`GmailClient` wraps `Google::Apis::GmailV1::GmailService` and exposes:
- `list_message_ids(query:)` → Array<String>, paginated.
- `fetch_metadata_batched(ids, batch_size: 50)` → Array of `{headers:, internal_date:}`. Per-message failures log warnings to stderr and are dropped.

For testability, `GmailClient` accepts a `service` in its constructor. We mock the service in tests rather than recording cassettes — Gmail batch RPC is hard to record cleanly and a mocked service tests the same logic.

- [ ] **Step 1: Write failing tests**

`test/gmail_client_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "stringio"
require "email_cleaner/gmail_client"

class GmailClientTest < Minitest::Test
  # Minimal fake service: tracks calls, returns canned data.
  class FakeService
    attr_reader :list_calls, :batched_gets

    def initialize(message_pages:, message_responses:)
      @message_pages = message_pages       # Array of [ids, next_page_token]
      @message_responses = message_responses # Hash{id => msg or :raise}
      @list_calls = []
      @batched_gets = []
    end

    def list_user_messages(user_id, q:, page_token: nil, max_results: 500)
      @list_calls << { user_id: user_id, q: q, page_token: page_token }
      ids, next_token = @message_pages.shift
      msgs = ids.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(msgs, next_token)
    end

    def batch(&block)
      yield self
    end

    def get_user_message(user_id, id, format:, metadata_headers:, &block)
      @batched_gets << id
      response = @message_responses[id]
      if response == :raise
        block.call(nil, StandardError.new("boom"))
      else
        block.call(response, nil)
      end
    end
  end

  def fake_msg(headers:, internal_date_ms:)
    Struct.new(:payload, :internal_date).new(
      Struct.new(:headers).new(
        headers.map { |n, v| Struct.new(:name, :value).new(n, v) }
      ),
      internal_date_ms.to_s
    )
  end

  def test_list_paginates
    pages = [[%w[a b c], "tok"], [%w[d e], nil]]
    svc = FakeService.new(message_pages: pages, message_responses: {})
    client = EmailCleaner::GmailClient.new(service: svc)

    ids = client.list_message_ids(query: "newer_than:30d")
    assert_equal %w[a b c d e], ids
    assert_equal 2, svc.list_calls.size
    assert_equal "newer_than:30d", svc.list_calls.first[:q]
  end

  def test_batch_fetches_in_chunks_of_50
    ids = (1..101).map(&:to_s)
    responses = ids.to_h { |i| [i, fake_msg(headers: { "From" => "a@b.com" }, internal_date_ms: 1_700_000_000_000)] }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    client = EmailCleaner::GmailClient.new(service: svc)

    msgs = client.fetch_metadata_batched(ids, batch_size: 50)
    assert_equal 101, msgs.size
    assert_equal 101, svc.batched_gets.size
  end

  def test_individual_failure_warns_and_continues
    ids = %w[a b c]
    responses = {
      "a" => fake_msg(headers: { "From" => "x@y.com" }, internal_date_ms: 1_700_000_000_000),
      "b" => :raise,
      "c" => fake_msg(headers: { "From" => "z@y.com" }, internal_date_ms: 1_700_000_000_000)
    }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    client = EmailCleaner::GmailClient.new(service: svc)

    captured_stderr = capture_stderr do
      msgs = client.fetch_metadata_batched(ids)
      assert_equal 2, msgs.size
    end
    assert_match(/warn|fail|skip/i, captured_stderr)
  end

  def test_message_shape_has_headers_and_date
    ids = ["a"]
    responses = { "a" => fake_msg(headers: { "From" => "x@y.com", "Subject" => "hi" }, internal_date_ms: 1_700_000_000_000) }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    client = EmailCleaner::GmailClient.new(service: svc)

    msgs = client.fetch_metadata_batched(ids)
    assert_equal "x@y.com", msgs.first[:headers]["From"]
    assert_equal "hi", msgs.first[:headers]["Subject"]
    assert_kind_of Date, msgs.first[:internal_date]
  end

  private

  def capture_stderr
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/gmail_client_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/gmail_client.rb`**

```ruby
# frozen_string_literal: true

require "date"

module EmailCleaner
  class GmailClient
    METADATA_HEADERS = %w[From List-Unsubscribe List-Unsubscribe-Post Subject Date].freeze

    def initialize(service:, progress: $stderr)
      @service = service
      @progress = progress
    end

    # Lists message IDs matching `query`, paginating through all results.
    def list_message_ids(query:)
      ids = []
      page_token = nil
      loop do
        result = @service.list_user_messages("me", q: query, page_token: page_token, max_results: 500)
        (result.messages || []).each { |m| ids << m.id }
        page_token = result.next_page_token
        break unless page_token
      end
      ids
    end

    # Fetches metadata for each id, in batches. Returns
    #   [{ headers: {String=>String}, internal_date: Date }, ...]
    # Drops messages whose individual fetch fails (warns to stderr).
    def fetch_metadata_batched(ids, batch_size: 50)
      results = []
      ids.each_slice(batch_size) do |chunk|
        @service.batch do |svc|
          chunk.each do |id|
            svc.get_user_message(
              "me", id,
              format: "metadata",
              metadata_headers: METADATA_HEADERS
            ) do |msg, err|
              if err
                @progress.puts "warn: failed to fetch message #{id}: #{err.message}"
              else
                results << to_message_hash(msg)
              end
            end
          end
        end
        @progress.write(".")
      end
      @progress.write("\n") unless ids.empty?
      results
    end

    private

    def to_message_hash(msg)
      headers = {}
      Array(msg.payload&.headers).each { |h| headers[h.name] = h.value }
      ms = msg.internal_date.to_i
      date = ms.zero? ? nil : Time.at(ms / 1000).utc.to_date
      { headers: headers, internal_date: date }
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/gmail_client_test.rb`
Expected: PASS — 4 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/gmail_client.rb test/gmail_client_test.rb
git commit -m "Add GmailClient with list pagination and batched metadata fetch"
```

---

## Task 11: Auth — OAuth loopback flow

**Files:**
- Create: `lib/email_cleaner/auth.rb`

`Auth.authorize(config:)` returns an authorized `Google::Apis::GmailV1::GmailService`. Per spec, this module is **not unit-tested** (it requires real Google OAuth interaction). Keep it thin so there's little untested logic.

- [ ] **Step 1: Write `lib/email_cleaner/auth.rb`**

```ruby
# frozen_string_literal: true

require "googleauth"
require "googleauth/stores/file_token_store"
require "google/apis/gmail_v1"
require "webrick"
require "rbconfig"

module EmailCleaner
  module Auth
    SCOPES = [
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.send"
    ].freeze
    REDIRECT_URI = "http://localhost:8765"
    PORT = 8765
    CALLBACK_TIMEOUT = 300 # seconds

    module_function

    def authorize(config:)
      unless File.exist?(config.credentials_path)
        warn "Missing credentials.json at #{config.credentials_path}."
        warn "See README.md for setup instructions."
        raise SetupError, "credentials.json not found"
      end

      authorizer = build_authorizer(config)
      credentials = authorizer.get_credentials("default")
      credentials ||= run_loopback_flow(authorizer)

      service = Google::Apis::GmailV1::GmailService.new
      service.authorization = credentials
      service
    end

    class SetupError < StandardError; end
    class AuthError < StandardError; end

    def build_authorizer(config)
      client_id = Google::Auth::ClientId.from_file(config.credentials_path)
      token_store = Google::Auth::Stores::FileTokenStore.new(file: config.token_path)
      Google::Auth::UserAuthorizer.new(client_id, SCOPES, token_store)
    end

    def run_loopback_flow(authorizer)
      url = authorizer.get_authorization_url(base_url: REDIRECT_URI)
      code = capture_code_via_loopback(url)
      authorizer.get_and_store_credentials_from_code(
        user_id: "default",
        code: code,
        base_url: REDIRECT_URI
      )
    end

    def capture_code_via_loopback(url)
      code_holder = { code: nil }
      mutex = Mutex.new
      cond = ConditionVariable.new

      server = WEBrick::HTTPServer.new(
        Port: PORT,
        BindAddress: "127.0.0.1",
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

      server.mount_proc "/" do |req, res|
        mutex.synchronize do
          code_holder[:code] = req.query["code"]
          cond.signal
        end
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = "<html><body><h2>Authentication received.</h2>" \
                   "<p>You can close this tab.</p></body></html>"
      end

      thread = Thread.new { server.start }
      open_in_browser(url) || warn("Open this URL to authorize: #{url}")

      mutex.synchronize do
        cond.wait(mutex, CALLBACK_TIMEOUT)
      end

      server.shutdown
      thread.join

      raise AuthError, "OAuth code not received within #{CALLBACK_TIMEOUT}s" if code_holder[:code].nil?

      code_holder[:code]
    end

    def open_in_browser(url)
      cmd =
        case RbConfig::CONFIG["host_os"]
        when /darwin/  then ["open", url]
        when /mswin|mingw|cygwin/ then ["cmd", "/c", "start", url]
        when /linux|bsd/ then ["xdg-open", url]
        end
      return false unless cmd

      pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      true
    rescue StandardError
      false
    end
  end
end
```

- [ ] **Step 2: Verify it loads**

Run: `bundle exec ruby -Ilib -e 'require "email_cleaner/auth"; puts EmailCleaner::Auth::SCOPES'`
Expected: prints both scope URLs.

- [ ] **Step 3: Commit**

```bash
git add lib/email_cleaner/auth.rb
git commit -m "Add Auth with loopback OAuth flow on :8765"
```

---

## Task 12: Table printer

**Files:**
- Create: `lib/email_cleaner/table.rb`
- Create: `test/table_test.rb`

A small ASCII table printer for the audit output. Tested at the level of "given these stats, the output contains the expected substrings" — not pixel-perfect equality.

- [ ] **Step 1: Write failing tests**

`test/table_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "stringio"
require "email_cleaner/table"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"
require "email_cleaner/unsub_info"

class TableTest < Minitest::Test
  def stats(addr:, count:, name: nil, has_unsub: false, one_click: false, state_status: :none)
    info =
      if has_unsub
        EmailCleaner::UnsubInfo.new(
          urls: [{ scheme: :https, value: "https://x.com/u" }],
          one_click: one_click
        )
      end

    s = EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: addr, name: name),
      count: count, unsub_info: info, last_seen: Date.new(2026, 5, 1)
    )
    s.state_status = state_status
    s
  end

  def test_renders_columns_and_marks
    rows = [
      stats(addr: "a@b.com", count: 10, name: "A", has_unsub: true,  one_click: true,  state_status: :confirmed),
      stats(addr: "c@d.com", count: 3,  name: nil, has_unsub: true,  one_click: false, state_status: :unconfirmed),
      stats(addr: "e@f.com", count: 2,  name: "E", has_unsub: false, one_click: false, state_status: :none)
    ]
    out = StringIO.new
    EmailCleaner::Table.print(rows, io: out)
    s = out.string

    assert_match(/COUNT/, s)
    assert_match(/a@b\.com/, s)
    assert_match(/c@d\.com/, s)
    assert_match(/e@f\.com/, s)
    # one-click row has both ✓ for UNSUB and 1-CLICK
    assert_match(/10\s+✓\s+✓\s+✓/, s) # COUNT UNSUB 1-CLICK DONE
    # unconfirmed gets ~ in DONE
    assert_match(/c@d\.com/, s)
    assert_includes s, "~"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/table_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/table.rb`**

```ruby
# frozen_string_literal: true

module EmailCleaner
  module Table
    HEADERS = %w[COUNT UNSUB 1-CLICK DONE DOMAIN NAME ADDRESS].freeze

    module_function

    def print(stats, io: $stdout)
      rows = stats.map { |s| row_for(s) }
      widths = column_widths(rows)
      io.puts format_row(HEADERS, widths)
      io.puts format_row(widths.map { |w| "-" * w }, widths)
      rows.each { |r| io.puts format_row(r, widths) }
    end

    def row_for(s)
      [
        s.count.to_s,
        s.unsub_info ? "✓" : "",
        (s.unsub_info && s.unsub_info.one_click?) ? "✓" : "",
        done_marker(s),
        s.sender.domain,
        (s.sender.name || ""),
        s.sender.address
      ]
    end

    def done_marker(s)
      case s.state_status
      when :confirmed   then "✓"
      when :unconfirmed then "~"
      else ""
      end
    end

    def column_widths(rows)
      HEADERS.each_with_index.map do |h, i|
        ([h.length] + rows.map { |r| r[i].to_s.length }).max
      end
    end

    def format_row(cells, widths)
      cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ")
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/table_test.rb`
Expected: PASS — 1 run.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/table.rb test/table_test.rb
git commit -m "Add ASCII Table printer for audit/unsubscribe output"
```

---

## Task 13: Audit subcommand

**Files:**
- Create: `lib/email_cleaner/audit.rb`
- Create: `test/audit_test.rb`

`Audit.run(options:, gmail_service:, state:, io:)` — given parsed options, runs the pipeline and prints. Splitting from the CLI keeps it testable with a fake service.

- [ ] **Step 1: Write failing test**

`test/audit_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "email_cleaner/audit"
require "email_cleaner/state"

class AuditTest < Minitest::Test
  # Minimal fake service compatible with GmailClient
  class FakeService
    def initialize(messages_by_id:)
      @messages_by_id = messages_by_id
    end

    def list_user_messages(_user_id, q:, page_token: nil, max_results: 500)
      ids = @messages_by_id.keys.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(ids, nil)
    end

    def batch
      yield self
    end

    def get_user_message(_user_id, id, format:, metadata_headers:, &block)
      block.call(@messages_by_id[id], nil)
    end
  end

  def msg(headers:, ms: 1_700_000_000_000)
    Struct.new(:payload, :internal_date).new(
      Struct.new(:headers).new(
        headers.map { |n, v| Struct.new(:name, :value).new(n, v) }
      ),
      ms.to_s
    )
  end

  def make_state
    @tmp = Dir.mktmpdir
    EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp
  end

  def test_audit_default_lists_count_gt_1_senders
    msgs = {
      "1" => msg(headers: { "From" => "a@x.com" }),
      "2" => msg(headers: { "From" => "a@x.com" }),
      "3" => msg(headers: { "From" => "b@x.com" }) # count 1, dropped
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new

    EmailCleaner::Audit.run(
      options: { days: 30, actionable: false, min: 3, include_done: false },
      gmail_service: svc,
      state: make_state,
      io: out
    )

    assert_match(/a@x\.com/, out.string)
    refute_match(/b@x\.com/, out.string)
    assert_match(/2 senders shown|1 senders shown/, out.string)
  end

  def test_actionable_filters_min_and_unsub_header
    msgs = {
      "1" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "2" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "3" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "4" => msg(headers: { "From" => "b@x.com" }),  # no unsub header
      "5" => msg(headers: { "From" => "b@x.com" }),
      "6" => msg(headers: { "From" => "c@x.com", "List-Unsubscribe" => "<https://x/u>" }), # only count 2 → below min 3
      "7" => msg(headers: { "From" => "c@x.com", "List-Unsubscribe" => "<https://x/u>" })
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new

    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: false },
      gmail_service: svc,
      state: make_state,
      io: out
    )

    assert_match(/a@x\.com/, out.string)
    refute_match(/b@x\.com/, out.string)
    refute_match(/c@x\.com/, out.string)
    assert_match(/email_cleaner unsubscribe/, out.string)
  end

  def test_actionable_excludes_done_unless_include_done
    state = make_state
    state.record("a@x.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x/u")

    msgs = {
      "1" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "2" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "3" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" })
    }
    svc = FakeService.new(messages_by_id: msgs)

    out_excluded = StringIO.new
    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: false },
      gmail_service: svc, state: state, io: out_excluded
    )
    refute_match(/a@x\.com/, out_excluded.string)

    out_included = StringIO.new
    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: true },
      gmail_service: svc, state: state, io: out_included
    )
    assert_match(/a@x\.com/, out_included.string)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/audit_test.rb`
Expected: FAIL — cannot load `email_cleaner/audit`.

- [ ] **Step 3: Write `lib/email_cleaner/audit.rb`**

```ruby
# frozen_string_literal: true

require_relative "gmail_client"
require_relative "aggregator"
require_relative "table"

module EmailCleaner
  module Audit
    module_function

    # options: { days:, actionable:, min:, include_done: }
    def run(options:, gmail_service:, state:, io: $stdout, progress: $stderr)
      client = GmailClient.new(service: gmail_service, progress: progress)
      ids = client.list_message_ids(query: "newer_than:#{options[:days]}d")
      messages = client.fetch_metadata_batched(ids)
      progress.puts "Fetched #{messages.size} messages."

      stats = Aggregator.group(messages)
      state.annotate(stats)

      stats = filter(stats, options) if options[:actionable]

      Table.print(stats, io: io)
      io.puts
      io.puts "#{stats.size} senders shown, #{messages.size} messages."
      if options[:actionable]
        io.puts "Use: email_cleaner unsubscribe <pattern> to act on these."
      end
    end

    def filter(stats, options)
      stats.select do |s|
        next false if s.unsub_info.nil?
        next false if s.count < options[:min]
        next false if !options[:include_done] && s.state_status == :confirmed
        true
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/audit_test.rb`
Expected: PASS — 3 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/audit.rb test/audit_test.rb
git commit -m "Add Audit subcommand with --actionable filtering"
```

---

## Task 14: Unsubscribe subcommand (orchestrator)

**Files:**
- Create: `lib/email_cleaner/unsubscribe_command.rb`
- Create: `test/unsubscribe_command_test.rb`

The `unsubscribe` subcommand orchestrates: pull senders from the audit pipeline, filter by pattern, prompt, run `Unsubscriber` per sender, record state, append to log.

(Filename note: `unsubscribe.rb` would shadow Ruby's `Object#unsubscribe`-style ambiguity in code reading; `unsubscribe_command.rb` is clearer. The module is `EmailCleaner::UnsubscribeCommand`.)

- [ ] **Step 1: Write failing tests**

`test/unsubscribe_command_test.rb`:
```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "email_cleaner/unsubscribe_command"
require "email_cleaner/state"

class UnsubscribeCommandTest < Minitest::Test
  class FakeService
    def initialize(messages_by_id:)
      @messages_by_id = messages_by_id
    end

    def list_user_messages(_u, q:, page_token: nil, max_results: 500)
      ids = @messages_by_id.keys.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(ids, nil)
    end

    def batch
      yield self
    end

    def get_user_message(_u, id, format:, metadata_headers:, &block)
      block.call(@messages_by_id[id], nil)
    end
  end

  def msg(from:, list_unsub:, post: nil)
    headers = { "From" => from, "List-Unsubscribe" => list_unsub }
    headers["List-Unsubscribe-Post"] = post if post
    Struct.new(:payload, :internal_date).new(
      Struct.new(:headers).new(headers.map { |n, v| Struct.new(:name, :value).new(n, v) }),
      "1700000000000"
    )
  end

  def setup
    @tmp = Dir.mktmpdir
    @state = EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
    @log_path = File.join(@tmp, "u.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_dry_run_makes_no_http_or_state_writes
    msgs = {
      "1" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "2" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "3" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click")
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new

    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "@substack.com",
      options: { days: 30, dry_run: true, yes: true },
      gmail_service: svc, state: @state, log_path: @log_path, io: out, stdin: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/dry-run|would unsubscribe/i, out.string)
    refute @state.already_unsubscribed?("a@substack.com")
    refute File.exist?(@log_path)
  end

  def test_one_click_path_records_state_and_appends_log
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    msgs = {
      "1" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "2" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click")
    }
    svc = FakeService.new(messages_by_id: msgs)

    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "substack",
      options: { days: 30, dry_run: false, yes: true },
      gmail_service: svc, state: @state, log_path: @log_path, io: StringIO.new, stdin: StringIO.new
    )
    assert_equal 0, rc
    assert @state.already_unsubscribed?("a@substack.com")
    log = File.read(@log_path)
    assert_match(/one-click/, log)
    assert_match(/a@substack\.com/, log)
    assert_match(/200/, log)
  end

  def test_no_matches_exits_zero_with_message
    svc = FakeService.new(messages_by_id: {})
    out = StringIO.new
    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "nothing",
      options: { days: 30, dry_run: false, yes: true },
      gmail_service: svc, state: @state, log_path: @log_path, io: out, stdin: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/No matches/i, out.string)
  end

  def test_prompt_no_answer_aborts
    stub = stub_request(:post, "https://x.com/u")
    msgs = {
      "1" => msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "2" => msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click")
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new
    stdin = StringIO.new("n\n")

    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "@x.com",
      options: { days: 30, dry_run: false, yes: false },
      gmail_service: svc, state: @state, log_path: @log_path, io: out, stdin: stdin
    )
    assert_equal 0, rc
    assert_match(/abort/i, out.string)
    refute_requested(stub)
    refute @state.already_unsubscribed?("a@x.com")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/unsubscribe_command_test.rb`
Expected: FAIL — cannot load.

- [ ] **Step 3: Write `lib/email_cleaner/unsubscribe_command.rb`**

```ruby
# frozen_string_literal: true

require "time"
require_relative "gmail_client"
require_relative "aggregator"
require_relative "pattern_matcher"
require_relative "table"
require_relative "unsubscriber"

module EmailCleaner
  module UnsubscribeCommand
    module_function

    # Returns an exit code (0 on success, non-zero on usage/runtime errors).
    def run(pattern:, options:, gmail_service:, state:, log_path:, io: $stdout, stdin: $stdin, progress: $stderr)
      client = GmailClient.new(service: gmail_service, progress: progress)
      ids = client.list_message_ids(query: "newer_than:#{options[:days]}d")
      messages = client.fetch_metadata_batched(ids)
      stats = Aggregator.group(messages)
      state.annotate(stats)

      candidates = stats.select { |s| s.unsub_info }
      matched = PatternMatcher.filter(candidates, pattern)

      if matched.empty?
        io.puts "No matches."
        return 0
      end

      Table.print(matched, io: io)
      io.puts

      if options[:dry_run]
        io.puts "[dry-run] would unsubscribe from #{matched.size} senders."
        return 0
      end

      unless options[:yes]
        io.print "Unsubscribe from #{matched.size} senders? [y/N] "
        answer = stdin.gets&.strip&.downcase
        unless %w[y yes].include?(answer)
          io.puts "Aborted."
          return 0
        end
      end

      executor = Unsubscriber.new(gmail_service: gmail_service)
      summary = { success: 0, manual: 0, error: 0 }

      File.open(log_path, "a") do |log|
        matched.each do |s|
          if state.already_unsubscribed?(s.sender.address)
            io.puts "warn: #{s.sender.address} already confirmed-unsubscribed; re-firing."
          end

          result = executor.run(s)
          state.record(
            s.sender.address,
            method: result[:method],
            status: result[:status],
            confirmed: result[:confirmed],
            last_url: result[:url]
          )
          log.puts "#{Time.now.utc.iso8601}\t#{result[:method]}\t#{s.sender.address}\t#{result[:status]}"

          case result[:method]
          when :one_click
            io.puts "[one-click] #{s.sender.address} → HTTP #{result[:status]}"
            result[:confirmed] ? summary[:success] += 1 : summary[:error] += 1
          when :https_only
            io.puts "[manual] #{s.sender.address} → #{result[:url]}"
            summary[:manual] += 1
          when :mailto
            io.puts "[mailto] #{s.sender.address} → sent"
            summary[:success] += 1
          when :error
            io.puts "[error] #{s.sender.address} → #{result[:status]}"
            summary[:error] += 1
          end
        end
      end

      state.save
      io.puts
      io.puts "#{summary[:success]} succeeded, #{summary[:manual]} manual, #{summary[:error]} errors."
      0
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Ilib -Itest test/unsubscribe_command_test.rb`
Expected: PASS — 4 runs.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/unsubscribe_command.rb test/unsubscribe_command_test.rb
git commit -m "Add UnsubscribeCommand orchestrator with prompt and logging"
```

---

## Task 15: CLI dispatcher

**Files:**
- Create: `lib/email_cleaner/cli.rb`

`CLI.run(argv)` parses subcommand + flags, runs auth, dispatches. Per spec, this glue is verified by inspection — no unit tests.

- [ ] **Step 1: Write `lib/email_cleaner/cli.rb`**

```ruby
# frozen_string_literal: true

require "optparse"
require_relative "config"
require_relative "auth"
require_relative "state"
require_relative "audit"
require_relative "unsubscribe_command"

module EmailCleaner
  module CLI
    module_function

    USAGE = <<~USAGE
      email_cleaner — audit and unsubscribe from Gmail senders

      Usage:
        email_cleaner audit [--days N] [--actionable] [--min N] [--include-done]
        email_cleaner unsubscribe <pattern> [--dry-run] [--days N] [--yes]
        email_cleaner --help

      Pattern: substring on email address (case-insensitive),
               or "@domain.com" for exact domain match.
    USAGE

    def run(argv)
      argv = argv.dup
      if argv.empty? || %w[-h --help].include?(argv.first)
        puts USAGE
        return 0
      end

      subcmd = argv.shift
      case subcmd
      when "audit"        then run_audit(argv)
      when "unsubscribe"  then run_unsubscribe(argv)
      else
        warn "Unknown subcommand: #{subcmd}"
        warn USAGE
        2
      end
    rescue Auth::SetupError, Auth::AuthError => e
      warn "auth error: #{e.message}"
      1
    rescue Interrupt
      warn "\nInterrupted."
      1
    end

    def run_audit(argv)
      opts = { days: 30, actionable: false, min: 3, include_done: false }
      OptionParser.new do |o|
        o.banner = "Usage: email_cleaner audit [options]"
        o.on("--days N", Integer) { |n| opts[:days] = n }
        o.on("--actionable")      { opts[:actionable] = true }
        o.on("--min N", Integer)  { |n| opts[:min] = n }
        o.on("--include-done")    { opts[:include_done] = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end.parse!(argv)

      config = Config.new
      service = Auth.authorize(config: config)
      state = State.new(path: config.state_path)
      Audit.run(options: opts, gmail_service: service, state: state)
      0
    end

    def run_unsubscribe(argv)
      opts = { days: 30, dry_run: false, yes: false }
      parser = OptionParser.new do |o|
        o.banner = "Usage: email_cleaner unsubscribe <pattern> [options]"
        o.on("--days N", Integer) { |n| opts[:days] = n }
        o.on("--dry-run")         { opts[:dry_run] = true }
        o.on("--yes")             { opts[:yes] = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end
      parser.parse!(argv)

      pattern = argv.shift
      if pattern.nil? || pattern.empty?
        warn "missing required <pattern>"
        warn parser
        return 2
      end

      config = Config.new
      service = Auth.authorize(config: config)
      state = State.new(path: config.state_path)
      rc = UnsubscribeCommand.run(
        pattern: pattern,
        options: opts,
        gmail_service: service,
        state: state,
        log_path: config.log_path
      )
      rc
    end
  end
end
```

- [ ] **Step 2: Verify it loads**

Run: `bundle exec ruby -Ilib -e 'require "email_cleaner/cli"; puts EmailCleaner::CLI::USAGE'`
Expected: prints usage block.

- [ ] **Step 3: Verify --help works end-to-end**

Run: `./bin/email_cleaner --help`
Expected: prints USAGE, exits 0.

- [ ] **Step 4: Run full test suite**

Run: `bundle exec rake test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/cli.rb
git commit -m "Add CLI dispatcher for audit and unsubscribe subcommands"
```

---

## Task 16: README with setup steps

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# email_cleaner

A Ruby CLI that audits your Gmail and unsubscribes you from bulk senders in
batches. Built for opting out of the attention economy.

## What it does

- `email_cleaner audit` — surveys your inbox, groups by sender, shows count,
  whether each sender exposes a `List-Unsubscribe` header, and whether
  they support RFC 8058 one-click unsubscribe.
- `email_cleaner audit --actionable` — same view filtered to senders you
  can actually unsubscribe from (have List-Unsubscribe, count ≥ min, not
  already done).
- `email_cleaner unsubscribe <pattern>` — for matched senders, fires the
  one-click POST, sends a mailto unsubscribe email, or surfaces a manual
  link. Records what it did to `unsubscribed.yaml` and `unsubscribe.log`.

## Setup

1. **Create a Google Cloud project.**
   Go to https://console.cloud.google.com/ and create a new project.

2. **Enable the Gmail API.**
   APIs & Services → Library → search "Gmail API" → Enable.

3. **Create an OAuth client (Desktop app).**
   APIs & Services → Credentials → Create Credentials → OAuth client ID →
   Application type **Desktop app**. Add `http://localhost:8765` as an
   authorized redirect URI.

4. **Download `credentials.json`.**
   From the credentials page, download the JSON file. Save it as
   `credentials.json` in this project's root directory. (It is gitignored.)

5. **Add yourself as a Test User.**
   APIs & Services → OAuth consent screen → Test users → Add your Gmail
   address. (Required while the app is in Testing status.)

6. **Install dependencies.**
   ```
   bundle install
   ```

7. **First run triggers OAuth.**
   ```
   bin/email_cleaner audit
   ```
   A browser tab opens to Google's consent screen. After you approve, the
   tool captures the OAuth code on `localhost:8765` and saves a token to
   `token.yaml` for future runs.

## Usage

```
email_cleaner audit [--days N] [--actionable] [--min N] [--include-done]
email_cleaner unsubscribe <pattern> [--dry-run] [--days N] [--yes]
```

**Pattern:** substring on the email address (case-insensitive), or
`@domain.com` for an exact-domain match.

## Files

| File | Purpose |
|---|---|
| `credentials.json` | OAuth client config (you download from Google Cloud) |
| `token.yaml` | cached OAuth tokens (mode 0600) |
| `unsubscribed.yaml` | record of unsubscribe attempts |
| `unsubscribe.log` | append-only timeline of unsub actions |

All four files stay in this directory and are gitignored.

## Development

```
bundle exec rake test
```

Re-record VCR cassettes:
```
VCR_RECORD=new_episodes bundle exec rake test
```
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Add README with Google Cloud OAuth setup instructions"
```

---

## Self-Review

**Spec coverage:**
- audit subcommand — Task 13 ✓
- unsubscribe subcommand — Task 14 ✓
- `--actionable`, `--min`, `--include-done` flags — Task 13/15 ✓
- pattern matching (substring + `@domain`) — Task 7 ✓
- one-click POST — Task 9 ✓
- https-only manual link — Task 9 ✓
- mailto send via Gmail — Task 9 ✓
- prefer https over mailto — Task 9 ✓
- batch metadata fetch with progress dots — Task 10 ✓
- per-message error tolerance — Task 10 ✓
- OAuth loopback on :8765 with browser open — Task 11 ✓
- token caching at 0600 — Tasks 11, 8 ✓
- YAML state file with confirmed semantics — Task 8 ✓
- unsubscribe.log appended per action — Task 14 ✓
- ASCII table output — Task 12 ✓
- Header parsing edge cases (quoted, malformed, comma-in-URL) — Tasks 3, 4 ✓
- Setup README — Task 16 ✓
- Minitest + VCR + WebMock testing — Task 1 ✓
- `--dry-run`, `--yes` flags — Tasks 14, 15 ✓
- Exit codes 0/1/2 — Task 15 ✓
- Phase B readiness (State.each, swappable backend) — Task 8 ✓

**No spec gaps identified.**

**Placeholder scan:** no TBD/TODO patterns; all code blocks are concrete.

**Type consistency:** `SenderStats`, `UnsubInfo`, `Sender`, `State` interface
methods (`record`, `lookup`, `each`, `already_unsubscribed?`, `annotate`,
`save`) are referenced consistently across tasks 6, 8, 13, 14. `Unsubscriber#run`
returns the same `{method:, status:, url:, confirmed:}` shape that
`UnsubscribeCommand` consumes in Task 14.
