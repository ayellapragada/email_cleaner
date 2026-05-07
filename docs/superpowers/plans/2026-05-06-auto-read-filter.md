# Auto-Read Senders & Chunked Triage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-side managed Gmail filter that auto-marks selected senders as read, fed by a local source-of-truth list populated during interactive triage; also add resumable weekly-chunked triage for large date windows.

**Architecture:** Triage gains two new keystrokes (`r`, `R`) that append to a local `auto_read.yaml` (addresses + domains) and never touch Gmail. A new `auto-read` subcommand reconciles that local list to a single managed Gmail filter via `users.settings.filters` (delete-then-recreate, since filters are immutable). Triage with `--days > --chunk` slices the window into weekly chunks with progress persisted between chunks for resumption.

**Tech Stack:** Ruby, `google-apis-gmail_v1`, minitest, webmock, VCR (existing).

Spec: [`docs/superpowers/specs/2026-05-06-auto-read-filter-design.md`](../specs/2026-05-06-auto-read-filter-design.md).

---

## File Map

**Create:**
- `lib/email_cleaner/auto_read_state.rb` — local `auto_read.yaml` source-of-truth (addresses, domains, filter_id)
- `lib/email_cleaner/gmail_filter.rb` — wrapper over `users.settings.filters` + query builder
- `lib/email_cleaner/auto_read_command.rb` — `auto-read` subcommand (list/add/remove/sync/status)
- `lib/email_cleaner/triage_progress.rb` — chunk progress persistence (`triage_progress.yaml`)
- `test/auto_read_state_test.rb`
- `test/gmail_filter_test.rb`
- `test/auto_read_command_test.rb`
- `test/triage_progress_test.rb`

**Modify:**
- `lib/email_cleaner/config.rb` — add `auto_read_path`, `triage_progress_path`
- `lib/email_cleaner/auth.rb` — add `gmail.settings.basic` scope
- `lib/email_cleaner/cli.rb` — register `auto-read` subcommand, add `--chunk` flag to `triage`
- `lib/email_cleaner/snapshot.rb` — accept optional `query:` override on `all_senders`
- `lib/email_cleaner/triage_command.rb` — `r`/`R` keys, chunked driver, progress integration
- `test/triage_command_test.rb` — cover `r`/`R`
- `test/config_test.rb` — cover new paths

---

## Task 1: AutoReadState — load/save/normalize

**Files:**
- Create: `lib/email_cleaner/auto_read_state.rb`
- Test: `test/auto_read_state_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# test/auto_read_state_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "email_cleaner/auto_read_state"

class AutoReadStateTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "auto_read.yaml")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_empty_file_initializes_blank
    s = EmailCleaner::AutoReadState.new(path: @path)
    assert_equal [], s.addresses
    assert_equal [], s.domains
    assert_nil s.filter_id
  end

  def test_add_address_dedupes_and_lowercases
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("Foo@Bar.com")
    s.add("foo@bar.com")
    assert_equal ["foo@bar.com"], s.addresses
    assert_equal [], s.domains
  end

  def test_add_at_prefixed_string_becomes_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("@Chase.com")
    assert_equal [], s.addresses
    assert_equal ["chase.com"], s.domains
  end

  def test_add_domain_only_becomes_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add_domain("Stripe.com")
    assert_equal ["stripe.com"], s.domains
  end

  def test_remove_strips_address_or_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("a@x.com")
    s.add_domain("y.com")
    s.remove("a@x.com")
    s.remove("@y.com")
    assert_equal [], s.addresses
    assert_equal [], s.domains
  end

  def test_save_and_reload_roundtrip
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("a@x.com")
    s.add_domain("y.com")
    s.filter_id = "FID123"
    s.save

    s2 = EmailCleaner::AutoReadState.new(path: @path)
    assert_equal ["a@x.com"], s2.addresses
    assert_equal ["y.com"], s2.domains
    assert_equal "FID123", s2.filter_id
  end

  def test_empty_returns_true_when_no_addresses_or_domains
    s = EmailCleaner::AutoReadState.new(path: @path)
    assert s.empty?
    s.add("a@x.com")
    refute s.empty?
  end
end
```

- [ ] **Step 2: Run tests, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/auto_read_state_test.rb`
Expected: `LoadError` or `NameError` — file doesn't exist.

- [ ] **Step 3: Implement `auto_read_state.rb`**

```ruby
# lib/email_cleaner/auto_read_state.rb
# frozen_string_literal: true

require "yaml"
require "fileutils"

module EmailCleaner
  # Local source of truth for the managed auto-read Gmail filter.
  # Addresses are full email addresses; domains are bare hostnames
  # (no leading @). Both are stored lowercased and deduped.
  class AutoReadState
    attr_accessor :filter_id

    def initialize(path:)
      @path = path
      data = load_or_init
      @addresses = data["addresses"] || []
      @domains   = data["domains"]   || []
      @filter_id = data["filter_id"]
    end

    def addresses = @addresses.dup
    def domains   = @domains.dup
    def empty?    = @addresses.empty? && @domains.empty?

    # Accepts "a@x.com" (address), "@x.com" (domain), and routes accordingly.
    def add(entry)
      e = entry.to_s.strip.downcase
      if e.start_with?("@")
        add_domain(e[1..])
      else
        @addresses << e unless @addresses.include?(e)
      end
    end

    def add_domain(domain)
      d = domain.to_s.strip.downcase.sub(/\A@/, "")
      @domains << d unless @domains.include?(d)
    end

    def remove(entry)
      e = entry.to_s.strip.downcase
      if e.start_with?("@")
        @domains.delete(e[1..])
      else
        @addresses.delete(e)
      end
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(
          "filter_id" => @filter_id,
          "addresses" => @addresses,
          "domains"   => @domains
        ))
      end
    end

    private

    def load_or_init
      return {} unless File.exist?(@path)

      YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false) || {}
    end
  end
