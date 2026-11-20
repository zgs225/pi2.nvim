# Bad (fixture)

Both directions of the G19 drift, one finding each:

* `---@field timeout integer` is **required** but has no `timeout` key in
  `defaults`, so `vim.tbl_deep_extend("force", defaults, opts)` has nothing to
  merge and the option ships permanently disabled.
* `retries = 3` sits in `defaults` but no `---@field` declares it, so it is
  invisible in the documented defaults block and gets no completion.

Expected: 2 findings.
