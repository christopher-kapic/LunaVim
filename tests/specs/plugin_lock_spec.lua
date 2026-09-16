describe("plugin_lock", function()
  local plugin_lock

  before_each(function()
    package.loaded["lvim.core.plugin_lock"] = nil
    plugin_lock = require("lvim.core.plugin_lock")
  end)

  it("treats github ssh and https remotes as the same repo", function()
    assert.is_true(
      plugin_lock.urls_match("git@github.com:echasnovski/mini.nvim.git", "https://github.com/echasnovski/mini.nvim")
    )
    assert.is_false(
      plugin_lock.urls_match("https://github.com/echasnovski/mini.nvim", "https://github.com/echasnovski/mini.comment")
    )
  end)

  it("rewrites lockfile pins whose on-disk origin no longer matches the spec URL", function()
    local lock = {
      comment = { branch = "main", commit = "oldcomment" },
      autopairs = { branch = "main", commit = "oldpairs" },
      telescope = { branch = "master", commit = "keepme" },
    }
    local snapshot = {
      comment = { branch = "main", commit = "newcomment" },
      autopairs = { branch = "main", commit = "newpairs" },
      telescope = { branch = "master", commit = "snaptele" },
    }
    local installed = {
      comment = {
        spec_url = "https://github.com/echasnovski/mini.comment.git",
        origin = "https://github.com/echasnovski/mini.nvim.git",
      },
      autopairs = {
        spec_url = "https://github.com/echasnovski/mini.pairs.git",
        origin = "https://github.com/saghen/blink.pairs.git",
      },
      telescope = {
        spec_url = "https://github.com/nvim-telescope/telescope.nvim.git",
        origin = "https://github.com/nvim-telescope/telescope.nvim.git",
      },
    }

    local next_lock, rewritten = plugin_lock.rebase_stale_pins(lock, snapshot, installed)

    assert.same({ "autopairs", "comment" }, rewritten)
    assert.equals("newcomment", next_lock.comment.commit)
    assert.equals("newpairs", next_lock.autopairs.commit)
    assert.equals("keepme", next_lock.telescope.commit)
    assert.equals("oldcomment", lock.comment.commit)
  end)

  it("drops a stale pin when the snapshot has no replacement", function()
    local next_lock, rewritten = plugin_lock.rebase_stale_pins({
      leftover = { branch = "main", commit = "abc" },
    }, {}, {
      leftover = {
        spec_url = "https://github.com/example/new.git",
        origin = "https://github.com/example/old.git",
      },
    })

    assert.same({ "leftover" }, rewritten)
    assert.is_nil(next_lock.leftover)
  end)

  it("leaves pins alone when origin is missing or already matches", function()
    local lock = {
      missing = { branch = "main", commit = "abc" },
      matching = { branch = "main", commit = "def" },
    }
    local next_lock, rewritten = plugin_lock.rebase_stale_pins(lock, {
      missing = { branch = "main", commit = "snap" },
      matching = { branch = "main", commit = "snap" },
    }, {
      missing = { spec_url = "https://github.com/example/x.git", origin = nil },
      matching = {
        spec_url = "https://github.com/example/x.git",
        origin = "https://github.com/example/x.git",
      },
    })

    assert.same({}, rewritten)
    assert.equals("abc", next_lock.missing.commit)
    assert.equals("def", next_lock.matching.commit)
  end)

  it("reads remote.origin.url from a checkout's git config", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.git", "p")
    local fd = assert(io.open(dir .. "/.git/config", "w"))
    fd:write(
      '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://github.com/echasnovski/mini.nvim.git\n'
    )
    fd:close()

    assert.equals("https://github.com/echasnovski/mini.nvim.git", plugin_lock.read_origin(dir))
    assert.is_true(plugin_lock.plugin_origin_mismatches({
      dir = dir,
      url = "https://github.com/echasnovski/mini.comment.git",
    }))
    assert.is_false(plugin_lock.plugin_origin_mismatches({
      dir = dir,
      url = "https://github.com/echasnovski/mini.nvim.git",
    }))
  end)

  it("only treats paths as under the lazy root when they are real subdirectories", function()
    assert.is_true(plugin_lock.is_under_root("/home/x/lazy/autopairs", "/home/x/lazy"))
    assert.is_false(plugin_lock.is_under_root("/home/x/lazy", "/home/x/lazy"))
    assert.is_false(plugin_lock.is_under_root("/home/x/lazyevil/autopairs", "/home/x/lazy"))
    assert.is_false(plugin_lock.is_under_root("", "/home/x/lazy"))
  end)

  it("lists origin-mismatched plugins that live under the lazy root", function()
    local root = vim.fn.tempname()
    local dir = root .. "/autopairs"
    vim.fn.mkdir(dir .. "/.git", "p")
    local fd = assert(io.open(dir .. "/.git/config", "w"))
    fd:write('[remote "origin"]\n\turl = https://github.com/saghen/blink.pairs.git\n')
    fd:close()

    local found = plugin_lock.list_mismatched({
      {
        name = "autopairs",
        dir = dir,
        url = "https://github.com/echasnovski/mini.pairs.git",
      },
      {
        name = "outside",
        dir = "/tmp/not-under-root/autopairs",
        url = "https://github.com/echasnovski/mini.pairs.git",
      },
    }, root)

    assert.equals(1, #found)
    assert.equals("autopairs", found[1].name)
    assert.equals(dir, found[1].dir)
  end)

  it("applies snapshot pins only for failed checkouts whose lock commit differs", function()
    local lock = {
      autopairs = { branch = "main", commit = "oldpairs" },
      comment = { branch = "main", commit = "same" },
      telescope = { branch = "master", commit = "userpin" },
    }
    local snapshot = {
      autopairs = { branch = "main", commit = "newpairs" },
      comment = { branch = "main", commit = "same" },
      telescope = { branch = "master", commit = "snappin" },
    }

    local next_lock, applied = plugin_lock.pins_for_failed_checkouts(lock, snapshot, { "autopairs", "comment" })

    assert.same({ "autopairs" }, applied)
    assert.equals("newpairs", next_lock.autopairs.commit)
    assert.equals("same", next_lock.comment.commit)
    assert.equals("userpin", next_lock.telescope.commit)
  end)

  it("does not treat pin-differs-from-snapshot as a URL change without a failure", function()
    local next_lock, applied = plugin_lock.pins_for_failed_checkouts({
      telescope = { branch = "master", commit = "userpin" },
    }, {
      telescope = { branch = "master", commit = "snappin" },
    }, {})

    assert.same({}, applied)
    assert.equals("userpin", next_lock.telescope.commit)
  end)

  it("reports only error tasks that appeared after the before snapshot", function()
    local old_task = {}
    local new_task = {}
    local before = { [old_task] = "autopairs" }
    local after = { [old_task] = "autopairs", [new_task] = "comment" }
    assert.same({ "comment" }, plugin_lock.new_error_names(before, after))
    assert.same({}, plugin_lock.new_error_names(before, before))
  end)

  it("encodes a lockfile with sorted names", function()
    local encoded = plugin_lock.encode({
      zed = { branch = "main", commit = "z" },
      alpha = { branch = "master", commit = "a" },
    })
    assert.equals(
      '{\n  "alpha": { "branch": "master", "commit": "a" },\n  "zed": { "branch": "main", "commit": "z" }\n}\n',
      encoded
    )
  end)
end)