end
```

- [ ] **Step 4: Run tests, expect pass**

Run: `bundle exec ruby -Ilib -Itest test/auto_read_state_test.rb`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/auto_read_state.rb test/auto_read_state_test.rb
git commit -m "feat: AutoReadState local source-of-truth for auto-read senders"
```

---

## Task 2: Config paths

**Files:**
- Modify: `lib/email_cleaner/config.rb`
- Test: `test/config_test.rb`

- [ ] **Step 1: Add failing test**

Append to `test/config_test.rb`:

```ruby
  def test_auto_read_path
    c = EmailCleaner::Config.new(root: "/tmp/foo")
    assert_equal "/tmp/foo/auto_read.yaml", c.auto_read_path
  end

  def test_triage_progress_path
    c = EmailCleaner::Config.new(root: "/tmp/foo")
    assert_equal "/tmp/foo/triage_progress.yaml", c.triage_progress_path
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/config_test.rb`
Expected: NoMethodError on `auto_read_path` / `triage_progress_path`.

- [ ] **Step 3: Add methods to `Config`**

In `lib/email_cleaner/config.rb`, after `def triage_log_path`:

```ruby
    def auto_read_path        = File.join(@root, "auto_read.yaml")
    def triage_progress_path  = File.join(@root, "triage_progress.yaml")
```

- [ ] **Step 4: Run, expect pass**

Run: `bundle exec ruby -Ilib -Itest test/config_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/config.rb test/config_test.rb
git commit -m "feat: add auto_read_path and triage_progress_path to Config"
```

---

## Task 3: GmailFilter — query builder + API wrapper

**Files:**
- Create: `lib/email_cleaner/gmail_filter.rb`
- Test: `test/gmail_filter_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# test/gmail_filter_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "email_cleaner/gmail_filter"

class GmailFilterTest < Minitest::Test
  def test_build_query_addresses_only
    q = EmailCleaner::GmailFilter.build_query(addresses: ["a@x.com", "b@y.com"], domains: [])
    assert_equal "from:(a@x.com OR b@y.com)", q
  end

  def test_build_query_domains_only
    q = EmailCleaner::GmailFilter.build_query(addresses: [], domains: ["x.com", "y.com"])
    assert_equal "from:(@x.com OR @y.com)", q
  end

  def test_build_query_mixed
    q = EmailCleaner::GmailFilter.build_query(addresses: ["a@x.com"], domains: ["y.com"])
    assert_equal "from:(a@x.com OR @y.com)", q
  end

  def test_build_query_empty_raises
    assert_raises(EmailCleaner::GmailFilter::EmptyError) do
      EmailCleaner::GmailFilter.build_query(addresses: [], domains: [])
    end
  end

  def test_build_query_too_long_raises
    many = (1..400).map { |i| "user#{i}@somelongdomain.example.com" }
    err = assert_raises(EmailCleaner::GmailFilter::TooLongError) do
      EmailCleaner::GmailFilter.build_query(addresses: many, domains: [])
    end
    assert_match(/exceeds/i, err.message)
  end

  def test_create_calls_filters_create
    svc = Minitest::Mock.new
    expected = Google::Apis::GmailV1::Filter.new(
      criteria: Google::Apis::GmailV1::FilterCriteria.new(query: "from:(a@x.com)"),
      action:   Google::Apis::GmailV1::FilterAction.new(remove_label_ids: ["UNREAD"])
    )
    returned = Google::Apis::GmailV1::Filter.new(id: "FID1")
    svc.expect(:create_user_setting_filter, returned) do |user, filter|
      user == "me" &&
        filter.criteria.query == expected.criteria.query &&
        filter.action.remove_label_ids == ["UNREAD"]
    end

    gf = EmailCleaner::GmailFilter.new(service: svc)
    id = gf.create(query: "from:(a@x.com)")
    assert_equal "FID1", id
    svc.verify
  end

  def test_delete_calls_filters_delete
    svc = Minitest::Mock.new
    svc.expect(:delete_user_setting_filter, nil, ["me", "FID1"])
    gf = EmailCleaner::GmailFilter.new(service: svc)
    gf.delete(id: "FID1")
    svc.verify
  end

  def test_delete_swallows_404
    svc = Object.new
    def svc.delete_user_setting_filter(_user, _id)
      raise Google::Apis::ClientError.new("not found", status_code: 404)
    end
    gf = EmailCleaner::GmailFilter.new(service: svc)
    assert_equal :not_found, gf.delete(id: "FID1")
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/gmail_filter_test.rb`
Expected: LoadError on `email_cleaner/gmail_filter`.

- [ ] **Step 3: Implement `gmail_filter.rb`**

```ruby
# lib/email_cleaner/gmail_filter.rb
# frozen_string_literal: true

require "google/apis/gmail_v1"

module EmailCleaner
  # Thin wrapper around users.settings.filters plus the query builder
  # used to compose the managed auto-read filter from a list of
  # addresses and domains. Filters are immutable in the Gmail API, so
  # "updating" means delete + create.
  class GmailFilter
    MAX_QUERY_LENGTH = 1500

    class EmptyError   < StandardError; end
    class TooLongError < StandardError; end

    def self.build_query(addresses:, domains:)
      parts = addresses.map(&:to_s) + domains.map { |d| "@#{d}" }
      raise EmptyError, "no addresses or domains" if parts.empty?

      query = "from:(#{parts.join(' OR ')})"
      if query.length > MAX_QUERY_LENGTH
        raise TooLongError, "query length #{query.length} exceeds #{MAX_QUERY_LENGTH} (entries: #{parts.size})"
      end

      query
    end

    def initialize(service:)
      @service = service
    end

    def create(query:)
      filter = Google::Apis::GmailV1::Filter.new(
        criteria: Google::Apis::GmailV1::FilterCriteria.new(query: query),
        action:   Google::Apis::GmailV1::FilterAction.new(remove_label_ids: ["UNREAD"])
      )
      @service.create_user_setting_filter("me", filter).id
    end

    # Returns :ok on success, :not_found if the filter id was already
    # gone server-side (manual deletion or stale id from a half-failed
    # prior sync).
    def delete(id:)
      @service.delete_user_setting_filter("me", id)
      :ok
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404

      :not_found
    end
  end
end
```

- [ ] **Step 4: Run, expect pass**

Run: `bundle exec ruby -Ilib -Itest test/gmail_filter_test.rb`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/gmail_filter.rb test/gmail_filter_test.rb
git commit -m "feat: GmailFilter wrapper + query builder for managed auto-read filter"
```

---

## Task 4: Auth scope + AutoReadCommand

**Files:**
- Modify: `lib/email_cleaner/auth.rb`
- Create: `lib/email_cleaner/auto_read_command.rb`
- Test: `test/auto_read_command_test.rb`

- [ ] **Step 1: Add the gmail.settings.basic scope**

In `lib/email_cleaner/auth.rb`, change `SCOPES`:

```ruby
    SCOPES = [
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.send",
      "https://www.googleapis.com/auth/gmail.modify",
      "https://www.googleapis.com/auth/gmail.settings.basic"
    ].freeze
```

- [ ] **Step 2: Write failing tests for AutoReadCommand**

```ruby
# test/auto_read_command_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "email_cleaner/auto_read_command"
require "email_cleaner/auto_read_state"

class AutoReadCommandTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "auto_read.yaml")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  # Captures GmailFilter calls without hitting any service.
  class FakeFilter
    attr_reader :created_with, :deleted_ids
    def initialize(create_returns: "FID-NEW", delete_result: :ok)
      @create_returns = create_returns
      @delete_result  = delete_result
      @created_with   = []
      @deleted_ids    = []
    end
    def create(query:)
      @created_with << query
      @create_returns
    end
    def delete(id:)
      @deleted_ids << id
      @delete_result
    end
  end

  def state
    EmailCleaner::AutoReadState.new(path: @path)
  end

  def test_add_persists_address
    out = StringIO.new
    rc = EmailCleaner::AutoReadCommand.run(
      argv: ["add", "a@x.com"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_equal 0, rc
    assert_equal ["a@x.com"], state.addresses
  end

  def test_add_persists_domain
    EmailCleaner::AutoReadCommand.run(
      argv: ["add", "@chase.com"], state_path: @path, gmail_filter: FakeFilter.new, io: StringIO.new
    )
    assert_equal ["chase.com"], state.domains
  end

  def test_remove_persists
    s = state; s.add("a@x.com"); s.save
    EmailCleaner::AutoReadCommand.run(
      argv: ["remove", "a@x.com"], state_path: @path, gmail_filter: FakeFilter.new, io: StringIO.new
    )
    assert_equal [], state.addresses
  end

  def test_list_prints_entries
    s = state; s.add("a@x.com"); s.add_domain("y.com"); s.save
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["list"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_match(/a@x\.com/, out.string)
    assert_match(/@y\.com/,  out.string)
  end

  def test_sync_creates_when_no_prior_filter
    s = state; s.add("a@x.com"); s.save
    ff = FakeFilter.new(create_returns: "FID-1")
    rc = EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal 0, rc
    assert_equal ["from:(a@x.com)"], ff.created_with
    assert_empty ff.deleted_ids
    assert_equal "FID-1", state.filter_id
  end

  def test_sync_deletes_then_creates_when_filter_id_present
    s = state; s.add("a@x.com"); s.filter_id = "FID-OLD"; s.save
    ff = FakeFilter.new(create_returns: "FID-NEW")
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal ["FID-OLD"], ff.deleted_ids
    assert_equal ["from:(a@x.com)"], ff.created_with
    assert_equal "FID-NEW", state.filter_id
  end

  def test_sync_warns_on_stale_filter_id_and_creates
    s = state; s.add("a@x.com"); s.filter_id = "STALE"; s.save
    ff = FakeFilter.new(delete_result: :not_found, create_returns: "FID-NEW")
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: out
    )
    assert_match(/already gone|not found/i, out.string)
    assert_equal "FID-NEW", state.filter_id
  end

  def test_sync_with_empty_list_deletes_filter_and_clears_id
    s = state; s.filter_id = "FID-OLD"; s.save
    ff = FakeFilter.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal ["FID-OLD"], ff.deleted_ids
    assert_empty ff.created_with
    assert_nil state.filter_id
  end

  def test_sync_with_empty_list_and_no_filter_is_noop
    ff = FakeFilter.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_empty ff.deleted_ids
    assert_empty ff.created_with
  end

  def test_status_prints_count_and_filter_id
    s = state; s.add("a@x.com"); s.add_domain("y.com"); s.filter_id = "FID-1"; s.save
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["status"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_match(/1 address/, out.string)
    assert_match(/1 domain/,  out.string)
    assert_match(/FID-1/,     out.string)
  end
end
```

- [ ] **Step 3: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/auto_read_command_test.rb`
Expected: LoadError on `auto_read_command`.

- [ ] **Step 4: Implement `auto_read_command.rb`**

```ruby
# lib/email_cleaner/auto_read_command.rb
# frozen_string_literal: true

require_relative "auto_read_state"
require_relative "gmail_filter"
require_relative "pretty"

module EmailCleaner
  # Subcommand: email_cleaner auto-read [list|add|remove|sync|status] ...
  #
  # The local YAML at config.auto_read_path is the source of truth.
  # `sync` reconciles it to a single managed Gmail filter (delete the
  # prior one, create a fresh one with the current query, save id).
  module AutoReadCommand
    module_function

    USAGE = <<~USAGE
      Usage:
        email_cleaner auto-read list
        email_cleaner auto-read add    <addr|@domain>
        email_cleaner auto-read remove <addr|@domain>
        email_cleaner auto-read sync
        email_cleaner auto-read status
    USAGE

    def run(argv:, state_path:, gmail_filter:, io: $stdout)
      verb = argv.shift
      state = AutoReadState.new(path: state_path)

      case verb
      when "list"   then run_list(state, io)
      when "add"    then run_add(state, argv, io)
      when "remove" then run_remove(state, argv, io)
      when "sync"   then run_sync(state, gmail_filter, io)
      when "status" then run_status(state, io)
      else
        io.puts USAGE
        2
      end
    end

    def run_list(state, io)
      state.addresses.each { |a| io.puts a }
      state.domains.each   { |d| io.puts "@#{d}" }
      0
    end

    def run_add(state, argv, io)
      entry = argv.shift
      return missing_arg(io) if entry.nil? || entry.empty?

      state.add(entry)
      state.save
      io.puts "added: #{entry.downcase}"
      io.puts Pretty.dim("run `auto-read sync` to apply to Gmail")
      0
    end

    def run_remove(state, argv, io)
      entry = argv.shift
      return missing_arg(io) if entry.nil? || entry.empty?

      state.remove(entry)
      state.save
      io.puts "removed: #{entry.downcase}"
      io.puts Pretty.dim("run `auto-read sync` to apply to Gmail")
      0
    end

    def run_status(state, io)
      io.puts "#{state.addresses.size} address(es), #{state.domains.size} domain(s)"
      io.puts "filter_id: #{state.filter_id || '(none)'}"
      0
    end

    def run_sync(state, gmail_filter, io)
      if state.empty?
        if state.filter_id
          gmail_filter.delete(id: state.filter_id)
          io.puts "deleted managed filter #{state.filter_id} (list is empty)"
          state.filter_id = nil
          state.save
        else
          io.puts "nothing to sync (list is empty, no managed filter)"
        end
        return 0
      end

      query = GmailFilter.build_query(addresses: state.addresses, domains: state.domains)

      if state.filter_id
        result = gmail_filter.delete(id: state.filter_id)
        io.puts "warning: prior filter #{state.filter_id} already gone server-side" if result == :not_found
      end

      new_id = gmail_filter.create(query: query)
      state.filter_id = new_id
      state.save
      io.puts "synced: filter #{new_id} (#{state.addresses.size} address(es), #{state.domains.size} domain(s))"
      0
    rescue GmailFilter::TooLongError => e
      io.puts "error: #{e.message}"
      io.puts "split the list or remove some entries; multi-filter splitting is not supported."
      1
    end

    def missing_arg(io)
      io.puts "missing <addr|@domain>"
      io.puts USAGE
      2
    end
  end
end
```

- [ ] **Step 5: Run, expect pass**

Run: `bundle exec ruby -Ilib -Itest test/auto_read_command_test.rb`
Expected: 10 tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/email_cleaner/auth.rb lib/email_cleaner/auto_read_command.rb test/auto_read_command_test.rb
git commit -m "feat: auto-read subcommand (list/add/remove/sync/status) + settings.basic scope"
```

---

## Task 5: Triage `r`/`R` keys

**Files:**
- Modify: `lib/email_cleaner/triage_command.rb`
- Modify: `test/triage_command_test.rb`

- [ ] **Step 1: Add failing tests**

Append to `test/triage_command_test.rb` (before final `end`):

```ruby
  def test_r_marks_address_as_auto_read_no_gmail_call
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    auto_read_path = File.join(@tmp, "auto_read.yaml")
    out = StringIO.new
    rc = EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      auto_read_path: auto_read_path,
      io: out, stdin: StringIO.new("r\nq\n"), progress: StringIO.new
    )
    assert_equal 0, rc
    saved = EmailCleaner::AutoReadState.new(path: auto_read_path)
    assert_equal ["a@x.com"], saved.addresses
    assert_empty saved.domains
    assert_empty svc.batch_calls # no trash
    assert_match(/triage\tauto_read_addr\ta@x\.com/, File.read(@log))
  end

  def test_R_marks_domain_as_auto_read
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    auto_read_path = File.join(@tmp, "auto_read.yaml")
    rc = EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      auto_read_path: auto_read_path,
      io: StringIO.new, stdin: StringIO.new("R\nq\n"), progress: StringIO.new
    )
    assert_equal 0, rc
    saved = EmailCleaner::AutoReadState.new(path: auto_read_path)
    assert_equal ["x.com"], saved.domains
    assert_empty saved.addresses
    assert_match(/triage\tauto_read_domain\tx\.com/, File.read(@log))
  end
```

Update existing `run_triage` helper in this test file to pass an auto_read_path so other tests still work:

```ruby
  def run_triage(svc, stdin_input)
    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      auto_read_path: File.join(@tmp, "auto_read.yaml"),
      io: StringIO.new, stdin: StringIO.new(stdin_input), progress: StringIO.new
    )
  end
```

Also add `require "email_cleaner/auto_read_state"` near the top.

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/triage_command_test.rb`
Expected: failures because `r`/`R` are unrecognized + ArgumentError on `auto_read_path:`.

- [ ] **Step 3: Update `triage_command.rb`**

At top of file, add:

```ruby
require_relative "auto_read_state"
```

Change `run` signature:

```ruby
    def run(options:, gmail_service:, state:, log_path:, auto_read_path:, io: $stdout, stdin: $stdin, progress: $stderr)
```

Open `AutoReadState` once for the session (right after `snapshot.empty?` early-return):

```ruby
      auto_read = AutoReadState.new(path: auto_read_path)
```

Update the `prompt_and_act` call to pass it:

```ruby
          choice, trashed_this_step = prompt_and_act(stats, gmail_service, state, auto_read, log, io, stdin, progress)
```

Update `prompt_and_act` signature and add `r`/`R` cases:

```ruby
    def prompt_and_act(stats, gmail, state, auto_read, log, io, stdin, progress)
      loop do
        io.print Pretty.cyan("[u/m/k/t/s/r/R/q/?]") + " > "
        answer = stdin.gets || "q"
        answer_raw = answer.strip
        answer = answer_raw.downcase

        case answer_raw
        when "R"
          handle_auto_read_domain(stats, auto_read, log, io); return [:auto_read, 0]
        end

        case answer
        when "u"         then return [:unsub, handle_unsub_and_trash(stats, gmail, state, log, io, progress)]
        when "m"         then return [:done,  handle_mark_done(stats, gmail, state, log, io, progress)]
        when "k"         then handle_keep(stats, state, log, io); return [:keep, 0]
        when "t"         then return [:trash, trash_backlog(stats, gmail, log, io, progress)]
        when "s"         then handle_skip(stats, log, io); return [:skip, 0]
        when "r"         then handle_auto_read_addr(stats, auto_read, log, io); return [:auto_read, 0]
        when "q", ""     then handle_quit(log, io); return [:quit, 0]
        when "?", "help" then print_help(io)
        else
          io.puts "  " + Pretty.dim("unrecognized: '#{answer_raw}' — type ? for help")
        end
      end
    end
```

Add handlers:

```ruby
    def handle_auto_read_addr(stats, auto_read, log, io)
      addr = stats.sender.address
      auto_read.add(addr)
      auto_read.save
      log.write("auto_read_addr", addr, "ok")
      io.puts "  " + Pretty.green("auto-read: #{addr} (run `auto-read sync` to apply)")
    end

    def handle_auto_read_domain(stats, auto_read, log, io)
      addr = stats.sender.address
      domain = addr.split("@", 2).last.to_s.downcase
      auto_read.add_domain(domain)
      auto_read.save
      log.write("auto_read_domain", domain, "ok")
      io.puts "  " + Pretty.green("auto-read domain: @#{domain} (run `auto-read sync` to apply)")
    end
```

Add `:auto_read` to the decisions hash:

```ruby
      decisions = { unsub: [], done: [], keep: [], trash: [], skip: [], auto_read: [] }
```

Add to recap headings constant:

```ruby
    RECAP_HEADINGS = {
      unsub:     "Unsubscribed",
      done:      "Marked done",
      keep:      "Kept",
      trash:     "Trashed only",
      skip:      "Skipped",
      auto_read: "Marked auto-read"
    }.freeze
```

Update `format_tally`:

```ruby
    def format_tally(decisions)
      [
        "#{decisions[:unsub].size} unsub",
        "#{decisions[:done].size} done",
        "#{decisions[:keep].size} keep",
        "#{decisions[:trash].size} trash",
        "#{decisions[:skip].size} skip",
        "#{decisions[:auto_read].size} auto-read"
      ].join(", ")
    end
```

Update `print_help`:

```ruby
    def print_help(io)
      io.puts <<~HELP.gsub(/^/, "  ")
        #{Pretty.bold('u')} — unsubscribe + trash backlog
        #{Pretty.bold('m')} — mark done (open URL in browser, record as manually unsubscribed, trash backlog)
        #{Pretty.bold('k')} — keep #{EmailCleaner::DEFAULT_KEEP_DAYS}d (auto-resurfaces after that)
        #{Pretty.bold('t')} — trash backlog only (no state change)
        #{Pretty.bold('s')} — skip (no state change, reappears next run)
        #{Pretty.bold('r')} — auto-read this address (local only; run `auto-read sync` to apply)
        #{Pretty.bold('R')} — auto-read whole domain (local only; run `auto-read sync` to apply)
        #{Pretty.bold('q')} — quit (state is saved)
      HELP
    end
```

- [ ] **Step 4: Run all tests, expect pass**

Run: `bundle exec rake test` (or `bundle exec ruby -Ilib -Itest test/triage_command_test.rb`)
Expected: all triage tests pass, including new `r`/`R` tests.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/triage_command.rb test/triage_command_test.rb
git commit -m "feat: triage r/R keys mark sender address/domain as auto-read"
```

---

## Task 6: TriageProgress — chunk resumption state

**Files:**
- Create: `lib/email_cleaner/triage_progress.rb`
- Test: `test/triage_progress_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# test/triage_progress_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "date"
require "email_cleaner/triage_progress"

class TriageProgressTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "triage_progress.yaml")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_chunks_for_30_day_window_with_chunk_7
    today = Date.new(2026, 5, 6)
    chunks = EmailCleaner::TriageProgress.chunks(days: 30, chunk: 7, today: today)
    # newest first, last chunk truncated to total window
    assert_equal Date.new(2026, 4, 29), chunks.first[:from]
    assert_equal today,                 chunks.first[:to]
    assert_equal Date.new(2026, 4, 6),  chunks.last[:from]
    assert_equal 5, chunks.size # 7+7+7+7+2
  end

  def test_chunks_when_days_le_chunk_returns_single_window
    today = Date.new(2026, 5, 6)
    chunks = EmailCleaner::TriageProgress.chunks(days: 5, chunk: 7, today: today)
    assert_equal 1, chunks.size
    assert_equal Date.new(2026, 5, 1), chunks.first[:from]
  end

  def test_load_returns_nil_when_missing
    p = EmailCleaner::TriageProgress.new(path: @path)
    assert_nil p.last_completed_chunk_end
  end

  def test_record_and_reload
    p = EmailCleaner::TriageProgress.new(path: @path)
    p.record_completed(Date.new(2026, 4, 29))
    p2 = EmailCleaner::TriageProgress.new(path: @path)
    assert_equal Date.new(2026, 4, 29), p2.last_completed_chunk_end
  end

  def test_clear_removes_file
    p = EmailCleaner::TriageProgress.new(path: @path)
    p.record_completed(Date.new(2026, 4, 29))
    p.clear
    refute File.exist?(@path)
  end

  def test_remaining_chunks_skips_completed
    today = Date.new(2026, 5, 6)
    all = EmailCleaner::TriageProgress.chunks(days: 30, chunk: 7, today: today)
    remaining = EmailCleaner::TriageProgress.remaining_chunks(
      all, last_completed_end: Date.new(2026, 4, 29)
    )
    # The first chunk's `to` was 2026-05-06; last_completed_end refers
    # to the `from` boundary of the most-recently-completed chunk.
    # So if the chunk ending at 2026-04-29's `from` was just completed,
    # we should resume at the next (older) chunk.
    assert_equal Date.new(2026, 4, 22), remaining.first[:from]
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/triage_progress_test.rb`
Expected: LoadError.

- [ ] **Step 3: Implement `triage_progress.rb`**

```ruby
# lib/email_cleaner/triage_progress.rb
# frozen_string_literal: true

require "yaml"
require "fileutils"
require "date"

module EmailCleaner
  # Persists "which chunk was last completed" between runs of chunked
  # triage. Chunks are computed deterministically from (days, chunk,
  # today), newest-first. A chunk's identity is its `from` date.
  class TriageProgress
    def self.chunks(days:, chunk:, today: Date.today)
      result = []
      cursor_to = today
      remaining = days
      while remaining.positive?
        span = [chunk, remaining].min
        cursor_from = cursor_to - span
        result << { from: cursor_from, to: cursor_to }
        cursor_to = cursor_from
        remaining -= span
      end
      result
    end

    def self.remaining_chunks(all_chunks, last_completed_end:)
      return all_chunks if last_completed_end.nil?

      idx = all_chunks.index { |c| c[:from] == last_completed_end }
      return all_chunks if idx.nil?

      all_chunks[(idx + 1)..] || []
    end

    def initialize(path:)
      @path = path
      @last = load
    end

    def last_completed_chunk_end
      @last
    end

    def record_completed(from_date)
      @last = from_date
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump("last_completed_chunk_end" => from_date.to_s))
      end
    end

    def clear
      File.delete(@path) if File.exist?(@path)
      @last = nil
    end

    private

    def load
      return nil unless File.exist?(@path)

      data = YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false) || {}
      data["last_completed_chunk_end"] ? Date.parse(data["last_completed_chunk_end"]) : nil
    end
  end
end
```

- [ ] **Step 4: Run, expect pass**

Run: `bundle exec ruby -Ilib -Itest test/triage_progress_test.rb`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/triage_progress.rb test/triage_progress_test.rb
git commit -m "feat: TriageProgress for chunk resumption state"
```

---

## Task 7: Snapshot accepts custom query for chunked windows

**Files:**
- Modify: `lib/email_cleaner/snapshot.rb`

- [ ] **Step 1: Update `Snapshot.all_senders`**

Replace the existing method:

```ruby
    # `query_override` lets chunked triage pass a custom date-window
    # query (e.g. "after:2026/04/29 before:2026/05/06") instead of the
    # default newer_than:Nd.
    def all_senders(days:, gmail_service:, state:, progress:, query_override: nil)
      query = query_override || "newer_than:#{days}d"
      messages = fetch_messages(query: query,
                                gmail_service: gmail_service, progress: progress)
      stats = Aggregator.group(messages)
      stats = Aggregator.drop_singletons(stats)
      state.annotate(stats)
      stats
    end
```

- [ ] **Step 2: Run all tests, expect pass**

Run: `bundle exec rake test`
Expected: all green (existing callers don't pass `query_override`, default behavior preserved).

- [ ] **Step 3: Commit**

```bash
git add lib/email_cleaner/snapshot.rb
git commit -m "feat: Snapshot.all_senders accepts query_override for custom date windows"
```

---

## Task 8: Chunked triage driver

**Files:**
- Modify: `lib/email_cleaner/triage_command.rb`
- Modify: `test/triage_command_test.rb`

- [ ] **Step 1: Add failing test**

Append to `test/triage_command_test.rb`:

```ruby
  def test_chunked_triage_runs_per_chunk_and_records_progress
    # Two senders in different "chunks" — we don't actually slice
    # messages by date here (FakeGmailService doesn't honor it), but we
    # verify the driver makes the expected number of fetch calls and
    # writes progress between chunks.
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    progress_path = File.join(@tmp, "triage_progress.yaml")
    rc = EmailCleaner::TriageCommand.run(
      options: { days: 14, min: 3, chunk: 7 },
      gmail_service: svc, state: @state, log_path: @log,
      auto_read_path: File.join(@tmp, "auto_read.yaml"),
      triage_progress_path: progress_path,
      io: StringIO.new, stdin: StringIO.new("k\n\nk\n"),  # decide chunk1, Enter to continue, decide chunk2
      progress: StringIO.new
    )
    assert_equal 0, rc
    # progress file should be cleared after full run
    refute File.exist?(progress_path), "progress file should be cleared after completion"
  end

  def test_chunked_triage_quitting_mid_run_persists_progress
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    progress_path = File.join(@tmp, "triage_progress.yaml")
    EmailCleaner::TriageCommand.run(
      options: { days: 14, min: 3, chunk: 7 },
      gmail_service: svc, state: @state, log_path: @log,
      auto_read_path: File.join(@tmp, "auto_read.yaml"),
      triage_progress_path: progress_path,
      io: StringIO.new, stdin: StringIO.new("k\nq\n"),  # finish chunk1, quit at "continue?" prompt
      progress: StringIO.new
    )
    assert File.exist?(progress_path), "progress should persist after mid-run quit"
  end
```

Note: this test will be flaky if `chunk` isn't routed through `options`. The test relies on accepting `chunk:` and `triage_progress_path:` parameters.

- [ ] **Step 2: Run, expect failure**

Run: `bundle exec ruby -Ilib -Itest test/triage_command_test.rb -n /chunked/`
Expected: ArgumentError (unknown keyword `triage_progress_path`).

- [ ] **Step 3: Update `triage_command.rb` to support chunks**

Add `require_relative "triage_progress"` near top.

Change `run` signature:

```ruby
    def run(options:, gmail_service:, state:, log_path:, auto_read_path:,
            triage_progress_path: nil, io: $stdout, stdin: $stdin, progress: $stderr)
      chunk = options[:chunk]
      days  = options[:days]

      if chunk.nil? || chunk >= days || triage_progress_path.nil?
        run_single(options: options, gmail_service: gmail_service, state: state,
                   log_path: log_path, auto_read_path: auto_read_path,
                   query_override: nil, io: io, stdin: stdin, progress: progress)
      else
        run_chunked(options: options, gmail_service: gmail_service, state: state,
                    log_path: log_path, auto_read_path: auto_read_path,
                    triage_progress_path: triage_progress_path,
                    io: io, stdin: stdin, progress: progress)
      end
    end
```

Rename current body of `run` to `run_single`:

```ruby
    def run_single(options:, gmail_service:, state:, log_path:, auto_read_path:,
                   query_override:, io:, stdin:, progress:)
      snapshot = build_snapshot(options, gmail_service, state, progress, query_override: query_override)

      if snapshot.empty?
        io.puts "Nothing to triage. Inbox is clean (or fully decided)."
        return :empty
      end
      # ... existing body unchanged, but instead of `return 0` at the
      # quit branch, return :quit; on full completion return :done.
    end
```

(Replace the two `return 0` statements: the quit path returns `:quit`, the full-completion path returns `:done`. The `run` wrapper for the single case maps `:empty`/`:quit`/`:done` → `0`.)

Then add the chunked driver:

```ruby
    def run_chunked(options:, gmail_service:, state:, log_path:, auto_read_path:,
                    triage_progress_path:, io:, stdin:, progress:)
      tracker = TriageProgress.new(path: triage_progress_path)
      all_chunks = TriageProgress.chunks(days: options[:days], chunk: options[:chunk])
      remaining = TriageProgress.remaining_chunks(all_chunks, last_completed_end: tracker.last_completed_chunk_end)

      if remaining.empty?
        io.puts "All chunks already triaged. Clearing progress."
        tracker.clear
        return 0
      end

      total = all_chunks.size
      remaining.each_with_index do |c, i|
        position = total - remaining.size + i + 1
        io.puts Pretty.bold("=== Chunk #{position}/#{total}: #{c[:from]} … #{c[:to]} ===")

        query = "after:#{c[:from].strftime('%Y/%m/%d')} before:#{c[:to].strftime('%Y/%m/%d')}"
        chunk_opts = options.merge(days: options[:days]) # `days:` ignored when query_override set
        result = run_single(
          options: chunk_opts, gmail_service: gmail_service, state: state,
          log_path: log_path, auto_read_path: auto_read_path,
          query_override: query, io: io, stdin: stdin, progress: progress
        )

        return 0 if result == :quit

        tracker.record_completed(c[:from])

        if i < remaining.size - 1
          io.print Pretty.cyan("Chunk done. Press Enter for next chunk, q to quit > ")
          line = (stdin.gets || "q").strip.downcase
          if line == "q"
            io.puts Pretty.dim("Quit. Resume with the same command — chunk #{position} is recorded as done.")
            return 0
          end
        end
      end

      tracker.clear
      io.puts Pretty.bold("All #{total} chunks triaged.")
      0
    end
```

Update `build_snapshot` to thread `query_override`:

```ruby
    def build_snapshot(options, gmail_service, state, progress, query_override: nil)
      stats = Snapshot.all_senders(
        days: options[:days], gmail_service: gmail_service,
        state: state, progress: progress, query_override: query_override
      )
      min = options[:min] || EmailCleaner::DEFAULT_MIN_COUNT
      stats.select do |s|
        s.unsub_info &&
          s.count >= min &&
          s.state_status != :confirmed &&
          s.state_status != :kept
      end
    end
```

The single-path `run` wrapper translates symbolic returns:

```ruby
    # If you opt for a wrapper rather than refactoring run_single's
    # return type: keep run_single returning 0 and just remove the
    # symbolic returns. Either approach works — the contract that
    # matters is that run() returns an int exit code.
```

(Engineer's choice: simplest is to keep `run_single` returning `0` and have `run_chunked` detect quit by checking whether `stdin.gets` returned `"q"` directly. If you take that path, drop the symbolic returns and instead expose a "did the user quit mid-chunk" signal. **Simpler implementation:** make `run_single` return `[exit_code, :quit_mid_chunk | :ok]`.)

Pick one approach, keep it consistent. The tests above only check exit code (`rc == 0`) and progress file presence.

- [ ] **Step 4: Run all tests, expect pass**

Run: `bundle exec rake test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/email_cleaner/triage_command.rb test/triage_command_test.rb
git commit -m "feat: chunked weekly triage with resumable progress"
```

---

## Task 9: CLI wiring — auto-read subcommand + --chunk flag

**Files:**
- Modify: `lib/email_cleaner/cli.rb`

- [ ] **Step 1: Update USAGE constant**

```ruby
    USAGE = <<~USAGE
      email_cleaner — audit and clean up Gmail bulk senders

      Usage:
        email_cleaner triage      [--days N] [--min N] [--chunk N]
        email_cleaner audit       [--days N] [--actionable] [--min N] [--include-done] [--include-kept]
        email_cleaner unsubscribe <pattern> [--days N] [--yes]
        email_cleaner keep        <pattern> [--days N] [--for DAYS] [--yes]
        email_cleaner trash       <pattern> [--days N] [--yes]
        email_cleaner auto-read   list|add|remove|sync|status [args...]
        email_cleaner --help

      Pattern: substring on email address (case-insensitive),
               or "@domain.com" for exact domain match.
    USAGE
```

- [ ] **Step 2: Add require + dispatch**

At top with other requires:

```ruby
require_relative "auto_read_command"
require_relative "gmail_filter"
```

In the case statement:

```ruby
      when "auto-read"    then run_auto_read(argv)
```

- [ ] **Step 3: Add `--chunk` to triage and pass auto_read_path/progress**

Replace `run_triage`:

```ruby
    def run_triage(argv)
      opts, _ = parse_options(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, min: EmailCleaner::DEFAULT_MIN_COUNT, chunk: nil },
        "Usage: email_cleaner triage [options]"
      ) do |o, opts|
        o.on("--days N",  Integer) { |n| opts[:days]  = n }
        o.on("--min N",   Integer) { |n| opts[:min]   = n }
        o.on("--chunk N", Integer) { |n| opts[:chunk] = n }
      end

      config, service, state = build_context
      TriageCommand.run(
        options: opts, gmail_service: service, state: state,
        log_path: config.triage_log_path,
        auto_read_path: config.auto_read_path,
        triage_progress_path: config.triage_progress_path
      )
    end
```

- [ ] **Step 4: Add `run_auto_read`**

```ruby
    def run_auto_read(argv)
      config, service, _ = build_context
      gmail_filter = GmailFilter.new(service: service)
      AutoReadCommand.run(
        argv: argv,
        state_path: config.auto_read_path,
        gmail_filter: gmail_filter
      )
    end
```

- [ ] **Step 5: Run full test suite**

Run: `bundle exec rake test`
Expected: all green.

- [ ] **Step 6: Smoke check the CLI**

Run: `bundle exec ruby bin/email_cleaner --help`
Expected: USAGE prints, includes `auto-read` line and `--chunk N` for triage.

Run: `bundle exec ruby bin/email_cleaner auto-read` (with no verb)
Expected: prints AutoReadCommand USAGE and exits 2.

- [ ] **Step 7: Commit**

```bash
git add lib/email_cleaner/cli.rb
git commit -m "feat: wire auto-read subcommand and --chunk flag in CLI"
```

---

## Task 10: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a section documenting `auto-read` and `--chunk`**

Add under existing usage docs:

```markdown
### Auto-read senders

Senders you want to keep receiving but never see as unread (statements,
receipts, low-priority notifications). Triage them once with `r` (this
address) or `R` (whole domain), then sync to Gmail:

    email_cleaner auto-read list
    email_cleaner auto-read add a@x.com
    email_cleaner auto-read add @chase.com
    email_cleaner auto-read remove @chase.com
    email_cleaner auto-read sync     # creates/updates the managed Gmail filter
    email_cleaner auto-read status

The local list at `auto_read.yaml` is the source of truth. `sync`
reconciles it to a single managed Gmail filter (delete + recreate,
since Gmail filters are immutable).

### Chunked triage for long windows

For backfills (e.g. 90 days), break the window into resumable weekly
chunks:

    email_cleaner triage --days 90 --chunk 7

Between chunks you'll get a "press Enter to continue, q to quit"
prompt. Quitting persists progress to `triage_progress.yaml`; rerun
the same command to resume.

### Re-authorization note

This release adds the `gmail.settings.basic` OAuth scope (required for
filter creation). If you're upgrading, delete `token.yaml` and re-run
any command — you'll be prompted to re-authorize once.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document auto-read subcommand, chunked triage, and re-auth"
```

---

## Self-Review Checklist

- [x] Spec coverage:
  - Local YAML source-of-truth → Task 1 (AutoReadState).
  - Filter wrapper + query builder → Task 3.
  - Auth scope → Task 4 step 1.
  - Subcommand verbs (list/add/remove/sync/status) → Task 4.
  - Empty-list deletes filter → Task 4 (`test_sync_with_empty_list_deletes_filter_and_clears_id`).
  - Stale id (404) → Task 3 + Task 4 tests.
  - Mid-flight failure recovery via "delete then create, only clear id on success" → Task 4 `run_sync` body.
  - Query length cap → Task 3 (`test_build_query_too_long_raises`).
  - Triage `r`/`R` keys → Task 5.
  - 90-day chunked triage with resumption → Tasks 6, 7, 8.
  - CLI wiring → Task 9.
  - Tests for all of the above.

- [x] No placeholders. Code blocks present for every code step.
- [x] Type/name consistency: `AutoReadState`, `GmailFilter`, `AutoReadCommand`, `TriageProgress` used uniformly. `auto_read_path` (state), `triage_progress_path` (chunk progress) used consistently across Config / TriageCommand / CLI.

One known judgment call in Task 8: the implementation style of `run_single`'s "did the user quit mid-chunk" signal is left to the engineer (symbolic return value vs. explicit struct vs. tracking `:quit` via a side channel). Tests only assert exit code and progress file presence, so any consistent internal contract works.

---

Plan complete and saved to [docs/superpowers/plans/2026-05-06-auto-read-filter.md](2026-05-06-auto-read-filter.md).
